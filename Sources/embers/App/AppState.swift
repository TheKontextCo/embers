import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import EmbersCore
import EmbersPluginKit

@MainActor
final class AppState: ObservableObject {
    let context: ContextIndexController
    let notch: NotchViewModel
    lazy private(set) var dash = DashboardViewModel(
        context: context,
        speech: speech,
        voiceRoutingStatus: voiceRoutingStatus,
        voiceRoutingPreferences: voiceRoutingPreferenceState,
        navigation: dashboardNavigation,
        taskMutations: taskMutations,
        chooseDirectory: { [weak self] providerID in
            self?.presentFolderPicker(for: providerID)
        },
        canOpenContextLens: { [weak self] sourceID in
            self?.contextLensRequest(for: sourceID) != nil
        },
        openContextLens: { [weak self] sourceID in
            self?.openContextLens(for: sourceID)
        }
    )
    let peeks: PeekQueue
    let speech: SpeechListener
    let voiceRouting: VoiceRoutingCoordinator
    var voiceRoutingStatus: VoiceRoutingStatus { voiceRouting.status }
    var voiceRoutingPreferenceState: VoiceRoutingPreferenceState { voiceRouting.preferenceState }

    private let dashboardNavigation: DashboardNavigationCoordinator
    private let taskMutations: DashboardTaskMutationCoordinator
    private let changeBaselines: any ChangeBaselineStore
    private let hoverMon = HoverMonitor()
    private let keys = KeyMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var muteHotKey: GlobalHotKey?
    private var contextLensExportTask: Task<Void, Never>?
    weak var hostWindow: NSWindow?
    private var onboardingGate = OnboardingGate()

    init(
        context: ContextIndexController,
        speech: SpeechListener,
        notch: NotchViewModel,
        peeks: PeekQueue,
        voiceRouting: VoiceRoutingCoordinator,
        dashboardNavigation: DashboardNavigationCoordinator,
        taskMutations: DashboardTaskMutationCoordinator,
        changeBaselines: any ChangeBaselineStore
    ) {
        self.context = context
        self.speech = speech
        self.notch = notch
        self.peeks = peeks
        self.voiceRouting = voiceRouting
        self.dashboardNavigation = dashboardNavigation
        self.taskMutations = taskMutations
        self.changeBaselines = changeBaselines
        _ = dash

        context.$state.combineLatest(context.$snapshot)
            .sink { [weak self] state, snapshot in
                guard let self else { return }
                if onboardingGate.shouldOpen(state: state, hasSnapshot: snapshot != nil) {
                    openNotch()
                }
            }
            .store(in: &cancellables)

        context.onRemoveSource = { [weak self] sourceID in
            guard let self else { return }
            self.changeBaselines.removeBaselines(forSourceID: sourceID)
            await self.voiceRouting.removeSourceCaches(sourceID)
        }
        voiceRouting.start(delegate: self)
        installMuteHotkey()
        Task {
            await context.bootstrap()
            if Settings.shared.listenOnLaunch, context.snapshot != nil { await speech.startIfAuthorized() }
        }
    }

    func presentFolderPicker() {
        presentFolderPicker(for: context.defaultDirectoryProviderID)
    }

    func presentFolderPicker(for providerID: PluginIdentifier) {
        // A folder picker is a new interaction surface. Do not wait for the hover
        // monitor's exit debounce or animate the notch beneath the modal panel.
        closeNotch(immediately: true)
        DispatchQueue.main.async { [weak self] in
            self?.runFolderPicker(for: providerID)
        }
    }

    private func runFolderPicker(for providerID: PluginIdentifier) {
        let panel = NSOpenPanel()
        panel.title = "Choose your context folder"
        panel.prompt = "Index Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { try? await context.chooseDirectory(url, for: providerID) }
    }

    func useSampleVault() { Task { try? await context.useSampleVault() } }

    private func contextLensRequest(for sourceID: PluginSourceIdentifier) -> ContextLensRequest? {
        guard let source = context.contextSources.first(where: { $0.descriptor.id == sourceID }) else { return nil }
        return voiceRouting.contextLensRequest(
            sourceID: sourceID.rawValue,
            sourceName: source.descriptor.displayName,
            sourceSnapshot: source.snapshot
        )
    }

    private func openContextLens(for sourceID: PluginSourceIdentifier) {
        guard contextLensExportTask == nil,
              let request = contextLensRequest(for: sourceID) else { return }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Embers", isDirectory: true)
            .appendingPathComponent("Context Lens", isDirectory: true)
        contextLensExportTask = Task { [weak self] in
            defer { self?.contextLensExportTask = nil }
            do {
                let fileURL = try await Task.detached(priority: .utility) {
                    guard let document = request.build() else { return Optional<URL>.none }
                    return try ContextLensFileExporter(directoryURL: root, openURL: { _ in true })
                        .write(document)
                }.value
                guard !Task.isCancelled, let fileURL else { return }
                guard NSWorkspace.shared.open(fileURL) else {
                    throw ContextLensFileExporter.ExportError.defaultApplicationRejectedFile
                }
            } catch {
                Log.app.error("context_lens_open_failed")
            }
        }
    }

    private func installMuteHotkey() {
        muteHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            guard Settings.shared.muteHotkeyEnabled else { return }
            self?.toggleListening()
        }
    }

    func toggleListening() {
        guard context.snapshot != nil else { return }
        if speech.isListening { speech.stop() } else { Task { await speech.startFromUserAction() } }
    }

    func triggerMockPeek() {
        guard let node = context.graph?.activationNodes.first else { return }
        peeks.push(.init(phrase: node.name, ref: .node(node.id), title: node.name))
    }

    func runTour(_ spec: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(NotchViewModel.openSpring) { notch.open(focus: .hybrid) }
            switch spec {
            case "list", "context": openNotch()
            case "recent": openNotch(); dash.showRecent()
            case "settings": openNotch(); dash.toggleSettings()
            default: openNotch(anchor: spec)
            }
        }
    }

    func startNotchHover() {
        hoverMon.start(region: { [weak self] in self?.notchRegion() ?? .zero }) { [weak self] inside in
            Log.app.info("notch_hover_changed")
            // A hover can arrive while NSHostingView is still committing a SwiftUI update
            // (especially on launch when the pointer already sits over the hardware notch).
            // Mutating @Published state in that transaction is dropped by SwiftUI and leaves
            // the model "open" while the rendered panel stays closed. Defer one frame.
            if inside {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    self?.openNotch()
                }
            } else {
                self?.closeNotch()
            }
        }
    }

    private func notchRegion() -> CGRect {
        guard let frame = hostWindow?.frame else { return .zero }
        if notch.state == .open {
            return CGRect(x: frame.minX, y: frame.maxY - NotchMetrics.openSize.height, width: frame.width, height: NotchMetrics.openSize.height)
        }
        let size = notch.closedSize
        return CGRect(x: frame.midX - size.width / 2 - 8, y: frame.maxY - size.height - 6, width: size.width + 16, height: size.height + 6)
    }

    func openNotch(
        anchor: String? = nil,
        closeWhenPointerLeaves: Bool = false,
        takeKeyboardFocus: Bool = false
    ) {
        guard notch.state == .closed || anchor != nil else { return }
        let resumesNavigation = anchor == nil && dash.resumeRetainedNavigation()
        if anchor != nil { dash.discardRetainedNavigation() }
        Log.app.info("notch_opened")
        withAnimation(NotchViewModel.openSpring) { notch.open(focus: anchor.map(OpenFocus.entity) ?? .hybrid) }
        if closeWhenPointerLeaves { hoverMon.armExit() }
        else { hoverMon.armExitIfPointerInside() }
        if let anchor {
            Task { await dash.openAnchor(anchor, emphasizedReveal: closeWhenPointerLeaves) }
        } else if !resumesNavigation {
            Task { await dash.openList() }
        }
        if takeKeyboardFocus { activateKeyboardNavigation() }
    }

    /// Selection boundary for a surfaced match. Presentation is neutral; only an explicit open
    /// of a compiler-declared shared candidate teaches the local ordering overlay.
    func openMatch(_ target: MatchTarget, closeWhenPointerLeaves: Bool = false) {
        guard case .node(let nodeID) = target.ref else { return }
        if let conceptID = target.conceptID {
            voiceRouting.recordOpen(conceptID: conceptID, nodeID: nodeID)
        }
        openNotch(anchor: nodeID, closeWhenPointerLeaves: closeWhenPointerLeaves, takeKeyboardFocus: true)
    }

    func closeNotch(immediately: Bool = false) {
        guard notch.state == .open else { return }
        keys.stop(); dash.dismissSettings()
        dash.retainNavigationForReturn()
        if immediately {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { notch.close() }
        } else {
            withAnimation(NotchViewModel.closeSpring) { notch.close() }
        }
    }

    /// Entering keyboard navigation is an explicit interaction boundary. The normal notch
    /// remains nonactivating while hovered or opened by automation/voice; this path activates
    /// only Embers, makes its panel key, and then listens to its own local event stream.
    func activateKeyboardNavigation() {
        guard notch.state == .open, let hostWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        hostWindow.makeKeyAndOrderFront(nil)
        keys.start { [weak self] in self?.handleKey($0) }
    }

    /// Called when the explicitly focused panel resigns key status. Keeping this separate from
    /// closing lets a hover-open panel remain visible without retaining an input monitor.
    func deactivateKeyboardNavigation() {
        keys.stop()
    }

    private func handleKey(_ key: KeyMonitor.Key) {
        switch key {
        case .escape: dash.selected != nil ? dash.back() : closeNotch()
        case .left: if dash.selected != nil { dash.back() }
        case .right, .up, .down: break
        }
    }

    func runDemo() {
        Task { @MainActor in
            let nodes = context.graph.map { Array($0.activationNodes.prefix(4)) } ?? []
            try? await Task.sleep(for: .seconds(1))
            if ProcessInfo.processInfo.environment["EMBERS_DEMO"] != "peek" { openNotch() }
            for node in nodes {
                try? await Task.sleep(for: .milliseconds(600))
                peeks.push(.init(phrase: node.name, ref: .node(node.id), title: node.name))
            }
        }
    }
}

extension AppState: VoiceRoutingCoordinatorDelegate {
    var selectedVoiceNodeID: String? { dash.selected }

    func voiceRoutingCoordinatorReloadDashboard() {
        Task { await dash.reload() }
    }

    func voiceRoutingCoordinatorOpenAnchor(_ nodeID: String) {
        Task { await dash.openAnchor(nodeID) }
    }

    func voiceRoutingCoordinatorOpenMatch(_ target: MatchTarget) {
        openMatch(target)
    }
}

struct OnboardingGate {
    private(set) var isRequired = false

    mutating func shouldOpen(state: IndexingState, hasSnapshot: Bool) -> Bool {
        let wasRequired = isRequired
        if hasSnapshot {
            isRequired = false
        } else if state.requiresOnboarding {
            isRequired = true
        }
        return isRequired && !wasRequired
    }
}

private extension IndexingState {
    var requiresOnboarding: Bool {
        if self == .unconfigured { return true }
        if case .failed = self { return true }
        return false
    }
}
