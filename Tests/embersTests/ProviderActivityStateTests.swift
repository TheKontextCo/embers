import XCTest
import EmbersCore
import EmbersPluginHost
import EmbersPluginKit
@testable import embers

final class ProviderActivityStateTests: XCTestCase {
    func testConnectedProviderCyclesThroughDiscoveryAndIndexing() {
        var state = ProviderActivityState()

        state.apply(.beginConnection)
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertTrue(state.phase.presentsIndexingTrail)

        state.apply(.beginDiscovery)
        XCTAssertEqual(state.phase, .discovering)
        XCTAssertTrue(state.phase.presentsIndexingTrail)

        state.apply(.beginIndexing)
        XCTAssertEqual(state.phase, .indexing)
        XCTAssertTrue(state.phase.presentsIndexingTrail)

        state.apply(.completed)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertFalse(state.phase.presentsIndexingTrail)
    }

    func testEveryProviderCanRecoverFromAStaleOrFailedCycle() {
        var state = ProviderActivityState()

        state.apply(.beginIndexing)
        state.apply(.degraded("offline"))
        XCTAssertEqual(state.phase, .stale("offline"))

        state.apply(.beginIndexing)
        state.apply(.failed("invalid snapshot"))
        XCTAssertEqual(state.phase, .failed("invalid snapshot"))

        state.apply(.beginIndexing)
        state.apply(.completed)
        XCTAssertEqual(state.phase, .ready)
    }

    func testProviderActivityOverridesAnExistingWorkspaceSnapshot() {
        let providerID = PluginIdentifier(rawValue: "remote")!
        let activity = ProviderActivityPresentation(
            id: providerID,
            providerName: "Remote",
            isLocal: false,
            phase: .indexing
        )

        XCTAssertEqual(
            DashboardContentState.resolve(
                providerActivity: activity,
                hasSnapshot: true,
                indexingState: .ready
            ),
            .providerActivity(activity)
        )
    }

    @MainActor
    func testBackgroundSourceRefreshDoesNotBecomeForegroundIndexing() throws {
        let providerID = PluginIdentifier(rawValue: "folder")!
        let sourceID = PluginSourceIdentifier(pluginID: providerID, sourceID: "writing")
        let host = try PluginHost(plugins: [], repository: ProviderActivityMemoryRepository())
        let coordinator = ProviderLifecycleCoordinator(host: host)
        coordinator.reconcileProviderActivity(with: [
            HostedPluginSource(
                descriptor: .init(id: sourceID, displayName: "Writing", kind: "folder"),
                health: .refreshing
            )
        ])

        XCTAssertNil(
            coordinator.activePresentation(descriptors: [
                PluginDescriptor(
                    id: providerID,
                    displayName: "Folder",
                    version: "1",
                    capabilities: [.sourceRefresh, .changeObservation],
                    sourceSetup: .directoryPicker
                )
            ])
        )
    }
}

private actor ProviderActivityMemoryRepository: PluginSnapshotRepository {
    func load(for source: PluginSourceIdentifier) async -> ContextSnapshot? { nil }
    func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws {}
    func remove(source: PluginSourceIdentifier) async throws {}
}
