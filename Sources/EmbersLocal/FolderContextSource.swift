import Foundation
import EmbersCore

public enum FolderSourceError: LocalizedError {
    case unavailable(URL)
    case enumerationFailed(URL, Error)
    case fileReadFailed(URL, Error)
    case manifestBytesLimitExceeded(limit: Int)
    case fileCountLimitExceeded(limit: Int)
    case totalParsedBytesLimitExceeded(limit: Int)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let url): return "The selected folder is unavailable: \(url.path)"
        case .enumerationFailed(let url, let error): return "Could not fully inspect the selected folder near \(url.path): \(error.localizedDescription)"
        case .fileReadFailed(let url, let error): return "Could not safely read \(url.lastPathComponent): \(error.localizedDescription)"
        case .manifestBytesLimitExceeded(let limit): return "The Embers context manifest is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)). Reduce .embers/context.json before indexing."
        case .fileCountLimitExceeded(let limit): return "The selected folder contains more than \(limit.formatted()) files. Choose a smaller folder or exclude generated content."
        case .totalParsedBytesLimitExceeded(let limit): return "The selected folder contains more than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) of text to index. Choose a smaller folder."
        }
    }
}

/// Bounds for a single folder scan. Reaching either aggregate bound fails the
/// scan rather than accepting an incomplete graph.
public struct FolderScanLimits: Sendable, Equatable {
    public var maximumFileCount: Int
    public var maximumTotalParsedBytes: Int

    public init(maximumFileCount: Int = 20_000, maximumTotalParsedBytes: Int = 50 * 1_024 * 1_024) {
        self.maximumFileCount = maximumFileCount
        self.maximumTotalParsedBytes = maximumTotalParsedBytes
    }

    public static let `default` = FolderScanLimits()
}

enum FolderTraversalDirective: Equatable { case `continue`, skipDescendants }

struct FolderFileEntry {
    var url: URL
    var isDirectory: Bool
    var isRegularFile: Bool
    var isSymbolicLink: Bool
    var fileSize: Int
    var contentModificationDate: Date?
}

/// Kept at the filesystem boundary so tests can induce provider failures
/// without relying on permissions or timing-sensitive volume behaviour.
protocol FolderFileScanning: Sendable {
    func isAvailableDirectory(at url: URL) -> Bool
    func enumerate(at rootURL: URL, visit: (FolderFileEntry) throws -> FolderTraversalDirective) throws
    func readData(at url: URL) throws -> Data
}

/// A configured source, rather than a single scan, owns the security scope.
/// FSEvents and task mutations outlive individual scans, so releasing the
/// scope in `scan()` makes a sandboxed folder intermittently inaccessible.
protocol FolderSecurityScopedAccessing: AnyObject, Sendable {
    var isAccessing: Bool { get }
    func close()
}

final class SecurityScopedFolderAccess: FolderSecurityScopedAccessing, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var active: Bool

    init(url: URL) {
        self.url = url
        active = url.startAccessingSecurityScopedResource()
    }

    var isAccessing: Bool { lock.withLock { active } }

    func close() {
        let shouldStop = lock.withLock { () -> Bool in
            guard active else { return false }
            active = false
            return true
        }
        if shouldStop { url.stopAccessingSecurityScopedResource() }
    }

    deinit { close() }
}

struct SystemFolderFileScanner: FolderFileScanning, @unchecked Sendable {
    func isAvailableDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func enumerate(at rootURL: URL, visit: (FolderFileEntry) throws -> FolderTraversalDirective) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw FolderSourceError.unavailable(rootURL)
        }
        for case let url as URL in enumerator {
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                let directive = try visit(.init(
                    url: url,
                    isDirectory: values.isDirectory == true,
                    isRegularFile: values.isRegularFile == true,
                    isSymbolicLink: values.isSymbolicLink == true,
                    fileSize: values.fileSize ?? 0,
                    contentModificationDate: values.contentModificationDate
                ))
                if directive == .skipDescendants { enumerator.skipDescendants() }
            } catch let error as FolderSourceError {
                throw error
            } catch {
                throw FolderSourceError.enumerationFailed(url, error)
            }
        }
        if let enumerationError { throw FolderSourceError.enumerationFailed(rootURL, enumerationError) }
    }

    func readData(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var accessError: Error?
        var result: Data?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do { result = try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe]) }
            catch { accessError = error }
        }
        if let coordinationError { throw coordinationError }
        if let accessError { throw accessError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return result
    }
}

public final class FolderContextSource: ContextSource, @unchecked Sendable {
    public let sourceID: String
    public let rootURL: URL
    private let parser: any ContextParser
    private let normalizer: any ArtifactNormalizer
    private let monitor: FSEventsChangeMonitor
    private let scanner: any FolderFileScanning
    private let limits: FolderScanLimits
    private let cancellationCheck: @Sendable () throws -> Void
    private let securityScopedAccess: any FolderSecurityScopedAccessing
    private let scanLock = NSLock()
    private struct CachedParse {
        var data: Data
        var modified: Date
        var document: ParsedDocument
    }
    private var parsedFiles: [String: CachedParse] = [:]
    private var lastScan: SourceScan?
    private var lastRawArtifacts: [SourceArtifact] = []

    /// A validated, provider-owned checkbox write changes one known artifact. Reuse
    /// the accepted inventory here; the independent watcher still scans for external
    /// changes. Any structural difference falls back to ordinary folder discovery.
    public func scanAfterTaskWrite(at url: URL) async throws -> SourceScan {
        try scanLock.withLock {
            guard let previous = lastScan, previous.diagnostics.isEmpty,
                  let index = lastRawArtifacts.firstIndex(where: { $0.localURL?.standardizedFileURL == url.standardizedFileURL }) else {
                return try scanFiles()
            }
            let old = lastRawArtifacts[index]
            let data = try scanner.readData(at: url)
            guard data.count <= Self.maximumParsedBytes,
                  data.count == parsedFiles[old.relativePath]?.data.count else { return try scanFiles() }
            var refreshedURL = url
            refreshedURL.removeAllCachedResourceValues()
            let modified = try refreshedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let parsed = try parser.parse(.init(url: url, relativePath: old.relativePath, data: data, modifiedAt: modified))
            var metadataWithoutTasks = parsed.metadata
            metadataWithoutTasks.tasks = old.metadata.tasks
            guard metadataWithoutTasks == old.metadata, parsed.title == old.title,
                  parsed.diagnostics.isEmpty else { return try scanFiles() }
            var artifacts = lastRawArtifacts
            artifacts[index] = makeArtifact(relative: old.relativePath, url: url, data: data, modified: modified, parsed: parsed)
            // Keep the scanner's canonical location when the caller used an equivalent
            // filesystem alias (for example /var versus /private/var).
            artifacts[index].location = old.location
            let scan = SourceScan(sourceID: sourceID, artifacts: normalizer.normalize(artifacts),
                declarations: previous.declarations, diagnostics: previous.diagnostics)
            parsedFiles[old.relativePath] = .init(data: data.withUnsafeBytes { Data($0) }, modified: modified, document: parsed)
            lastRawArtifacts = artifacts
            lastScan = scan
            return scan
        }
    }
    public static let maximumParsedBytes = 2 * 1_024 * 1_024

    public convenience init(sourceID: String, rootURL: URL, parser: any ContextParser = MarkdownTextParser(), normalizer: any ArtifactNormalizer = AutomaticArtifactNormalizer(), limits: FolderScanLimits = .default) {
        self.init(sourceID: sourceID, rootURL: rootURL, parser: parser, normalizer: normalizer, limits: limits, scanner: SystemFolderFileScanner(), cancellationCheck: { try Task.checkCancellation() }, securityScopedAccess: nil)
    }

    init(sourceID: String, rootURL: URL, parser: any ContextParser = MarkdownTextParser(), normalizer: any ArtifactNormalizer = AutomaticArtifactNormalizer(), limits: FolderScanLimits = .default, scanner: any FolderFileScanning, cancellationCheck: @escaping @Sendable () throws -> Void, securityScopedAccess: (any FolderSecurityScopedAccessing)? = nil) {
        self.sourceID = sourceID
        self.rootURL = rootURL.standardizedFileURL
        self.parser = parser
        self.normalizer = normalizer
        self.scanner = scanner
        self.limits = limits
        self.cancellationCheck = cancellationCheck
        self.monitor = FSEventsChangeMonitor(url: rootURL)
        self.securityScopedAccess = securityScopedAccess ?? SecurityScopedFolderAccess(url: self.rootURL)
    }

    deinit { close() }

    /// Call when the source is removed. Keeping this explicit makes folder
    /// switches and forgetting release the entitlement immediately instead of
    /// waiting for ARC or an FSEvents stream to drain.
    public func close() { securityScopedAccess.close() }

    public func changes() -> AsyncStream<Void> { monitor.events() }

    public func scan() async throws -> SourceScan {
        try scanLock.withLock { try scanFiles() }
    }

    private func scanFiles() throws -> SourceScan {
        guard scanner.isAvailableDirectory(at: rootURL) else { throw FolderSourceError.unavailable(rootURL) }

        var textFiles: [(URL, String, Int, Date?)] = []
        var allFiles: [String: (URL, Date?)] = [:]
        var diagnostics: [ContextDiagnostic] = []
        var manifest: ContextManifest?
        var manifestParsedBytes = 0

        var regularFileCount = 0
        var totalParsedBytes = 0
        try scanner.enumerate(at: rootURL) { entry in
            try cancellationCheck()
            let url = entry.url
            let relative = relativePath(for: url)
            let components = relative.split(separator: "/").map(String.init)
            if entry.isSymbolicLink { return entry.isDirectory ? .skipDescendants : .continue }
            if FolderSourcePathPolicy.shouldIgnore(components: components, isDirectory: entry.isDirectory) {
                return entry.isDirectory ? .skipDescendants : .continue
            }
            guard entry.isRegularFile else { return .continue }
            regularFileCount += 1
            guard regularFileCount <= limits.maximumFileCount else { throw FolderSourceError.fileCountLimitExceeded(limit: limits.maximumFileCount) }
            allFiles[normalized(relative)] = (url, entry.contentModificationDate)
            if FolderSourcePathPolicy.isManifest(relative) {
                guard entry.fileSize <= Self.maximumParsedBytes else {
                    throw FolderSourceError.manifestBytesLimitExceeded(limit: Self.maximumParsedBytes)
                }
                let data: Data
                do {
                    data = try scanner.readData(at: url)
                } catch {
                    throw FolderSourceError.fileReadFailed(url, error)
                }
                // File providers can report zero or stale sizes. Bound the
                // coordinated bytes before JSON decoding as well as metadata.
                guard data.count <= Self.maximumParsedBytes else {
                    throw FolderSourceError.manifestBytesLimitExceeded(limit: Self.maximumParsedBytes)
                }
                manifestParsedBytes = data.count
                totalParsedBytes += data.count
                guard totalParsedBytes <= limits.maximumTotalParsedBytes else {
                    throw FolderSourceError.totalParsedBytesLimitExceeded(limit: limits.maximumTotalParsedBytes)
                }
                let loaded = ManifestLoader().load(data)
                manifest = loaded.0
                diagnostics.append(contentsOf: loaded.1)
                return .continue
            }
            if FolderSourcePathPolicy.isSupportedContentFile(relative) {
                if entry.fileSize <= Self.maximumParsedBytes {
                    totalParsedBytes += entry.fileSize
                    guard totalParsedBytes <= limits.maximumTotalParsedBytes else { throw FolderSourceError.totalParsedBytesLimitExceeded(limit: limits.maximumTotalParsedBytes) }
                }
                textFiles.append((url, relative, entry.fileSize, entry.contentModificationDate))
            }
            return .continue
        }
        // An inaccessible or ejected root after a successful walk still means
        // the candidate graph was not built from a coherent source.
        guard scanner.isAvailableDirectory(at: rootURL) else { throw FolderSourceError.unavailable(rootURL) }

        var artifacts: [SourceArtifact] = []
        var referencedPaths = Set<String>()
        var actualParsedBytes = manifestParsedBytes
        var nextParsedFiles: [String: CachedParse] = [:]
        for (url, relative, size, modificationDate) in textFiles.sorted(by: { $0.1 < $1.1 }) {
            try cancellationCheck()
            let modified = modificationDate ?? .distantPast
            if size > Self.maximumParsedBytes {
                diagnostics.append(.init(id: "oversized-\(StableHash.hex(relative))", severity: .warning, message: "Skipped deep parsing because this text file is larger than 2 MiB.", path: relative))
                artifacts.append(makeArtifact(relative: relative, url: url, data: Data(), modified: modified, parsed: .init(title: url.deletingPathExtension().lastPathComponent, text: "", metadata: .init())))
                continue
            }
            do {
                let data: Data
                do { data = try scanner.readData(at: url) }
                catch { throw FolderSourceError.fileReadFailed(url, error) }
                // File providers and editors can replace a file between
                // enumeration and coordinated read. Never parse more than the
                // advertised aggregate budget in that case.
                guard data.count <= Self.maximumParsedBytes else {
                    throw FolderSourceError.fileReadFailed(url, FolderSourceError.totalParsedBytesLimitExceeded(limit: Self.maximumParsedBytes))
                }
                actualParsedBytes += data.count
                guard actualParsedBytes <= limits.maximumTotalParsedBytes else {
                    throw FolderSourceError.totalParsedBytesLimitExceeded(limit: limits.maximumTotalParsedBytes)
                }
                // Compare bytes, not just mtime/size: a checkbox can change without either
                // metadata field changing. Cache only parsing; traversal and read failures
                // must still reject the scan rather than silently serving stale content.
                let parsed: ParsedDocument
                if let cached = parsedFiles[relative], cached.data == data, cached.modified == modified {
                    parsed = cached.document
                } else {
                    parsed = try parser.parse(.init(url: url, relativePath: relative, data: data, modifiedAt: modified))
                }
                // The scanner may return mapped bytes. Own a copy so an external
                // in-place write cannot silently change the cache's comparison value.
                nextParsedFiles[relative] = .init(data: data.withUnsafeBytes { Data($0) }, modified: modified, document: parsed)
                diagnostics.append(contentsOf: parsed.diagnostics)
                let artifact = makeArtifact(relative: relative, url: url, data: data, modified: modified, parsed: parsed)
                artifacts.append(artifact)
                for link in parsed.metadata.links {
                    let directory = NSString(string: relative).deletingLastPathComponent
                    let joined = directory.isEmpty || directory == "." ? link.target : directory + "/" + link.target
                    let referenced = normalized(joined.components(separatedBy: "#")[0])
                    if !URL(fileURLWithPath: referenced).pathExtension.isEmpty { referencedPaths.insert(referenced) }
                }
            } catch let error as FolderSourceError {
                throw error
            } catch {
                diagnostics.append(.init(id: "parse-\(StableHash.hex(relative))", severity: .warning, message: "Could not parse file: \(error.localizedDescription)", path: relative))
            }
        }

        let existing = Set(artifacts.map { normalized($0.relativePath) })
        for path in referencedPaths.subtracting(existing).sorted() {
            guard let (url, modificationDate) = allFiles[path] else { continue }
            artifacts.append(makeArtifact(relative: relativePath(for: url), url: url, data: Data(), modified: modificationDate ?? .distantPast, parsed: .init(title: url.lastPathComponent, text: "", metadata: .init())))
        }
        var seenIDs = Set<String>()
        for index in artifacts.indices {
            guard !seenIDs.insert(artifacts[index].id).inserted else { continue }
            diagnostics.append(.init(id: "duplicate-artifact-id-\(StableHash.hex(artifacts[index].relativePath))", severity: .warning, message: "Duplicate embers_id; this file received a path-based identity.", path: artifacts[index].relativePath))
            artifacts[index].id = "artifact-\(StableHash.hex(sourceID + ":" + normalized(artifacts[index].relativePath)))"
            artifacts[index].metadata.explicitID = nil
            _ = seenIDs.insert(artifacts[index].id)
        }
        let normalizedArtifacts = normalizer.normalize(artifacts)
        parsedFiles = nextParsedFiles
        lastRawArtifacts = artifacts
        if let manifest {
            let adapted = folderDeclarations(from: manifest, artifacts: normalizedArtifacts)
            diagnostics.append(contentsOf: adapted.diagnostics)
            let scan = SourceScan(sourceID: sourceID, artifacts: normalizedArtifacts, declarations: adapted.declarations, diagnostics: diagnostics, indexedAt: Date())
            lastScan = scan
            return scan
        }
        let scan = SourceScan(sourceID: sourceID, artifacts: normalizedArtifacts, declarations: nil, diagnostics: diagnostics, indexedAt: Date())
        lastScan = scan
        return scan
    }

    private func makeArtifact(relative: String, url: URL, data: Data, modified: Date, parsed: ParsedDocument) -> SourceArtifact {
        let ext = url.pathExtension.lowercased()
        let kind: ArtifactMediaKind = ["md", "markdown"].contains(ext) ? .markdown : (ext == "txt" ? .text : .other)
        let id = parsed.metadata.explicitID ?? "artifact-\(StableHash.hex(sourceID + ":" + normalized(relative)))"
        return .init(id: id, relativePath: relative, mediaKind: kind, title: parsed.title, extractedText: parsed.text, modifiedAt: modified, contentHash: StableHash.hex(data), localURL: url, metadata: parsed.metadata)
    }

    private func relativePath(for url: URL) -> String { String(url.standardizedFileURL.path.dropFirst(rootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}

private func normalized(_ path: String) -> String { NSString(string: path.replacingOccurrences(of: "\\", with: "/")).standardizingPath }

private func folderDeclarations(from manifest: ContextManifest, artifacts: [SourceArtifact]) -> (declarations: ContextDeclarations, diagnostics: [ContextDiagnostic]) {
    var diagnostics: [ContextDiagnostic] = []
    let contexts = manifest.anchors.map { anchor -> ContextDeclaration in
        var artifactIDs = Set<String>()
        for rawPath in anchor.paths {
            guard let path = safeManifestPath(rawPath) else {
                diagnostics.append(.init(id: "manifest-path-\(StableHash.hex(rawPath))", severity: .warning, message: "Rejected a manifest path outside the selected folder.", path: rawPath))
                continue
            }
            let matches = artifacts.filter {
                let candidate = normalized($0.relativePath)
                return candidate == path || candidate.hasPrefix(path + "/")
            }
            if matches.isEmpty {
                diagnostics.append(.init(id: "manifest-missing-\(StableHash.hex(rawPath))", severity: .warning, message: "Manifest path does not exist.", path: rawPath))
            }
            artifactIDs.formUnion(matches.map(\.id))
        }
        return .init(id: anchor.id, name: anchor.name, aliases: anchor.aliases, kind: anchor.kind, artifactIDs: artifactIDs.sorted())
    }
    return (.init(version: manifest.version, contexts: contexts, relations: manifest.relations.map { .init(from: $0.from, to: $0.to, kind: $0.kind, detail: "manifest") }), diagnostics)
}

private func safeManifestPath(_ path: String) -> String? {
    guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
    let value = normalized(path)
    guard value != "..", !value.hasPrefix("../"), !value.isEmpty else { return nil }
    return value
}
