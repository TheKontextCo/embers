import XCTest
import EmbersCore
import EmbersPluginKit
import EmbersPluginHost
import FolderPlugin

final class FolderTaskRefreshRegressionTests: XCTestCase {
    func testRefreshAfterAcknowledgedTaskWriteIsUnchangedButExternalEditStillPublishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("embers-task-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Tasks.md")
        let peer = root.appendingPathComponent("Peer.md")
        try Data("# Tasks\n- [ ] Ship the app\n".utf8).write(to: file)
        try Data("# Peer\n[Tasks](Tasks.md)\n".utf8).write(to: peer)

        let plugin = FolderPlugin(taskFileCoordinator: DirectCoordinator())
        let descriptor = PluginSourceDescriptor(
            id: .init(pluginID: FolderPlugin.identifier, sourceID: "checkbox-regression"),
            displayName: "Synthetic tasks", kind: "folder")
        plugin.configure(source: descriptor, rootURL: root)
        defer { plugin.remove(sourceID: descriptor.id) }
        let initial = try await plugin.refresh(descriptor)
        let taskArtifact = try XCTUnwrap(initial.snapshot?.artifacts.first { $0.relativePath == "Tasks.md" })
        let task = try XCTUnwrap(taskArtifact.metadata.tasks.first)
        try await plugin.setTaskState(.completed, for: task, in: taskArtifact)
        let acknowledged = try await plugin.refresh(descriptor)
        XCTAssertEqual(acknowledged.snapshot?.artifacts.first { $0.relativePath == "Tasks.md" }?.metadata.tasks.first?.state, .completed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Tasks\n- [x] Ship the app\n")

        // Explicitly replay the refresh that a delayed self-write event requests.
        // This is deterministic and does not depend on FSEvents delivery timing.
        let repeated = try await plugin.refresh(descriptor)
        XCTAssertEqual(repeated.disposition, .unchanged,
                       "Already acknowledged task bytes must not publish another workspace replacement.")

        try Data("# Peer edited externally\n[Tasks](Tasks.md)\n".utf8).write(to: peer, options: .atomic)
        let external = try await plugin.refresh(descriptor)
        XCTAssertEqual(external.disposition, .updated)
        XCTAssertEqual(external.snapshot?.artifacts.first { $0.relativePath == "Peer.md" }?.title, "Peer edited externally")
        XCTAssertEqual(external.snapshot?.artifacts.first { $0.relativePath == "Tasks.md" }?.metadata.tasks.first?.state, .completed)

        // Concurrent notifications must produce one replacement, and must not suppress
        // a subsequent external edit of the very same checkbox.
        try Data("# Tasks\n- [ ] Ship the app\n".utf8).write(to: file, options: .atomic)
        async let first = plugin.refresh(descriptor)
        async let second = plugin.refresh(descriptor)
        let concurrent = try await [first, second]
        XCTAssertEqual(concurrent.filter { $0.disposition == .updated }.count, 1)
        XCTAssertEqual(concurrent.filter { $0.disposition == .unchanged }.count, 1)
        XCTAssertTrue(concurrent.allSatisfy {
            $0.snapshot?.artifacts.first { $0.relativePath == "Tasks.md" }?.metadata.tasks.first?.state == .open
        })
    }

    private struct DirectCoordinator: FolderTaskFileCoordinating {
        func coordinateWrite(at url: URL, accessor: (URL) throws -> Void) throws { try accessor(url) }
    }

    func testCachedProviderSnapshotCanRetryFailedHostPersistence() async throws {
        let sourceID = PluginSourceIdentifier(pluginID: FolderPlugin.identifier, sourceID: "retry")
        let descriptor = PluginSourceDescriptor(id: sourceID, displayName: "Retry", kind: "synthetic")
        let snapshot = ContextSnapshot(sourceID: sourceID.rawValue, revision: "revision",
            artifacts: [], anchors: [], relations: [], diagnostics: [], indexedAt: .distantPast)
        let repository = FailOnceRepository()
        let host = try PluginHost(plugins: [CachedProvider(source: descriptor, snapshot: snapshot)], repository: repository)
        try await host.synchronizeSources()
        let failed = await host.refresh(sourceID)
        guard case .stale = failed.sourceState.health else { return XCTFail("Expected the persistence failure") }
        let retried = await host.refresh(sourceID)
        XCTAssertEqual(retried.sourceState.health, .ready)
        XCTAssertEqual(retried.sourceState.snapshot?.revision, snapshot.revision)
        let writes = await repository.writes
        XCTAssertEqual(writes, 2)
    }

    private struct CachedProvider: PluginSourceProviding, PluginRefreshing {
        let source: PluginSourceDescriptor
        let snapshot: ContextSnapshot
        var descriptor: PluginDescriptor {
            .init(id: source.id.pluginID, displayName: "Cached", version: "1", capabilities: [.sourceRefresh])
        }
        func sources() async throws -> [PluginSourceDescriptor] { [source] }
        func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
            var result = PluginRefreshResult(source: source, snapshot: snapshot)
            result.disposition = .unchanged
            return result
        }
    }

    private actor FailOnceRepository: PluginSnapshotRepository {
        var writes = 0
        func load(for source: PluginSourceIdentifier) async -> ContextSnapshot? { nil }
        func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws {
            writes += 1
            if writes == 1 { throw CocoaError(.fileWriteUnknown) }
        }
        func remove(source: PluginSourceIdentifier) async throws {}
    }
}
