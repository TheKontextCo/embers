import AppKit
import Foundation
import EmbersCore
import EmbersLocal
import EmbersPluginKit

/// The narrow authenticated transport used by the read-only Kontext snapshot client.
/// Keeping it separate from OAuth makes page/restart handling completely deterministic in tests.
public protocol KontextAPITransport: Sendable {
    func execute(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse
}

public actor OAuthKontextAPITransport: KontextAPITransport {
    private let connection: OAuthConnection

    public init(connection: OAuthConnection) {
        self.connection = connection
    }

    public func execute(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        try await connection.authorizedRequest(request)
    }
}

/// The UI boundary for remote artifacts. The plugin never assumes that a web URL can be opened
/// or copied by a particular UI framework.
public protocol KontextArtifactActionOpening: Sendable {
    func open(_ url: URL) async throws
    func copyLink(_ url: URL) async throws
}

public struct SystemKontextArtifactActionOpener: KontextArtifactActionOpening, @unchecked Sendable {
    public init() {}

    public func open(_ url: URL) async throws {
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }

    public func copyLink(_ url: URL) async throws {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }
}

public enum KontextPluginError: Error, LocalizedError, Equatable, Sendable {
    case invalidResponse(String)
    case snapshotChangedTooOften
    case unconfiguredSource(PluginSourceIdentifier)
    case accountChanged
    case unsupportedAction(ArtifactActionKind)
    case invalidTaskReference

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail): return "Kontext returned an invalid graph snapshot: \(detail)"
        case .snapshotChangedTooOften: return "Kontext Library changed repeatedly while syncing. Please try again."
        case .unconfiguredSource(let source): return "Kontext source \(source.rawValue) is not connected."
        case .accountChanged: return "This Kontext connection belongs to a different account. Disconnect before connecting another account."
        case .unsupportedAction(let kind): return "Kontext does not support the \(kind.rawValue) action."
        case .invalidTaskReference: return "This Kontext task is no longer available."
        }
    }
}

/// Non-secret identity required to restore a connected library's cached graph
/// before the network or its credential is available. OAuth material stays in
/// Keychain; this record contains only the opaque source descriptor.
public struct KontextSourceConfiguration: Codable, Hashable, Sendable {
    public var source: PluginSourceDescriptor

    public init(source: PluginSourceDescriptor) { self.source = source }
}

public final class KontextSourceConfigurationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "kontextSourceConfiguration") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> KontextSourceConfiguration? {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(KontextSourceConfiguration.self, from: data),
              value.source.id.pluginID == KontextPlugin.identifier else { return nil }
        return value
    }

    public func save(_ source: PluginSourceDescriptor) {
        guard source.id.pluginID == KontextPlugin.identifier,
              let data = try? JSONEncoder().encode(KontextSourceConfiguration(source: source)) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() { defaults.removeObject(forKey: key) }
}

/// A compiled-in adapter for one person's Kontext Library. Reads remain a
/// complete graph snapshot; task status is the only narrow write capability.
/// All provider JSON stays private to this target; EmbersCore receives only a normal SourceScan.
public actor KontextPlugin: PluginConnecting, PluginSourceProviding, PluginRefreshing, PluginArtifactActionProviding, PluginTaskMutating, PluginTaskMutationAcknowledging {
    public static let identifier = PluginIdentifier(rawValue: "kontext")!
    public static let productionOrigin = URL(string: "https://thekontextco.ai")!
    public static let redirectURI = URL(string: "embers://oauth/kontext")!

    public nonisolated let descriptor = PluginDescriptor(
        id: KontextPlugin.identifier,
        displayName: "Kontext",
        version: "1",
        capabilities: [.connection, .sourceRefresh, .artifactActions, .taskMutation],
        presentation: .init(
            systemImage: "link.circle.fill",
            sourceDescription: "Connect your Kontext Library",
            setupActionTitle: "Connect",
            changeActionTitle: "Reconnect",
            removeActionTitle: "Disconnect…"
        )
    )

    private let connection: OAuthConnection
    private let client: KontextGraphSnapshotClient
    private let builder: DeterministicGraphBuilder
    private let actionOpener: any KontextArtifactActionOpening
    private let sourceConfiguration: KontextSourceConfigurationStore
    private var knownSource: PluginSourceDescriptor?
    private var pendingSnapshot: KontextRetrievedSnapshot?
    private var latestRetrievedSnapshot: KontextRetrievedSnapshot?
    private var transientState: PluginConnectionState?
    private var transientDetail: String?

    public init(
        connection: OAuthConnection,
        transport: any KontextAPITransport,
        actionOpener: any KontextArtifactActionOpening = SystemKontextArtifactActionOpener(),
        builder: DeterministicGraphBuilder = .init(),
        maximumSnapshotRestarts: Int = 2,
        sourceConfiguration: KontextSourceConfigurationStore = .init()
    ) {
        self.connection = connection
        self.client = .init(transport: transport, origin: Self.productionOrigin, maximumRestarts: maximumSnapshotRestarts)
        self.actionOpener = actionOpener
        self.builder = builder
        self.sourceConfiguration = sourceConfiguration
        var restored = sourceConfiguration.load()?.source
        restored?.presentsUnassignedArtifactsAtRoot = true
        self.knownSource = restored
    }

    /// Production construction deliberately uses discovery, public DCR, S256 PKCE, a non-ephemeral
    /// shared browser session, and Keychain storage supplied by EmbersLocal's OAuth foundation.
    public init(
        secretStore: any OAuthSecretStore = KeychainOAuthSecretStore(),
        http: any OAuthHTTPClient = URLSessionOAuthHTTPClient(),
        browser: any OAuthBrowserSession = SystemOAuthBrowserSession(),
        actionOpener: any KontextArtifactActionOpening = SystemKontextArtifactActionOpener(),
        sourceConfiguration: KontextSourceConfigurationStore = .init()
    ) {
        let credentials = OAuthCredentialStore(key: "kontext.oauth.connection", secrets: secretStore)
        let connection = OAuthConnection(
            configuration: .init(
                issuer: Self.productionOrigin,
                clientName: "Embers",
                redirectURI: Self.redirectURI,
                scopes: ["kontext"],
                refreshTokenLifetime: 30 * 24 * 60 * 60
            ),
            http: http,
            browser: browser,
            credentials: credentials
        )
        self.connection = connection
        self.client = .init(transport: OAuthKontextAPITransport(connection: connection), origin: Self.productionOrigin, maximumRestarts: 2)
        self.actionOpener = actionOpener
        self.builder = .init()
        self.sourceConfiguration = sourceConfiguration
        var restored = sourceConfiguration.load()?.source
        restored?.presentsUnassignedArtifactsAtRoot = true
        self.knownSource = restored
    }

    public func connectionStatus() async -> PluginConnectionStatus {
        if let transientState {
            return .init(state: transientState, detail: transientDetail)
        }
        do {
            guard let credential = try await connection.storedCredential() else {
                return .init(state: .requiresAuthentication)
            }
            let now = Date()
            if credential.token.accessIsValid(at: now) || credential.token.refreshIsValid(at: now) {
                return .init(state: .connected)
            }
            return .init(state: .expired, detail: "Reconnect to continue syncing Kontext.")
        } catch {
            return .init(state: .failed, detail: error.localizedDescription)
        }
    }

    public func connect() async throws {
        transientState = .connecting
        transientDetail = nil
        do {
            _ = try await connection.connect()
            // The graph snapshot is also the authoritative account identity.
            // Keep it for the immediately following refresh so connecting does
            // not fetch a complete library twice.
            let retrieved = try await client.fetch()
            _ = try acceptSource(retrieved.source)
            pendingSnapshot = retrieved
            transientState = nil
        } catch {
            transientState = .failed
            transientDetail = error.localizedDescription
            throw error
        }
    }

    public func disconnect() async throws {
        defer {
            sourceConfiguration.clear()
            knownSource = nil
            pendingSnapshot = nil
            latestRetrievedSnapshot = nil
            transientState = nil
            transientDetail = nil
        }
        // Revocation is best-effort: an expired/offline connection must still
        // be removable locally. The bearer token is scoped to the current grant.
        let sessionURL = Self.productionOrigin.appendingPathComponent("api/v1/session")
        _ = try? await connection.authorizedRequest(.init(url: sessionURL, method: "DELETE"))
        try await connection.disconnect()
    }

    /// Discovery validates the authenticated account key returned by Kontext rather than deriving
    /// identity from an email or token claim.
    public func sources() async throws -> [PluginSourceDescriptor] {
        if let knownSource { return [knownSource] }
        let retrieved = try await client.fetch()
        let source = try acceptSource(retrieved.source)
        pendingSnapshot = retrieved
        return [source]
    }

    public func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        guard source.id.pluginID == Self.identifier else { throw KontextPluginError.unconfiguredSource(source.id) }
        let retrieved: KontextRetrievedSnapshot
        if let pendingSnapshot, pendingSnapshot.source.accountID == source.id.sourceID {
            retrieved = pendingSnapshot
            self.pendingSnapshot = nil
        } else {
            retrieved = try await client.fetch()
        }
        let accepted = try acceptSource(retrieved.source)
        guard accepted.id == source.id else { throw KontextPluginError.accountChanged }
        let snapshot = try map(retrieved, source: accepted)
        latestRetrievedSnapshot = retrieved
        return .init(source: accepted, snapshot: snapshot)
    }

    public nonisolated func artifactActions(for artifact: SourceArtifact) -> [ArtifactAction] {
        guard case let .web(url) = artifact.location, Self.isKontextURL(url) else { return [] }
        return [
            .init(id: "open", title: "Open in Kontext", kind: .open),
            .init(id: "copy-link", title: "Copy Kontext link", kind: .copyLink),
        ]
    }

    public func perform(_ action: ArtifactAction, for artifact: SourceArtifact) async throws {
        guard case let .web(url) = artifact.location, Self.isKontextURL(url) else {
            throw KontextPluginError.invalidResponse("artifact is not a Kontext web artifact")
        }
        switch action.kind {
        case .open:
            try await actionOpener.open(url)
        case .copyLink:
            try await actionOpener.copyLink(url)
        case .reveal:
            throw KontextPluginError.unsupportedAction(.reveal)
        }
    }

    public func supportedTaskStates(for task: SourceTask, in artifact: SourceArtifact) async -> Set<SourceTaskState> {
        guard artifact.provider?.pluginID == Self.identifier.rawValue,
              let entity = PluginEntityIdentifier(rawValue: artifact.id),
              entity.source.pluginID == Self.identifier,
              entity.kind == KontextEntityKind.task.rawValue,
              entity.externalID == task.id,
              task.mutationToken == Self.ownedTaskMutationToken(for: entity.externalID) else { return [] }
        return [.open, .completed]
    }

    public func setTaskState(_ state: SourceTaskState, for task: SourceTask, in artifact: SourceArtifact) async throws {
        _ = try await setTaskStateWithAcknowledgement(state, for: task, in: artifact)
    }

    public func setTaskStateWithAcknowledgement(
        _ state: SourceTaskState,
        for task: SourceTask,
        in artifact: SourceArtifact
    ) async throws -> [PluginTaskStateUpdate] {
        guard await supportedTaskStates(for: task, in: artifact).contains(state),
              let entity = PluginEntityIdentifier(rawValue: artifact.id) else {
            throw KontextPluginError.invalidTaskReference
        }
        let updates = try await client.setTaskState(state, externalID: entity.externalID)
        var contentHashes: [String: String] = [:]
        if var retrieved = latestRetrievedSnapshot, retrieved.source.accountID == entity.source.sourceID {
            for update in updates {
                guard let index = retrieved.entities.firstIndex(where: { $0.kind == .task && $0.id == update.taskID }) else { continue }
                retrieved.entities[index].taskStatus = update.status
                contentHashes[update.taskID] = StableHash.hex(retrieved.entities[index].contentRevisionMaterial)
            }
            latestRetrievedSnapshot = retrieved
        }
        return updates.map { update in
            .init(
                artifactID: PluginEntityIdentifier(source: entity.source, kind: KontextEntityKind.task.rawValue, externalID: update.taskID).rawValue,
                taskID: update.taskID,
                state: update.status.sourceState,
                contentHash: contentHashes[update.taskID]
            )
        }
    }

    private func acceptSource(_ source: KontextRemoteSource) throws -> PluginSourceDescriptor {
        let id = PluginSourceIdentifier(pluginID: Self.identifier, sourceID: source.accountID)
        if let knownSource, knownSource.id != id { throw KontextPluginError.accountChanged }
        let descriptor = PluginSourceDescriptor(
            id: id,
            displayName: "Kontext Library",
            kind: "kontext-library",
            detail: "Connected context source",
            presentsUnassignedArtifactsAtRoot: true
        )
        knownSource = descriptor
        sourceConfiguration.save(descriptor)
        return descriptor
    }

    private func map(_ remote: KontextRetrievedSnapshot, source: PluginSourceDescriptor) throws -> ContextSnapshot {
        let sourceID = source.id
        let entityID: (String, String) -> String = { kind, externalID in
            PluginEntityIdentifier(source: sourceID, kind: kind, externalID: externalID).rawValue
        }
        let artifacts = remote.entities.compactMap { entity -> SourceArtifact? in
            guard entity.kind != .project else { return nil }
            let id = entityID(entity.kind.rawValue, entity.id)
            let text = entity.searchText
            return SourceArtifact(
                id: id,
                // A remote item is an artifact, not a pseudo-folder or an
                // implicit activation context. Its provider-scoped ID carries
                // identity; this display path intentionally has no hierarchy.
                relativePath: "\(entity.kind.rawValue)-\(entity.id)",
                mediaKind: .markdown,
                title: entity.title,
                extractedText: text,
                modifiedAt: entity.modifiedAt,
                contentHash: StableHash.hex(entity.contentRevisionMaterial),
                location: .web(entity.permanentLink),
                provider: .init(pluginID: Self.identifier.rawValue, sourceID: source.id.rawValue),
                metadata: .init(
                    kind: entity.kind == .task ? "task" : entity.documentKind,
                    tasks: entity.kind == .task ? [SourceTask(
                        id: entity.id,
                        text: entity.title,
                        state: entity.taskState ?? .open,
                        mutationToken: entity.isShared ? nil : Self.ownedTaskMutationToken(for: entity.id)
                    )] : [],
                    importKind: "kontext",
                    modificationDateReliable: true
                )
            )
        }
        let artifactsByExternalID = Dictionary(uniqueKeysWithValues: artifacts.map { artifact in
            let entity = remote.entities.first { entityID($0.kind.rawValue, $0.id) == artifact.id }!
            return ("\(entity.kind.rawValue):\(entity.id)", artifact.id)
        })
        let entityKeys = Set(remote.entities.map { "\($0.kind.rawValue):\($0.id)" })
        let declarations = remote.entities.compactMap { entity -> ContextDeclaration? in
            guard entity.kind == .project else { return nil }
            let members = remote.entities.compactMap { candidate -> String? in
                guard candidate.projectIDs.contains(entity.id) else { return nil }
                return artifactsByExternalID["\(candidate.kind.rawValue):\(candidate.id)"]
            }.sorted()
            return .init(
                id: entityID(entity.kind.rawValue, entity.id),
                name: entity.title,
                kind: entity.isShared ? "shared project" : entity.contextKind,
                artifactIDs: members
            )
        }
        var declaredRelations: [DeclaredContextRelation] = []
        var directRelations: [ContextRelation] = []
        // Project membership is represented exactly once by the declaration's
        // artifact IDs. The graph projector turns that authored membership
        // into its canonical `includes` edge, so do not add a parallel
        // provider relation here.
        for edge in remote.edges {
            let from = "\(edge.from.kind.rawValue):\(edge.from.id)"
            let to = "\(edge.to.kind.rawValue):\(edge.to.id)"
            guard entityKeys.contains(from), entityKeys.contains(to) else { continue }
            let endpoint: (KontextEndpoint) -> String = { endpoint in
                let id = entityID(endpoint.kind.rawValue, endpoint.id)
                return endpoint.kind == .project ? id : "artifact:\(id)"
            }
            if edge.from.kind == .project, edge.to.kind == .project {
                declaredRelations.append(.init(from: endpoint(edge.from), to: endpoint(edge.to), kind: edge.kind, detail: "kontext-edge:\(edge.publicID)"))
            } else {
                directRelations.append(.init(source: endpoint(edge.from), target: endpoint(edge.to), kind: edge.kind, provenance: .init(detail: "kontext-edge:\(edge.publicID)"), evidence: .authored, weight: 1.0))
            }
        }
        let scan = SourceScan(
            sourceID: sourceID.rawValue,
            artifacts: artifacts,
            declarations: .init(contexts: declarations, relations: declaredRelations),
            diagnostics: remote.entities.filter(\.contentWasTruncated).map { entity in
                .init(
                    id: "kontext-truncated-\(StableHash.hex(entity.key))",
                    severity: .warning,
                    message: "Kontext returned truncated document content; search results for this item may be incomplete.",
                    path: "\(entity.kind.rawValue)s/\(entity.id)"
                )
            } + remote.entities.filter(\.contentWasUnavailable).map { entity in
                .init(
                    id: "kontext-unavailable-\(StableHash.hex(entity.key))",
                    severity: .warning,
                    message: "Kontext could not provide this document's stored content; search results for this item may be incomplete.",
                    path: "\(entity.kind.rawValue)s/\(entity.id)"
                )
            },
            indexedAt: remote.indexedAt
        )
        var snapshot = try builder.build(from: scan)
        snapshot.relations = Array(Set(snapshot.relations + directRelations)).sorted {
            ($0.source, $0.target, $0.kind, $0.provenance.artifactID ?? "") < ($1.source, $1.target, $1.kind, $1.provenance.artifactID ?? "")
        }
        // The server revision identifies the complete, atomically-read provider snapshot. It is a
        // stronger cache validator than a locally reconstructed revision and is accepted only after
        // every page has been structurally validated.
        snapshot.revision = remote.revision
        return try snapshot.validated()
    }

    private static func isKontextURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == productionOrigin.host
    }

    private static func ownedTaskMutationToken(for externalID: String) -> String {
        "kontext-owned-task:\(StableHash.hex(externalID))"
    }
}

// MARK: - Private graph-snapshot contract

struct KontextGraphSnapshotClient: Sendable {
    let transport: any KontextAPITransport
    let origin: URL
    let maximumRestarts: Int

    init(transport: any KontextAPITransport, origin: URL, maximumRestarts: Int) {
        self.transport = transport
        self.origin = origin
        self.maximumRestarts = max(0, maximumRestarts)
    }

    func fetch() async throws -> KontextRetrievedSnapshot {
        for attempt in 0...maximumRestarts {
            do { return try await fetchOnce() }
            catch KontextSnapshotReadError.restartRequested {
                if attempt < maximumRestarts { continue }
            }
        }
        throw KontextPluginError.snapshotChangedTooOften
    }

    func setTaskState(_ state: SourceTaskState, externalID: String) async throws -> [KontextTaskStatusUpdate] {
        let url = origin.appendingPathComponent("api/v1/tasks").appendingPathComponent(externalID)
        let body = try JSONSerialization.data(withJSONObject: ["status": state == .completed ? "done" : "open"])
        let response = try await transport.execute(.init(
            url: url,
            method: "PATCH",
            headers: ["Accept": "application/json", "Content-Type": "application/json"],
            body: body
        ))
        guard (200..<300).contains(response.statusCode) else {
            throw KontextPluginError.invalidResponse("task status update returned HTTP \(response.statusCode)")
        }
        let envelope: KontextTaskStatusMutationEnvelope
        do { envelope = try JSONDecoder().decode(KontextTaskStatusMutationEnvelope.self, from: response.body) }
        catch { throw KontextPluginError.invalidResponse("task status update response could not be decoded") }
        guard envelope.ok else {
            throw KontextPluginError.invalidResponse("task status update did not return a successful envelope")
        }
        if envelope.alreadyDeleted == true { throw KontextPluginError.invalidTaskReference }
        guard envelope.item?.id == externalID,
              envelope.item?.isCompleted == (state == .completed) else {
            throw KontextPluginError.invalidResponse("task status update returned an unexpected task")
        }
        let updates = envelope.taskStatusUpdates ?? [
            .init(taskID: externalID, status: state == .completed ? .done : .open),
        ]
        guard updates.contains(where: { $0.taskID == externalID && $0.status.sourceState == state }) else {
            throw KontextPluginError.invalidResponse("task status update omitted the requested task")
        }
        return updates
    }

    private func fetchOnce() async throws -> KontextRetrievedSnapshot {
        var cursor: String?
        var expectedOffset = 0
        var expectedTotal: Int?
        var expectedRevision: String?
        var expectedSource: KontextRemoteSource?
        var entities: [KontextRemoteEntity] = []
        var edges: [KontextRemoteEdge] = []
        var seenEntities = Set<String>()
        var seenEdges = Set<String>()
        while true {
            var components = URLComponents(url: origin.appendingPathComponent("api/v1/graph-snapshot"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "includeShared", value: "true"),
                URLQueryItem(name: "limit", value: "100"),
            ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            guard let url = components.url else { throw KontextPluginError.invalidResponse("could not form request URL") }
            let response = try await transport.execute(.init(url: url, headers: ["Accept": "application/json"]))
            if response.statusCode == 409 {
                if try Self.isRestartResponse(response.body) { throw KontextSnapshotReadError.restartRequested }
                throw KontextPluginError.invalidResponse("HTTP 409 did not request a safe restart")
            }
            guard (200..<300).contains(response.statusCode) else {
                throw KontextPluginError.invalidResponse("HTTP \(response.statusCode)")
            }
            let envelope: KontextSnapshotEnvelope
            do { envelope = try JSONDecoder().decode(KontextSnapshotEnvelope.self, from: response.body) }
            catch { throw KontextPluginError.invalidResponse("JSON decoding failed: \(error)") }
            guard envelope.ok, envelope.version == 1 else { throw KontextPluginError.invalidResponse("missing successful version-1 envelope") }
            let page = try envelope.snapshot.validated(expectedOffset: expectedOffset, expectedTotal: expectedTotal, expectedRevision: expectedRevision, expectedSource: expectedSource)
            guard page.entities.count <= page.limit else { throw KontextPluginError.invalidResponse("page exceeds its requested limit") }
            for entity in page.entities {
                guard seenEntities.insert(entity.key).inserted else { throw KontextPluginError.invalidResponse("duplicate entity \(entity.key)") }
                entities.append(entity)
            }
            let pageEntityKeys = Set(page.entities.map(\.key))
            for edge in page.edges {
                guard pageEntityKeys.contains(edge.from.key) else { throw KontextPluginError.invalidResponse("edge source was not included in its page") }
                guard seenEdges.insert(edge.identityMaterial).inserted else { throw KontextPluginError.invalidResponse("duplicate edge \(edge.publicID)") }
                edges.append(edge)
            }
            expectedOffset += page.entities.count
            expectedTotal = page.totalEntities
            expectedRevision = page.revision
            expectedSource = page.source
            if page.complete {
                guard expectedOffset == page.totalEntities, seenEntities.count == page.totalEntities else {
                    throw KontextPluginError.invalidResponse("complete page did not cover the declared snapshot")
                }
                guard edges.allSatisfy({ seenEntities.contains($0.from.key) && seenEntities.contains($0.to.key) }) else {
                    throw KontextPluginError.invalidResponse("edge references an entity outside the complete snapshot")
                }
                return .init(source: page.source, revision: page.revision, entities: entities, edges: edges, indexedAt: Date())
            }
            guard !page.entities.isEmpty, let next = page.nextCursor, !next.isEmpty else {
                throw KontextPluginError.invalidResponse("incomplete page did not advance")
            }
            cursor = next
        }
    }

    private static func isRestartResponse(_ data: Data) throws -> Bool {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["restart"] as? Bool == true,
              let error = value["error"] as? [String: Any], error["code"] as? String == "snapshot_changed" else { return false }
        return true
    }
}

private enum KontextSnapshotReadError: Error { case restartRequested }

struct KontextRetrievedSnapshot: Sendable {
    var source: KontextRemoteSource
    var revision: String
    var entities: [KontextRemoteEntity]
    var edges: [KontextRemoteEdge]
    var indexedAt: Date
}

struct KontextSnapshotEnvelope: Decodable {
    let ok: Bool
    let version: Int
    let snapshot: KontextSnapshotPage
}

struct KontextSnapshotPage: Decodable {
    let source: KontextRemoteSource
    let schemaVersion: Int
    let scope: KontextSnapshotScope
    let revision: String
    let page: KontextPageInfo
    let entities: [KontextRemoteEntity]
    let edges: [KontextRemoteEdge]

    func validated(expectedOffset: Int, expectedTotal: Int?, expectedRevision: String?, expectedSource: KontextRemoteSource?) throws -> KontextValidatedPage {
        guard schemaVersion == 1, revision.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw KontextPluginError.invalidResponse("unsupported schema or revision")
        }
        guard scope == .ownedAndShared else {
            throw KontextPluginError.invalidResponse("snapshot omitted the requested shared scope")
        }
        guard page.limit == 100, page.offset == expectedOffset, page.totalEntities >= 0 else {
            throw KontextPluginError.invalidResponse("invalid page offsets")
        }
        guard expectedTotal == nil || expectedTotal == page.totalEntities,
              expectedRevision == nil || expectedRevision == revision,
              expectedSource == nil || expectedSource == source else {
            throw KontextPluginError.invalidResponse("pages mixed snapshot identity")
        }
        let consumed = page.offset + entities.count
        guard consumed <= page.totalEntities else { throw KontextPluginError.invalidResponse("page exceeds total entities") }
        if page.complete {
            guard page.nextCursor == nil, consumed == page.totalEntities else { throw KontextPluginError.invalidResponse("invalid completion marker") }
        } else {
            guard page.nextCursor != nil, consumed < page.totalEntities else { throw KontextPluginError.invalidResponse("invalid incomplete page") }
        }
        let ordered = entities.sorted { ($0.kind.sortOrder, $0.id) < ($1.kind.sortOrder, $1.id) }
        guard ordered.map(\.key) == entities.map(\.key) else { throw KontextPluginError.invalidResponse("entities are not deterministically ordered") }
        return .init(source: source, revision: revision, limit: page.limit, totalEntities: page.totalEntities, complete: page.complete, nextCursor: page.nextCursor, entities: entities, edges: edges)
    }
}

enum KontextSnapshotScope: String, Decodable, Sendable {
    case ownedAndShared = "owned_and_shared"
}

struct KontextValidatedPage {
    var source: KontextRemoteSource
    var revision: String
    var limit: Int
    var totalEntities: Int
    var complete: Bool
    var nextCursor: String?
    var entities: [KontextRemoteEntity]
    var edges: [KontextRemoteEdge]
}

struct KontextRemoteSource: Decodable, Hashable, Sendable {
    let provider: String
    let accountID: String

    enum CodingKeys: String, CodingKey { case provider; case accountID = "accountId" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(String.self, forKey: .provider)
        accountID = try values.decode(String.self, forKey: .accountID)
        guard provider == "kontext", !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KontextPluginError.invalidResponse("invalid source identity")
        }
    }
}

struct KontextPageInfo: Decodable {
    let limit: Int
    let offset: Int
    let totalEntities: Int
    let nextCursor: String?
    let complete: Bool
}

enum KontextEntityKind: String, Codable, Sendable {
    case project, task, document
    var sortOrder: Int { self == .project ? 0 : self == .task ? 1 : 2 }
}

/// Kontext owns its richer task lifecycle. Embers Core currently needs only
/// the actionable/terminal distinction used by context task presentation.
enum KontextTaskStatus: String, Decodable, Sendable {
    case open
    case inProgress = "in_progress"
    case done
    case cancelled

    var sourceState: SourceTaskState {
        switch self {
        case .open, .inProgress: return .open
        case .done, .cancelled: return .completed
        }
    }
}

struct KontextTaskStatusUpdate: Decodable, Sendable {
    let taskID: String
    let status: KontextTaskStatus

    init(taskID: String, status: KontextTaskStatus) {
        self.taskID = taskID
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case taskID = "taskId", status }
}

private struct KontextTaskStatusMutationEnvelope: Decodable {
    struct Item: Decodable {
        let id: String
        let isCompleted: Bool
    }

    let ok: Bool
    let alreadyDeleted: Bool?
    let item: Item?
    let taskStatusUpdates: [KontextTaskStatusUpdate]?
}

struct KontextEndpoint: Codable, Hashable, Sendable {
    let kind: KontextEntityKind
    let id: String
    enum CodingKeys: String, CodingKey { case kind = "type"; case id }
    var key: String { "\(kind.rawValue):\(id)" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(KontextEntityKind.self, forKey: .kind)
        id = try values.decode(String.self, forKey: .id)
        guard !id.isEmpty else { throw KontextPluginError.invalidResponse("empty entity ID") }
    }
}

struct KontextRemoteEdge: Decodable, Sendable {
    let kind: String
    let from: KontextEndpoint
    let to: KontextEndpoint
    let evidence: KontextEdgeEvidence

    enum CodingKeys: String, CodingKey { case kind, from, to, evidence }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        from = try values.decode(KontextEndpoint.self, forKey: .from)
        to = try values.decode(KontextEndpoint.self, forKey: .to)
        evidence = try values.decode(KontextEdgeEvidence.self, forKey: .evidence)
        guard !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KontextPluginError.invalidResponse("invalid edge")
        }
    }

    /// The wire contract intentionally excludes database row IDs. This stable
    /// public identity is derived only from canonical graph facts, so it can be
    /// used for dedupe and provenance without leaking provider internals.
    var identityMaterial: String {
        [
            stableField("kind", kind),
            stableField("from-type", from.kind.rawValue),
            stableField("from-id", from.id),
            stableField("to-type", to.kind.rawValue),
            stableField("to-id", to.id),
            stableField("evidence-source", evidence.source),
            stableField("asserted-at", evidence.assertedAt),
            stableField("metadata", evidence.metadata.canonicalRepresentation),
        ].joined(separator: "|")
    }

    var publicID: String { StableHash.hex(identityMaterial) }
}

/// Provider-authored evidence is part of an edge's observable identity. The
/// server emits metadata with recursively sorted keys; the client still
/// canonicalizes it before dedupe so JSON object ordering can never affect the
/// accepted graph.
struct KontextEdgeEvidence: Decodable, Sendable {
    let source: String
    let assertedAt: String
    let metadata: KontextJSONValue

    enum CodingKeys: String, CodingKey { case source, assertedAt, metadata }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(String.self, forKey: .source)
        assertedAt = try values.decode(String.self, forKey: .assertedAt)
        metadata = try values.decode(KontextJSONValue.self, forKey: .metadata)
        guard source == "kontext", !assertedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KontextPluginError.invalidResponse("invalid edge evidence")
        }
    }
}

indirect enum KontextJSONValue: Decodable, Sendable {
    case object([String: KontextJSONValue])
    case array([KontextJSONValue])
    case string(String)
    case number(Decimal)
    case boolean(Bool)
    case null

    private struct Key: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: Key.self) {
            var values: [String: KontextJSONValue] = [:]
            for key in keyed.allKeys { values[key.stringValue] = try keyed.decode(KontextJSONValue.self, forKey: key) }
            self = .object(values)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var values: [KontextJSONValue] = []
            while !unkeyed.isAtEnd { values.append(try unkeyed.decode(KontextJSONValue.self)) }
            self = .array(values)
            return
        }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
        else if let decimal = try? value.decode(Decimal.self) { self = .number(decimal) }
        else { self = .string(try value.decode(String.self)) }
    }

    var canonicalRepresentation: String {
        switch self {
        case let .object(values):
            return "object[" + values.keys.sorted().map { stableField($0, values[$0]!.canonicalRepresentation) }.joined(separator: ",") + "]"
        case let .array(values):
            return "array[" + values.map(\.canonicalRepresentation).joined(separator: ",") + "]"
        case let .string(value): return stableField("string", value)
        case let .number(value): return stableField("number", NSDecimalNumber(decimal: value).stringValue)
        case let .boolean(value): return value ? "boolean:1" : "boolean:0"
        case .null: return "null"
        }
    }
}

private func stableField(_ name: String, _ value: String) -> String {
    "\(name.utf8.count):\(name)\(value.utf8.count):\(value)"
}

struct KontextRemoteEntity: Decodable, Sendable {
    let kind: KontextEntityKind
    let id: String
    let title: String
    let permanentLink: URL
    let modifiedAt: Date
    let projectIDs: [String]
    let searchText: String
    let documentKind: String?
    let bodyTruncated: Bool
    let bodyUnavailable: Bool
    let access: KontextEntityAccess?
    var taskStatus: KontextTaskStatus?

    var taskState: SourceTaskState? { taskStatus?.sourceState }

    enum CodingKeys: String, CodingKey {
        case entityType = "type", id, title, permanentLink, createdAt, updatedAt, content, body, bodyTruncated, bodyUnavailable, projectID = "projectId", projectIDs = "projectIds", description, documentKind = "kind", status, access
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(KontextEntityKind.self, forKey: .entityType)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        permanentLink = try values.decode(URL.self, forKey: .permanentLink)
        bodyTruncated = try values.decodeIfPresent(Bool.self, forKey: .bodyTruncated) ?? false
        bodyUnavailable = try values.decodeIfPresent(Bool.self, forKey: .bodyUnavailable) ?? false
        access = try values.decodeIfPresent(KontextEntityAccess.self, forKey: .access)
        guard !id.isEmpty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              permanentLink.scheme?.lowercased() == "https", permanentLink.host?.lowercased() == KontextPlugin.productionOrigin.host else {
            throw KontextPluginError.invalidResponse("invalid entity identity or permanent link")
        }
        let createdAt = try values.decode(String.self, forKey: .createdAt)
        switch kind {
        case .project:
            taskStatus = nil
            modifiedAt = try Self.date(createdAt)
            projectIDs = []
            searchText = title + "\n" + (try values.decode(String?.self, forKey: .description) ?? "")
            documentKind = "project"
        case .task:
            taskStatus = try values.decode(KontextTaskStatus.self, forKey: .status)
            modifiedAt = try Self.date(createdAt)
            let project = try values.decode(String?.self, forKey: .projectID)
            projectIDs = project.map { [$0] } ?? []
            searchText = title + "\n" + (try values.decode(String.self, forKey: .content))
            documentKind = "task"
        case .document:
            taskStatus = nil
            modifiedAt = try Self.date(try values.decode(String.self, forKey: .updatedAt))
            projectIDs = try values.decode([String].self, forKey: .projectIDs)
            searchText = title + "\n" + (try values.decode(String?.self, forKey: .body) ?? "")
            documentKind = try values.decode(String?.self, forKey: .documentKind)
        }
        guard Set(projectIDs).count == projectIDs.count, projectIDs.allSatisfy({ !$0.isEmpty }) else {
            throw KontextPluginError.invalidResponse("invalid project membership")
        }
        guard kind == .document || (!bodyTruncated && !bodyUnavailable) else {
            throw KontextPluginError.invalidResponse("non-document entity declared document body state")
        }
    }

    var key: String { "\(kind.rawValue):\(id)" }
    var isShared: Bool { access != nil }
    var contentWasTruncated: Bool { bodyTruncated }
    var contentWasUnavailable: Bool { bodyUnavailable }
    var contextKind: String { kind == .project ? "project" : kind == .task ? "task" : (documentKind ?? "document") }

    /// Canonical semantic and behavioral state used by Changed Since Last Peek.
    /// `modifiedAt` is intentionally excluded: it remains useful for ordering,
    /// but server clocks and metadata-only touches are not evidence of change.
    var contentRevisionMaterial: String {
        let projects = projectIDs.sorted().map { stableField("project", $0) }.joined()
        let accessMaterial = access.map {
            [
                stableField("scope", $0.scope),
                stableField("read-only", $0.readOnly ? "true" : "false"),
                stableField("permission", $0.permission.rawValue),
                stableField("shared-by", $0.sharedBy),
            ].joined()
        } ?? "none"
        return [
            stableField("kind", kind.rawValue),
            stableField("id", id),
            stableField("text", searchText),
            stableField("document-kind", documentKind ?? "none"),
            stableField("task-status", taskStatus?.rawValue ?? "none"),
            stableField("projects", projects),
            stableField("permanent-link", permanentLink.absoluteString),
            stableField("body-truncated", bodyTruncated ? "true" : "false"),
            stableField("body-unavailable", bodyUnavailable ? "true" : "false"),
            stableField("access", accessMaterial),
        ].joined()
    }

    private static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else { throw KontextPluginError.invalidResponse("invalid timestamp") }
        return date
    }
}

struct KontextEntityAccess: Decodable, Sendable {
    let scope: String
    let readOnly: Bool
    let permission: KontextEntityPermission
    let sharedBy: String

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scope = try values.decode(String.self, forKey: .scope)
        readOnly = try values.decode(Bool.self, forKey: .readOnly)
        permission = try values.decode(KontextEntityPermission.self, forKey: .permission)
        sharedBy = try values.decode(String.self, forKey: .sharedBy)
        guard scope == "shared", readOnly,
              !sharedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KontextPluginError.invalidResponse("invalid shared access metadata")
        }
    }

    private enum CodingKeys: String, CodingKey { case scope, readOnly, permission, sharedBy }
}

enum KontextEntityPermission: String, Decodable, Sendable {
    case read, edit
}
