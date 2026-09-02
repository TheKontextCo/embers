import EmbersPluginHost
import EmbersPluginKit
import Foundation

enum IndexingPresentation {
    case visible
    case silent
}

/// Owns provider connection/refresh transitions and concurrent indexing activity.
/// ContextIndexController remains responsible for installing the resulting workspace snapshot.
@MainActor
final class ProviderLifecycleCoordinator {
    private(set) var activity: [PluginIdentifier: ProviderActivityState] = [:]

    private let host: PluginHost
    private var providerIndexingOperations: [PluginIdentifier: Int] = [:]
    private var publishActivity: (([PluginIdentifier: ProviderActivityState]) -> Void)?
    private var hasStarted = false

    init(host: PluginHost) {
        self.host = host
    }

    func start(publishActivity: @escaping ([PluginIdentifier: ProviderActivityState]) -> Void) {
        precondition(!hasStarted, "ProviderLifecycleCoordinator may only be started once")
        hasStarted = true
        self.publishActivity = publishActivity
        publishActivity(activity)
    }

    func synchronizeSources() async throws {
        try await host.synchronizeSources()
    }

    func connect(_ pluginID: PluginIdentifier) async throws {
        transitionProvider(pluginID, with: .beginConnection)
        do {
            try await host.connect(pluginID)
            transitionProvider(pluginID, with: .beginDiscovery)
            try await host.synchronizeSources()
        } catch {
            transitionProvider(pluginID, with: .failed(error.localizedDescription))
            throw error
        }
    }

    func disconnect(_ pluginID: PluginIdentifier) async throws {
        do {
            try await host.disconnect(pluginID)
            transitionProvider(pluginID, with: .reset)
        } catch {
            transitionProvider(pluginID, with: .failed(error.localizedDescription))
            throw error
        }
    }

    func fail(_ pluginID: PluginIdentifier, message: String) {
        transitionProvider(pluginID, with: .failed(message))
    }

    func refreshProvider(
        _ providerID: PluginIdentifier,
        sourceIDs: [PluginSourceIdentifier],
        presentation: IndexingPresentation
    ) async -> [WorkspaceRefreshOutcome] {
        guard !sourceIDs.isEmpty else { return [] }
        if presentation == .visible {
            providerIndexingOperations[providerID, default: 0] += 1
            transitionProvider(providerID, with: .beginIndexing)
        }
        var outcomes: [WorkspaceRefreshOutcome] = []
        for sourceID in sourceIDs {
            outcomes.append(await host.refresh(sourceID))
        }
        if presentation == .visible {
            let remaining = max(0, providerIndexingOperations[providerID, default: 1] - 1)
            if remaining == 0 {
                providerIndexingOperations.removeValue(forKey: providerID)
            } else {
                providerIndexingOperations[providerID] = remaining
            }
        }
        return outcomes
    }

    func finishProvider(
        _ providerID: PluginIdentifier,
        outcomes: [WorkspaceRefreshOutcome],
        currentSources: [HostedPluginSource]
    ) {
        guard providerIndexingOperations[providerID, default: 0] == 0 else { return }
        let currentFailure = currentSources.compactMap { source -> String? in
            if case .stale(let message) = source.health { return message }
            return nil
        }.first
        let outcomeFailure = outcomes.compactMap { outcome -> String? in
            if case .stale(let message) = outcome.sourceState.health { return message }
            return nil
        }.first
        if let message = currentFailure ?? outcomeFailure {
            transitionProvider(providerID, with: .degraded(message))
        } else {
            transitionProvider(providerID, with: .completed)
        }
    }

    func reconcileProviderActivity(with sources: [HostedPluginSource]) {
        let sourcesByProvider = Dictionary(grouping: sources, by: { $0.descriptor.id.pluginID })
        for (providerID, providerSources) in sourcesByProvider {
            if providerIndexingOperations[providerID, default: 0] > 0 {
                transitionProvider(providerID, with: .beginIndexing)
            } else if activity[providerID]?.phase == .connecting
                        || activity[providerID]?.phase == .discovering {
                continue
            } else if let message = providerSources.compactMap({ source -> String? in
                if case .stale(let message) = source.health { return message }
                return nil
            }).first {
                transitionProvider(providerID, with: .degraded(message))
            } else if providerSources.contains(where: { $0.health == .ready }) {
                transitionProvider(providerID, with: .completed)
            } else if activity[providerID]?.phase.presentsIndexingTrail != true {
                transitionProvider(providerID, with: .reset)
            }
        }
        for providerID in activity.keys where sourcesByProvider[providerID] == nil {
            switch activity[providerID]?.phase {
            case .connecting, .discovering:
                break
            case .idle, .indexing, .ready, .stale, .failed, nil:
                transitionProvider(providerID, with: .reset)
            }
        }
    }

    func activePresentation(descriptors: [PluginDescriptor]) -> ProviderActivityPresentation? {
        let active = activity.compactMap { id, state -> ProviderActivityPresentation? in
            guard state.phase.presentsIndexingTrail,
                  let descriptor = descriptors.first(where: { $0.id == id }) else { return nil }
            return .init(
                id: id,
                providerName: descriptor.displayName,
                isLocal: descriptor.sourceSetup == .directoryPicker,
                phase: state.phase
            )
        }
        return active.sorted { lhs, rhs in
            let lhsPriority = Self.activityPriority(lhs.phase)
            let rhsPriority = Self.activityPriority(rhs.phase)
            return lhsPriority == rhsPriority ? lhs.id < rhs.id : lhsPriority < rhsPriority
        }.first
    }

    private func transitionProvider(
        _ providerID: PluginIdentifier,
        with event: ProviderActivityEvent
    ) {
        var provider = activity[providerID] ?? .init()
        provider.apply(event)
        activity[providerID] = provider
        publishActivity?(activity)
    }

    private static func activityPriority(_ phase: ProviderActivityPhase) -> Int {
        switch phase {
        case .indexing: return 0
        case .discovering: return 1
        case .connecting: return 2
        case .idle, .ready, .stale, .failed: return 3
        }
    }
}
