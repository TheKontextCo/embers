import AppKit
import Foundation
import EmbersCore
import EmbersLocal
import EmbersPluginKit

public protocol FolderTaskFileCoordinating: Sendable {
    func coordinateWrite(at url: URL, accessor: (URL) throws -> Void) throws
}

public struct SystemFolderTaskFileCoordinator: FolderTaskFileCoordinating, @unchecked Sendable {
    public init() {}

    public func coordinateWrite(at url: URL, accessor: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var accessError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try accessor(coordinatedURL) }
            catch { accessError = error }
        }
        if let coordinationError { throw coordinationError }
        if let accessError { throw accessError }
    }
}

/// The built-in filesystem adapter. It owns folder scanning, file monitoring,
/// and filesystem actions; the plugin host only sees provider-neutral snapshots.
public final class FolderPlugin: PluginSourceProviding, PluginRefreshing, PluginChangeObserving, PluginArtifactActionProviding, PluginTaskMutating, @unchecked Sendable {
    public static let identifier = PluginIdentifier(rawValue: "folder")!

    public let descriptor = PluginDescriptor(
        id: FolderPlugin.identifier,
        displayName: "Folder",
        version: "1",
        capabilities: [.sourceRefresh, .changeObservation, .artifactActions, .taskMutation],
        presentation: .init(
            systemImage: "folder.fill",
            sourceDescription: "Choose a Markdown folder or Obsidian vault",
            setupActionTitle: "Choose…",
            changeActionTitle: "Change…",
            removeActionTitle: "Forget Folder…"
        ),
        sourceSetup: .directoryPicker
    )

    private let lock = NSLock()
    private let builder: DeterministicGraphBuilder
    private let taskFileCoordinator: any FolderTaskFileCoordinating
    private var configuredSources: [PluginSourceIdentifier: ConfiguredSource] = [:]

    private struct ConfiguredSource {
        var descriptor: PluginSourceDescriptor
        var rootURL: URL
        var source: FolderContextSource
        var refreshState = FolderRefreshState()
    }

    public init(builder: DeterministicGraphBuilder = .init(), taskFileCoordinator: any FolderTaskFileCoordinating = SystemFolderTaskFileCoordinator()) {
        self.builder = builder
        self.taskFileCoordinator = taskFileCoordinator
    }

    public func configure(source descriptor: PluginSourceDescriptor, rootURL: URL) {
        precondition(descriptor.id.pluginID == Self.identifier, "FolderPlugin only accepts folder source IDs.")
        lock.lock()
        defer { lock.unlock() }
        let normalized = rootURL.standardizedFileURL
        if let existing = configuredSources[descriptor.id], existing.rootURL == normalized {
            configuredSources[descriptor.id]?.descriptor = descriptor
            return
        }
        configuredSources[descriptor.id]?.source.close()
        configuredSources[descriptor.id] = .init(
            descriptor: descriptor,
            rootURL: normalized,
            source: FolderContextSource(sourceID: descriptor.id.rawValue, rootURL: normalized)
        )
    }

    public func remove(sourceID: PluginSourceIdentifier) {
        lock.lock()
        let removed = configuredSources.removeValue(forKey: sourceID)
        lock.unlock()
        removed?.source.close()
    }

    public func sources() async throws -> [PluginSourceDescriptor] {
        lock.withLock { configuredSources.values.map(\.descriptor).sorted { $0.id < $1.id } }
    }

    public func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        let configured = try configuredSource(for: source)
        return try await configured.refreshState.refresh(source, from: configured.source, builder: builder)
    }

    public func changes(for source: PluginSourceDescriptor) -> AsyncStream<Void> {
        guard let configured = try? configuredSource(for: source) else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return configured.source.changes()
    }

    public func artifactActions(for artifact: SourceArtifact) -> [ArtifactAction] {
        guard artifact.localURL != nil else { return [] }
        return [
            .init(id: "open", title: "Open", kind: .open),
            .init(id: "reveal", title: "Reveal in Finder", kind: .reveal),
            .init(id: "copy-link", title: "Copy file link", kind: .copyLink),
        ]
    }

    public func perform(_ action: ArtifactAction, for artifact: SourceArtifact) async throws {
        guard let url = artifact.localURL,
              let configured = configuredSource(for: artifact) else {
            throw FolderPluginError.invalidArtifactReference
        }
        switch action.kind {
        case .open:
            if configured.descriptor.kind == "obsidian", let obsidianURL = obsidianOpenURL(for: url), NSWorkspace.shared.open(obsidianURL) {
                return
            }
            NSWorkspace.shared.open(url)
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .copyLink:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }

    public func supportedTaskStates(for task: SourceTask, in artifact: SourceArtifact) async -> Set<SourceTaskState> {
        guard artifact.provider?.pluginID == Self.identifier.rawValue,
              artifact.mediaKind == .markdown,
              artifact.localURL != nil,
              task.line != nil,
              task.mutationToken != nil else { return [] }
        return [.open, .completed]
    }

    public func setTaskState(_ state: SourceTaskState, for task: SourceTask, in artifact: SourceArtifact) async throws {
        guard artifact.provider?.pluginID == Self.identifier.rawValue,
              let rawSourceID = artifact.provider?.sourceID,
              let sourceID = PluginSourceIdentifier(rawValue: rawSourceID),
              let configured = lock.withLock({ configuredSources[sourceID] }),
              let url = artifact.localURL?.standardizedFileURL,
              Self.contains(url, in: configured.rootURL),
              artifact.mediaKind == .markdown,
              let line = task.line,
              let mutationToken = task.mutationToken else {
            throw FolderPluginError.invalidTaskReference
        }

        try taskFileCoordinator.coordinateWrite(at: url) { coordinatedURL in
            let data = try Data(contentsOf: coordinatedURL)
            guard StableHash.hex(data) == artifact.contentHash else { throw FolderPluginError.taskConflict }
            guard let raw = String(data: data, encoding: .utf8) else { throw FolderPluginError.unsupportedTaskEncoding }
            let source = raw as NSString
            guard let lineRange = Self.lineContentRange(line, in: source) else { throw FolderPluginError.taskConflict }
            let currentLine = source.substring(with: lineRange)
            guard StableHash.hex(currentLine) == mutationToken else { throw FolderPluginError.taskConflict }

            let regex = try NSRegularExpression(pattern: "^(\\s*[-*+]\\s+\\[)([ xX])(\\])")
            guard let match = regex.firstMatch(in: currentLine, range: NSRange(location: 0, length: (currentLine as NSString).length)) else {
                throw FolderPluginError.taskConflict
            }
            let markerRange = match.range(at: 2)
            let absoluteMarkerRange = NSRange(location: lineRange.location + markerRange.location, length: markerRange.length)
            let updated = source.mutableCopy() as! NSMutableString
            updated.replaceCharacters(in: absoluteMarkerRange, with: state == .completed ? "x" : " ")
            try Data((updated as String).utf8).write(to: coordinatedURL, options: .atomic)
        }
        await configured.refreshState.recordTaskWrite(at: url)
    }

    private static func lineContentRange(_ requestedLine: Int, in source: NSString) -> NSRange? {
        guard requestedLine > 0 else { return nil }
        var start = 0
        var end = 0
        var contentsEnd = 0
        var line = 1
        while start < source.length || (source.length == 0 && line == 1) {
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            if line == requestedLine { return NSRange(location: start, length: contentsEnd - start) }
            guard end > start else { break }
            start = end
            line += 1
        }
        return nil
    }

    private static func contains(_ itemURL: URL, in directoryURL: URL) -> Bool {
        var relationship = FileManager.URLRelationship.other
        do {
            try FileManager.default.getRelationship(
                &relationship,
                ofDirectoryAt: directoryURL,
                toItemAt: itemURL
            )
            return relationship == .contains
        } catch {
            return false
        }
    }

    private func configuredSource(for descriptor: PluginSourceDescriptor) throws -> ConfiguredSource {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor.id.pluginID == Self.identifier,
              let source = configuredSources[descriptor.id] else {
            throw FolderPluginError.unconfigured(descriptor.id)
        }
        return source
    }

    private func configuredSource(for artifact: SourceArtifact) -> ConfiguredSource? {
        guard artifact.provider?.pluginID == Self.identifier.rawValue,
              let rawSourceID = artifact.provider?.sourceID,
              let sourceID = PluginSourceIdentifier(rawValue: rawSourceID),
              let url = artifact.localURL?.standardizedFileURL else { return nil }
        return lock.withLock {
            guard let source = configuredSources[sourceID],
                  Self.contains(url, in: source.rootURL) else { return nil }
            return source
        }
    }

    private func obsidianOpenURL(for url: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [.init(name: "path", value: url.path)]
        return components.url
    }
}

public enum FolderPluginError: LocalizedError {
    case unconfigured(PluginSourceIdentifier)
    case invalidArtifactReference
    case invalidTaskReference
    case taskConflict
    case unsupportedTaskEncoding

    public var errorDescription: String? {
        switch self {
        case .unconfigured(let id): return "Folder source \(id.rawValue) is not configured."
        case .invalidArtifactReference: return "This file is no longer inside a configured folder source."
        case .invalidTaskReference: return "This Markdown task no longer has a valid source location."
        case .taskConflict: return "The Markdown file changed before the task could be updated. Reindex and try again."
        case .unsupportedTaskEncoding: return "Only UTF-8 Markdown tasks can be updated safely."
        }
    }
}
