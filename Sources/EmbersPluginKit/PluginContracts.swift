import Foundation
import EmbersCore

/// Identifies a compiled-in Embers provider. This is intentionally separate
/// from a user account or individual configured source.
public struct PluginIdentifier: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "_" }) else { return nil }
        self.rawValue = value
    }

    public static func < (lhs: PluginIdentifier, rhs: PluginIdentifier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The stable, provider-scoped identifier for one configured source.
public struct PluginSourceIdentifier: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let pluginID: PluginIdentifier
    public let sourceID: String

    public init(pluginID: PluginIdentifier, sourceID: String) {
        self.pluginID = pluginID
        self.sourceID = sourceID
    }

    public init?(rawValue: String) {
        let pieces = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[1] == "source", let pluginID = PluginIdentifier(rawValue: String(pieces[0])), let sourceID = Self.decodeComponent(String(pieces[2])) else { return nil }
        self.init(pluginID: pluginID, sourceID: sourceID)
    }

    public var rawValue: String { "\(pluginID.rawValue):source:\(Self.encodeComponent(sourceID))" }
    public static func < (lhs: PluginSourceIdentifier, rhs: PluginSourceIdentifier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A deterministic, collision-resistant namespace for provider entity IDs.
/// It keeps provider data outside the IDs emitted by unrelated plugins.
public struct PluginEntityIdentifier: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let source: PluginSourceIdentifier
    public let kind: String
    public let externalID: String

    public init(source: PluginSourceIdentifier, kind: String, externalID: String) {
        self.source = source
        self.kind = kind
        self.externalID = externalID
    }

    public init?(rawValue: String) {
        let pieces = rawValue.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false)
        guard pieces.count == 5,
              pieces[1] == "source",
              let pluginID = PluginIdentifier(rawValue: String(pieces[0])),
              let sourceID = PluginSourceIdentifier.decodeComponent(String(pieces[2])),
              let kind = PluginSourceIdentifier.decodeComponent(String(pieces[3])),
              let externalID = PluginSourceIdentifier.decodeComponent(String(pieces[4]))
        else { return nil }
        self.init(source: .init(pluginID: pluginID, sourceID: sourceID), kind: kind, externalID: externalID)
    }

    public var rawValue: String {
        "\(source.pluginID.rawValue):source:\(PluginSourceIdentifier.encodeComponent(source.sourceID)):\(PluginSourceIdentifier.encodeComponent(kind)):\(PluginSourceIdentifier.encodeComponent(externalID))"
    }

    public static func < (lhs: PluginEntityIdentifier, rhs: PluginEntityIdentifier) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension PluginSourceIdentifier {
    fileprivate static func encodeComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }

    fileprivate static func decodeComponent(_ value: String) -> String? {
        value.removingPercentEncoding
    }
}

public enum PluginCapability: String, Codable, Hashable, Sendable {
    case connection
    case sourceRefresh
    case changeObservation
    case artifactActions
    case taskMutation
}

/// Declarative app chrome for one provider. The executable renders these
/// values uniformly and never branches on a concrete provider identifier.
public struct PluginPresentation: Codable, Hashable, Sendable {
    public var systemImage: String
    public var sourceDescription: String
    public var setupActionTitle: String
    public var changeActionTitle: String
    public var removeActionTitle: String

    public init(
        systemImage: String = "shippingbox.fill",
        sourceDescription: String = "Context source",
        setupActionTitle: String = "Configure…",
        changeActionTitle: String = "Change…",
        removeActionTitle: String = "Remove…"
    ) {
        self.systemImage = systemImage
        self.sourceDescription = sourceDescription
        self.setupActionTitle = setupActionTitle
        self.changeActionTitle = changeActionTitle
        self.removeActionTitle = removeActionTitle
    }
}

public enum PluginSourceSetup: String, Codable, Hashable, Sendable {
    case none
    case directoryPicker
}

public struct PluginDescriptor: Codable, Hashable, Sendable {
    public var id: PluginIdentifier
    public var displayName: String
    public var version: String
    public var capabilities: Set<PluginCapability>
    public var presentation: PluginPresentation
    public var sourceSetup: PluginSourceSetup

    public init(
        id: PluginIdentifier,
        displayName: String,
        version: String,
        capabilities: Set<PluginCapability>,
        presentation: PluginPresentation = .init(),
        sourceSetup: PluginSourceSetup = .none
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.capabilities = capabilities
        self.presentation = presentation
        self.sourceSetup = sourceSetup
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, version, capabilities, presentation, sourceSetup
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(PluginIdentifier.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        version = try values.decode(String.self, forKey: .version)
        capabilities = try values.decode(Set<PluginCapability>.self, forKey: .capabilities)
        presentation = try values.decodeIfPresent(PluginPresentation.self, forKey: .presentation) ?? .init()
        sourceSetup = try values.decodeIfPresent(PluginSourceSetup.self, forKey: .sourceSetup) ?? .none
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(version, forKey: .version)
        try values.encode(capabilities, forKey: .capabilities)
        try values.encode(presentation, forKey: .presentation)
        try values.encode(sourceSetup, forKey: .sourceSetup)
    }
}

public enum PluginConnectionState: String, Codable, Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    case requiresAuthentication
    case expired
    case failed
}

public struct PluginConnectionStatus: Codable, Hashable, Sendable {
    public var state: PluginConnectionState
    public var detail: String?
    public var updatedAt: Date

    public init(state: PluginConnectionState, detail: String? = nil, updatedAt: Date = Date()) {
        self.state = state
        self.detail = detail
        self.updatedAt = updatedAt
    }
}

public struct PluginSourceDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: PluginSourceIdentifier
    public var displayName: String
    public var kind: String
    public var detail: String?
    public var isOnboarding: Bool
    public var presentsUnassignedArtifactsAtRoot: Bool

    public init(
        id: PluginSourceIdentifier,
        displayName: String,
        kind: String,
        detail: String? = nil,
        isOnboarding: Bool = false,
        presentsUnassignedArtifactsAtRoot: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.detail = detail
        self.isOnboarding = isOnboarding
        self.presentsUnassignedArtifactsAtRoot = presentsUnassignedArtifactsAtRoot
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, kind, detail, isOnboarding, presentsUnassignedArtifactsAtRoot
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(PluginSourceIdentifier.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        kind = try values.decode(String.self, forKey: .kind)
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
        isOnboarding = try values.decodeIfPresent(Bool.self, forKey: .isOnboarding) ?? false
        presentsUnassignedArtifactsAtRoot = try values.decodeIfPresent(Bool.self, forKey: .presentsUnassignedArtifactsAtRoot) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(detail, forKey: .detail)
        try values.encode(isOnboarding, forKey: .isOnboarding)
        try values.encode(presentsUnassignedArtifactsAtRoot, forKey: .presentsUnassignedArtifactsAtRoot)
    }
}

public enum PluginRefreshDisposition: String, Codable, Hashable, Sendable {
    case updated
    case unchanged
}

/// A plugin refresh either supplies a fully validated candidate snapshot or
/// explicitly reports that its cached revision remains current.
public struct PluginRefreshResult: Codable, Sendable {
    public var source: PluginSourceDescriptor
    public var disposition: PluginRefreshDisposition
    public var snapshot: ContextSnapshot?
    public var diagnostics: [ContextDiagnostic]
    public var refreshedAt: Date

    public init(source: PluginSourceDescriptor, snapshot: ContextSnapshot, diagnostics: [ContextDiagnostic] = [], refreshedAt: Date = Date()) {
        self.source = source
        self.disposition = .updated
        self.snapshot = snapshot
        self.diagnostics = diagnostics
        self.refreshedAt = refreshedAt
    }

    public init(unchanged source: PluginSourceDescriptor, diagnostics: [ContextDiagnostic] = [], refreshedAt: Date = Date()) {
        self.source = source
        self.disposition = .unchanged
        self.snapshot = nil
        self.diagnostics = diagnostics
        self.refreshedAt = refreshedAt
    }
}

public enum ArtifactActionKind: String, Codable, Hashable, Sendable {
    case open
    case reveal
    case copyLink
}

public struct ArtifactAction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var kind: ArtifactActionKind

    public init(id: String, title: String, kind: ArtifactActionKind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

// Capability protocols deliberately remain small: a local folder can refresh
// without authenticating, while Kontext can opt into each relevant behavior.
public protocol PluginDescribing: Sendable {
    var descriptor: PluginDescriptor { get }
}

public protocol PluginConnecting: PluginDescribing {
    func connectionStatus() async -> PluginConnectionStatus
    func connect() async throws
    func disconnect() async throws
}

public protocol PluginSourceProviding: PluginDescribing {
    func sources() async throws -> [PluginSourceDescriptor]
}

public protocol PluginRefreshing: PluginDescribing {
    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult
}

public protocol PluginChangeObserving: PluginDescribing {
    func changes(for source: PluginSourceDescriptor) -> AsyncStream<Void>
}

public protocol PluginArtifactActionProviding: PluginDescribing {
    func artifactActions(for artifact: SourceArtifact) -> [ArtifactAction]
    func perform(_ action: ArtifactAction, for artifact: SourceArtifact) async throws
}

/// Provider-owned write-back for tasks. Core and UI express only the desired
/// semantic state; each provider retains authority over identity, validation,
/// persistence, and conflict handling.
public protocol PluginTaskMutating: PluginDescribing {
    func supportedTaskStates(for task: SourceTask, in artifact: SourceArtifact) async -> Set<SourceTaskState>
    func setTaskState(_ state: SourceTaskState, for task: SourceTask, in artifact: SourceArtifact) async throws
}

/// One provider-confirmed task delta. Providers that can return every task
/// affected by a write let the host reconcile its cached snapshot without an
/// immediate broad source refresh.
public struct PluginTaskStateUpdate: Hashable, Sendable {
    public var artifactID: String
    public var taskID: String
    public var state: SourceTaskState
    public var contentHash: String?

    public init(artifactID: String, taskID: String, state: SourceTaskState, contentHash: String? = nil) {
        self.artifactID = artifactID
        self.taskID = taskID
        self.state = state
        self.contentHash = contentHash
    }
}

/// Optional fast path for authoritative providers. The acknowledgement must
/// include the requested task and every derived task-state change caused by the
/// same mutation; otherwise the host falls back to a normal source refresh.
public protocol PluginTaskMutationAcknowledging: PluginTaskMutating {
    func setTaskStateWithAcknowledgement(
        _ state: SourceTaskState,
        for task: SourceTask,
        in artifact: SourceArtifact
    ) async throws -> [PluginTaskStateUpdate]
}
