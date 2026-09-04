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
    let exclusionKey: VoiceRouteExclusionKey
    let message: String
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

    private let store: VoiceLearningStore
    private weak var delegate: (any VoiceLearningCoordinatorDelegate)?
    private var activeSourceIDs = Set<String>()
    private var sourceGenerations: [String: UInt64] = [:]
    private var mutationTasks: [String: [UUID: Task<Void, Never>]] = [:]
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0
    private var noticeExpiryTask: Task<Void, Never>?
    private var hasStarted = false

    init(store: VoiceLearningStore) {
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
        let task = Task { [weak self] in
            do {
                try await store.recordExclusion(
                    key,
                    sourceGeneration: sourceGeneration
                )
                guard !Task.isCancelled, let self,
                      self.sourceGenerations[key.sourceID, default: 0] == sourceGeneration,
                      self.activeSourceIDs.contains(key.sourceID) else { return }
                let snapshot = try await store.snapshot(sourceIDs: self.activeSourceIDs)
                guard !Task.isCancelled else { return }
                self.publish(snapshot)
                self.presentNotice(for: key)
            } catch is CancellationError {
                // Source retirement or a newer lifecycle owns the visible state.
            } catch {
                Log.speech.error("voice_learning_exclusion_write_failed")
            }
            self?.mutationFinished(sourceID: key.sourceID, taskID: taskID)
        }
        mutationTasks[key.sourceID, default: [:]][taskID] = task
    }

    func undoNotice() {
        guard let notice else { return }
        let key = notice.exclusionKey
        let taskID = UUID()
        let sourceGeneration = sourceGenerations[key.sourceID, default: 0]
        let store = store
        let task = Task { [weak self] in
            do {
                try await store.removeExclusion(key, sourceGeneration: sourceGeneration)
                guard !Task.isCancelled, let self,
                      self.sourceGenerations[key.sourceID, default: 0] == sourceGeneration else { return }
                let snapshot = try await store.snapshot(sourceIDs: self.activeSourceIDs)
                guard !Task.isCancelled else { return }
                self.publish(snapshot)
                self.clearNotice()
            } catch is CancellationError {
            } catch {
                Log.speech.error("voice_learning_exclusion_undo_failed")
            }
            self?.mutationFinished(sourceID: key.sourceID, taskID: taskID)
        }
        mutationTasks[key.sourceID, default: [:]][taskID] = task
    }

    func removeSourceData(_ sourceID: String) async {
        activeSourceIDs.remove(sourceID)
        if activeJourney?.evidence.exclusionKey.sourceID == sourceID { invalidateJourney() }
        if notice?.exclusionKey.sourceID == sourceID { clearNotice() }
        mutationTasks.removeValue(forKey: sourceID)?.values.forEach { $0.cancel() }
        reloadTask?.cancel()
        reloadGeneration += 1
        let generation = sourceGenerations[sourceID, default: 0] &+ 1
        sourceGenerations[sourceID] = generation
        do {
            try await store.delete(sourceID: sourceID, sourceGeneration: generation)
            let snapshot = try await store.snapshot(sourceIDs: activeSourceIDs)
            publish(snapshot)
        } catch {
            Log.speech.error("voice_learning_source_deletion_failed")
        }
    }

    private func reload() {
        reloadTask?.cancel()
        reloadGeneration += 1
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
            } catch {
                Log.speech.error("voice_learning_snapshot_load_failed")
            }
        }
    }

    private func publish(_ snapshot: VoiceLearningSnapshot) {
        self.snapshot = snapshot
        delegate?.voiceLearningDidChange(snapshot)
    }

    private func mutationFinished(sourceID: String, taskID: UUID) {
        mutationTasks[sourceID]?[taskID] = nil
        if mutationTasks[sourceID]?.isEmpty == true {
            mutationTasks[sourceID] = nil
        }
    }

    private func presentNotice(for key: VoiceRouteExclusionKey) {
        noticeExpiryTask?.cancel()
        let notice = VoiceLearningNotice(
            id: UUID(),
            exclusionKey: key,
            message: "Not this — learned"
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
                normalizedTerms: terms.map(PhraseMatcher.normalize),
                maximumGap: maximumGap
            )
        }
    }
}
