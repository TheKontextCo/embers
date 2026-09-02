import Foundation

public struct SourceScan: Sendable {
    public var sourceID: String
    public var artifacts: [SourceArtifact]
    /// Provider-authored contexts and relations. Folder manifests are adapted to
    /// this representation at the filesystem boundary.
    public var declarations: ContextDeclarations?
    public var diagnostics: [ContextDiagnostic]
    public var indexedAt: Date

    public init(sourceID: String, artifacts: [SourceArtifact], declarations: ContextDeclarations? = nil, diagnostics: [ContextDiagnostic], indexedAt: Date = Date()) {
        self.sourceID = sourceID; self.artifacts = artifacts; self.declarations = declarations; self.diagnostics = diagnostics; self.indexedAt = indexedAt
    }

    /// Compatibility initializer while folder manifests are migrated at their boundary.
    public init(sourceID: String, artifacts: [SourceArtifact], manifest: ContextManifest?, diagnostics: [ContextDiagnostic], indexedAt: Date = Date()) {
        guard let manifest else {
            self.init(sourceID: sourceID, artifacts: artifacts, declarations: nil, diagnostics: diagnostics, indexedAt: indexedAt)
            return
        }
        let adapted = manifest.adaptLegacyPaths(in: artifacts)
        self.init(sourceID: sourceID, artifacts: artifacts, declarations: adapted.declarations, diagnostics: diagnostics + adapted.diagnostics, indexedAt: indexedAt)
    }
}

public protocol ContextSource: Sendable {
    var sourceID: String { get }
    func scan() async throws -> SourceScan
    func changes() -> AsyncStream<Void>
}

public struct ParseInput: Sendable {
    public var url: URL
    public var relativePath: String
    public var data: Data
    public var modifiedAt: Date
    public init(url: URL, relativePath: String, data: Data, modifiedAt: Date) { self.url = url; self.relativePath = relativePath; self.data = data; self.modifiedAt = modifiedAt }
}

public struct ParsedDocument: Sendable {
    public var title: String
    public var text: String
    public var metadata: ArtifactMetadata
    public var diagnostics: [ContextDiagnostic]
    public init(title: String, text: String, metadata: ArtifactMetadata, diagnostics: [ContextDiagnostic] = []) { self.title = title; self.text = text; self.metadata = metadata; self.diagnostics = diagnostics }
}

public protocol ContextParser: Sendable {
    func parse(_ input: ParseInput) throws -> ParsedDocument
}

public protocol ArtifactNormalizer: Sendable {
    func normalize(_ artifacts: [SourceArtifact]) -> [SourceArtifact]
}

public protocol ContextRepository: Sendable {
    func load() async -> ContextSnapshot?
    func replace(with snapshot: ContextSnapshot) async throws
    func delete() async throws
}

/// Provider-neutral declarations that may accompany a source scan. They model
/// explicit context membership and authored relations without requiring paths
/// or filesystem manifests.
public struct ContextDeclarations: Codable, Hashable, Sendable {
    public var version: Int
    public var contexts: [ContextDeclaration]
    public var relations: [DeclaredContextRelation]

    public init(version: Int = 1, contexts: [ContextDeclaration] = [], relations: [DeclaredContextRelation] = []) {
        self.version = version
        self.contexts = contexts
        self.relations = relations
    }
}

public struct ContextDeclaration: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var kind: String?
    /// Stable artifact identifiers owned by the provider, not local paths.
    public var artifactIDs: [String]

    public init(id: String, name: String, aliases: [String] = [], kind: String? = nil, artifactIDs: [String] = []) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.kind = kind
        self.artifactIDs = artifactIDs
    }
}

public struct DeclaredContextRelation: Codable, Hashable, Sendable {
    public var from: String
    public var to: String
    public var kind: String
    public var detail: String?

    public init(from: String, to: String, kind: String, detail: String? = nil) {
        self.from = from
        self.to = to
        self.kind = kind
        self.detail = detail
    }
}

/// Filesystem-specific input retained only for decoding `.embers/context.json`.
/// The folder source adapts paths into artifact IDs before graph construction.
public struct ContextManifest: Codable, Sendable {
    public var version: Int
    public var anchors: [ManifestAnchor]
    public var relations: [ManifestRelation]

    public init(version: Int, anchors: [ManifestAnchor] = [], relations: [ManifestRelation] = []) {
        self.version = version
        self.anchors = anchors
        self.relations = relations
    }

    fileprivate func adaptLegacyPaths(in artifacts: [SourceArtifact]) -> (declarations: ContextDeclarations, diagnostics: [ContextDiagnostic]) {
        var diagnostics: [ContextDiagnostic] = []
        let contexts = anchors.map { anchor -> ContextDeclaration in
            var artifactIDs = Set<String>()
            for rawPath in anchor.paths {
                guard let path = safeLegacyManifestPath(rawPath) else {
                    diagnostics.append(.init(id: "manifest-path-\(StableHash.hex(rawPath))", severity: .warning, message: "Rejected a manifest path outside the selected folder.", path: rawPath))
                    continue
                }
                let matches = artifacts.filter {
                    let candidate = normalizedLegacyManifestPath($0.relativePath)
                    return candidate == path || candidate.hasPrefix(path + "/")
                }
                if matches.isEmpty {
                    diagnostics.append(.init(id: "manifest-missing-\(StableHash.hex(rawPath))", severity: .warning, message: "Manifest path does not exist.", path: rawPath))
                }
                artifactIDs.formUnion(matches.map(\.id))
            }
            return .init(id: anchor.id, name: anchor.name, aliases: anchor.aliases, kind: anchor.kind, artifactIDs: artifactIDs.sorted())
        }
        return (.init(version: version, contexts: contexts, relations: relations.map { .init(from: $0.from, to: $0.to, kind: $0.kind, detail: "manifest") }), diagnostics)
    }
}

public struct ManifestAnchor: Codable, Sendable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var kind: String?
    public var paths: [String]
    public init(id: String, name: String, aliases: [String] = [], kind: String? = nil, paths: [String] = []) { self.id = id; self.name = name; self.aliases = aliases; self.kind = kind; self.paths = paths }
}

public struct ManifestRelation: Codable, Sendable {
    public var from: String
    public var to: String
    public var kind: String
    public init(from: String, to: String, kind: String) { self.from = from; self.to = to; self.kind = kind }
}

private func normalizedLegacyManifestPath(_ path: String) -> String {
    NSString(string: path.replacingOccurrences(of: "\\", with: "/")).standardizingPath
}

private func safeLegacyManifestPath(_ path: String) -> String? {
    guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }
    let normalized = normalizedLegacyManifestPath(path)
    guard normalized != "..", !normalized.hasPrefix("../"), !normalized.isEmpty else { return nil }
    return normalized
}
