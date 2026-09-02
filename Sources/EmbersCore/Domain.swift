import Foundation

public enum ArtifactMediaKind: String, Codable, Sendable {
    case markdown
    case text
    case other
}

/// A provider-neutral way to locate an artifact. The graph only needs a stable
/// identity and content; opening is delegated to the source that supplied it.
public enum ArtifactLocation: Hashable, Sendable {
    case file(URL)
    case web(URL)
    case provider(pluginID: String, externalID: String)
    case unavailable

    public var fileURL: URL? {
        guard case let .file(url) = self else { return nil }
        return url
    }

    public var webURL: URL? {
        guard case let .web(url) = self else { return nil }
        return url
    }
}

/// Identifies the plugin and configured source that supplied an artifact.
/// This is routing provenance, not semantic metadata: graph and retrieval code
/// must not infer meaning from it. Core intentionally stores strings so it
/// remains independent of the plugin-kit module.
public struct ArtifactProviderReference: Codable, Hashable, Sendable {
    public var pluginID: String
    public var sourceID: String?

    public init(pluginID: String, sourceID: String? = nil) {
        self.pluginID = pluginID
        self.sourceID = sourceID
    }
}

extension ArtifactLocation: Codable {
    private enum CodingKeys: String, CodingKey { case kind, url, pluginID, externalID }
    private enum Kind: String, Codable { case file, web, provider, unavailable }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .file:
            self = .file(try container.decode(URL.self, forKey: .url))
        case .web:
            self = .web(try container.decode(URL.self, forKey: .url))
        case .provider:
            self = .provider(
                pluginID: try container.decode(String.self, forKey: .pluginID),
                externalID: try container.decode(String.self, forKey: .externalID)
            )
        case .unavailable:
            self = .unavailable
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .file(url):
            try container.encode(Kind.file, forKey: .kind)
            try container.encode(url, forKey: .url)
        case let .web(url):
            try container.encode(Kind.web, forKey: .kind)
            try container.encode(url, forKey: .url)
        case let .provider(pluginID, externalID):
            try container.encode(Kind.provider, forKey: .kind)
            try container.encode(pluginID, forKey: .pluginID)
            try container.encode(externalID, forKey: .externalID)
        case .unavailable:
            try container.encode(Kind.unavailable, forKey: .kind)
        }
    }
}

public enum ArtifactLinkKind: String, Codable, Sendable {
    case wiki
    case embed
    case markdown
}

public struct ArtifactLink: Codable, Hashable, Sendable {
    public var target: String
    public var label: String?
    public var kind: ArtifactLinkKind

    public init(target: String, label: String? = nil, kind: ArtifactLinkKind) {
        self.target = target
        self.label = label
        self.kind = kind
    }
}

public enum SourceTaskState: String, Codable, Hashable, Sendable {
    case open
    case completed
}

/// A provider-neutral task projected from a source artifact. `id` is stable
/// within the owning artifact; mutation details remain opaque to Core.
public struct SourceTask: Codable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var state: SourceTaskState
    public var line: Int?
    public var mutationToken: String?

    public init(id: String? = nil, text: String, state: SourceTaskState = .open, line: Int? = nil, mutationToken: String? = nil) {
        self.id = id ?? line.map { "line:\($0)" } ?? text
        self.text = text
        self.state = state
        self.line = line
        self.mutationToken = mutationToken
    }

    private enum CodingKeys: String, CodingKey { case id, text, state, line, mutationToken }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        state = try container.decodeIfPresent(SourceTaskState.self, forKey: .state) ?? .open
        line = try container.decodeIfPresent(Int.self, forKey: .line)
        mutationToken = try container.decodeIfPresent(String.self, forKey: .mutationToken)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? line.map { "line:\($0)" } ?? text
    }
}

/// Compatibility name for snapshots and integrations created before tasks had
/// provider-neutral identity and state.
public typealias ParsedTask = SourceTask

public struct ArtifactMetadata: Codable, Hashable, Sendable {
    public var explicitID: String?
    public var declaredTitle: String?
    public var kind: String?
    public var aliases: [String]
    public var tags: [String]
    public var headings: [String]
    public var links: [ArtifactLink]
    public var tasks: [SourceTask]
    public var logicalPath: String?
    public var importKind: String?
    public var modificationDateReliable: Bool?

    public init(
        explicitID: String? = nil,
        declaredTitle: String? = nil,
        kind: String? = nil,
        aliases: [String] = [],
        tags: [String] = [],
        headings: [String] = [],
        links: [ArtifactLink] = [],
        tasks: [SourceTask] = [],
        uncheckedTasks: [ParsedTask]? = nil,
        logicalPath: String? = nil,
        importKind: String? = nil,
        modificationDateReliable: Bool? = nil
    ) {
        self.explicitID = explicitID
        self.declaredTitle = declaredTitle
        self.kind = kind
        self.aliases = aliases
        self.tags = tags
        self.headings = headings
        self.links = links
        self.tasks = uncheckedTasks ?? tasks
        self.logicalPath = logicalPath
        self.importKind = importKind
        self.modificationDateReliable = modificationDateReliable
    }

    public var uncheckedTasks: [SourceTask] {
        get { tasks.filter { $0.state == .open } }
        set { tasks = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case explicitID, declaredTitle, kind, aliases, tags, headings, links, tasks, uncheckedTasks, logicalPath, importKind, modificationDateReliable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        explicitID = try container.decodeIfPresent(String.self, forKey: .explicitID)
        declaredTitle = try container.decodeIfPresent(String.self, forKey: .declaredTitle)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        headings = try container.decodeIfPresent([String].self, forKey: .headings) ?? []
        links = try container.decodeIfPresent([ArtifactLink].self, forKey: .links) ?? []
        tasks = try container.decodeIfPresent([SourceTask].self, forKey: .tasks)
            ?? container.decodeIfPresent([SourceTask].self, forKey: .uncheckedTasks)
            ?? []
        logicalPath = try container.decodeIfPresent(String.self, forKey: .logicalPath)
        importKind = try container.decodeIfPresent(String.self, forKey: .importKind)
        modificationDateReliable = try container.decodeIfPresent(Bool.self, forKey: .modificationDateReliable)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(explicitID, forKey: .explicitID)
        try container.encodeIfPresent(declaredTitle, forKey: .declaredTitle)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(tags, forKey: .tags)
        try container.encode(headings, forKey: .headings)
        try container.encode(links, forKey: .links)
        try container.encode(tasks, forKey: .tasks)
        try container.encodeIfPresent(logicalPath, forKey: .logicalPath)
        try container.encodeIfPresent(importKind, forKey: .importKind)
        try container.encodeIfPresent(modificationDateReliable, forKey: .modificationDateReliable)
    }
}

public struct SourceArtifact: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var relativePath: String
    public var mediaKind: ArtifactMediaKind
    public var title: String
    public var extractedText: String
    public var modifiedAt: Date
    public var contentHash: String
    public var location: ArtifactLocation
    /// The provider that owns actions for this artifact. It is distinct from
    /// import metadata such as a document's original format or semantic kind.
    public var provider: ArtifactProviderReference?
    public var metadata: ArtifactMetadata

    public init(id: String, relativePath: String, mediaKind: ArtifactMediaKind, title: String, extractedText: String, modifiedAt: Date, contentHash: String, location: ArtifactLocation = .unavailable, provider: ArtifactProviderReference? = nil, metadata: ArtifactMetadata = .init()) {
        self.id = id
        self.relativePath = relativePath
        self.mediaKind = mediaKind
        self.title = title
        self.extractedText = extractedText
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.location = location
        self.provider = provider
        self.metadata = metadata
    }

    /// Compatibility initializer for existing filesystem-backed sources.
    public init(id: String, relativePath: String, mediaKind: ArtifactMediaKind, title: String, extractedText: String, modifiedAt: Date, contentHash: String, localURL: URL, provider: ArtifactProviderReference? = nil, metadata: ArtifactMetadata = .init()) {
        self.init(id: id, relativePath: relativePath, mediaKind: mediaKind, title: title, extractedText: extractedText, modifiedAt: modifiedAt, contentHash: contentHash, location: .file(localURL), provider: provider, metadata: metadata)
    }

    /// The local file location when this artifact is filesystem-backed.
    public var localURL: URL? { location.fileURL }

    public var graphRelativePath: String { metadata.logicalPath ?? relativePath }
    public var rankingModifiedAt: Date { metadata.modificationDateReliable == false ? .distantPast : modifiedAt }

    private enum CodingKeys: String, CodingKey {
        case id, relativePath, mediaKind, title, extractedText, modifiedAt, contentHash, location, localURL, provider, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        mediaKind = try container.decode(ArtifactMediaKind.self, forKey: .mediaKind)
        title = try container.decode(String.self, forKey: .title)
        extractedText = try container.decode(String.self, forKey: .extractedText)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        location = try container.decodeIfPresent(ArtifactLocation.self, forKey: .location)
            ?? container.decodeIfPresent(URL.self, forKey: .localURL).map(ArtifactLocation.file)
            ?? .unavailable
        provider = try container.decodeIfPresent(ArtifactProviderReference.self, forKey: .provider)
        metadata = try container.decodeIfPresent(ArtifactMetadata.self, forKey: .metadata) ?? .init()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(mediaKind, forKey: .mediaKind)
        try container.encode(title, forKey: .title)
        try container.encode(extractedText, forKey: .extractedText)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(location, forKey: .location)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encode(metadata, forKey: .metadata)
    }
}

public enum AnchorProvenance: String, Codable, Hashable, Sendable {
    case manifest
    case frontmatter
    case folder
    case tag
    case linkedDocument
    case unresolvedLink
}

public struct AnchorEvidence: Codable, Hashable, Sendable {
    public var manifest: Bool
    public var frontmatter: Bool
    public var folder: Bool
    public var inboundLinkCount: Int
    public var exactMentionCount: Int
    public var mostRecentModification: Date

    public init(manifest: Bool = false, frontmatter: Bool = false, folder: Bool = false, inboundLinkCount: Int = 0, exactMentionCount: Int = 0, mostRecentModification: Date = .distantPast) {
        self.manifest = manifest
        self.frontmatter = frontmatter
        self.folder = folder
        self.inboundLinkCount = inboundLinkCount
        self.exactMentionCount = exactMentionCount
        self.mostRecentModification = mostRecentModification
    }
}

public struct Anchor: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var canonicalName: String
    public var aliases: [String]
    public var kind: String?
    public var provenance: Set<AnchorProvenance>
    public var evidence: AnchorEvidence
    public var memberArtifactIDs: Set<String>
    /// Root-relative structural scope for folder-backed anchors. Semantic anchors leave this nil.
    public var scopePath: String?

    public init(id: String, canonicalName: String, aliases: [String] = [], kind: String? = nil, provenance: Set<AnchorProvenance>, evidence: AnchorEvidence = .init(), memberArtifactIDs: Set<String> = [], scopePath: String? = nil) {
        self.id = id
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.kind = kind
        self.provenance = provenance
        self.evidence = evidence
        self.memberArtifactIDs = memberArtifactIDs
        self.scopePath = scopePath
    }
}

public struct RelationProvenance: Codable, Hashable, Sendable {
    public var artifactID: String?
    public var detail: String?

    public init(artifactID: String? = nil, detail: String? = nil) {
        self.artifactID = artifactID
        self.detail = detail
    }
}

public enum RelationEvidence: String, Codable, Hashable, Sendable {
    case authored
    case extracted
    case derived
    case inferred
}

public struct ContextRelation: Codable, Hashable, Sendable {
    public var source: String
    public var target: String
    public var kind: String
    public var provenance: RelationProvenance
    public var evidence: RelationEvidence?
    public var weight: Double?

    public init(source: String, target: String, kind: String, provenance: RelationProvenance = .init(), evidence: RelationEvidence? = nil, weight: Double? = nil) {
        self.source = source
        self.target = target
        self.kind = kind
        self.provenance = provenance
        self.evidence = evidence
        self.weight = weight
    }
}

public enum DiagnosticSeverity: String, Codable, Sendable { case info, warning, error }

public struct ContextDiagnostic: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var severity: DiagnosticSeverity
    public var message: String
    public var path: String?

    public init(id: String, severity: DiagnosticSeverity, message: String, path: String? = nil) {
        self.id = id
        self.severity = severity
        self.message = message
        self.path = path
    }
}

public struct ContextSnapshot: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var sourceID: String
    public var revision: String
    public var artifacts: [SourceArtifact]
    public var anchors: [Anchor]
    public var relations: [ContextRelation]
    public var diagnostics: [ContextDiagnostic]
    public var indexedAt: Date

    public init(schemaVersion: Int = currentSchemaVersion, sourceID: String, revision: String, artifacts: [SourceArtifact], anchors: [Anchor], relations: [ContextRelation], diagnostics: [ContextDiagnostic], indexedAt: Date) {
        self.schemaVersion = schemaVersion
        self.sourceID = sourceID
        self.revision = revision
        self.artifacts = artifacts
        self.anchors = anchors
        self.relations = relations
        self.diagnostics = diagnostics
        self.indexedAt = indexedAt
    }

    public func validated() throws -> ContextSnapshot {
        guard schemaVersion == Self.currentSchemaVersion else { throw ContextCoreError.unsupportedSchema(schemaVersion) }
        guard Set(artifacts.map(\.id)).count == artifacts.count else { throw ContextCoreError.duplicateArtifactID }
        guard Set(anchors.map(\.id)).count == anchors.count else { throw ContextCoreError.duplicateAnchorID }
        return self
    }
}

public enum ContextCoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case duplicateArtifactID
    case duplicateAnchorID
}

public struct AnchorSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: String?
    public var documentCount: Int
    public var linkCount: Int
    public var modifiedAt: Date

    public init(id: String, name: String, kind: String?, documentCount: Int, linkCount: Int, modifiedAt: Date) {
        self.id = id; self.name = name; self.kind = kind; self.documentCount = documentCount; self.linkCount = linkCount; self.modifiedAt = modifiedAt
    }
}

public struct ContextHit: Identifiable, Hashable, Sendable {
    public var id: String { artifact.id }
    public var artifact: SourceArtifact
    public var snippet: String
    public var changedSinceLastPeek: Bool
    public init(artifact: SourceArtifact, snippet: String, changedSinceLastPeek: Bool) { self.artifact = artifact; self.snippet = snippet; self.changedSinceLastPeek = changedSinceLastPeek }
}

public struct RelatedAnchor: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var relationKind: String
    public init(id: String, name: String, relationKind: String) { self.id = id; self.name = name; self.relationKind = relationKind }
}

public struct AnchorTask: Identifiable, Hashable, Sendable {
    public var id: String { "\(artifactID):\(taskID)" }
    public var taskID: String
    public var artifactID: String
    public var artifactTitle: String
    public var text: String
    public var state: SourceTaskState
    public var line: Int?
    public var mutationToken: String?
    public init(taskID: String? = nil, artifactID: String, artifactTitle: String, text: String, state: SourceTaskState = .open, line: Int? = nil, mutationToken: String? = nil) {
        self.taskID = taskID ?? line.map { "line:\($0)" } ?? text
        self.artifactID = artifactID
        self.artifactTitle = artifactTitle
        self.text = text
        self.state = state
        self.line = line
        self.mutationToken = mutationToken
    }
}

public struct AnchorDetail: Identifiable, Sendable {
    public var id: String { anchor.id }
    public var anchor: Anchor
    public var hits: [ContextHit]
    public var subcontexts: [AnchorSummary]
    public var relatedAnchors: [RelatedAnchor]
    public var tasks: [AnchorTask]
    public var changeSet: ContextChangeSet
    public init(anchor: Anchor, hits: [ContextHit], subcontexts: [AnchorSummary] = [], relatedAnchors: [RelatedAnchor], tasks: [AnchorTask], changeSet: ContextChangeSet = .init()) { self.anchor = anchor; self.hits = hits; self.subcontexts = subcontexts; self.relatedAnchors = relatedAnchors; self.tasks = tasks; self.changeSet = changeSet }
}

public struct RecentArtifact: Identifiable, Hashable, Sendable {
    public var id: String { artifact.id }
    public var artifact: SourceArtifact
    public var accessedAt: Date
    public init(artifact: SourceArtifact, accessedAt: Date) {
        self.artifact = artifact
        self.accessedAt = accessedAt
    }
}
