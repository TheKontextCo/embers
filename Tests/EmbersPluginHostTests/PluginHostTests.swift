import XCTest
import EmbersCore
import EmbersLocal
import EmbersPluginHost
import EmbersPluginKit
import FolderPlugin

final class PluginHostTests: XCTestCase {
    func testSourceStateStreamPublishesIndexingBeforeAcceptingReplacement() async throws {
        let pluginID = PluginIdentifier(rawValue: "delayed")!
        let sourceID = PluginSourceIdentifier(pluginID: pluginID, sourceID: "one")
        let plugin = SuspendedPlugin(
            source: .init(id: sourceID, displayName: "Delayed", kind: "synthetic"),
            snapshot: snapshot(source: sourceID.rawValue, artifactID: "fresh", anchorID: "fresh-anchor")
        )
        let host = try PluginHost(plugins: [plugin], repository: MemoryRepository())
        try await host.synchronizeSources()
        let updates = await host.sourceStateUpdates()
        var iterator = updates.makeAsyncIterator()

        let initialUpdate = await iterator.next()
        let initial = try XCTUnwrap(initialUpdate?.single())
        XCTAssertEqual(initial.health, .idle)

        let refresh = Task { await host.refresh(sourceID) }
        await plugin.waitUntilRefreshStarts()
        let indexingUpdate = await iterator.next()
        let indexing = try XCTUnwrap(indexingUpdate?.single())
        XCTAssertEqual(indexing.health, .refreshing)
        let workspaceWhileIndexing = await host.workspaceSnapshot()
        XCTAssertNil(workspaceWhileIndexing)

        await plugin.completeRefresh()
        _ = await refresh.value
        let readyUpdate = await iterator.next()
        let ready = try XCTUnwrap(readyUpdate?.single())
        XCTAssertEqual(ready.health, .ready)
        let acceptedWorkspace = await host.workspaceSnapshot()
        XCTAssertEqual(acceptedWorkspace?.artifacts.map(\.id), ["fresh"])
    }

    func testTwoSyntheticPluginsCoexist() async throws {
        let first = SyntheticPlugin(id: "alpha", sourceID: "one", snapshot: snapshot(source: "alpha:source:one", artifactID: "a", anchorID: "anchor-a"))
        let second = SyntheticPlugin(id: "beta", sourceID: "two", snapshot: snapshot(source: "beta:source:two", artifactID: "b", anchorID: "anchor-b"))
        let host = try PluginHost(plugins: [first, second], repository: MemoryRepository())
        try await host.synchronizeSources()
        _ = await host.refreshAll()
        let fetchedWorkspace = await host.workspaceSnapshot()
        let workspace = try XCTUnwrap(fetchedWorkspace)
        XCTAssertEqual(Set(workspace.artifacts.map(\.id)), ["a", "b"])
        XCTAssertEqual(Set(workspace.anchors.map(\.id)), ["anchor-a", "anchor-b"])
    }

    func testRefreshFailureKeepsFailedSourceLastGoodAndOtherSource() async throws {
        let first = SyntheticPlugin(id: "alpha", sourceID: "one", snapshot: snapshot(source: "alpha:source:one", artifactID: "a", anchorID: "anchor-a"))
        let second = SyntheticPlugin(id: "beta", sourceID: "two", snapshot: snapshot(source: "beta:source:two", artifactID: "b", anchorID: "anchor-b"))
        let host = try PluginHost(plugins: [first, second], repository: MemoryRepository())
        try await host.synchronizeSources()
        _ = await host.refreshAll()
        await second.fail(with: SyntheticError.unavailable)
        _ = await host.refresh(PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: "beta")!, sourceID: "two"))
        let fetchedWorkspace = await host.workspaceSnapshot()
        let workspace = try XCTUnwrap(fetchedWorkspace)
        XCTAssertEqual(Set(workspace.artifacts.map(\.id)), ["a", "b"])
        let sourceStates = await host.sourceStates()
        let failed = try XCTUnwrap(sourceStates.first { $0.descriptor.id.pluginID.rawValue == "beta" })
        guard case .stale = failed.health else { return XCTFail("Expected stale source") }
    }

    func testColdStartPublishesCachedSnapshotBeforeFailedRefresh() async throws {
        let pluginID = PluginIdentifier(rawValue: "remote")!
        let sourceID = PluginSourceIdentifier(pluginID: pluginID, sourceID: "account")
        let cached = snapshot(source: sourceID.rawValue, artifactID: "cached", anchorID: "cached-anchor")
        let repository = MemoryRepository(seed: [sourceID: cached])
        let plugin = SyntheticPlugin(
            id: pluginID.rawValue,
            sourceID: sourceID.sourceID,
            snapshot: snapshot(source: sourceID.rawValue, artifactID: "fresh", anchorID: "fresh-anchor")
        )
        await plugin.fail(with: SyntheticError.unavailable)
        let host = try PluginHost(plugins: [plugin], repository: repository)

        try await host.synchronizeSources()

        let initialWorkspace = await host.workspaceSnapshot()
        let initialStates = await host.sourceStates()
        XCTAssertEqual(initialWorkspace?.artifacts.map(\.id), ["cached"])
        let initial = try XCTUnwrap(initialStates.single())
        guard case .ready = initial.health else { return XCTFail("Expected cached source to start ready") }

        _ = await host.refresh(sourceID)

        let failedWorkspace = await host.workspaceSnapshot()
        let retainedCache = await repository.load(for: sourceID)
        let failedStates = await host.sourceStates()
        XCTAssertEqual(failedWorkspace?.artifacts.map(\.id), ["cached"])
        XCTAssertEqual(retainedCache?.artifacts.map(\.id), ["cached"])
        let failed = try XCTUnwrap(failedStates.single())
        guard case .stale = failed.health else { return XCTFail("Expected failed refresh to retain stale cache") }
    }

    func testDiscoveryFailureRetainsLastGoodSourceAndHealthyPeer() async throws {
        let first = SyntheticPlugin(id: "alpha", sourceID: "one", snapshot: snapshot(source: "alpha:source:one", artifactID: "a", anchorID: "anchor-a"))
        let second = SyntheticPlugin(id: "beta", sourceID: "two", snapshot: snapshot(source: "beta:source:two", artifactID: "b", anchorID: "anchor-b"))
        let host = try PluginHost(plugins: [first, second], repository: MemoryRepository())
        try await host.synchronizeSources()
        _ = await host.refreshAll()

        await second.failDiscovery(with: SyntheticError.unavailable)
        try await host.synchronizeSources()

        let workspace = await host.workspaceSnapshot()
        XCTAssertEqual(Set(workspace?.artifacts.map(\.id) ?? []), ["a", "b"])
        let states = await host.sourceStates()
        guard case .ready = try XCTUnwrap(states.first { $0.descriptor.id.pluginID.rawValue == "alpha" }).health else {
            return XCTFail("Expected the peer source to remain ready")
        }
        guard case .stale = try XCTUnwrap(states.first { $0.descriptor.id.pluginID.rawValue == "beta" }).health else {
            return XCTFail("Expected discovery failure to leave its source stale and visible")
        }
    }

    func testCacheWriteFailureDoesNotPublishUnpersistedSnapshot() async throws {
        let pluginID = PluginIdentifier(rawValue: "remote")!
        let sourceID = PluginSourceIdentifier(pluginID: pluginID, sourceID: "account")
        let cached = snapshot(source: sourceID.rawValue, artifactID: "cached", anchorID: "cached-anchor")
        let repository = FailingReplacementRepository(seed: [sourceID: cached])
        let plugin = SyntheticPlugin(
            id: pluginID.rawValue,
            sourceID: sourceID.sourceID,
            snapshot: snapshot(source: sourceID.rawValue, artifactID: "unpersisted", anchorID: "unpersisted-anchor")
        )
        let host = try PluginHost(plugins: [plugin], repository: repository)
        try await host.synchronizeSources()

        _ = await host.refresh(sourceID)

        let workspace = await host.workspaceSnapshot()
        let retainedCache = await repository.load(for: sourceID)
        let states = await host.sourceStates()
        XCTAssertEqual(workspace?.artifacts.map(\.id), ["cached"])
        XCTAssertEqual(retainedCache?.artifacts.map(\.id), ["cached"])
        let state = try XCTUnwrap(states.single())
        guard case .stale = state.health else { return XCTFail("Expected cache write failure to mark the source stale") }
    }

    func testChangeObservationRefreshesSignaledSourceWithoutEvictingPeer() async throws {
        let observedID = PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: "observed")!, sourceID: "one")
        let observed = ObservingPlugin(
            source: .init(id: observedID, displayName: "Observed", kind: "synthetic"),
            snapshot: snapshot(source: observedID.rawValue, artifactID: "before", anchorID: "before-anchor")
        )
        let peer = SyntheticPlugin(id: "peer", sourceID: "two", snapshot: snapshot(source: "peer:source:two", artifactID: "peer", anchorID: "peer-anchor"))
        let host = try PluginHost(plugins: [observed, peer], repository: MemoryRepository())
        try await host.synchronizeSources()
        _ = await host.refreshAll()
        let sourceUpdates = await host.sourceStateUpdates()
        var sourceIterator = sourceUpdates.makeAsyncIterator()
        let beforeChangeUpdate = await sourceIterator.next()
        let beforeChange = try XCTUnwrap(beforeChangeUpdate)
        XCTAssertFalse(beforeChange.contains { $0.health == .refreshing })

        observed.publish(snapshot(source: observedID.rawValue, artifactID: "after", anchorID: "after-anchor"))
        try await waitUntil {
            Set(await host.workspaceSnapshot()?.artifacts.map(\.id) ?? []) == ["after", "peer"]
        }

        let workspace = await host.workspaceSnapshot()
        let afterChangeUpdate = await sourceIterator.next()
        let afterChange = try XCTUnwrap(afterChangeUpdate)
        XCTAssertEqual(Set(workspace?.artifacts.map(\.id) ?? []), ["after", "peer"])
        XCTAssertFalse(afterChange.contains { $0.health == .refreshing })
    }

    func testNewerRefreshWinsWhenOlderRequestCompletesLast() async throws {
        let sourceID = PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: "ordered")!, sourceID: "one")
        let plugin = OrderedSuspendedPlugin(source: .init(id: sourceID, displayName: "Ordered", kind: "synthetic"))
        let repository = MemoryRepository()
        let host = try PluginHost(plugins: [plugin], repository: repository)
        try await host.synchronizeSources()

        let older = Task { await host.refresh(sourceID) }
        try await waitUntil { await plugin.requestCount == 1 }
        let newer = Task { await host.refresh(sourceID) }
        try await waitUntil { await plugin.requestCount == 2 }

        await plugin.complete(
            request: 2,
            with: snapshot(source: sourceID.rawValue, artifactID: "newer", anchorID: "newer-anchor")
        )
        _ = await newer.value
        await plugin.complete(
            request: 1,
            with: snapshot(source: sourceID.rawValue, artifactID: "older", anchorID: "older-anchor")
        )
        _ = await older.value

        let workspace = await host.workspaceSnapshot()
        let cached = await repository.load(for: sourceID)
        XCTAssertEqual(workspace?.artifacts.map(\.id), ["newer"])
        XCTAssertEqual(cached?.artifacts.map(\.id), ["newer"])
    }

    func testCompositionRevisionIsOrderIndependent() throws {
        let a = PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: "alpha")!, sourceID: "one")
        let b = PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: "beta")!, sourceID: "two")
        let first = snapshot(source: a.rawValue, artifactID: "a", anchorID: "anchor-a")
        let second = snapshot(source: b.rawValue, artifactID: "b", anchorID: "anchor-b")
        XCTAssertEqual(try PluginHost.compose([(a, first), (b, second)])?.revision, try PluginHost.compose([(b, second), (a, first)])?.revision)
    }

    func testSourceRemovalOnlyRemovesThatSource() async throws {
        let first = SyntheticPlugin(id: "alpha", sourceID: "one", snapshot: snapshot(source: "alpha:source:one", artifactID: "a", anchorID: "anchor-a"))
        let second = SyntheticPlugin(id: "beta", sourceID: "two", snapshot: snapshot(source: "beta:source:two", artifactID: "b", anchorID: "anchor-b"))
        let host = try PluginHost(plugins: [first, second], repository: MemoryRepository())
        try await host.synchronizeSources()
        _ = await host.refreshAll()
        await first.removeSource()
        try await host.synchronizeSources()
        let fetchedWorkspace = await host.workspaceSnapshot()
        let workspace = try XCTUnwrap(fetchedWorkspace)
        XCTAssertEqual(workspace.artifacts.map(\.id), ["b"])
        let sourceStates = await host.sourceStates()
        XCTAssertEqual(sourceStates.count, 1)
    }

    func testExactRemovalPreservesPeerSourceFromTheSameProvider() async throws {
        let pluginID = PluginIdentifier(rawValue: "multi")!
        let firstID = PluginSourceIdentifier(pluginID: pluginID, sourceID: "first")
        let secondID = PluginSourceIdentifier(pluginID: pluginID, sourceID: "second")
        let first = snapshot(source: firstID.rawValue, artifactID: "first-artifact", anchorID: "first-anchor")
        let second = snapshot(source: secondID.rawValue, artifactID: "second-artifact", anchorID: "second-anchor")
        let plugin = MultiSourcePlugin(id: pluginID, snapshots: [firstID: first, secondID: second])
        let repository = MemoryRepository()
        let host = try PluginHost(plugins: [plugin], repository: repository)
        try await host.synchronizeSources()
        _ = await host.refreshAll()

        try await host.removeSource(firstID)

        let workspace = await host.workspaceSnapshot()
        let states = await host.sourceStates()
        let removedCache = await repository.load(for: firstID)
        let retainedCache = await repository.load(for: secondID)
        XCTAssertEqual(workspace?.artifacts.map(\.id), ["second-artifact"])
        XCTAssertEqual(states.map(\.descriptor.id), [secondID])
        XCTAssertNil(removedCache)
        XCTAssertEqual(retainedCache?.artifacts.map(\.id), ["second-artifact"])
    }

    func testCollisionFailsClosed() async throws {
        let first = SyntheticPlugin(id: "alpha", sourceID: "one", snapshot: snapshot(source: "alpha:source:one", artifactID: "same", anchorID: "anchor-a"))
        let second = SyntheticPlugin(id: "beta", sourceID: "two", snapshot: snapshot(source: "beta:source:two", artifactID: "same", anchorID: "anchor-b"))
        let host = try PluginHost(plugins: [first, second], repository: MemoryRepository())
        try await host.synchronizeSources()
        _ = await host.refresh(PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: "alpha")!, sourceID: "one"))
        _ = await host.refresh(PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: "beta")!, sourceID: "two"))
        let fetchedWorkspace = await host.workspaceSnapshot()
        let workspace = try XCTUnwrap(fetchedWorkspace)
        XCTAssertEqual(workspace.artifacts.map(\.id), ["same"])
        let sourceStates = await host.sourceStates()
        let failed = try XCTUnwrap(sourceStates.first { $0.descriptor.id.pluginID.rawValue == "beta" })
        guard case .stale = failed.health else { return XCTFail("Expected collision to fail source refresh") }
    }

    func testFolderPluginReproducesSampleVaultGraph() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vault = root.appendingPathComponent("Sources/embers/Resources/SampleVault")
        let plugin = FolderPlugin()
        let id = PluginSourceIdentifier(pluginID: FolderPlugin.identifier, sourceID: "fixture")
        plugin.configure(source: .init(id: id, displayName: "Sample Vault", kind: "folder"), rootURL: vault)
        let host = try PluginHost(plugins: [plugin], repository: MemoryRepository())
        try await host.synchronizeSources()
        _ = await host.refreshAll()
        let fetchedWorkspace = await host.workspaceSnapshot()
        let workspace = try XCTUnwrap(fetchedWorkspace)
        XCTAssertEqual(workspace.artifacts.count, 10)
        let folderContexts = Set(
            workspace.anchors
                .filter { $0.provenance.contains(.folder) }
                .map(\.canonicalName)
        )
        XCTAssertEqual(
            folderContexts,
            Set(["San Francisco Trip", "Building a Second Brain", "No Local Model Required"])
        )

        let localModel = try XCTUnwrap(workspace.anchors.first(where: {
            $0.canonicalName == "No Local Model Required" && $0.provenance.contains(.folder)
        }))
        XCTAssertEqual(localModel.memberArtifactIDs.count, 3)
        let detail = try XCTUnwrap(LinearContextSearch().detail(anchorID: localModel.id, in: workspace))
        XCTAssertTrue(detail.tasks.contains(where: {
            $0.text == "Say “local model” and see this context's peek appear"
        }))
    }

    func testFolderTaskMutationRoutesThroughProviderAndRefreshesOnlyItsSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("embers-task-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Tasks.md")
        try Data("---\ntitle: Tasks\n---\n- [ ] Ship the app\n".utf8).write(to: file)

        let plugin = FolderPlugin(taskFileCoordinator: DirectTaskFileCoordinator())
        let sourceID = PluginSourceIdentifier(pluginID: FolderPlugin.identifier, sourceID: "task-fixture")
        plugin.configure(source: .init(id: sourceID, displayName: "Tasks", kind: "folder"), rootURL: root)
        let host = try PluginHost(plugins: [plugin], repository: MemoryRepository())
        try await host.synchronizeSources()
        _ = await host.refresh(sourceID)
        let initialWorkspace = await host.workspaceSnapshot()
        let artifact = try XCTUnwrap(initialWorkspace?.artifacts.single())
        let task = try XCTUnwrap(artifact.metadata.tasks.single())

        let supportedStates = await host.supportedTaskStates(for: task, in: artifact)
        XCTAssertTrue(supportedStates.contains(.completed))
        let outcome = try await host.setTaskState(.completed, for: task, in: artifact)

        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("- [x] Ship the app"))
        XCTAssertEqual(outcome.source, sourceID)
        XCTAssertEqual(outcome.workspace?.artifacts.single()?.metadata.tasks.single()?.state, .completed)
    }

    func testAcknowledgedTaskMutationPatchesCachedSourceWithoutRefreshingIt() async throws {
        let plugin = AcknowledgingTaskProvider()
        let repository = MemoryRepository()
        let host = try PluginHost(plugins: [plugin], repository: repository)
        try await host.synchronizeSources()
        _ = await host.refresh(AcknowledgingTaskProvider.sourceID)
        let workspace = await host.workspaceSnapshot()
        let initial = try XCTUnwrap(workspace)
        let artifact = try XCTUnwrap(initial.artifacts.first { $0.id == "acknowledged-task-artifact" })
        let task = try XCTUnwrap(artifact.metadata.tasks.single())

        let outcome = try await host.setTaskState(.completed, for: task, in: artifact)

        XCTAssertEqual(plugin.refreshCount, 1, "The acknowledged write must not download the source again.")
        XCTAssertEqual(plugin.legacyMutationCount, 0)
        XCTAssertEqual(plugin.acknowledgedMutationCount, 1)
        let completed = try XCTUnwrap(outcome.workspace)
        XCTAssertTrue(completed.artifacts.allSatisfy { $0.metadata.tasks.single()?.state == .completed })
        XCTAssertEqual(completed.artifacts.first { $0.id == artifact.id }?.contentHash, "server-confirmed-done")
        XCTAssertEqual(completed.artifacts.first { $0.id == "acknowledged-parent-artifact" }?.contentHash, "server-confirmed-parent")
    }

    func testFolderTaskMutationAcceptsAnEquivalentFilesystemPath() async throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-task-path-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("ActualRoot", isDirectory: true)
        let alias = container.appendingPathComponent("EquivalentRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: container) }

        let file = root.appendingPathComponent("Tasks.md")
        try Data("- [ ] Ship the app\n".utf8).write(to: file)

        let plugin = FolderPlugin(taskFileCoordinator: DirectTaskFileCoordinator())
        let sourceID = PluginSourceIdentifier(pluginID: FolderPlugin.identifier, sourceID: "task-path-fixture")
        let descriptor = PluginSourceDescriptor(id: sourceID, displayName: "Tasks", kind: "folder")
        plugin.configure(source: descriptor, rootURL: root)
        let result = try await plugin.refresh(descriptor)
        let snapshot = try XCTUnwrap(result.snapshot)
        var artifact = try XCTUnwrap(snapshot.artifacts.single())
        let task = try XCTUnwrap(artifact.metadata.tasks.single())
        artifact.location = .file(alias.appendingPathComponent("Tasks.md"))

        try await plugin.setTaskState(.completed, for: task, in: artifact)

        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("- [x] Ship the app"))
    }

    func testConnectionCapabilityIsGenericAndDisconnectRemovesOnlyItsSource() async throws {
        let folder = SyntheticPlugin(id: "folderish", sourceID: "local", snapshot: snapshot(source: "folderish:source:local", artifactID: "local", anchorID: "local-anchor"))
        let remote = SyntheticPlugin(id: "remote", sourceID: "account", snapshot: snapshot(source: "remote:source:account", artifactID: "remote", anchorID: "remote-anchor"))
        let host = try PluginHost(plugins: [folder, remote], repository: MemoryRepository())
        try await host.synchronizeSources()
        _ = await host.refreshAll()
        let remoteID = PluginIdentifier(rawValue: "remote")!
        let initialStatus = await host.connectionStatus(for: remoteID)
        XCTAssertEqual(initialStatus?.state, .requiresAuthentication)
        try await host.connect(remoteID)
        let connectedStatus = await host.connectionStatus(for: remoteID)
        XCTAssertEqual(connectedStatus?.state, .connected)
        try await host.disconnect(remoteID)
        let fetchedWorkspace = await host.workspaceSnapshot()
        let workspace = try XCTUnwrap(fetchedWorkspace)
        XCTAssertEqual(workspace.artifacts.map(\.id), ["local"])
        let states = await host.sourceStates()
        XCTAssertEqual(states.count, 1)
    }

    func testRemovedSourceCannotPublishAnInFlightRefresh() async throws {
        let sourceID = PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: "delayed")!, sourceID: "one")
        let delayed = SuspendedPlugin(
            source: .init(id: sourceID, displayName: "Delayed", kind: "synthetic"),
            snapshot: snapshot(source: sourceID.rawValue, artifactID: "delayed-artifact", anchorID: "delayed-anchor")
        )
        let repository = MemoryRepository()
        let host = try PluginHost(plugins: [delayed], repository: repository)
        try await host.synchronizeSources()

        let task = Task { await host.refresh(sourceID) }
        await delayed.waitUntilRefreshStarts()
        try await host.removeSources(for: sourceID.pluginID)
        await delayed.completeRefresh()
        _ = await task.value

        let workspace = await host.workspaceSnapshot()
        let states = await host.sourceStates()
        let cached = await repository.load(for: sourceID)
        XCTAssertNil(workspace)
        XCTAssertTrue(states.isEmpty)
        XCTAssertNil(cached)
    }

    func testArtifactActionsUseProviderProvenanceInsteadOfImportMetadata() async throws {
        let alpha = ActionPlugin(id: "alpha", sourceID: "one")
        let beta = ActionPlugin(id: "beta", sourceID: "two")
        let host = try PluginHost(plugins: [alpha, beta], repository: MemoryRepository())
        let artifact = SourceArtifact(
            id: "remote",
            relativePath: "Remote",
            mediaKind: .text,
            title: "Remote",
            extractedText: "",
            modifiedAt: .distantPast,
            contentHash: "remote",
            location: .web(URL(string: "https://example.com/document")!),
            provider: .init(pluginID: "alpha", sourceID: "alpha:source:one"),
            metadata: .init(importKind: "beta")
        )

        let actions = await host.availableArtifactActions(for: artifact)
        XCTAssertEqual(actions.map(\.id), ["alpha-open"])
    }

    func testCacheRemovalFailureKeepsTheSourceVisibleForRetry() async throws {
        let sourceID = PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: "alpha")!, sourceID: "one")
        let plugin = SyntheticPlugin(id: "alpha", sourceID: "one", snapshot: snapshot(source: sourceID.rawValue, artifactID: "a", anchorID: "anchor-a"))
        let host = try PluginHost(plugins: [plugin], repository: FailingRemovalRepository())
        try await host.synchronizeSources()
        _ = await host.refresh(sourceID)

        do {
            try await host.removeSources(for: sourceID.pluginID)
            XCTFail("The host must not silently drop a source whose cache remains on disk")
        } catch {}

        let workspace = await host.workspaceSnapshot()
        let states = await host.sourceStates()
        XCTAssertEqual(workspace?.artifacts.map(\.id), ["a"])
        XCTAssertEqual(states.map(\.descriptor.id), [sourceID])
    }
}

private final class AcknowledgingTaskProvider: PluginSourceProviding, PluginRefreshing, PluginTaskMutating, PluginTaskMutationAcknowledging, @unchecked Sendable {
    static let identifier = PluginIdentifier(rawValue: "acknowledging-task")!
    static let sourceID = PluginSourceIdentifier(pluginID: identifier, sourceID: "account")

    let descriptor = PluginDescriptor(
        id: identifier,
        displayName: "Acknowledging task provider",
        version: "1",
        capabilities: [.sourceRefresh, .taskMutation]
    )
    private let lock = NSLock()
    private var _refreshCount = 0
    private var _legacyMutationCount = 0
    private var _acknowledgedMutationCount = 0
    var refreshCount: Int { lock.withLock { _refreshCount } }
    var legacyMutationCount: Int { lock.withLock { _legacyMutationCount } }
    var acknowledgedMutationCount: Int { lock.withLock { _acknowledgedMutationCount } }

    func sources() async throws -> [PluginSourceDescriptor] {
        [.init(id: Self.sourceID, displayName: "Acknowledged tasks", kind: "synthetic")]
    }

    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        lock.withLock { _refreshCount += 1 }
        let artifact = SourceArtifact(
            id: "acknowledged-task-artifact",
            relativePath: "task",
            mediaKind: .markdown,
            title: "Ship",
            extractedText: "Ship",
            modifiedAt: .distantPast,
            contentHash: "server-open",
            provider: .init(pluginID: Self.identifier.rawValue, sourceID: Self.sourceID.rawValue),
            metadata: .init(tasks: [.init(id: "ship", text: "Ship", state: .open)])
        )
        let parent = SourceArtifact(
            id: "acknowledged-parent-artifact",
            relativePath: "parent",
            mediaKind: .markdown,
            title: "Launch",
            extractedText: "Launch",
            modifiedAt: .distantPast,
            contentHash: "server-parent-open",
            provider: .init(pluginID: Self.identifier.rawValue, sourceID: Self.sourceID.rawValue),
            metadata: .init(tasks: [.init(id: "launch", text: "Launch", state: .open)])
        )
        return .init(source: source, snapshot: .init(
            sourceID: Self.sourceID.rawValue,
            revision: "server-open",
            artifacts: [artifact, parent],
            anchors: [.init(id: "launch-context", canonicalName: "Launch", provenance: [.folder], memberArtifactIDs: [artifact.id, parent.id])],
            relations: [],
            diagnostics: [],
            indexedAt: .distantPast
        ))
    }

    func supportedTaskStates(for task: SourceTask, in artifact: SourceArtifact) async -> Set<SourceTaskState> {
        [.open, .completed]
    }

    func setTaskState(_ state: SourceTaskState, for task: SourceTask, in artifact: SourceArtifact) async throws {
        lock.withLock { _legacyMutationCount += 1 }
    }

    func setTaskStateWithAcknowledgement(
        _ state: SourceTaskState,
        for task: SourceTask,
        in artifact: SourceArtifact
    ) async throws -> [PluginTaskStateUpdate] {
        lock.withLock { _acknowledgedMutationCount += 1 }
        return [
            .init(
                artifactID: "acknowledged-parent-artifact",
                taskID: "launch",
                state: state,
                contentHash: "server-confirmed-parent"
            ),
            .init(
                artifactID: artifact.id,
                taskID: task.id,
                state: state,
                contentHash: "server-confirmed-done"
            ),
        ]
    }
}

private actor MemoryRepository: PluginSnapshotRepository {
    private var values: [PluginSourceIdentifier: ContextSnapshot] = [:]
    init(seed: [PluginSourceIdentifier: ContextSnapshot] = [:]) { values = seed }
    func load(for source: PluginSourceIdentifier) async -> ContextSnapshot? { values[source] }
    func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws { values[source] = snapshot }
    func remove(source: PluginSourceIdentifier) async throws { values.removeValue(forKey: source) }
}

private actor FailingReplacementRepository: PluginSnapshotRepository {
    private var values: [PluginSourceIdentifier: ContextSnapshot]
    init(seed: [PluginSourceIdentifier: ContextSnapshot]) { values = seed }
    func load(for source: PluginSourceIdentifier) async -> ContextSnapshot? { values[source] }
    func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws { throw SyntheticError.unavailable }
    func remove(source: PluginSourceIdentifier) async throws { values.removeValue(forKey: source) }
}

private actor FailingRemovalRepository: PluginSnapshotRepository {
    private var values: [PluginSourceIdentifier: ContextSnapshot] = [:]
    func load(for source: PluginSourceIdentifier) async -> ContextSnapshot? { values[source] }
    func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws { values[source] = snapshot }
    func remove(source: PluginSourceIdentifier) async throws { throw SyntheticError.unavailable }
}

private enum SyntheticError: Error { case unavailable }

private struct DirectTaskFileCoordinator: FolderTaskFileCoordinating {
    func coordinateWrite(at url: URL, accessor: (URL) throws -> Void) throws { try accessor(url) }
}

private actor SyntheticPlugin: PluginSourceProviding, PluginRefreshing, PluginConnecting {
    let descriptor: PluginDescriptor
    private let source: PluginSourceDescriptor
    private var currentSnapshot: ContextSnapshot
    private var failure: Error?
    private var discoveryFailure: Error?
    private var isRemoved = false
    private var connected = false

    init(id: String, sourceID: String, snapshot: ContextSnapshot) {
        let pluginID = PluginIdentifier(rawValue: id)!
        descriptor = .init(id: pluginID, displayName: id, version: "1", capabilities: [.sourceRefresh])
        source = .init(id: .init(pluginID: pluginID, sourceID: sourceID), displayName: sourceID, kind: "synthetic")
        currentSnapshot = snapshot
    }

    func sources() async throws -> [PluginSourceDescriptor] {
        if let discoveryFailure { throw discoveryFailure }
        return isRemoved ? [] : [source]
    }
    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        if let failure { throw failure }
        return .init(source: source, snapshot: currentSnapshot)
    }
    func fail(with error: Error) { failure = error }
    func failDiscovery(with error: Error) { discoveryFailure = error }
    func removeSource() { isRemoved = true }
    func connectionStatus() async -> PluginConnectionStatus { .init(state: connected ? .connected : .requiresAuthentication) }
    func connect() async throws { connected = true }
    func disconnect() async throws { connected = false }
}

private actor MultiSourcePlugin: PluginSourceProviding, PluginRefreshing {
    let descriptor: PluginDescriptor
    private let snapshots: [PluginSourceIdentifier: ContextSnapshot]

    init(id: PluginIdentifier, snapshots: [PluginSourceIdentifier: ContextSnapshot]) {
        descriptor = .init(id: id, displayName: "Multi", version: "1", capabilities: [.sourceRefresh])
        self.snapshots = snapshots
    }

    func sources() async throws -> [PluginSourceDescriptor] {
        snapshots.keys.sorted().map {
            .init(id: $0, displayName: $0.sourceID, kind: "synthetic")
        }
    }

    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        guard let snapshot = snapshots[source.id] else { throw SyntheticError.unavailable }
        return .init(source: source, snapshot: snapshot)
    }
}

private final class ObservingPlugin: PluginSourceProviding, PluginRefreshing, PluginChangeObserving, @unchecked Sendable {
    let descriptor: PluginDescriptor
    private let source: PluginSourceDescriptor
    private let lock = NSLock()
    private var currentSnapshot: ContextSnapshot
    private var continuation: AsyncStream<Void>.Continuation?

    init(source: PluginSourceDescriptor, snapshot: ContextSnapshot) {
        self.source = source
        currentSnapshot = snapshot
        descriptor = .init(id: source.id.pluginID, displayName: source.displayName, version: "1", capabilities: [.sourceRefresh, .changeObservation])
    }

    func sources() async throws -> [PluginSourceDescriptor] { [source] }

    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        .init(source: source, snapshot: lock.withLock { currentSnapshot })
    }

    func changes(for source: PluginSourceDescriptor) -> AsyncStream<Void> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func publish(_ snapshot: ContextSnapshot) {
        let continuation = lock.withLock { () -> AsyncStream<Void>.Continuation? in
            currentSnapshot = snapshot
            return self.continuation
        }
        continuation?.yield()
    }
}

private actor OrderedSuspendedPlugin: PluginSourceProviding, PluginRefreshing {
    let descriptor: PluginDescriptor
    private let source: PluginSourceDescriptor
    private var nextRequest = 0
    private var continuations: [Int: CheckedContinuation<PluginRefreshResult, Never>] = [:]

    init(source: PluginSourceDescriptor) {
        self.source = source
        descriptor = .init(id: source.id.pluginID, displayName: source.displayName, version: "1", capabilities: [.sourceRefresh])
    }

    var requestCount: Int { nextRequest }
    func sources() async throws -> [PluginSourceDescriptor] { [source] }

    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        nextRequest += 1
        let request = nextRequest
        return await withCheckedContinuation { continuation in
            continuations[request] = continuation
        }
    }

    func complete(request: Int, with snapshot: ContextSnapshot) {
        continuations.removeValue(forKey: request)?.resume(returning: .init(source: source, snapshot: snapshot))
    }
}

private actor SuspendedPlugin: PluginSourceProviding, PluginRefreshing {
    let descriptor: PluginDescriptor
    private let source: PluginSourceDescriptor
    private let snapshot: ContextSnapshot
    private var refreshContinuation: CheckedContinuation<PluginRefreshResult, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    init(source: PluginSourceDescriptor, snapshot: ContextSnapshot) {
        self.source = source
        self.snapshot = snapshot
        descriptor = .init(id: source.id.pluginID, displayName: "Delayed", version: "1", capabilities: [.sourceRefresh])
    }

    func sources() async throws -> [PluginSourceDescriptor] { [source] }

    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        await withCheckedContinuation { continuation in
            didStart = true
            startedContinuation?.resume()
            startedContinuation = nil
            refreshContinuation = continuation
        }
    }

    func waitUntilRefreshStarts() async {
        guard !didStart else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func completeRefresh() {
        let continuation = refreshContinuation
        refreshContinuation = nil
        continuation?.resume(returning: .init(source: source, snapshot: snapshot))
    }
}

private struct ActionPlugin: PluginSourceProviding, PluginRefreshing, PluginArtifactActionProviding {
    let descriptor: PluginDescriptor
    private let source: PluginSourceDescriptor

    init(id: String, sourceID: String) {
        let pluginID = PluginIdentifier(rawValue: id)!
        descriptor = .init(id: pluginID, displayName: id, version: "1", capabilities: [.sourceRefresh, .artifactActions])
        source = .init(id: .init(pluginID: pluginID, sourceID: sourceID), displayName: sourceID, kind: "synthetic")
    }

    func sources() async throws -> [PluginSourceDescriptor] { [source] }

    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        .init(unchanged: source)
    }

    func artifactActions(for artifact: SourceArtifact) -> [ArtifactAction] {
        [.init(id: "\(descriptor.id.rawValue)-open", title: "Open", kind: .open)]
    }

    func perform(_ action: ArtifactAction, for artifact: SourceArtifact) async throws {}
}

private func snapshot(source: String, artifactID: String, anchorID: String) -> ContextSnapshot {
    .init(
        sourceID: source,
        revision: StableHash.hex("\(source)-\(artifactID)-\(anchorID)"),
        artifacts: [.init(id: artifactID, relativePath: "\(artifactID).md", mediaKind: .markdown, title: artifactID, extractedText: artifactID, modifiedAt: .distantPast, contentHash: artifactID)],
        anchors: [.init(id: anchorID, canonicalName: anchorID, provenance: [.manifest], memberArtifactIDs: [artifactID])],
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
    throw SyntheticError.unavailable
}

private extension Array {
    func single() -> Element? { count == 1 ? first : nil }
}
