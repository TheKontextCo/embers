import EmbersCore
import EmbersLocal
import EmbersPluginHost
import EmbersPluginKit
import Combine
import Foundation
import XCTest

@testable import embers

@MainActor
final class TaskCompletionJourneyTests: XCTestCase {
    func testCompletionKeepsDetailStableAndNeverPresentsProviderIndexing() async throws {
        let fixture = try TaskCompletionFixture(failsMutation: false)
        defer { fixture.cleanUp() }
        let controller = fixture.makeController()
        try await fixture.waitUntilReady(controller)
        let viewModel = fixture.makeViewModel(context: controller)
        await viewModel.openAnchor(TaskCompletionProvider.anchorID)
        let task = try XCTUnwrap(viewModel.detail?.tasks.first)
        var publishedProviderPhases: [ProviderActivityPhase] = []
        var publishedIndexingStates: [IndexingState] = []
        let activityObservation = controller.$providerActivity.sink { activity in
            if let phase = activity[TaskCompletionProvider.identifier]?.phase {
                publishedProviderPhases.append(phase)
            }
        }
        let stateObservation = controller.$state.sink { publishedIndexingStates.append($0) }

        let completion = Task { await viewModel.complete(task) }
        await fixture.provider.waitUntilMutationStarts()

        XCTAssertEqual(viewModel.selected, TaskCompletionProvider.anchorID)
        XCTAssertEqual(viewModel.detail?.anchor.id, TaskCompletionProvider.anchorID)
        XCTAssertEqual(viewModel.detail?.tasks.map(\.id), [task.id])
        XCTAssertEqual(controller.state, .ready)
        XCTAssertNil(controller.activeProviderActivity)
        XCTAssertEqual(
            controller.providerActivity[TaskCompletionProvider.identifier]?.phase,
            .ready
        )
        XCTAssertTrue(fixture.provider.openedArtifactIDs.isEmpty)

        await fixture.provider.releaseMutation()
        await completion.value

        XCTAssertEqual(viewModel.selected, TaskCompletionProvider.anchorID)
        XCTAssertEqual(viewModel.detail?.anchor.id, TaskCompletionProvider.anchorID)
        XCTAssertTrue(viewModel.detail?.tasks.isEmpty == true)
        XCTAssertEqual(
            controller.snapshot?.artifacts.first?.metadata.tasks.first?.state,
            .completed
        )
        XCTAssertNil(viewModel.taskMutationError)
        XCTAssertNil(controller.activeProviderActivity)
        XCTAssertFalse(publishedProviderPhases.contains(where: \.presentsIndexingTrail))
        XCTAssertFalse(publishedIndexingStates.contains(.indexing))
        XCTAssertTrue(fixture.provider.openedArtifactIDs.isEmpty)
        withExtendedLifetime((activityObservation, stateObservation)) {}
    }

    func testFailedCompletionRollsBackInPlaceWithATaskLocalError() async throws {
        let fixture = try TaskCompletionFixture(failsMutation: true)
        defer { fixture.cleanUp() }
        let controller = fixture.makeController()
        try await fixture.waitUntilReady(controller)
        let viewModel = fixture.makeViewModel(context: controller)
        await viewModel.openAnchor(TaskCompletionProvider.anchorID)
        let task = try XCTUnwrap(viewModel.detail?.tasks.first)
        var publishedProviderPhases: [ProviderActivityPhase] = []
        let activityObservation = controller.$providerActivity.sink { activity in
            if let phase = activity[TaskCompletionProvider.identifier]?.phase {
                publishedProviderPhases.append(phase)
            }
        }

        let completion = Task { await viewModel.complete(task) }
        await fixture.provider.waitUntilMutationStarts()
        await fixture.provider.releaseMutation()
        await completion.value

        XCTAssertEqual(viewModel.selected, TaskCompletionProvider.anchorID)
        XCTAssertEqual(viewModel.detail?.anchor.id, TaskCompletionProvider.anchorID)
        XCTAssertEqual(viewModel.detail?.tasks.map(\.id), [task.id])
        XCTAssertEqual(
            controller.snapshot?.artifacts.first?.metadata.tasks.first?.state,
            .open
        )
        XCTAssertEqual(viewModel.taskMutationError, TaskCompletionFailure.message)
        XCTAssertEqual(
            controller.providerActivity[TaskCompletionProvider.identifier]?.phase,
            .ready
        )
        XCTAssertFalse(publishedProviderPhases.isEmpty)
        XCTAssertTrue(publishedProviderPhases.allSatisfy { $0 == .ready })
        XCTAssertNil(controller.activeProviderActivity)
        XCTAssertTrue(fixture.provider.openedArtifactIDs.isEmpty)
        withExtendedLifetime(activityObservation) {}
    }
}

private struct TaskCompletionFixture {
    let rootURL: URL
    let defaults: UserDefaults
    let defaultsName: String
    let provider: TaskCompletionProvider

    init(failsMutation: Bool) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-task-completion-\(UUID().uuidString)", isDirectory: true)
        defaultsName = "embers.task-completion.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        provider = TaskCompletionProvider(failsMutation: failsMutation)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    @MainActor
    func makeController() -> ContextIndexController {
        let snapshotRepository = TaskCompletionMemoryRepository()
        let host = try! PluginHost(plugins: [provider], repository: snapshotRepository)
        let registry = ProviderRegistry(
            host: host,
            directorySourceManagers: [provider],
            defaultDirectoryProviderID: provider.descriptor.id
        )
        let controller = ContextIndexController(
            repository: JSONSnapshotRepository(fileURL: rootURL.appendingPathComponent("legacy.json")),
            configurations: SourceConfigurationStore(defaults: defaults),
            defaults: defaults,
            recentAccesses: UserDefaultsRecentAccess(defaults),
            providerRegistry: registry,
            providerLifecycle: ProviderLifecycleCoordinator(host: host)
        )
        Task { await controller.bootstrap() }
        return controller
    }

    @MainActor
    func makeViewModel(context: ContextIndexController) -> DashboardViewModel {
        let speech = SpeechListener()
        let navigation = DashboardNavigationCoordinator(
            context: context,
            speech: speech,
            changeBaselines: UserDefaultsChangeBaselineStore(
                defaults,
                storageKey: "test.task-completion-baseline"
            )
        )
        return DashboardViewModel(
            context: context,
            speech: speech,
            voiceRoutingStatus: VoiceRoutingStatus(),
            voiceRoutingPreferences: VoiceRoutingPreferenceState(),
            navigation: navigation,
            taskMutations: DashboardTaskMutationCoordinator(context: context, navigation: navigation),
            chooseDirectory: { _ in }
        )
    }

    @MainActor
    func waitUntilReady(_ controller: ContextIndexController) async throws {
        for _ in 0..<100 {
            if controller.state == .ready, controller.graphSearch != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected the synthetic Kontext provider to become ready.")
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class TaskCompletionProvider: PluginSourceProviding, PluginRefreshing, PluginTaskMutating, PluginArtifactActionProviding, DirectorySourceManaging, @unchecked Sendable {
    static let identifier = PluginIdentifier(rawValue: "kontext-task-test")!
    static let sourceID = PluginSourceIdentifier(pluginID: identifier, sourceID: "account")
    static let anchorID = "project"

    let descriptor = PluginDescriptor(
        id: identifier,
        displayName: "Kontext",
        version: "1",
        capabilities: [.sourceRefresh, .artifactActions, .taskMutation],
        presentation: .init(),
        sourceSetup: .directoryPicker
    )

    private let lock = NSLock()
    private let gate = TaskMutationGate()
    private let failsMutation: Bool
    private var taskState: SourceTaskState = .open
    private var openedIDs: [String] = []

    init(failsMutation: Bool) {
        self.failsMutation = failsMutation
    }

    var openedArtifactIDs: [String] { lock.withLock { openedIDs } }

    func configure(source: PluginSourceDescriptor, rootURL: URL) {}
    func remove(sourceID: PluginSourceIdentifier) {}

    func sources() async throws -> [PluginSourceDescriptor] {
        [.init(id: Self.sourceID, displayName: "Kontext Account", kind: "synthetic")]
    }

    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        .init(source: source, snapshot: snapshot(state: lock.withLock { taskState }))
    }

    func supportedTaskStates(for task: SourceTask, in artifact: SourceArtifact) async -> Set<SourceTaskState> {
        [.open, .completed]
    }

    func setTaskState(_ state: SourceTaskState, for task: SourceTask, in artifact: SourceArtifact) async throws {
        await gate.arriveAndWait()
        if failsMutation { throw TaskCompletionFailure() }
        lock.withLock { taskState = state }
    }

    func artifactActions(for artifact: SourceArtifact) -> [ArtifactAction] {
        [.init(id: "kontext.open", title: "Open", kind: .open)]
    }

    func perform(_ action: ArtifactAction, for artifact: SourceArtifact) async throws {
        lock.withLock { openedIDs.append(artifact.id) }
    }

    func waitUntilMutationStarts() async { await gate.waitUntilArrival() }
    func releaseMutation() async { await gate.release() }

    private func snapshot(state: SourceTaskState) -> ContextSnapshot {
        let artifact = SourceArtifact(
            id: "task-artifact",
            relativePath: "Projects/Launch/Tasks.md",
            mediaKind: .markdown,
            title: "Launch tasks",
            extractedText: "Ship the open-source launch.",
            modifiedAt: .distantPast,
            contentHash: "task-\(state.rawValue)",
            provider: .init(
                pluginID: Self.identifier.rawValue,
                sourceID: Self.sourceID.rawValue
            ),
            metadata: .init(tasks: [
                .init(id: "ship", text: "Ship the open-source launch", state: state)
            ])
        )
        return ContextSnapshot(
            sourceID: Self.sourceID.rawValue,
            revision: "task-\(state.rawValue)",
            artifacts: [artifact],
            anchors: [
                .init(
                    id: Self.anchorID,
                    canonicalName: "Launch",
                    provenance: [.folder],
                    memberArtifactIDs: [artifact.id]
                )
            ],
            relations: [],
            diagnostics: [],
            indexedAt: .now
        )
    }
}

private actor TaskMutationGate {
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private struct TaskCompletionFailure: LocalizedError {
    static let message = "Synthetic task mutation failed."
    var errorDescription: String? { Self.message }
}

private actor TaskCompletionMemoryRepository: PluginSnapshotRepository {
    private var snapshots: [PluginSourceIdentifier: ContextSnapshot] = [:]

    func load(for source: PluginSourceIdentifier) async -> ContextSnapshot? { snapshots[source] }

    func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws {
        snapshots[source] = snapshot
    }

    func remove(source: PluginSourceIdentifier) async throws {
        snapshots.removeValue(forKey: source)
    }
}
