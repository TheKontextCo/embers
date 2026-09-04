import Combine
import EmbersCore
import EmbersLocal
import EmbersPluginHost
import Foundation

@MainActor
protocol VoiceRoutingCoordinatorDelegate: AnyObject {
    var selectedVoiceNodeID: String? { get }
    func voiceRoutingCoordinatorReloadDashboard()
    func voiceRoutingCoordinatorOpenAnchor(
        _ nodeID: String,
        routeEvidence: RoutePresentationEvidence?
    )
    func voiceRoutingCoordinatorOpenPeek(_ peek: Peek)
}

/// Coordinates graph publication and transcript events into routing and presentation intents.
/// Pack compilation and preference persistence are injected lifecycle collaborators.
@MainActor
final class VoiceRoutingCoordinator {
    var status: VoiceRoutingStatus { packLifecycle.status }
    var preferenceState: VoiceRoutingPreferenceState { preferences.state }

    private let context: ContextIndexController
    private let speech: SpeechListener
    private let notch: NotchViewModel
    private let peeks: PeekQueue
    private let packLifecycle: VoiceRoutingPackCoordinator
    private let preferences: VoiceRoutingPreferenceCoordinator
    private let learning: VoiceLearningCoordinator
    private let featureFlags: AppFeatureFlags
    private weak var delegate: (any VoiceRoutingCoordinatorDelegate)?
    private var hasStarted = false

    private var voiceRouter = VoiceRoutingStreamRouter(baseTargets: [], pack: nil)
    private var baseVoiceTargets: [MatchTarget] = []
    private var baseVoiceVocabulary: [String] = []
    private var routingPack: VoiceRoutingPack?
    private var sourceIDByNodeID: [String: String] = [:]
    private var peekOpenCommandTask: Task<Void, Never>?
    private var peekCommandTranscriptPrefix: (utteranceID: UUID, text: String)?
    private var voiceStateFingerprint: String?
    private var cancellables = Set<AnyCancellable>()

    init(
        context: ContextIndexController,
        speech: SpeechListener,
        notch: NotchViewModel,
        peeks: PeekQueue,
        packLifecycle: VoiceRoutingPackCoordinator,
        preferences: VoiceRoutingPreferenceCoordinator,
        learning: VoiceLearningCoordinator,
        featureFlags: AppFeatureFlags = AppFeatureFlags()
    ) {
        self.context = context
        self.speech = speech
        self.notch = notch
        self.peeks = peeks
        self.packLifecycle = packLifecycle
        self.preferences = preferences
        self.learning = learning
        self.featureFlags = featureFlags
    }

    func start(delegate: any VoiceRoutingCoordinatorDelegate) {
        precondition(!hasStarted, "VoiceRoutingCoordinator may only be started once")
        hasStarted = true
        self.delegate = delegate
        packLifecycle.start(delegate: self)
        preferences.start(delegate: self)
        learning.start(delegate: self)

        context.$graph.combineLatest(context.$snapshot)
            .sink { [weak self] graph, snapshot in self?.applyGraph(graph, snapshot: snapshot) }
            .store(in: &cancellables)

        context.$contextSources
            .sink { [weak self] sources in
                guard let self else { return }
                self.preferences.apply(sources: sources, graph: self.context.graph)
                self.learning.apply(sources: sources)
                self.rebuildSourceOwnership(sources: sources, graph: self.context.graph)
            }
            .store(in: &cancellables)

        speech.onTranscript = { [weak self] event in
            self?.handleTranscript(event)
        }
    }

    func recordOpen(conceptID: String, nodeID: String) {
        preferences.recordOpen(conceptID: conceptID, nodeID: nodeID)
    }

    func removeSourceCaches(_ sourceID: String) async {
        await packLifecycle.deleteCache()
        await preferences.removeSourceData(sourceID)
        await learning.removeSourceData(sourceID)
    }

    func contextLensRequest(
        sourceID: String,
        sourceName: String,
        sourceSnapshot: ContextSnapshot?
    ) -> ContextLensRequest? {
        ContextLensRequest(
            sourceID: sourceID,
            sourceName: sourceName,
            sourceSnapshot: sourceSnapshot,
            graph: context.graph,
            snapshot: context.snapshot,
            pack: routingPack
        )
    }

    private func applyGraph(_ graph: ContextGraph?, snapshot: ContextSnapshot?) {
        guard let fingerprint = Self.voiceInputFingerprint(graph: graph, snapshot: snapshot) else { return }
        guard fingerprint != voiceStateFingerprint else { return }
        voiceStateFingerprint = fingerprint
        preferences.apply(sources: context.contextSources, graph: graph)
        rebuildSourceOwnership(sources: context.contextSources, graph: graph)
        guard let graph, let graphSearch = context.graphSearch else {
            baseVoiceTargets = []
            baseVoiceVocabulary = []
            voiceRouter.replace(baseTargets: [], pack: nil)
            routingPack = nil
            speech.setBaseVocabulary([])
            speech.prioritizeVocabulary([])
            packLifecycle.waitForContext()
            return
        }
        let nodes: [GraphNode]
        if let snapshot, snapshot.revision == graph.revision {
            nodes = VoiceRoutingAddressabilityPolicy().nodes(in: graph, snapshot: snapshot)
        } else {
            // Preserve exact-name routing while graph and snapshot publications briefly cross.
            nodes = graph.voiceNodes
        }
        baseVoiceTargets = VoiceRoutingBaseTargetBuilder().build(nodes: nodes)
        baseVoiceVocabulary = graphSearch.vocabulary()
        installRoutingPack(nil)
        Log.speech.info("voice_matcher_loaded")
        if let snapshot, snapshot.revision == graph.revision {
            packLifecycle.compile(graph: graph, snapshot: snapshot)
        } else {
            packLifecycle.waitForMatchingSnapshot()
        }
        delegate?.voiceRoutingCoordinatorReloadDashboard()
    }

    nonisolated static func voiceInputFingerprint(graph: ContextGraph?, snapshot: ContextSnapshot?) -> String? {
        if let graph, let snapshot, graph.revision == snapshot.revision {
            let seeds = VoiceRoutingSeedBuilder().build(graph: graph, snapshot: snapshot)
            return VoiceRoutingInputRevision.make(seeds)
        }
        if graph != nil, snapshot != nil { return nil }
        return StableHash.hex([graph?.revision ?? "none", snapshot?.revision ?? "none"].joined(separator: "|"))
    }

    private func handleTranscript(_ event: SpeechTranscript) {
        peekOpenCommandTask?.cancel()
        peekOpenCommandTask = nil
        let visiblePeeks = PeekPresentationPolicy().displayedPeeks(
            peeks.peeks,
            notchIsOpen: notch.state == .open
        )
        let commandText = PeekOpenVoiceCommand.textAfterPeek(
            in: event,
            prefix: peekCommandTranscriptPrefix
        )
        let commandEvent = SpeechTranscript(
            text: commandText,
            isFinal: event.isFinal,
            utteranceID: event.utteranceID
        )
        switch PeekOpenVoiceCommand.resolve(
            commandEvent,
            visiblePeeks: visiblePeeks,
            isEnabled: featureFlags.voiceOpenSinglePeek
        ) {
        case .notACommand:
            break
        case .held(let candidate):
            Log.speech.debug("peek_open_command_held")
            scheduleStablePeekOpen(candidate)
            return
        case .ambiguous:
            Log.speech.info("peek_open_command_abstained")
            return
        case .open(let candidate):
            executePeekOpen(candidate)
            return
        }

        var visibleNodeIDs = peeks.visibleNodeIDs
        if let selected = delegate?.selectedVoiceNodeID { visibleNodeIDs.insert(selected) }
        let update = voiceRouter.process(
            event,
            visibleNodeIDs: visibleNodeIDs,
            visibleConceptCandidates: peeks.visibleConceptCandidates
        )
        for nodeID in update.retractedNodeIDs {
            let peekIDs = peeks.peeks.compactMap { peek -> String? in
                guard case .node(let visibleID) = peek.target.ref, visibleID == nodeID else { return nil }
                return peek.id
            }
            peekIDs.forEach(peeks.remove)
            Log.speech.info("voice_match_retracted")
        }
        for conceptID in update.retractedConceptIDs {
            peeks.removeConcept(conceptID)
            Log.speech.info("shared_concept_retracted")
        }
        if update.isEmpty {
            Log.speech.debug("voice_match_abstained_or_held")
            return
        }

        Log.speech.debug("voice_match_presented")

        for concept in update.sharedConcepts {
            let evidenceByNodeID: [String: RoutePresentationEvidence] = Dictionary(
                uniqueKeysWithValues: concept.candidates.compactMap { match -> (String, RoutePresentationEvidence)? in
                guard case .node(let nodeID) = match.target.ref,
                      let evidence = routeEvidence(for: match) else { return nil }
                return (nodeID, evidence)
                }
            )
            peeks.replaceConcept(
                concept.conceptID,
                with: concept.candidates.map(\.target),
                routeEvidenceByNodeID: evidenceByNodeID
            )
            Log.speech.info("shared_concept_matched")
        }
        if !update.sharedConcepts.isEmpty {
            rememberPeekCommandPrefix(event)
        }

        if notch.state == .open, !update.matches.isEmpty {
            let preferredMatch = update.max(by: {
                $0.trigger.pattern.displayPhrase.count < $1.trigger.pattern.displayPhrase.count
            })!
            let preferred = preferredMatch.target
            guard case .node(let preferredID) = preferred.ref else { return }
            voiceRouter.markPresented(update.sharedConcepts)
            voiceRouter.markPresented([preferredMatch])
            Log.speech.info("context_opened")
            let routeEvidence = update.matches.count == 1 && update.sharedConcepts.isEmpty
                ? routeEvidence(for: preferredMatch)
                : nil
            delegate?.voiceRoutingCoordinatorOpenAnchor(
                preferredID,
                routeEvidence: routeEvidence
            )
            return
        }
        voiceRouter.markPresented(update)
        for match in update {
            Log.speech.info("context_matched")
            peeks.push(match.target, routeEvidence: routeEvidence(for: match))
        }
        if !update.matches.isEmpty {
            rememberPeekCommandPrefix(event)
        }
    }

    private func rememberPeekCommandPrefix(_ event: SpeechTranscript) {
        peekCommandTranscriptPrefix = (
            utteranceID: event.utteranceID,
            text: PhraseMatcher.normalize(event.text)
        )
    }

    private func scheduleStablePeekOpen(_ candidate: Peek) {
        peekOpenCommandTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: PeekOpenVoiceCommand.partialStabilityDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.peekOpenCommandTask = nil
            self.executePeekOpen(candidate)
        }
    }

    private func executePeekOpen(_ candidate: Peek) {
        // Re-read presentation state at the execution boundary. A timer or a corrected
        // transcript must not redirect the command to a replacement peek.
        let currentVisiblePeeks = PeekPresentationPolicy().displayedPeeks(
            peeks.peeks,
            notchIsOpen: notch.state == .open
        )
        guard currentVisiblePeeks.count == 1,
              currentVisiblePeeks.first?.id == candidate.id else {
            Log.speech.info("peek_open_command_stale")
            return
        }
        Log.speech.info("peek_open_command_executed")
        delegate?.voiceRoutingCoordinatorOpenPeek(candidate)
    }

    @discardableResult
    private func installRoutingPack(_ pack: VoiceRoutingPack?) -> Int {
        routingPack = pack
        voiceRouter.replace(baseTargets: baseVoiceTargets, pack: pack)
        voiceRouter.replacePreferences(preferences.snapshot)
        speech.setBaseVocabulary(voiceRouter.vocabulary + baseVoiceVocabulary)
        return voiceRouter.triggerCount
    }

    private func routeEvidence(for match: VoiceRoutingRuntimeMatch) -> RoutePresentationEvidence? {
        guard case .node(let nodeID) = match.target.ref,
              let sourceID = sourceIDByNodeID[nodeID] else { return nil }
        return RoutePresentationEvidence(
            exclusionKey: VoiceRouteExclusionKey(
                sourceID: sourceID,
                nodeID: nodeID,
                pattern: match.trigger.pattern.routePatternIdentity
            )
        )
    }

    private func rebuildSourceOwnership(
        sources: [HostedPluginSource],
        graph: ContextGraph?
    ) {
        let sourceIDByReferenceID = sources.reduce(into: [String: String]()) { result, source in
            let sourceID = source.descriptor.id.rawValue
            for anchor in source.snapshot?.anchors ?? [] {
                result[anchor.id] = sourceID
            }
        }
        sourceIDByNodeID = Dictionary(uniqueKeysWithValues: (graph?.nodes ?? []).compactMap { node in
            sourceIDByReferenceID[node.referenceID].map { (node.id, $0) }
        })
    }
}

extension VoiceRoutingCoordinator: VoiceRoutingPackCoordinatorDelegate {
    func voiceRoutingPackCoordinatorInstall(_ pack: VoiceRoutingPack) -> Int {
        installRoutingPack(pack)
    }
}

extension VoiceRoutingCoordinator: VoiceRoutingPreferenceCoordinatorDelegate {
    func voiceRoutingPreferencesDidChange() {
        voiceRouter.replacePreferences(preferences.snapshot)
    }
}

extension VoiceRoutingCoordinator: VoiceLearningCoordinatorDelegate {
    func voiceLearningDidChange(_ snapshot: VoiceLearningSnapshot) {
        voiceRouter.replaceLearning(snapshot)
    }
}
