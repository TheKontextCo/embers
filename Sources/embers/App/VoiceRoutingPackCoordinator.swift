import EmbersCore
import EmbersLocal
import Foundation

@MainActor
protocol VoiceRoutingPackCoordinatorDelegate: AnyObject {
    /// Installs one immutable routing pack and returns the resulting executable trigger count.
    func voiceRoutingPackCoordinatorInstall(_ pack: VoiceRoutingPack) -> Int
}

/// Owns compiled-pack cache lookup, model compilation, cancellation, and user-visible status.
/// The streaming router owns pack activation; this collaborator only delivers validated packs.
@MainActor
final class VoiceRoutingPackCoordinator {
    let status = VoiceRoutingStatus()

    private let store: VoiceRoutingStore
    private let compiler: VoiceRoutingCompiler
    private weak var delegate: (any VoiceRoutingPackCoordinatorDelegate)?
    private var hasStarted = false
    private var routingCompilationTask: Task<Void, Never>?
    private var generation = 0

    init(store: VoiceRoutingStore) {
        self.store = store
        self.compiler = VoiceRoutingCompiler(store: store)
    }

    func start(delegate: any VoiceRoutingPackCoordinatorDelegate) {
        precondition(!hasStarted, "VoiceRoutingPackCoordinator may only be started once")
        hasStarted = true
        self.delegate = delegate
    }

    func waitForContext() {
        advanceGeneration()
        status.set(.waitingForContext)
    }

    func waitForMatchingSnapshot() {
        advanceGeneration()
        status.set(.checking)
    }

    func compile(graph: ContextGraph, snapshot: ContextSnapshot) {
        advanceGeneration()
        let generation = generation
        status.set(.checking)
        let store = store
        let compiler = compiler
        routingCompilationTask = Task { [weak self] in
            let seeds = await Task.detached(priority: .utility) {
                VoiceRoutingSeedBuilder().build(graph: graph, snapshot: snapshot)
            }.value
            guard !Task.isCancelled else { return }
            let inputRevision = VoiceRoutingInputRevision.make(seeds)
            if let cached = await store.activePack(
                inputRevision: inputRevision,
                compilerVersion: VoiceRoutingCompiler.compilerVersion,
                modelVersion: VoiceRoutingCompiler.modelVersion
            ) {
                guard let self, generation == self.generation else { return }
                let phraseCount = self.delegate?.voiceRoutingPackCoordinatorInstall(cached) ?? 0
                self.status.set(.ready(
                    contextCount: cached.cards.count,
                    phraseCount: phraseCount,
                    recallWarningCount: 0
                ))
                Log.speech.info("voice_routing_pack_restored")
                return
            }
            guard compiler.isAvailable else {
                guard let self, generation == self.generation else { return }
                self.status.set(.namesOnly(reason: "Apple’s on-device model is unavailable; names and title words still work"))
                return
            }
            guard let self, generation == self.generation else { return }
            self.status.set(.building(progress: .init(
                stage: .generatingNotes,
                completed: 0,
                total: seeds.count * VoiceRoutingGenerationProgress.unitsPerNote
            )))
            Log.speech.info("voice_compiler_started")
            let outcome = await compiler.compile(
                seeds: seeds,
                graphRevision: graph.revision,
                inputRevision: inputRevision
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.generation else { return }
                    self.status.update(progress)
                }
            }
            guard !Task.isCancelled, generation == self.generation else { return }
            guard let pack = outcome.pack else {
                self.status.set(.namesOnly(reason: "Expanded phrases could not be validated; names and title words still work"))
                Log.speech.info("voice_compiler_retained_fallback")
                return
            }
            let phraseCount = self.delegate?.voiceRoutingPackCoordinatorInstall(pack) ?? 0
            self.status.completeBuildingProgress()
            try? await Task.sleep(for: .seconds(ContextProgressCompletionTiming.statusHoldDuration))
            guard !Task.isCancelled, generation == self.generation else { return }
            self.status.set(.ready(
                contextCount: pack.cards.count,
                phraseCount: phraseCount,
                recallWarningCount: outcome.warnings.count
            ))
            Log.speech.info("voice_routing_pack_activated")
        }
    }

    func deleteCache() async {
        do {
            try await store.delete()
        } catch {
            Log.speech.error("voice_routing_cache_deletion_failed")
        }
    }

    private func advanceGeneration() {
        routingCompilationTask?.cancel()
        generation += 1
    }
}
