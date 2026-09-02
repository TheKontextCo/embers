import XCTest
import EmbersCore
import EmbersPluginHost
import EmbersPluginKit

/// Acceptance tests for the plugin boundary itself. This provider deliberately
/// has no dependency on FolderPlugin, KontextPlugin, or app-layer types: if it
/// can participate end to end, a third compiled-in provider can do the same.
final class ThirdProviderAcceptanceTests: XCTestCase {
    func testThirdProviderParticipatesEndToEndThroughProviderNeutralContracts() async throws {
        let provider = ThirdProvider()
        let cached = makeThirdSnapshot(revision: "cached", title: "Cached brief", taskState: .open)
        let repository = AcceptanceRepository(seed: [ThirdProvider.sourceID: cached])
        let host = try PluginHost(plugins: [provider], repository: repository)

        let registered = await host.registeredPlugins()
        let disconnectedStatus = await host.connectionStatus(for: ThirdProvider.identifier)
        XCTAssertEqual(registered.map(\.id), [ThirdProvider.identifier])
        XCTAssertEqual(disconnectedStatus?.state, .requiresAuthentication)
        try await host.connect(ThirdProvider.identifier)
        let connectedStatus = await host.connectionStatus(for: ThirdProvider.identifier)
        XCTAssertEqual(connectedStatus?.state, .connected)

        let discovered = try await host.synchronizeSources()
        XCTAssertEqual(discovered.map(\.descriptor.id), [ThirdProvider.sourceID])
        let cachedWorkspace = await host.workspaceSnapshot()
        XCTAssertEqual(cachedWorkspace?.artifacts.single()?.title, "Cached brief")

        let refreshed = await host.refresh(ThirdProvider.sourceID)
        XCTAssertEqual(refreshed.workspace?.artifacts.single()?.title, "Current brief")
        let persistedCurrent = await repository.load(for: ThirdProvider.sourceID)
        XCTAssertEqual(persistedCurrent?.revision, "current")

        let artifact = try XCTUnwrap(refreshed.workspace?.artifacts.single())
        let actions = await host.availableArtifactActions(for: artifact)
        XCTAssertEqual(actions.map(\.id), ["third.open"])
        try await host.performDefaultOpen(for: artifact)
        XCTAssertEqual(provider.openedArtifactIDs, [artifact.id])

        let task = try XCTUnwrap(artifact.metadata.tasks.single())
        let supportedStates = await host.supportedTaskStates(for: task, in: artifact)
        XCTAssertEqual(supportedStates, [.open, .completed])
        let mutation = try await host.setTaskState(.completed, for: task, in: artifact)
        XCTAssertEqual(mutation.source, ThirdProvider.sourceID)
        XCTAssertEqual(mutation.workspace?.artifacts.single()?.metadata.tasks.single()?.state, .completed)
        XCTAssertEqual(provider.mutations, ["ship:.completed"])

        try await waitUntil { provider.hasObserver }
        provider.publish(makeThirdSnapshot(revision: "observed", title: "Observed update", taskState: .completed))
        try await waitUntil {
            await host.workspaceSnapshot()?.artifacts.single()?.title == "Observed update"
        }
        let observedWorkspace = await host.workspaceSnapshot()
        let persistedObserved = await repository.load(for: ThirdProvider.sourceID)
        XCTAssertEqual(observedWorkspace?.revision, try XCTUnwrap(persistedObserved).mapToWorkspaceRevision())
    }

    func testThirdProviderMutationRefreshesOnlyTheOwningSource() async throws {
        let provider = ThirdProvider()
        let peer = CountingProvider()
        let host = try PluginHost(plugins: [provider, peer], repository: AcceptanceRepository())
        try await host.synchronizeSources()
        _ = await host.refreshAll()
        let peerRefreshesBeforeMutation = peer.refreshCount

        let fetchedWorkspace = await host.workspaceSnapshot()
        let workspace = try XCTUnwrap(fetchedWorkspace)
        let artifact = try XCTUnwrap(workspace.artifacts.first { $0.provider?.pluginID == ThirdProvider.identifier.rawValue })
        let task = try XCTUnwrap(artifact.metadata.tasks.single())
        _ = try await host.setTaskState(.completed, for: task, in: artifact)

        XCTAssertEqual(peer.refreshCount, peerRefreshesBeforeMutation)
        XCTAssertEqual(provider.refreshCount, 2, "The provider refreshes once initially and once after its mutation")
        let mutatedWorkspace = await host.workspaceSnapshot()
        XCTAssertEqual(Set(mutatedWorkspace?.artifacts.map(\.title) ?? []), ["Current brief", "Peer brief"])
    }

    func testMalformedThirdProviderRefreshCannotReplaceItsCacheOrHealthyPeer() async throws {
        let provider = ThirdProvider()
        let peer = CountingProvider()
        let cached = makeThirdSnapshot(revision: "cached", title: "Cached brief", taskState: .open)
        let repository = AcceptanceRepository(seed: [ThirdProvider.sourceID: cached])
        let host = try PluginHost(plugins: [provider, peer], repository: repository)
        try await host.synchronizeSources()
        _ = await host.refresh(CountingProvider.sourceID)
        provider.returnSnapshotForWrongSource = true

        let outcome = await host.refresh(ThirdProvider.sourceID)

        XCTAssertEqual(outcome.workspace?.artifacts.first { $0.provider?.pluginID == ThirdProvider.identifier.rawValue }?.title, "Cached brief")
        XCTAssertEqual(outcome.workspace?.artifacts.first { $0.provider?.pluginID == CountingProvider.identifier.rawValue }?.title, "Peer brief")
        let retainedCache = await repository.load(for: ThirdProvider.sourceID)
        XCTAssertEqual(retainedCache?.revision, "cached")
        guard case .stale = outcome.sourceState.health else {
            return XCTFail("An invalid provider candidate must fail closed and retain its last-good cache")
        }
    }

    func testStrictCompositionRejectsAnchorCollisionsAsWellAsArtifactCollisions() throws {
        let alpha = PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: "alpha")!, sourceID: "one")
        let beta = PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: "beta")!, sourceID: "two")
        let first = makeSnapshot(sourceID: alpha, artifactID: "alpha-artifact", anchorID: "shared-anchor", title: "Alpha")
        let second = makeSnapshot(sourceID: beta, artifactID: "beta-artifact", anchorID: "shared-anchor", title: "Beta")

        XCTAssertThrowsError(try PluginHost.compose([(alpha, first), (beta, second)])) { error in
            XCTAssertEqual(error as? PluginHostError, .anchorIDCollision("shared-anchor"))
        }
    }

    func testExplicitUnknownProviderProvenanceNeverFallsBackToAnotherPlugin() async throws {
        let host = try PluginHost(plugins: [GreedyActionProvider()], repository: AcceptanceRepository())
        let artifact = SourceArtifact(
            id: "ghost-artifact",
            relativePath: "Ghost",
            mediaKind: .text,
            title: "Ghost",
            extractedText: "",
            modifiedAt: .distantPast,
            contentHash: "ghost",
            location: .provider(pluginID: "missing-provider", externalID: "ghost"),
            provider: .init(pluginID: "missing-provider", sourceID: "missing-provider:source:account")
        )

        let actions = await host.availableArtifactActions(for: artifact)
        XCTAssertTrue(actions.isEmpty, "Explicit provenance must fail closed; fallback is only valid for genuinely legacy artifacts without provenance")
        do {
            try await host.performDefaultOpen(for: artifact)
            XCTFail("An unrelated provider must never receive an explicitly owned artifact")
        } catch let error as PluginHostError {
            XCTAssertEqual(error, .noArtifactAction)
        }
    }

    func testTaskMutationRejectsAProviderAndSourceNamespaceMismatch() async throws {
        let provider = ThirdProvider()
        let peer = CountingProvider()
        let host = try PluginHost(plugins: [provider, peer], repository: AcceptanceRepository())
        try await host.synchronizeSources()
        _ = await host.refreshAll()
        let peerRefreshesBeforeMutation = peer.refreshCount
        let fetchedWorkspace = await host.workspaceSnapshot()
        var artifact = try XCTUnwrap(fetchedWorkspace?.artifacts.first {
            $0.provider?.pluginID == ThirdProvider.identifier.rawValue
        })
        artifact.provider = .init(
            pluginID: ThirdProvider.identifier.rawValue,
            sourceID: CountingProvider.sourceID.rawValue
        )
        let task = try XCTUnwrap(artifact.metadata.tasks.single())

        do {
            _ = try await host.setTaskState(.completed, for: task, in: artifact)
            XCTFail("A task must not mutate through one provider and refresh another provider's source")
        } catch let error as PluginHostError {
            XCTAssertEqual(error, .taskSourceUnavailable)
        }
        XCTAssertTrue(provider.mutations.isEmpty)
        XCTAssertEqual(peer.refreshCount, peerRefreshesBeforeMutation)
    }

    /// Capability metadata is consumed by generic settings and lifecycle UI.
    /// It must be host-verified truth, not a second hand-maintained declaration
    /// that can drift away from the protocols a provider actually implements.
    func testRegisteredCapabilitiesAreDerivedFromImplementedContracts() async throws {
        let understated = ThirdProvider(declaredCapabilities: [.sourceRefresh])
        let overstated = DeclaredOnlyActionProvider()
        let host = try PluginHost(plugins: [understated, overstated], repository: AcceptanceRepository())

        let descriptors = Dictionary(uniqueKeysWithValues: await host.registeredPlugins().map { ($0.id, $0) })
        XCTAssertEqual(
            descriptors[ThirdProvider.identifier]?.capabilities,
            [.connection, .sourceRefresh, .changeObservation, .artifactActions, .taskMutation]
        )
        XCTAssertEqual(
            descriptors[DeclaredOnlyActionProvider.identifier]?.capabilities,
            [.sourceRefresh],
            "Advertising a capability without implementing its contract must not leak into app UI"
        )
    }
}

private final class ThirdProvider: PluginConnecting, PluginSourceProviding, PluginRefreshing, PluginChangeObserving, PluginArtifactActionProviding, PluginTaskMutating, @unchecked Sendable {
    static let identifier = PluginIdentifier(rawValue: "third")!
    static let sourceID = PluginSourceIdentifier(pluginID: identifier, sourceID: "account")

    let descriptor: PluginDescriptor
    private let lock = NSLock()
    private var snapshot = makeThirdSnapshot(revision: "current", title: "Current brief", taskState: .open)
    private var continuation: AsyncStream<Void>.Continuation?
    private var connected = false
    private var _openedArtifactIDs: [String] = []
    private var _mutations: [String] = []
    private var _refreshCount = 0
    private var _returnSnapshotForWrongSource = false

    init(declaredCapabilities: Set<PluginCapability> = [.connection, .sourceRefresh, .changeObservation, .artifactActions, .taskMutation]) {
        descriptor = .init(id: Self.identifier, displayName: "Third Provider", version: "1", capabilities: declaredCapabilities)
    }

    var openedArtifactIDs: [String] { lock.withLock { _openedArtifactIDs } }
    var mutations: [String] { lock.withLock { _mutations } }
    var refreshCount: Int { lock.withLock { _refreshCount } }
    var hasObserver: Bool { lock.withLock { continuation != nil } }
    var returnSnapshotForWrongSource: Bool {
        get { lock.withLock { _returnSnapshotForWrongSource } }
        set { lock.withLock { _returnSnapshotForWrongSource = newValue } }
    }

    func connectionStatus() async -> PluginConnectionStatus {
        .init(state: lock.withLock { connected } ? .connected : .requiresAuthentication)
    }

    func connect() async throws { lock.withLock { connected = true } }
    func disconnect() async throws { lock.withLock { connected = false } }

    func sources() async throws -> [PluginSourceDescriptor] {
        [.init(id: Self.sourceID, displayName: "Third Account", kind: "synthetic")]
    }

    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        let result = lock.withLock { () -> ContextSnapshot in
            _refreshCount += 1
            guard _returnSnapshotForWrongSource else { return snapshot }
            var invalid = snapshot
            invalid.sourceID = "other:source:account"
            return invalid
        }
        return .init(source: source, snapshot: result)
    }

    func changes(for source: PluginSourceDescriptor) -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
    }

    func artifactActions(for artifact: SourceArtifact) -> [ArtifactAction] {
        guard artifact.provider?.pluginID == Self.identifier.rawValue else { return [] }
        return [.init(id: "third.open", title: "Open", kind: .open)]
    }

    func perform(_ action: ArtifactAction, for artifact: SourceArtifact) async throws {
        lock.withLock { _openedArtifactIDs.append(artifact.id) }
    }

    func supportedTaskStates(for task: SourceTask, in artifact: SourceArtifact) async -> Set<SourceTaskState> {
        artifact.provider?.pluginID == Self.identifier.rawValue ? [.open, .completed] : []
    }

    func setTaskState(_ state: SourceTaskState, for task: SourceTask, in artifact: SourceArtifact) async throws {
        lock.withLock {
            _mutations.append("\(task.id):.\(state.rawValue)")
            snapshot = makeThirdSnapshot(revision: "task-\(state.rawValue)", title: "Current brief", taskState: state)
        }
    }

    func publish(_ snapshot: ContextSnapshot) {
        let observer = lock.withLock { () -> AsyncStream<Void>.Continuation? in
            self.snapshot = snapshot
            return continuation
        }
        observer?.yield()
    }
}

private final class CountingProvider: PluginSourceProviding, PluginRefreshing, @unchecked Sendable {
    static let identifier = PluginIdentifier(rawValue: "peer")!
    static let sourceID = PluginSourceIdentifier(pluginID: identifier, sourceID: "one")
    let descriptor = PluginDescriptor(id: identifier, displayName: "Peer", version: "1", capabilities: [.sourceRefresh])
    private let lock = NSLock()
    private var _refreshCount = 0
    var refreshCount: Int { lock.withLock { _refreshCount } }

    func sources() async throws -> [PluginSourceDescriptor] {
        [.init(id: Self.sourceID, displayName: "Peer", kind: "synthetic")]
    }

    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        lock.withLock { _refreshCount += 1 }
        return .init(source: source, snapshot: makeSnapshot(sourceID: Self.sourceID, artifactID: "peer-artifact", anchorID: "peer-anchor", title: "Peer brief"))
    }
}

private struct DeclaredOnlyActionProvider: PluginSourceProviding, PluginRefreshing {
    static let identifier = PluginIdentifier(rawValue: "overstated")!
    let descriptor = PluginDescriptor(id: identifier, displayName: "Overstated", version: "1", capabilities: [.sourceRefresh, .artifactActions])

    func sources() async throws -> [PluginSourceDescriptor] { [] }
    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult { .init(unchanged: source) }
}

private struct GreedyActionProvider: PluginSourceProviding, PluginRefreshing, PluginArtifactActionProviding {
    static let identifier = PluginIdentifier(rawValue: "greedy")!
    let descriptor = PluginDescriptor(id: identifier, displayName: "Greedy", version: "1", capabilities: [.sourceRefresh, .artifactActions])

    func sources() async throws -> [PluginSourceDescriptor] { [] }
    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult { .init(unchanged: source) }
    func artifactActions(for artifact: SourceArtifact) -> [ArtifactAction] { [.init(id: "greedy.open", title: "Open", kind: .open)] }
    func perform(_ action: ArtifactAction, for artifact: SourceArtifact) async throws {}
}

private actor AcceptanceRepository: PluginSnapshotRepository {
    private var snapshots: [PluginSourceIdentifier: ContextSnapshot]

    init(seed: [PluginSourceIdentifier: ContextSnapshot] = [:]) { snapshots = seed }
    func load(for source: PluginSourceIdentifier) async -> ContextSnapshot? { snapshots[source] }
    func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws { snapshots[source] = snapshot }
    func remove(source: PluginSourceIdentifier) async throws { snapshots.removeValue(forKey: source) }
}

private func makeThirdSnapshot(revision: String, title: String, taskState: SourceTaskState) -> ContextSnapshot {
    let artifactID = PluginEntityIdentifier(source: ThirdProvider.sourceID, kind: "document", externalID: "brief").rawValue
    let anchorID = PluginEntityIdentifier(source: ThirdProvider.sourceID, kind: "project", externalID: "apollo").rawValue
    let artifact = SourceArtifact(
        id: artifactID,
        relativePath: "Apollo/Brief",
        mediaKind: .text,
        title: title,
        extractedText: title,
        modifiedAt: Date(timeIntervalSince1970: 1),
        contentHash: revision,
        location: .provider(pluginID: ThirdProvider.identifier.rawValue, externalID: "brief"),
        provider: .init(pluginID: ThirdProvider.identifier.rawValue, sourceID: ThirdProvider.sourceID.rawValue),
        metadata: .init(tasks: [.init(id: "ship", text: "Ship", state: taskState, mutationToken: revision)])
    )
    return .init(
        sourceID: ThirdProvider.sourceID.rawValue,
        revision: revision,
        artifacts: [artifact],
        anchors: [.init(id: anchorID, canonicalName: "Apollo", provenance: [.manifest], memberArtifactIDs: [artifactID])],
        relations: [],
        diagnostics: [],
        indexedAt: Date(timeIntervalSince1970: 1)
    )
}

private func makeSnapshot(sourceID: PluginSourceIdentifier, artifactID: String, anchorID: String, title: String) -> ContextSnapshot {
    let artifact = SourceArtifact(
        id: artifactID,
        relativePath: title,
        mediaKind: .text,
        title: title,
        extractedText: title,
        modifiedAt: .distantPast,
        contentHash: artifactID,
        location: .provider(pluginID: sourceID.pluginID.rawValue, externalID: artifactID),
        provider: .init(pluginID: sourceID.pluginID.rawValue, sourceID: sourceID.rawValue)
    )
    return .init(
        sourceID: sourceID.rawValue,
        revision: artifactID,
        artifacts: [artifact],
        anchors: [.init(id: anchorID, canonicalName: title, provenance: [.manifest], memberArtifactIDs: [artifactID])],
        relations: [],
        diagnostics: [],
        indexedAt: .distantPast
    )
}

private func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AcceptanceTimeout()
}

private struct AcceptanceTimeout: Error {}

private extension Array {
    func single() -> Element? { count == 1 ? first : nil }
}

private extension ContextSnapshot {
    func mapToWorkspaceRevision() -> String {
        StableHash.hex("\(ThirdProvider.sourceID.rawValue):\(revision)")
    }
}
