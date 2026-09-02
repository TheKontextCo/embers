import XCTest
import EmbersCore
import EmbersLocal
@testable import embers

@MainActor
final class DashboardChangeBaselineWiringTests: XCTestCase {
    func testSelectCapturesBaselineWhileReloadComparesWithoutAdvancingIt() async throws {
        let fixture = try LocalDashboardFixture()
        defer { fixture.cleanUp() }
        let controller = try fixture.makeController()
        try await controller.chooseFolder(fixture.vaultURL)
        let apolloID = try XCTUnwrap(
            controller.snapshot?.anchors.first(where: { $0.canonicalName == "Apollo" })?.id
        )
        let store = RecordingChangeBaselineStore()
        let speech = SpeechListener()
        let navigation = DashboardNavigationCoordinator(
            context: controller,
            speech: speech,
            changeBaselines: store
        )
        let viewModel = DashboardViewModel(
            context: controller,
            speech: speech,
            voiceRoutingStatus: VoiceRoutingStatus(),
            voiceRoutingPreferences: VoiceRoutingPreferenceState(),
            navigation: navigation,
            taskMutations: DashboardTaskMutationCoordinator(context: controller, navigation: navigation),
            chooseDirectory: { _ in }
        )

        await viewModel.openList()
        await viewModel.select(apolloID)

        XCTAssertEqual(store.saved.count, 1, "A successful peek should establish exactly one baseline.")
        XCTAssertEqual(
            store.saved.first,
            ContextChangeBaseline.capture(for: apolloID, in: try XCTUnwrap(controller.snapshot))
        )
        XCTAssertFalse(viewModel.detail?.hits.contains(where: \.changedSinceLastPeek) ?? true)

        try fixture.replaceBriefWithoutChangingItsFileDate()
        await controller.reindex(presentation: .silent)
        await viewModel.reload()

        XCTAssertEqual(store.saved.count, 1, "Reload must compare with the peek baseline, not advance it.")
        XCTAssertTrue(
            viewModel.detail?.hits.contains(where: \.changedSinceLastPeek) ?? false,
            "A content edit with a preserved old timestamp proves revision tokens, not wall clocks, drive the UI."
        )

        await viewModel.reload()
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertTrue(viewModel.detail?.hits.contains(where: \.changedSinceLastPeek) ?? false)

        await viewModel.openList()
        await viewModel.select(apolloID)
        XCTAssertEqual(store.saved.count, 2, "Starting a new peek advances the persisted baseline after comparison.")
        XCTAssertTrue(
            viewModel.detail?.hits.contains(where: \.changedSinceLastPeek) ?? false,
            "The new peek still presents changes against the baseline it loaded before saving."
        )

        await viewModel.reload()
        XCTAssertEqual(store.saved.count, 2)
        XCTAssertFalse(
            viewModel.detail?.hits.contains(where: \.changedSinceLastPeek) ?? true,
            "Once a new peek captures the current revision, later reloads should be clean."
        )
    }
}

private final class RecordingChangeBaselineStore: ChangeBaselineStore {
    private var values: [ContextChangeScope: ContextChangeBaseline] = [:]
    private(set) var saved: [ContextChangeBaseline] = []

    func baseline(for scope: ContextChangeScope) -> ContextChangeBaseline? {
        values[scope]
    }

    func save(_ baseline: ContextChangeBaseline) {
        values[baseline.scope] = baseline
        saved.append(baseline)
    }

    func removeBaseline(for scope: ContextChangeScope) {
        values.removeValue(forKey: scope)
    }

    func removeBaselines(forSourceID sourceID: String) {
        values = values.filter { $0.key.sourceID != sourceID }
    }
}

private struct LocalDashboardFixture {
    let rootURL: URL
    let vaultURL: URL
    let briefURL: URL
    let defaults: UserDefaults
    let defaultsName: String
    let fixedModificationDate = Date(timeIntervalSince1970: 1_600_000_000)

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-dashboard-baseline-\(UUID().uuidString)", isDirectory: true)
        vaultURL = rootURL.appendingPathComponent("vault", isDirectory: true)
        briefURL = vaultURL.appendingPathComponent("Projects/Apollo/Brief.md")
        defaultsName = "embers.dashboard-baseline.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        try FileManager.default.createDirectory(
            at: briefURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeBrief("# Brief\nOriginal local evidence.\n")
    }

    @MainActor func makeController() throws -> ContextIndexController {
        let pluginSnapshots = JSONPluginSnapshotRepository(
            directoryURL: rootURL.appendingPathComponent("plugin-snapshots", isDirectory: true)
        )
        let registry = try ProviderRegistry(builder: .init(), repository: pluginSnapshots)
        return ContextIndexController(
            repository: JSONSnapshotRepository(fileURL: rootURL.appendingPathComponent("legacy-snapshot.json")),
            configurations: SourceConfigurationStore(defaults: defaults),
            defaults: defaults,
            recentAccesses: UserDefaultsRecentAccess(defaults),
            providerRegistry: registry,
            providerLifecycle: ProviderLifecycleCoordinator(host: registry.host)
        )
    }

    func replaceBriefWithoutChangingItsFileDate() throws {
        try writeBrief("# Brief\nUpdated local evidence with the same old filesystem date.\n")
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func writeBrief(_ contents: String) throws {
        try Data(contents.utf8).write(to: briefURL)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedModificationDate],
            ofItemAtPath: briefURL.path
        )
    }
}
