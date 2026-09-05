//  DashboardViewModel.swift
import Combine
import EmbersCore
import EmbersPluginKit
import SwiftUI

/// Thin UI facade over injected navigation/detail and task-mutation coordinators.
@MainActor
final class DashboardViewModel: ObservableObject {
    typealias Tab = DashboardNavigationCoordinator.Tab
    typealias NavigationMotion = DashboardNavigationCoordinator.NavigationMotion

    @Published var showingSettings = false

    let context: ContextIndexController
    let speech: SpeechListener
    let voiceRoutingStatus: VoiceRoutingStatus
    let voiceRoutingPreferences: VoiceRoutingPreferenceState
    private let navigation: DashboardNavigationCoordinator
    private let taskMutations: DashboardTaskMutationCoordinator
    private let willNavigateManually: () -> Void
    private let chooseDirectoryAction: (PluginIdentifier) -> Void
    private let canOpenContextLensAction: (PluginSourceIdentifier) -> Bool
    private let openContextLensAction: (PluginSourceIdentifier) -> Void
    private let canResetVoiceFeedbackAction: (PluginSourceIdentifier) -> Bool
    private let resetVoiceFeedbackAction: (PluginSourceIdentifier) -> Void
    private var collaboratorChanges = Set<AnyCancellable>()

    init(
        context: ContextIndexController,
        speech: SpeechListener,
        voiceRoutingStatus: VoiceRoutingStatus,
        voiceRoutingPreferences: VoiceRoutingPreferenceState,
        navigation: DashboardNavigationCoordinator,
        taskMutations: DashboardTaskMutationCoordinator,
        willNavigateManually: @escaping () -> Void = {},
        chooseDirectory: @escaping (PluginIdentifier) -> Void,
        canOpenContextLens: @escaping (PluginSourceIdentifier) -> Bool = { _ in false },
        openContextLens: @escaping (PluginSourceIdentifier) -> Void = { _ in },
        canResetVoiceFeedback: @escaping (PluginSourceIdentifier) -> Bool = { _ in false },
        resetVoiceFeedback: @escaping (PluginSourceIdentifier) -> Void = { _ in }
    ) {
        self.context = context
        self.speech = speech
        self.voiceRoutingStatus = voiceRoutingStatus
        self.voiceRoutingPreferences = voiceRoutingPreferences
        self.navigation = navigation
        self.taskMutations = taskMutations
        self.willNavigateManually = willNavigateManually
        self.chooseDirectoryAction = chooseDirectory
        self.canOpenContextLensAction = canOpenContextLens
        self.openContextLensAction = openContextLens
        self.canResetVoiceFeedbackAction = canResetVoiceFeedback
        self.resetVoiceFeedbackAction = resetVoiceFeedback

        navigation.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &collaboratorChanges)
        taskMutations.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &collaboratorChanges)
    }

    var tab: Tab { navigation.tab }
    var selected: String? { navigation.selected }
    var detail: AnchorDetail? { navigation.detail }
    var navigationMotion: NavigationMotion { navigation.navigationMotion }
    var evidenceRevealNotBefore: Date? { navigation.evidenceRevealNotBefore }
    var mutatingTaskIDs: Set<String> { taskMutations.mutatingTaskIDs }
    var taskMutationError: String? { taskMutations.taskMutationError }

    var anchors: [AnchorSummary] { context.summaries }
    var unassignedArtifacts: [SourceArtifact] { context.unassignedArtifacts }
    var contextCount: Int { anchors.count + unassignedArtifacts.count }
    var recent: [RecentArtifact] { context.recent }

    func toggleSettings() {
        willNavigateManually()
        withAnimation(NotchViewModel.hoverSpring) { showingSettings.toggle() }
    }

    func dismissSettings() { showingSettings = false }

    func openList() async { willNavigateManually(); await navigation.openList() }
    func retainNavigationForReturn() { navigation.retainNavigationForReturn() }
    func resumeRetainedNavigation() -> Bool { navigation.resumeRetainedNavigation() }
    func discardRetainedNavigation() { navigation.discardRetainedNavigation() }

    func openAnchor(_ id: String, emphasizedReveal: Bool = false) async {
        await navigation.openAnchor(id, emphasizedReveal: emphasizedReveal)
    }

    func select(_ id: String, emphasizedReveal: Bool = false) async {
        willNavigateManually()
        await navigation.select(id, emphasizedReveal: emphasizedReveal)
    }

    func back() { willNavigateManually(); navigation.back() }
    func showContext() { willNavigateManually(); navigation.showContext() }
    func showRecent() { willNavigateManually(); navigation.showRecent() }
    func reload() async { await navigation.reload() }

    func ignoreSelected() { if let selected { context.ignore(selected); back() } }
    func restore(_ id: String) { context.restore(id) }
    func reindex() { Task { await context.reindex(presentation: .silent) } }
    func forget() { Task { await context.forget() } }
    func chooseFolder() { chooseDirectoryAction(context.defaultDirectoryProviderID) }
    func configureSource(_ provider: PluginDescriptor) {
        guard provider.sourceSetup == .directoryPicker else { return }
        chooseDirectoryAction(provider.id)
    }
    func canOpenContextLens(_ sourceID: PluginSourceIdentifier) -> Bool {
        canOpenContextLensAction(sourceID)
    }
    func openContextLens(_ sourceID: PluginSourceIdentifier) {
        openContextLensAction(sourceID)
    }
    func canResetVoiceFeedback(_ sourceID: PluginSourceIdentifier) -> Bool {
        canResetVoiceFeedbackAction(sourceID)
    }
    func resetVoiceFeedback(_ sourceID: PluginSourceIdentifier) {
        resetVoiceFeedbackAction(sourceID)
    }
    func toggleListening() { if speech.isListening { speech.stop() } else { Task { await speech.startFromUserAction() } } }
    func resetVoiceRoutingPreferences() { voiceRoutingPreferences.beginReset() }

    func open(_ artifact: SourceArtifact) {
        willNavigateManually()
        Task { await context.open(artifact) }
    }

    func artifactActions(for artifact: SourceArtifact) async -> [ArtifactAction] {
        await context.availableArtifactActions(for: artifact)
    }

    func perform(_ action: ArtifactAction, for artifact: SourceArtifact) async {
        do { try await context.perform(action, for: artifact) }
        catch { taskMutations.report(error) }
    }

    func supportsCompletion(_ task: AnchorTask) async -> Bool {
        await taskMutations.supportsCompletion(task)
    }

    func complete(_ task: AnchorTask) async {
        await taskMutations.complete(task)
    }
}
