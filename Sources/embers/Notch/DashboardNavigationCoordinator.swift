import EmbersCore
import SwiftUI

/// Owns dashboard navigation state, retained-return timing, and detached detail loading.
@MainActor
final class DashboardNavigationCoordinator: ObservableObject {
    enum Tab { case context, recent }
    enum NavigationMotion { case none, drillIn, traverse, back }

    @Published private(set) var tab: Tab = .context
    @Published private(set) var selected: String?
    @Published private(set) var detail: AnchorDetail?
    @Published private(set) var navigationMotion: NavigationMotion = .none
    @Published private(set) var evidenceRevealNotBefore: Date?

    private let context: ContextIndexController
    private let speech: SpeechListener
    private let changeBaselines: any ChangeBaselineStore
    private var navigationRetention: Task<Void, Never>?

    init(
        context: ContextIndexController,
        speech: SpeechListener,
        changeBaselines: any ChangeBaselineStore
    ) {
        self.context = context
        self.speech = speech
        self.changeBaselines = changeBaselines
    }

    func openList() async {
        tab = .context
        selected = nil
        detail = nil
        navigationMotion = .none
        evidenceRevealNotBefore = nil
        speech.prioritizeVocabulary([])
    }

    func retainNavigationForReturn() {
        navigationRetention?.cancel()
        navigationRetention = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self else { return }
            await self.openList()
            self.navigationRetention = nil
        }
    }

    func resumeRetainedNavigation() -> Bool {
        guard navigationRetention != nil else { return false }
        navigationRetention?.cancel()
        navigationRetention = nil
        return true
    }

    func discardRetainedNavigation() {
        navigationRetention?.cancel()
        navigationRetention = nil
    }

    func openAnchor(_ id: String, emphasizedReveal: Bool = false) async {
        tab = .context
        await select(id, emphasizedReveal: emphasizedReveal)
    }

    func select(_ id: String, emphasizedReveal: Bool = false) async {
        guard let snapshot = context.snapshot, let graphSearch = context.graphSearch else { return }
        let currentBaseline = ContextChangeBaseline.capture(for: id, in: snapshot)
        let priorBaseline = currentBaseline.flatMap { changeBaselines.baseline(for: $0.scope) }
        evidenceRevealNotBefore = emphasizedReveal ? Date().addingTimeInterval(0.18) : nil
        navigationMotion = selected == nil ? .drillIn : .traverse
        withAnimation(NotchViewModel.contentNavigate) { selected = id; detail = nil }
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.detail(
                nodeID: id,
                graphSearch: graphSearch,
                snapshot: snapshot,
                baseline: priorBaseline
            )
        }.value
        guard selected == id, context.snapshot?.revision == snapshot.revision else { return }
        withAnimation(NotchViewModel.contentReveal) { detail = loaded }
        if let loaded {
            speech.prioritizeVocabulary([loaded.anchor.canonicalName] + loaded.subcontexts.map(\.name) + loaded.relatedAnchors.map(\.name))
        }
        if loaded != nil, let currentBaseline { changeBaselines.save(currentBaseline) }
    }

    func back() {
        evidenceRevealNotBefore = nil
        navigationMotion = .back
        withAnimation(NotchViewModel.contentNavigate) { selected = nil; detail = nil }
        speech.prioritizeVocabulary([])
    }

    func showContext() {
        withAnimation(NotchViewModel.hoverSpring) { tab = .context }
    }

    func showRecent() {
        evidenceRevealNotBefore = nil
        withAnimation(NotchViewModel.hoverSpring) { tab = .recent }
        speech.prioritizeVocabulary([])
    }

    func reload() async {
        guard let id = selected, let snapshot = context.snapshot, let graphSearch = context.graphSearch else { return }
        let baseline = ContextChangeBaseline.capture(for: id, in: snapshot)
            .flatMap { changeBaselines.baseline(for: $0.scope) }
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.detail(
                nodeID: id,
                graphSearch: graphSearch,
                snapshot: snapshot,
                baseline: baseline
            )
        }.value
        guard selected == id, context.snapshot?.revision == snapshot.revision else { return }
        detail = loaded
    }

    private nonisolated static func detail(
        nodeID: String,
        graphSearch: GraphContextSearch,
        snapshot: ContextSnapshot,
        baseline: ContextChangeBaseline?
    ) -> AnchorDetail? {
        guard var detail = graphSearch.detail(nodeID: nodeID, in: snapshot, lastSeen: nil) else { return nil }
        let changeSet = ContextChangeDetector.changes(
            for: nodeID,
            in: snapshot,
            since: baseline
        )
        detail.changeSet = changeSet
        let changedIDs = changeSet.currentChangedArtifactIDs
        detail.hits = detail.hits.map { hit in
            var hit = hit
            hit.changedSinceLastPeek = changedIDs.contains(hit.artifact.id)
            return hit
        }
        return detail
    }
}
