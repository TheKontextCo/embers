import Foundation
import EmbersCore
import EmbersPluginKit

public enum PluginHostError: LocalizedError, Equatable {
    case duplicatePlugin(PluginIdentifier)
    case unknownPlugin(PluginIdentifier)
    case invalidSource(PluginSourceIdentifier)
    case duplicateSource(PluginSourceIdentifier)
    case sourceMismatch(expected: PluginSourceIdentifier, actual: String)
    case artifactIDCollision(String)
    case anchorIDCollision(String)
    case noArtifactAction
    case noTaskMutation
    case taskSourceUnavailable

    public var errorDescription: String? {
        switch self {
        case .duplicatePlugin(let id): return "Duplicate plugin registration: \(id.rawValue)"
        case .unknownPlugin(let id): return "No plugin is registered for \(id.rawValue)."
        case .invalidSource(let id): return "The plugin returned a source outside its namespace: \(id.rawValue)."
        case .duplicateSource(let id): return "Multiple plugins returned the same source: \(id.rawValue)."
        case .sourceMismatch(let expected, let actual): return "\(expected.rawValue) returned a snapshot for \(actual)."
        case .artifactIDCollision(let id): return "Multiple sources produced artifact ID \(id)."
        case .anchorIDCollision(let id): return "Multiple sources produced context ID \(id)."
        case .noArtifactAction: return "No configured plugin can open this artifact."
        case .noTaskMutation: return "This source does not support changing that task."
        case .taskSourceUnavailable: return "The source that owns this task is unavailable."
        }
    }
}

public enum PluginSourceHealth: Equatable, Sendable {
    case idle
    case refreshing
    case ready
    case stale(String)
}

public struct HostedPluginSource: Sendable {
    public var descriptor: PluginSourceDescriptor
    public var health: PluginSourceHealth
    public var snapshot: ContextSnapshot?
    public var refreshedAt: Date?

    public init(descriptor: PluginSourceDescriptor, health: PluginSourceHealth = .idle, snapshot: ContextSnapshot? = nil, refreshedAt: Date? = nil) {
        self.descriptor = descriptor
        self.health = health
        self.snapshot = snapshot
        self.refreshedAt = refreshedAt
    }
}

public struct WorkspaceRefreshOutcome: Sendable {
    public var source: PluginSourceIdentifier
    public var workspace: ContextSnapshot?
    public var sourceState: HostedPluginSource

    public init(source: PluginSourceIdentifier, workspace: ContextSnapshot?, sourceState: HostedPluginSource) {
        self.source = source
        self.workspace = workspace
        self.sourceState = sourceState
    }
}

/// A process-local registry for compiled-in plugins. The contracts are also
/// suitable for a future XPC-backed registry, but Embers intentionally does not
/// load arbitrary plugin code in-process.
public actor PluginHost {
    public static let workspaceSourceID = "workspace"

    private struct RegisteredPlugin: @unchecked Sendable {
        var descriptor: PluginDescriptor
        var provider: any PluginSourceProviding
        var refresher: any PluginRefreshing
        var observer: (any PluginChangeObserving)?
        var connector: (any PluginConnecting)?
        var artifactActions: (any PluginArtifactActionProviding)?
        var taskMutator: (any PluginTaskMutating)?
    }

    private let repository: any PluginSnapshotRepository
    private var plugins: [PluginIdentifier: RegisteredPlugin] = [:]
    private var sources: [PluginSourceIdentifier: HostedPluginSource] = [:]
    private var workspace: ContextSnapshot?
    private var observationTasks: [PluginSourceIdentifier: Task<Void, Never>] = [:]
    private var workspaceContinuations: [UUID: AsyncStream<ContextSnapshot>.Continuation] = [:]
    private var sourceStateContinuations: [UUID: AsyncStream<[HostedPluginSource]>.Continuation] = [:]
    private var sourcesBeingRemoved = Set<PluginSourceIdentifier>()
    /// Actor methods release isolation while plugins and repositories await.
    /// A monotonically increasing generation prevents an older or removed
    /// source refresh from publishing after a newer lifecycle operation.
    private var sourceGenerations: [PluginSourceIdentifier: UInt64] = [:]

    public init(plugins registered: [any PluginSourceProviding & PluginRefreshing], repository: any PluginSnapshotRepository) throws {
        self.repository = repository
        for plugin in registered {
            let observer = plugin as? any PluginChangeObserving
            let connector = plugin as? any PluginConnecting
            let artifactActions = plugin as? any PluginArtifactActionProviding
            let taskMutator = plugin as? any PluginTaskMutating
            var descriptor = plugin.descriptor
            // Protocol conformance is executable truth. Derive the descriptor
            // presented to generic UI so a stale hand-authored capability set
            // can neither hide supported behavior nor advertise missing code.
            descriptor.capabilities = [.sourceRefresh]
            if observer != nil { descriptor.capabilities.insert(.changeObservation) }
            if connector != nil { descriptor.capabilities.insert(.connection) }
            if artifactActions != nil { descriptor.capabilities.insert(.artifactActions) }
            if taskMutator != nil { descriptor.capabilities.insert(.taskMutation) }
            guard plugins[descriptor.id] == nil else { throw PluginHostError.duplicatePlugin(descriptor.id) }
            plugins[descriptor.id] = .init(
                descriptor: descriptor,
                provider: plugin,
                refresher: plugin,
                observer: observer,
                connector: connector,
                artifactActions: artifactActions,
                taskMutator: taskMutator
            )
        }
    }

    public func registeredPlugins() -> [PluginDescriptor] {
        plugins.values.map(\.descriptor).sorted { $0.id < $1.id }
    }

    public func sourceStates() -> [HostedPluginSource] {
        sources.values.sorted { $0.descriptor.id < $1.descriptor.id }
    }

    public func workspaceSnapshot() -> ContextSnapshot? { workspace }

    /// Connection is a provider capability, not a special case for a named
    /// remote service. Callers can build their source UI from this API alone.
    public func connectionStatus(for pluginID: PluginIdentifier) async -> PluginConnectionStatus? {
        guard let connector = plugins[pluginID]?.connector else { return nil }
        return await connector.connectionStatus()
    }

    public func connect(_ pluginID: PluginIdentifier) async throws {
        guard let connector = plugins[pluginID]?.connector else { throw PluginHostError.unknownPlugin(pluginID) }
        try await connector.connect()
    }

    /// A successful disconnect clears only this provider's configured sources
    /// and per-source caches. Peers (including the local folder) remain live.
    public func disconnect(_ pluginID: PluginIdentifier) async throws {
        guard let connector = plugins[pluginID]?.connector else { throw PluginHostError.unknownPlugin(pluginID) }
        // Do not revoke a grant and claim the source is gone while local
        // content still cannot be deleted. A failed cache removal leaves the
        // connection and source intact so the person can retry safely.
        try await removeSources(for: pluginID)
        try await connector.disconnect()
    }

    /// Emits every atomically accepted workspace snapshot, including refreshes
    /// triggered by a plugin's change observer.
    public func workspaceUpdates() -> AsyncStream<ContextSnapshot> {
        let token = UUID()
        return AsyncStream { continuation in
            workspaceContinuations[token] = continuation
            if let workspace { continuation.yield(workspace) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeWorkspaceContinuation(token) }
            }
        }
    }

    /// Emits source lifecycle changes independently from accepted workspace
    /// snapshots. Consumers can present indexing immediately while continuing to
    /// use the last-good workspace until a replacement has been validated.
    public func sourceStateUpdates() -> AsyncStream<[HostedPluginSource]> {
        let token = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            sourceStateContinuations[token] = continuation
            continuation.yield(sourceStates())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSourceStateContinuation(token) }
            }
        }
    }

    /// Reconciles provider-declared sources with cached source snapshots. Source
    /// removal only removes that source's cache and never touches its peers.
    @discardableResult
    public func synchronizeSources() async throws -> [HostedPluginSource] {
        var discovered: [PluginSourceIdentifier: PluginSourceDescriptor] = [:]
        var unavailablePlugins = Set<PluginIdentifier>()
        for plugin in plugins.values.sorted(by: { $0.descriptor.id < $1.descriptor.id }) {
            let pluginSources: [PluginSourceDescriptor]
            do {
                pluginSources = try await plugin.provider.sources().sorted { $0.id < $1.id }
            } catch {
                // Discovery is intentionally isolated. A failed remote lookup
                // must retain its cached source and must not stop folder sync.
                unavailablePlugins.insert(plugin.descriptor.id)
                for existing in sources.values where existing.descriptor.id.pluginID == plugin.descriptor.id {
                    discovered[existing.descriptor.id] = existing.descriptor
                    var stale = existing
                    stale.health = .stale(error.localizedDescription)
                    sources[existing.descriptor.id] = stale
                }
                continue
            }
            for source in pluginSources {
                guard source.id.pluginID == plugin.descriptor.id else { throw PluginHostError.invalidSource(source.id) }
                guard discovered[source.id] == nil else { throw PluginHostError.duplicateSource(source.id) }
                discovered[source.id] = source
            }
        }

        let removed = Set(sources.keys).subtracting(discovered.keys).filter { !unavailablePlugins.contains($0.pluginID) }
        for sourceID in removed {
            try await removeSourceState(sourceID)
        }

        for sourceID in discovered.keys.sorted() {
            guard let descriptor = discovered[sourceID] else { continue }
            if var existing = sources[sourceID] {
                existing.descriptor = descriptor
                sources[sourceID] = existing
            } else {
                let cached = await repository.load(for: sourceID)
                let isValid = cached.flatMap { try? $0.validated() }
                sources[sourceID] = .init(
                    descriptor: descriptor,
                    health: isValid == nil ? .idle : .ready,
                    snapshot: isValid,
                    refreshedAt: isValid?.indexedAt
                )
            }
        }
        workspace = try Self.compose(sources.values.compactMap { source in
            source.snapshot.map { (source.descriptor.id, $0) }
        })
        publishSourceStates()
        publishWorkspace()
        startObservingChanges()
        return sourceStates()
    }

    @discardableResult
    public func refresh(_ sourceID: PluginSourceIdentifier) async -> WorkspaceRefreshOutcome {
        await refresh(sourceID, publishingSourceActivity: true)
    }

    private func refresh(
        _ sourceID: PluginSourceIdentifier,
        publishingSourceActivity: Bool
    ) async -> WorkspaceRefreshOutcome {
        guard !sourcesBeingRemoved.contains(sourceID) else {
            let placeholder = HostedPluginSource(
                descriptor: sources[sourceID]?.descriptor ?? .init(id: sourceID, displayName: sourceID.rawValue, kind: "removing"),
                health: .stale("Removing this context source's local cache.")
            )
            return .init(source: sourceID, workspace: workspace, sourceState: placeholder)
        }
        guard var source = sources[sourceID] else {
            let placeholder = HostedPluginSource(descriptor: .init(id: sourceID, displayName: sourceID.rawValue, kind: "unknown"), health: .stale(PluginHostError.unknownPlugin(sourceID.pluginID).localizedDescription))
            return .init(source: sourceID, workspace: workspace, sourceState: placeholder)
        }
        guard let plugin = plugins[sourceID.pluginID] else {
            source.health = .stale(PluginHostError.unknownPlugin(sourceID.pluginID).localizedDescription)
            sources[sourceID] = source
            return .init(source: sourceID, workspace: workspace, sourceState: source)
        }
        source.health = .refreshing
        sources[sourceID] = source
        if publishingSourceActivity { publishSourceStates() }
        let generation = advanceGeneration(for: sourceID)

        do {
            var result = try await plugin.refresher.refresh(source.descriptor)
            guard isCurrent(sourceID, generation: generation) else {
                return outcomeForCurrentSource(sourceID)
            }
            guard result.source.id == sourceID else { throw PluginHostError.invalidSource(result.source.id) }
            if result.disposition == .unchanged, let candidate = result.snapshot,
               candidate.revision != source.snapshot?.revision {
                result.disposition = .updated
            }
            switch result.disposition {
            case .unchanged:
                source.health = source.snapshot == nil ? .idle : .ready
                source.refreshedAt = result.refreshedAt
                sources[sourceID] = source
            case .updated:
                guard let candidate = result.snapshot else { throw PluginHostError.sourceMismatch(expected: sourceID, actual: "missing snapshot") }
                guard candidate.sourceID == sourceID.rawValue else { throw PluginHostError.sourceMismatch(expected: sourceID, actual: candidate.sourceID) }
                let valid = try candidate.validated()
                var candidateSources = sources
                var candidateSource = source
                candidateSource.snapshot = valid
                candidateSource.health = .ready
                candidateSource.refreshedAt = result.refreshedAt
                candidateSources[sourceID] = candidateSource
                let candidateWorkspace = try Self.compose(candidateSources.values.compactMap { hosted in
                    hosted.snapshot.map { (hosted.descriptor.id, $0) }
                })
                try await repository.replace(valid, for: sourceID)
                guard isCurrent(sourceID, generation: generation) else {
                    return outcomeForCurrentSource(sourceID)
                }
                sources = candidateSources
                workspace = candidateWorkspace
                publishWorkspace()
            }
        } catch {
            guard isCurrent(sourceID, generation: generation) else {
                return outcomeForCurrentSource(sourceID)
            }
            source.health = .stale(error.localizedDescription)
            sources[sourceID] = source
        }
        publishSourceStates()
        return .init(source: sourceID, workspace: workspace, sourceState: sources[sourceID]!)
    }

    @discardableResult
    public func refreshAll() async -> [WorkspaceRefreshOutcome] {
        // Snapshot acceptance is serialized so each validated candidate is
        // composed against the latest peer set. Providers themselves can still
        // observe changes independently without ever publishing a partial graph.
        var outcomes: [WorkspaceRefreshOutcome] = []
        for sourceID in sources.keys.sorted() {
            outcomes.append(await refresh(sourceID))
        }
        return outcomes
    }

    public func removeAllSources() async throws {
        let all = sources.keys.sorted()
        for source in all {
            try await removeSourceState(source)
        }
        workspace = nil
    }

    /// Removes exactly one configured source and its cache, then atomically
    /// republishes the workspace composed from its surviving peers.
    public func removeSource(_ sourceID: PluginSourceIdentifier) async throws {
        try await removeSourceState(sourceID)
        workspace = try Self.compose(sources.values.compactMap { source in
            source.snapshot.map { (source.descriptor.id, $0) }
        })
        publishWorkspace()
    }

    public func removeSources(for pluginID: PluginIdentifier) async throws {
        let selected = sources.keys.filter { $0.pluginID == pluginID }.sorted()
        for source in selected {
            try await removeSourceState(source)
        }
        workspace = try? Self.compose(sources.values.compactMap { source in
            source.snapshot.map { (source.descriptor.id, $0) }
        })
        publishWorkspace()
    }

    public func availableArtifactActions(for artifact: SourceArtifact) -> [ArtifactAction] {
        actionProviders(for: artifact).flatMap { $0.artifactActions(for: artifact) }
    }

    public func perform(_ action: ArtifactAction, for artifact: SourceArtifact) async throws {
        guard let provider = actionProviders(for: artifact).first(where: { provider in
            provider.artifactActions(for: artifact).contains(action)
        }) else {
            throw PluginHostError.noArtifactAction
        }
        try await provider.perform(action, for: artifact)
    }

    public func performDefaultOpen(for artifact: SourceArtifact) async throws {
        guard let provider = actionProviders(for: artifact).first,
              let action = provider.artifactActions(for: artifact).first(where: { $0.kind == .open }) else {
            throw PluginHostError.noArtifactAction
        }
        try await provider.perform(action, for: artifact)
    }

    public func supportedTaskStates(for task: SourceTask, in artifact: SourceArtifact) async -> Set<SourceTaskState> {
        guard let (_, provider) = taskMutationRoute(for: artifact) else { return [] }
        return await provider.supportedTaskStates(for: task, in: artifact)
    }

    /// Mutates through the owning provider, then refreshes only that source so
    /// the workspace is atomically recomposed from authoritative provider data.
    @discardableResult
    public func setTaskState(_ state: SourceTaskState, for task: SourceTask, in artifact: SourceArtifact) async throws -> WorkspaceRefreshOutcome {
        guard let providerReference = artifact.provider,
              let pluginID = PluginIdentifier(rawValue: providerReference.pluginID),
              let rawSourceID = providerReference.sourceID,
              let sourceID = PluginSourceIdentifier(rawValue: rawSourceID),
              sourceID.pluginID == pluginID,
              sources[sourceID] != nil else {
            throw PluginHostError.taskSourceUnavailable
        }
        guard let provider = plugins[pluginID]?.taskMutator,
              await provider.supportedTaskStates(for: task, in: artifact).contains(state) else {
            throw PluginHostError.noTaskMutation
        }
        if let acknowledging = provider as? any PluginTaskMutationAcknowledging {
            let updates = try await acknowledging.setTaskStateWithAcknowledgement(state, for: task, in: artifact)
            if let outcome = await applyAcknowledgedTaskStates(
                updates,
                requestedState: state,
                requestedTask: task,
                requestedArtifact: artifact,
                sourceID: sourceID
            ) {
                return outcome
            }
            return await refresh(sourceID, publishingSourceActivity: false)
        }
        try await provider.setTaskState(state, for: task, in: artifact)
        return await refresh(sourceID, publishingSourceActivity: false)
    }

    private func applyAcknowledgedTaskStates(
        _ updates: [PluginTaskStateUpdate],
        requestedState: SourceTaskState,
        requestedTask: SourceTask,
        requestedArtifact: SourceArtifact,
        sourceID: PluginSourceIdentifier
    ) async -> WorkspaceRefreshOutcome? {
        guard updates.contains(where: {
            $0.artifactID == requestedArtifact.id && $0.taskID == requestedTask.id && $0.state == requestedState
        }), var source = sources[sourceID], var candidate = source.snapshot else { return nil }

        let unique = Dictionary(grouping: updates, by: { "\($0.artifactID)\u{0}\($0.taskID)" })
        guard unique.values.allSatisfy({ $0.count == 1 }) else { return nil }
        for update in updates {
            guard let artifactIndex = candidate.artifacts.firstIndex(where: { $0.id == update.artifactID }),
                  let taskIndex = candidate.artifacts[artifactIndex].metadata.tasks.firstIndex(where: { $0.id == update.taskID }) else {
                return nil
            }
            candidate.artifacts[artifactIndex].metadata.tasks[taskIndex].state = update.state
            candidate.artifacts[artifactIndex].contentHash = update.contentHash
                ?? StableHash.hex("\(candidate.artifacts[artifactIndex].contentHash)\u{0}\(update.taskID)\u{0}\(update.state.rawValue)")
        }
        candidate.revision = StableHash.hex([
            candidate.revision,
            updates.sorted { ($0.artifactID, $0.taskID) < ($1.artifactID, $1.taskID) }
                .map { "\($0.artifactID):\($0.taskID):\($0.state.rawValue):\($0.contentHash ?? "")" }
                .joined(separator: "|"),
        ].joined(separator: "|"))
        candidate.indexedAt = Date()

        guard let validated = try? candidate.validated() else { return nil }
        var candidateSources = sources
        source.snapshot = validated
        source.health = .ready
        source.refreshedAt = validated.indexedAt
        candidateSources[sourceID] = source
        guard let candidateWorkspace = try? Self.compose(candidateSources.values.compactMap { hosted in
            hosted.snapshot.map { (hosted.descriptor.id, $0) }
        }) else { return nil }

        let generation = advanceGeneration(for: sourceID)
        do {
            try await repository.replace(validated, for: sourceID)
        } catch {
            return nil
        }
        guard isCurrent(sourceID, generation: generation) else { return outcomeForCurrentSource(sourceID) }
        sources = candidateSources
        workspace = candidateWorkspace
        publishSourceStates()
        publishWorkspace()
        return .init(source: sourceID, workspace: workspace, sourceState: source)
    }

    private func startObservingChanges() {
        for source in sources.values {
            let sourceID = source.descriptor.id
            guard observationTasks[sourceID] == nil,
                  let observer = plugins[sourceID.pluginID]?.observer else { continue }
            let stream = observer.changes(for: source.descriptor)
            observationTasks[sourceID] = Task { [weak self] in
                for await _ in stream {
                    guard !Task.isCancelled else { return }
                    _ = await self?.refresh(sourceID, publishingSourceActivity: false)
                }
            }
        }
    }

    private func actionProviders(for artifact: SourceArtifact) -> [any PluginArtifactActionProviding] {
        // First-class provenance is authoritative. If its owner is missing or
        // malformed, fail closed instead of offering the artifact to an
        // unrelated provider that happens to claim broad action support.
        if let provider = artifact.provider {
            guard let pluginID = PluginIdentifier(rawValue: provider.pluginID),
                  let plugin = plugins[pluginID] else { return [] }
            if let rawSourceID = provider.sourceID {
                guard let sourceID = PluginSourceIdentifier(rawValue: rawSourceID),
                      sourceID.pluginID == pluginID else { return [] }
            }
            return plugin.artifactActions.map { [$0] } ?? []
        } else if case let .provider(rawID, _) = artifact.location {
            // `ArtifactLocation.provider` predates first-class routing
            // provenance. Retain it as a compatibility route for cached data.
            guard let pluginID = PluginIdentifier(rawValue: rawID),
                  let plugin = plugins[pluginID] else { return [] }
            return plugin.artifactActions.map { [$0] } ?? []
        }

        // Never use import metadata as plugin provenance. Truly legacy
        // artifacts without routing provenance are offered to every action
        // provider, each of which must positively claim before acting.
        return plugins.values
            .sorted { $0.descriptor.id < $1.descriptor.id }
            .compactMap(\.artifactActions)
    }

    private func taskMutationRoute(for artifact: SourceArtifact) -> (PluginSourceIdentifier, any PluginTaskMutating)? {
        guard let providerReference = artifact.provider,
              let pluginID = PluginIdentifier(rawValue: providerReference.pluginID),
              let rawSourceID = providerReference.sourceID,
              let sourceID = PluginSourceIdentifier(rawValue: rawSourceID),
              sourceID.pluginID == pluginID,
              sources[sourceID] != nil,
              let provider = plugins[pluginID]?.taskMutator else { return nil }
        return (sourceID, provider)
    }

    private func publishWorkspace() {
        guard let workspace else { return }
        for continuation in workspaceContinuations.values { continuation.yield(workspace) }
    }

    private func publishSourceStates() {
        let states = sourceStates()
        for continuation in sourceStateContinuations.values { continuation.yield(states) }
    }

    private func removeWorkspaceContinuation(_ token: UUID) {
        workspaceContinuations.removeValue(forKey: token)
    }

    private func removeSourceStateContinuation(_ token: UUID) {
        sourceStateContinuations.removeValue(forKey: token)
    }

    private func removeSourceState(_ sourceID: PluginSourceIdentifier) async throws {
        guard sources[sourceID] != nil else { return }
        guard sourcesBeingRemoved.insert(sourceID).inserted else { return }
        invalidateRefresh(for: sourceID)
        do {
            try await repository.remove(source: sourceID)
        } catch {
            sourcesBeingRemoved.remove(sourceID)
            throw error
        }
        observationTasks.removeValue(forKey: sourceID)?.cancel()
        sources.removeValue(forKey: sourceID)
        sourcesBeingRemoved.remove(sourceID)
        publishSourceStates()
    }

    private func advanceGeneration(for sourceID: PluginSourceIdentifier) -> UInt64 {
        let next = (sourceGenerations[sourceID] ?? 0) &+ 1
        sourceGenerations[sourceID] = next
        return next
    }

    private func invalidateRefresh(for sourceID: PluginSourceIdentifier) {
        _ = advanceGeneration(for: sourceID)
    }

    private func isCurrent(_ sourceID: PluginSourceIdentifier, generation: UInt64) -> Bool {
        sourceGenerations[sourceID] == generation && sources[sourceID] != nil
    }

    private func outcomeForCurrentSource(_ sourceID: PluginSourceIdentifier) -> WorkspaceRefreshOutcome {
        if let current = sources[sourceID] {
            return .init(source: sourceID, workspace: workspace, sourceState: current)
        }
        let placeholder = HostedPluginSource(
            descriptor: .init(id: sourceID, displayName: sourceID.rawValue, kind: "removed"),
            health: .stale("The context source was removed while refreshing.")
        )
        return .init(source: sourceID, workspace: workspace, sourceState: placeholder)
    }

    /// Composition is intentionally strict. Names are allowed to overlap, but
    /// graph identity collisions are a provider bug and must not silently merge.
    public static func compose(_ entries: [(PluginSourceIdentifier, ContextSnapshot)]) throws -> ContextSnapshot? {
        guard !entries.isEmpty else { return nil }
        let sorted = entries.sorted { $0.0 < $1.0 }
        var artifactIDs = Set<String>()
        var anchorIDs = Set<String>()
        var artifacts: [SourceArtifact] = []
        var anchors: [Anchor] = []
        var relations: [ContextRelation] = []
        var diagnostics: [ContextDiagnostic] = []
        for (_, snapshot) in sorted {
            for artifact in snapshot.artifacts {
                guard artifactIDs.insert(artifact.id).inserted else { throw PluginHostError.artifactIDCollision(artifact.id) }
                artifacts.append(artifact)
            }
            for anchor in snapshot.anchors {
                guard anchorIDs.insert(anchor.id).inserted else { throw PluginHostError.anchorIDCollision(anchor.id) }
                anchors.append(anchor)
            }
            relations.append(contentsOf: snapshot.relations)
            diagnostics.append(contentsOf: snapshot.diagnostics)
        }
        let revisionMaterial = sorted.map { "\($0.0.rawValue):\($0.1.revision)" }.joined(separator: "|")
        return try ContextSnapshot(
            sourceID: workspaceSourceID,
            revision: StableHash.hex(revisionMaterial),
            // Each source has already ranked its own anchors. Preserve that
            // display/voice order while source-ID ordering keeps multi-source
            // composition deterministic.
            artifacts: artifacts,
            anchors: anchors,
            relations: Array(Set(relations)).sorted { ($0.source, $0.target, $0.kind, $0.provenance.artifactID ?? "") < ($1.source, $1.target, $1.kind, $1.provenance.artifactID ?? "") },
            diagnostics: diagnostics.sorted { ($0.id, $0.message) < ($1.id, $1.message) },
            indexedAt: sorted.map { $0.1.indexedAt }.max() ?? .distantPast
        ).validated()
    }
}
