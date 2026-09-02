import EmbersCore
import EmbersLocal
import EmbersPluginHost
import Foundation

@MainActor
protocol VoiceRoutingPreferenceCoordinatorDelegate: AnyObject {
    func voiceRoutingPreferencesDidChange()
}

/// Owns source-scoped preference reads, writes, resets, cancellation, and source retirement.
/// It publishes complete immutable snapshots; routing remains unaware of persistence details.
@MainActor
final class VoiceRoutingPreferenceCoordinator {
    let state = VoiceRoutingPreferenceState()
    private(set) var snapshot = VoiceRoutingPreferenceSnapshot.empty

    private let store: VoiceRoutingPreferenceStore
    private weak var delegate: (any VoiceRoutingPreferenceCoordinatorDelegate)?
    private var hasStarted = false
    private var preferenceLoadTask: Task<Void, Never>?
    private var preferenceResetTask: Task<Void, Never>?
    private var preferenceResetID: UUID?
    private var resettingPreferenceScopes = Set<String>()
    private var preferenceRecordTasks: [String: [UUID: Task<Void, Never>]] = [:]
    private var preferenceSourceGenerations: [String: UInt64] = [:]
    private var retiredPreferenceSourceIDs = Set<String>()
    private var preferenceGeneration = 0
    private var preferenceSourceIDs = Set<String>()
    private var publishedPreferenceSourceIDs = Set<String>()
    private var nodePreferenceSourceIDs: [String: String] = [:]

    init(store: VoiceRoutingPreferenceStore) {
        self.store = store
    }

    func start(delegate: any VoiceRoutingPreferenceCoordinatorDelegate) {
        precondition(!hasStarted, "VoiceRoutingPreferenceCoordinator may only be started once")
        hasStarted = true
        self.delegate = delegate
        state.resetAction = { [weak self] in
            self?.reset()
        }
    }

    func apply(sources: [HostedPluginSource], graph: ContextGraph?) {
        // A source with the same stable identity can be deliberately connected
        // again after removal. Its freshly published lifecycle supersedes the
        // local retirement tombstone.
        let publishedSourceIDs = Set(sources.map { $0.descriptor.id.rawValue })
        retiredPreferenceSourceIDs.subtract(publishedSourceIDs.subtracting(publishedPreferenceSourceIDs))
        publishedPreferenceSourceIDs = publishedSourceIDs
        let activeSources = sources.filter { !retiredPreferenceSourceIDs.contains($0.descriptor.id.rawValue) }
        let ownerByReferenceID = activeSources.reduce(into: [String: String]()) { result, source in
            let sourceID = source.descriptor.id.rawValue
            for anchor in source.snapshot?.anchors ?? [] {
                result[anchor.id] = sourceID
            }
        }
        nodePreferenceSourceIDs = Dictionary(uniqueKeysWithValues: (graph?.nodes ?? []).compactMap { node in
            ownerByReferenceID[node.referenceID].map { (node.id, $0) }
        })
        preferenceSourceIDs = Set(activeSources.map { $0.descriptor.id.rawValue })
        reload()
    }

    func recordOpen(conceptID: String, nodeID: String) {
        guard let sourceID = nodePreferenceSourceIDs[nodeID] else { return }
        guard !resettingPreferenceScopes.contains(sourceID),
              !retiredPreferenceSourceIDs.contains(sourceID) else { return }
        let store = store
        let sourceGeneration = preferenceSourceGenerations[sourceID, default: 0]
        let taskID = UUID()
        let task = Task { [weak self] in
            var shouldReload = false
            do {
                try await store.recordOpen(
                    sourceID: sourceID,
                    conceptID: conceptID,
                    nodeID: nodeID,
                    sourceGeneration: sourceGeneration
                )
                try Task.checkCancellation()
                shouldReload = true
            } catch is CancellationError {
                // Reset/forget intentionally invalidated this pending open.
            } catch {
                Log.speech.error("voice_preference_write_failed")
            }
            self?.preferenceRecordFinished(
                sourceID: sourceID,
                taskID: taskID,
                reload: shouldReload
            )
        }
        preferenceRecordTasks[sourceID, default: [:]][taskID] = task
    }

    func removeSourceData(_ sourceID: String) async {
        retiredPreferenceSourceIDs.insert(sourceID)
        nodePreferenceSourceIDs = nodePreferenceSourceIDs.filter { $0.value != sourceID }
        preferenceSourceIDs.remove(sourceID)
        cancelPreferenceRecords(sourceID: sourceID)
        if resettingPreferenceScopes.contains(sourceID) { cancelPreferenceReset() }
        let sourceGeneration = invalidatePreferenceSource(sourceID)
        preferenceLoadTask?.cancel()
        preferenceGeneration += 1

        do {
            try await store.delete(
                sourceID: sourceID,
                sourceGeneration: sourceGeneration
            )
        } catch {
            state.report(error: "Could not erase voice learning")
            Log.speech.error("voice_preference_deletion_failed")
            return
        }
        reload()
    }

    private func reload() {
        preferenceLoadTask?.cancel()
        preferenceGeneration += 1
        let generation = preferenceGeneration
        let sourceIDs = preferenceSourceIDs
        let store = store
        preferenceLoadTask = Task { [weak self] in
            do {
                let snapshot = try await store.snapshot(sourceIDs: sourceIDs)
                guard !Task.isCancelled, let self, generation == self.preferenceGeneration,
                      sourceIDs == self.preferenceSourceIDs else { return }
                self.snapshot = snapshot
                self.delegate?.voiceRoutingPreferencesDidChange()
                self.state.install(
                    sourceSummaries: snapshot.summaryBySourceID.filter { sourceIDs.contains($0.key) }
                )
            } catch {
                guard let self, generation == self.preferenceGeneration else { return }
                // A transient read failure must not perturb candidate order. The
                // last complete immutable snapshot remains active until a later
                // source publication or write successfully replaces it.
                self.state.report(error: "Could not load voice learning")
                Log.speech.error("voice_preference_snapshot_load_failed")
            }
        }
    }

    private func reset() {
        let resettingSourceIDs = preferenceSourceIDs
        guard !resettingSourceIDs.isEmpty else {
            state.finishReset(error: "No context sources selected")
            return
        }
        resettingSourceIDs.forEach(cancelPreferenceRecords)
        if preferenceResetTask != nil { cancelPreferenceReset() }
        let sourceGenerations = Dictionary(uniqueKeysWithValues: resettingSourceIDs.map { sourceID in
            (sourceID, invalidatePreferenceSource(sourceID))
        })
        preferenceGeneration += 1
        let generation = preferenceGeneration
        let sourceIDs = preferenceSourceIDs
        let store = store
        preferenceLoadTask?.cancel()
        let resetID = UUID()
        preferenceResetID = resetID
        resettingPreferenceScopes = resettingSourceIDs
        preferenceResetTask = Task { [weak self] in
            var resetError: String?
            do {
                for sourceID in resettingSourceIDs.sorted() {
                    try Task.checkCancellation()
                    try await store.reset(
                        sourceID: sourceID,
                        sourceGeneration: sourceGenerations[sourceID]!
                    )
                }
                let snapshot = try await store.snapshot(sourceIDs: sourceIDs)
                guard !Task.isCancelled, let self else { return }
                if generation == self.preferenceGeneration,
                   sourceIDs == self.preferenceSourceIDs {
                    self.snapshot = snapshot
                    self.delegate?.voiceRoutingPreferencesDidChange()
                    self.state.install(
                        sourceSummaries: snapshot.summaryBySourceID.filter { sourceIDs.contains($0.key) }
                    )
                } else {
                    // Source state advanced while the mutation was in flight.
                    // Fetch the current scopes again after the reset completed.
                    self.reload()
                }
            } catch is CancellationError {
                // Superseding source lifecycle work owns the visible state.
            } catch {
                resetError = "Could not reset voice learning"
                Log.speech.error("voice_preference_reset_failed")
            }
            guard let self, self.preferenceResetID == resetID else { return }
            self.preferenceResetTask = nil
            self.preferenceResetID = nil
            self.resettingPreferenceScopes = []
            self.state.finishReset(error: resetError)
        }
    }

    private func preferenceRecordFinished(sourceID: String, taskID: UUID, reload: Bool) {
        preferenceRecordTasks[sourceID]?[taskID] = nil
        if preferenceRecordTasks[sourceID]?.isEmpty == true {
            preferenceRecordTasks[sourceID] = nil
        }
        if reload { self.reload() }
    }

    private func cancelPreferenceRecords(sourceID: String) {
        let tasks = preferenceRecordTasks.removeValue(forKey: sourceID)?.values.map { $0 } ?? []
        tasks.forEach { $0.cancel() }
    }

    private func cancelPreferenceReset() {
        preferenceResetTask?.cancel()
        preferenceResetTask = nil
        preferenceResetID = nil
        resettingPreferenceScopes = []
        state.finishReset()
    }

    private func invalidatePreferenceSource(_ sourceID: String) -> UInt64 {
        let generation = preferenceSourceGenerations[sourceID, default: 0] &+ 1
        preferenceSourceGenerations[sourceID] = generation
        return generation
    }
}
