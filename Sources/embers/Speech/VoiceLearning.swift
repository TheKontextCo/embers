import Combine
import EmbersCore
import EmbersLocal
import EmbersPluginHost
import Foundation

/// Immutable cause carried from a runtime match into its visible Peek and, if
/// opened, into that one context journey.
struct RoutePresentationEvidence: Equatable, Sendable {
    let presentationID: UUID
    let exclusionKey: VoiceRouteExclusionKey

    init(presentationID: UUID = UUID(), exclusionKey: VoiceRouteExclusionKey) {
        self.presentationID = presentationID
        self.exclusionKey = exclusionKey
    }
}

struct ActivePeekJourney: Equatable, Sendable {
    let evidence: RoutePresentationEvidence
    let peekID: String?
}

struct VoiceLearningNotice: Equatable, Identifiable, Sendable {
    let id: UUID
    let exclusionKey: VoiceRouteExclusionKey?
    let message: String

    var canUndo: Bool { exclusionKey != nil }
}

@MainActor
protocol VoiceLearningCoordinatorDelegate: AnyObject {
    func voiceLearningDidChange(_ snapshot: VoiceLearningSnapshot)
}

/// Main-actor bridge between explicit UI corrections, the actor-backed local
/// store, and immutable router snapshots. It never interprets transcript text.
@MainActor
final class VoiceLearningCoordinator: ObservableObject {
    @Published private(set) var notice: VoiceLearningNotice?
    private(set) var snapshot = VoiceLearningSnapshot.empty
    private(set) var activeJourney: ActivePeekJourney?

    private let store: any VoiceLearningStoring
    private weak var delegate: (any VoiceLearningCoordinatorDelegate)?
    private var activeSourceIDs = Set<String>()
    private var sourceGenerations: [String: UInt64] = [:]
    private var mutationTasks: [String: [UUID: Task<Void, Never>]] = [:]
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var noticeExpiryTask: Task<Void, Never>?
    private var hasStarted = false

    init(store: any VoiceLearningStoring) {
        self.store = store
    }

    func start(delegate: any VoiceLearningCoordinatorDelegate) {
        precondition(!hasStarted, "VoiceLearningCoordinator may only be started once")
        hasStarted = true
        self.delegate = delegate
    }

    func apply(sources: [HostedPluginSource]) {
        activeSourceIDs = Set(sources.map { $0.descriptor.id.rawValue })
        reload()
    }

    func beginJourney(_ evidence: RoutePresentationEvidence, peekID: String?) {
        guard activeSourceIDs.contains(evidence.exclusionKey.sourceID) else { return }
        activeJourney = ActivePeekJourney(evidence: evidence, peekID: peekID)
    }

    func invalidateJourney() {
        activeJourney = nil
    }

    /// Consuming first makes repeated mouse/key delivery idempotent even while
    /// the local atomic write is still queued.
    func consumeJourney() -> ActivePeekJourney? {
        guard let journey = activeJourney else { return nil }
        invalidateJourney()
        return journey
    }

    func recordRejection(_ journey: ActivePeekJourney) {
        let key = journey.evidence.exclusionKey
        guard activeSourceIDs.contains(key.sourceID) else { return }
        let taskID = UUID()
        let sourceGeneration = sourceGenerations[key.sourceID, default: 0]
        let store = store
        invalidateReload()
        let task = Task { [weak self] in
            var outcome: MutationOutcome = .cancelled
            do {
                _ = try await store.recordExclusion(
                    key,
                    at: .now,
                    sourceGeneration: sourceGeneration
                )
                if !Task.isCancelled, let self,
                   self.sourceGenerations[key.sourceID, default: 0] == sourceGeneration,
                   self.activeSourceIDs.contains(key.sourceID) {
                    outcome = .recorded(key)
                }
            } catch is CancellationError {
                // Source retirement or a newer lifecycle owns the visible state.
            } catch {
                outcome = .failed("Couldn’t save voice feedback")
                Log.speech.error("voice_learning_exclusion_write_failed")
            }
            self?.mutationFinished(sourceID: key.sourceID, taskID: taskID, outcome: outcome)
        }
        mutationTasks[key.sourceID, default: [:]][taskID] = task
    }

    func undoNotice() {
        guard let key = notice?.exclusionKey else { return }
        let taskID = UUID()
        let sourceGeneration = sourceGenerations[key.sourceID, default: 0]
        let store = store
        invalidateReload()
        let task = Task { [weak self] in
            var outcome: MutationOutcome = .cancelled
            do {
                _ = try await store.removeExclusion(key, sourceGeneration: sourceGeneration)
                if !Task.isCancelled, let self,
                   self.sourceGenerations[key.sourceID, default: 0] == sourceGeneration {
                    outcome = .undone
                }
            } catch is CancellationError {
            } catch {
                outcome = .failed("Couldn’t undo voice feedback")
                Log.speech.error("voice_learning_exclusion_undo_failed")
            }
            self?.mutationFinished(sourceID: key.sourceID, taskID: taskID, outcome: outcome)
        }
        mutationTasks[key.sourceID, default: [:]][taskID] = task
    }

    func canReset(sourceID: String) -> Bool {
        snapshot.exclusions.keys.contains { $0.sourceID == sourceID }
            && mutationTasks[sourceID] == nil
    }

    func reset(sourceID: String) {
        guard activeSourceIDs.contains(sourceID), canReset(sourceID: sourceID) else { return }
        mutationTasks.removeValue(forKey: sourceID)?.values.forEach { $0.cancel() }
        let sourceGeneration = invalidateSource(sourceID)
        let taskID = UUID()
        let store = store
        invalidateReload()
        let task = Task { [weak self] in
            var outcome: MutationOutcome = .cancelled
            do {
                try await store.delete(sourceID: sourceID, sourceGeneration: sourceGeneration)
                if !Task.isCancelled, let self,
                   self.sourceGenerations[sourceID, default: 0] == sourceGeneration,
                   self.activeSourceIDs.contains(sourceID) {
                    outcome = .reset
                }
            } catch is CancellationError {
            } catch {
                outcome = .failed("Couldn’t reset voice feedback")
                Log.speech.error("voice_learning_reset_failed")
            }
            self?.mutationFinished(sourceID: sourceID, taskID: taskID, outcome: outcome)
        }
        mutationTasks[sourceID, default: [:]][taskID] = task
    }

    func removeSourceData(_ sourceID: String) async {
        activeSourceIDs.remove(sourceID)
        if activeJourney?.evidence.exclusionKey.sourceID == sourceID { invalidateJourney() }
        if notice?.exclusionKey?.sourceID == sourceID { clearNotice() }
        mutationTasks.removeValue(forKey: sourceID)?.values.forEach { $0.cancel() }
        invalidateReload()
        let generation = invalidateSource(sourceID)
        do {
            try await store.delete(sourceID: sourceID, sourceGeneration: generation)
            reload()
        } catch {
            reload()
            presentNotice("Couldn’t erase voice feedback")
            Log.speech.error("voice_learning_source_deletion_failed")
        }
    }

    private func publish(_ snapshot: VoiceLearningSnapshot) {
        self.snapshot = snapshot
        delegate?.voiceLearningDidChange(snapshot)
    }

    private func mutationFinished(sourceID: String, taskID: UUID, outcome: MutationOutcome) {
        mutationTasks[sourceID]?[taskID] = nil
        if mutationTasks[sourceID]?.isEmpty == true {
            mutationTasks[sourceID] = nil
        }
        switch outcome {
        case .recorded(let key):
            reload { [weak self] in self?.presentNotice("Not this — learned", key: key) }
        case .undone:
            reload { [weak self] in self?.clearNotice() }
        case .reset:
            reload { [weak self] in self?.presentNotice("Voice feedback reset") }
        case .failed(let message):
            presentNotice(message)
        case .cancelled:
            break
        }
    }

    private func reload(onSuccess: (@MainActor () -> Void)? = nil) {
        invalidateReload()
        let generation = reloadGeneration
        let sourceIDs = activeSourceIDs
        let store = store
        reloadTask = Task { [weak self] in
            do {
                let snapshot = try await store.snapshot(sourceIDs: sourceIDs)
                guard !Task.isCancelled, let self,
                      generation == self.reloadGeneration,
                      sourceIDs == self.activeSourceIDs else { return }
                self.publish(snapshot)
                onSuccess?()
            } catch is CancellationError {
            } catch {
                guard let self, generation == self.reloadGeneration else { return }
                self.presentNotice("Couldn’t load voice feedback")
                Log.speech.error("voice_learning_snapshot_load_failed")
            }
        }
    }

    private func invalidateReload() {
        reloadTask?.cancel()
        reloadTask = nil
        reloadGeneration += 1
    }

    private func invalidateSource(_ sourceID: String) -> UInt64 {
        let generation = sourceGenerations[sourceID, default: 0] &+ 1
        sourceGenerations[sourceID] = generation
        return generation
    }

    private func presentNotice(_ message: String, key: VoiceRouteExclusionKey? = nil) {
        noticeExpiryTask?.cancel()
        let notice = VoiceLearningNotice(
            id: UUID(),
            exclusionKey: key,
            message: message
        )
        self.notice = notice
        noticeExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            guard self?.notice?.id == notice.id else { return }
            self?.clearNotice()
        }
    }

    private func clearNotice() {
        noticeExpiryTask?.cancel()
        noticeExpiryTask = nil
        notice = nil
    }

    private enum MutationOutcome {
        case recorded(VoiceRouteExclusionKey)
        case undone
        case reset
        case failed(String)
        case cancelled
    }
}

extension VoiceRoutingTriggerPattern {
    var routePatternIdentity: VoiceRoutePatternIdentity {
        switch self {
        case .phrase(let phrase):
            return VoiceRoutePatternIdentity(
                kind: .phrase,
                normalizedTerms: PhraseMatcher.normalize(phrase).split(separator: " ").map(String.init)
            )
        case .orderedTerms(let terms, let maximumGap):
            return VoiceRoutePatternIdentity(
                kind: .orderedTerms,
                normalizedTerms: terms.flatMap {
                    PhraseMatcher.normalize($0).split(separator: " ").map(String.init)
                },
                maximumGap: maximumGap
            )
        }
    }
}
