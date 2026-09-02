import Foundation
import EmbersCore
import EmbersLocal
import EmbersPluginHost
import EmbersPluginKit

enum ManagedSampleVaultPath {
    static func matches(
        _ candidate: URL,
        root: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let name = candidate.lastPathComponent
        guard name == "SampleVault" || name.hasPrefix("SampleVault-v") else { return false }

        let parent = candidate.deletingLastPathComponent().standardizedFileURL
        let canonicalRoot = root.standardizedFileURL
        var relationship = FileManager.URLRelationship.other
        do {
            try fileManager.getRelationship(
                &relationship,
                ofDirectoryAt: canonicalRoot,
                toItemAt: parent
            )
            if relationship == .same { return true }
        } catch {}

        return parent.resolvingSymlinksInPath() == canonicalRoot.resolvingSymlinksInPath()
    }
}

enum ManagedSampleVaultInstaller {
    @discardableResult
    static func prepare(
        bundled: URL,
        managed: URL,
        replacingExisting: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        let support = managed.deletingLastPathComponent()
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)

        if replacingExisting, fileManager.fileExists(atPath: managed.path) {
            let staged = support.appendingPathComponent(
                ".\(managed.lastPathComponent)-reset-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: staged) }
            try fileManager.copyItem(at: bundled, to: staged)
            try fileManager.removeItem(at: managed)
            try fileManager.moveItem(at: staged, to: managed)
        } else if !fileManager.fileExists(atPath: managed.path) {
            try fileManager.copyItem(at: bundled, to: managed)
        }

        return managed
    }
}

enum IndexingState: Equatable {
    case unconfigured
    case loadingCache
    case indexing
    case ready
    case stale(String)
    case failed(String)

    var label: String {
        switch self {
        case .unconfigured: return "Choose a context source"
        case .loadingCache: return "Loading cache…"
        case .indexing: return "Indexing…"
        case .ready: return "Ready"
        case .stale: return "Cached — source unavailable"
        case .failed: return "Indexing failed"
        }
    }
}

enum ProviderActivityPhase: Equatable {
    case idle
    case connecting
    case discovering
    case indexing
    case ready
    case stale(String)
    case failed(String)

    var presentsIndexingTrail: Bool {
        switch self {
        case .connecting, .discovering, .indexing: true
        case .idle, .ready, .stale, .failed: false
        }
    }
}

enum ProviderActivityEvent: Equatable {
    case beginConnection
    case beginDiscovery
    case beginIndexing
    case completed
    case degraded(String)
    case failed(String)
    case reset
}

struct ProviderActivityState: Equatable {
    private(set) var phase: ProviderActivityPhase = .idle

    mutating func apply(_ event: ProviderActivityEvent) {
        switch event {
        case .beginConnection: phase = .connecting
        case .beginDiscovery: phase = .discovering
        case .beginIndexing: phase = .indexing
        case .completed: phase = .ready
        case .degraded(let message): phase = .stale(message)
        case .failed(let message): phase = .failed(message)
        case .reset: phase = .idle
        }
    }
}

struct ProviderActivityPresentation: Equatable, Identifiable {
    let id: PluginIdentifier
    let providerName: String
    let isLocal: Bool
    let phase: ProviderActivityPhase
}

enum DirectorySourceSetupError: LocalizedError {
    case unregisteredProvider(PluginIdentifier)

    var errorDescription: String? {
        switch self {
        case .unregisteredProvider(let id):
            return "The \(id.rawValue) provider does not support directory setup."
        }
    }
}

@MainActor
final class ContextIndexController: ObservableObject {
    @Published private(set) var snapshot: ContextSnapshot?
    @Published private(set) var graph: ContextGraph?
    @Published private(set) var state: IndexingState = .loadingCache
    @Published private(set) var sourceConfiguration: SourceConfiguration?
    @Published private(set) var ignoredAnchorIDs: Set<String> = []
    @Published private(set) var summaries: [AnchorSummary] = []
    @Published private(set) var unassignedArtifacts: [SourceArtifact] = []
    @Published private(set) var recent: [RecentArtifact] = []
    @Published private(set) var contextSources: [HostedPluginSource] = []
    @Published private(set) var providerDescriptors: [PluginDescriptor] = []
    @Published private(set) var connectionPlugins: [PluginDescriptor] = []
    @Published private(set) var connectionStatuses: [PluginIdentifier: PluginConnectionStatus] = [:]
    @Published private(set) var providerActivity: [PluginIdentifier: ProviderActivityState] = [:]

    private(set) var graphSearch: GraphContextSearch?
    private let repository: any ContextRepository
    private let configurations: SourceConfigurationStore
    private let defaults: UserDefaults
    private let graphProjector: DeterministicContextGraphProjector
    private let directorySourceManagers: [PluginIdentifier: any DirectorySourceManaging]
    let defaultDirectoryProviderID: PluginIdentifier
    private var configuredDirectoryProviderID: PluginIdentifier
    private let pluginHost: PluginHost
    private let providerLifecycle: ProviderLifecycleCoordinator
    private let recentAccesses: RecentAccessStore
    private var workspaceTask: Task<Void, Never>?
    private var sourceStateTask: Task<Void, Never>?
    private var isRetiringOnboarding = false
    var onRemoveSource: ((String) async -> Void)?

    init(
        repository: any ContextRepository,
        configurations: SourceConfigurationStore,
        defaults: UserDefaults,
        graphProjector: DeterministicContextGraphProjector = .init(),
        recentAccesses: RecentAccessStore,
        providerRegistry: ProviderRegistry,
        providerLifecycle: ProviderLifecycleCoordinator
    ) {
        self.repository = repository
        self.configurations = configurations
        self.defaults = defaults
        self.graphProjector = graphProjector
        let registry = providerRegistry
        self.directorySourceManagers = registry.directorySourceManagers
        self.defaultDirectoryProviderID = registry.defaultDirectoryProviderID
        if let rawProviderID = defaults.string(forKey: "configuredDirectoryProviderID"),
           let savedProviderID = PluginIdentifier(rawValue: rawProviderID),
           registry.directorySourceManager(for: savedProviderID) != nil {
            self.configuredDirectoryProviderID = savedProviderID
        } else {
            self.configuredDirectoryProviderID = registry.defaultDirectoryProviderID
        }
        self.pluginHost = registry.host
        self.providerLifecycle = providerLifecycle
        self.recentAccesses = recentAccesses
        ignoredAnchorIDs = Set(defaults.stringArray(forKey: "ignoredAnchorIDs") ?? [])
        deleteObsoleteCredentials()
        providerLifecycle.start { [weak self] activity in
            self?.providerActivity = activity
        }
    }

    var diagnostics: [ContextDiagnostic] { snapshot?.diagnostics ?? [] }
    var isConfigured: Bool { sourceConfiguration != nil || !contextSources.isEmpty }
    var isUsingSampleVault: Bool {
        guard let configuration = sourceConfiguration else { return false }
        return isManagedSampleVaultPath(configuration.displayPath)
    }
    var activeProviderActivity: ProviderActivityPresentation? {
        providerLifecycle.activePresentation(descriptors: providerDescriptors)
    }

    func bootstrap() async {
        state = .loadingCache
        startWorkspaceObservation()
        // Plugin snapshots are source-scoped. The old composed cache had no
        // source membership, so it can never safely be presented after a
        // folder switch or removal. Retire it instead of using it as a stale
        // fallback; each source still preserves its own last good snapshot.
        install(nil)
        var compatibilityCacheError: Error?
        do { try await repository.delete() }
        catch { compatibilityCacheError = error }
        var folderFailure: Error?
        if var configuration = configurations.loadConfiguration() {
            if isManagedSampleVaultPath(configuration.displayPath),
               let currentSample = try? prepareSampleVault(),
               currentSample.standardizedFileURL.path != URL(fileURLWithPath: configuration.displayPath).standardizedFileURL.path,
               let migrated = try? configurations.save(url: currentSample, sourceType: "Sample") {
                configuration = migrated
            }
            sourceConfiguration = configuration
            do {
                let url = try configurations.resolve(configuration)
                await configureDirectory(
                    url: url,
                    configuration: configuration,
                    providerID: configuredDirectoryProviderID
                )
            } catch {
                folderFailure = error
            }
        } else {
            sourceConfiguration = nil
        }

        // Connected sources discover from their non-secret descriptors, so this
        // also restores a cached Kontext-only workspace while offline.
        _ = try? await providerLifecycle.synchronizeSources()
        await updateSourcePresentation()
        if let workspace = await pluginHost.workspaceSnapshot() {
            await installWorkspace(workspace)
        }
        if !contextSources.isEmpty {
            await reindex(presentation: .silent)
        } else if let folderFailure {
            state = snapshot == nil ? .failed(folderFailure.localizedDescription) : .stale(folderFailure.localizedDescription)
        } else {
            state = snapshot == nil ? .unconfigured : .stale("The previous source configuration is missing.")
        }
        if let compatibilityCacheError {
            state = snapshot == nil
                ? .failed("Could not erase obsolete context cache: \(compatibilityCacheError.localizedDescription)")
                : .stale("Could not erase obsolete context cache: \(compatibilityCacheError.localizedDescription)")
        }
    }

    func chooseFolder(_ url: URL, sourceType: String? = nil) async throws {
        try await chooseDirectory(url, for: defaultDirectoryProviderID, sourceType: sourceType)
    }

    func chooseDirectory(
        _ url: URL,
        for providerID: PluginIdentifier,
        sourceType: String? = nil
    ) async throws {
        guard let manager = directorySourceManagers[providerID],
              manager.descriptor.sourceSetup == .directoryPicker else {
            throw DirectorySourceSetupError.unregisteredProvider(providerID)
        }
        let type = sourceType ?? (FileManager.default.fileExists(atPath: url.appendingPathComponent(".obsidian").path) ? "Obsidian" : "Folder")
        if let existing = sourceConfiguration {
            let previousProviderID = configuredDirectoryProviderID
            let previousManager = directorySourceManagers[previousProviderID]
            let removedSourceID = directorySourceIdentifier(
                for: existing,
                providerID: previousProviderID
            )
            do {
                try await pluginHost.removeSource(removedSourceID)
            } catch {
                state = snapshot == nil
                    ? .failed("Could not erase the previous folder cache: \(error.localizedDescription)")
                    : .stale("Could not erase the previous folder cache: \(error.localizedDescription)")
                throw error
            }

            // Once the source itself has been removed, retire every route that
            // could display or resurrect it before attempting best-effort
            // secondary cache cleanup. A cache deletion error must be visible,
            // but it must never put forgotten private content back on screen.
            previousManager?.remove(sourceID: removedSourceID)
            sourceConfiguration = nil
            configurations.clear()
            defaults.removeObject(forKey: "configuredDirectoryProviderID")
            await onRemoveSource?(removedSourceID.rawValue)
            await updateSourcePresentation()
            if let workspace = await pluginHost.workspaceSnapshot() {
                await installWorkspace(workspace)
            } else {
                install(nil)
            }
            do {
                try await repository.delete()
            } catch {
                state = snapshot == nil
                    ? .failed("The previous folder was removed, but one of its caches could not be erased: \(error.localizedDescription)")
                    : .stale("The previous folder was removed, but one of its caches could not be erased: \(error.localizedDescription)")
                throw error
            }
        }
        do {
            let configuration = try configurations.save(url: url, sourceType: type)
            sourceConfiguration = configuration
            configuredDirectoryProviderID = providerID
            defaults.set(providerID.rawValue, forKey: "configuredDirectoryProviderID")
            await configureDirectory(url: url, configuration: configuration, providerID: providerID)
            await reindex(presentation: .visible)
        } catch {
            state = snapshot == nil
                ? .failed("Could not configure the new folder: \(error.localizedDescription)")
                : .stale("Could not configure the new folder: \(error.localizedDescription)")
            throw error
        }
    }

    func useSampleVault() async throws {
        try await chooseFolder(prepareSampleVault(replacingExisting: true), sourceType: "Sample")
    }

    private func prepareSampleVault(replacingExisting: Bool = false) throws -> URL {
        guard let bundled = bundledSampleVaultURL() else { throw CocoaError(.fileNoSuchFile) }
        let local = managedSampleVaultURL()
        return try ManagedSampleVaultInstaller.prepare(
            bundled: bundled,
            managed: local,
            replacingExisting: replacingExisting
        )
    }

    private func managedSampleVaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Embers", isDirectory: true)
            .appendingPathComponent("SampleVault-v7", isDirectory: true)
    }

    private func isManagedSampleVaultPath(_ path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let root = managedSampleVaultURL().deletingLastPathComponent().standardizedFileURL
        return ManagedSampleVaultPath.matches(candidate, root: root)
    }

    private func bundledSampleVaultURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "SampleVault", withExtension: nil) { return bundled }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "SampleVault", withExtension: nil)
        #else
        return nil
        #endif
    }

    func reindex(presentation: IndexingPresentation) async {
        if presentation == .visible { state = .indexing }
        do {
            try await providerLifecycle.synchronizeSources()
            await updateSourcePresentation()
            guard !contextSources.isEmpty else {
                install(nil)
                state = .unconfigured
                return
            }
            var outcomes: [WorkspaceRefreshOutcome] = []
            let sourcesByProvider = Dictionary(grouping: contextSources.map(\.descriptor.id), by: \.pluginID)
            for providerID in sourcesByProvider.keys.sorted() {
                let providerOutcomes = await providerLifecycle.refreshProvider(
                    providerID,
                    sourceIDs: sourcesByProvider[providerID, default: []].sorted(),
                    presentation: presentation
                )
                outcomes.append(contentsOf: providerOutcomes)
                await updateSourcePresentation()
                providerLifecycle.finishProvider(
                    providerID,
                    outcomes: providerOutcomes,
                    currentSources: contextSources.filter { $0.descriptor.id.pluginID == providerID }
                )
            }
            await updateSourcePresentation()
            if await retireOnboardingIfRealSourceIsUsable() { return }
            guard let workspace = await pluginHost.workspaceSnapshot() else {
                let reason = outcomes.compactMap { outcome -> String? in
                    if case let .stale(message) = outcome.sourceState.health { return message }
                    return nil
                }.first ?? "No source produced a valid snapshot."
                state = snapshot == nil ? .failed(reason) : .stale(reason)
                return
            }
            await installWorkspace(workspace)
            let stale = outcomes.compactMap { outcome -> String? in
                if case let .stale(message) = outcome.sourceState.health { return message }
                return nil
            }.first
            state = stale.map(IndexingState.stale) ?? .ready
        } catch {
            state = snapshot == nil ? .failed(error.localizedDescription) : .stale(error.localizedDescription)
        }
    }

    func open(_ artifact: SourceArtifact) async {
        do {
            try await pluginHost.performDefaultOpen(for: artifact)
            recentAccesses.markAccessed(artifact.id)
            refreshRecent()
        } catch {}
    }

    func availableArtifactActions(for artifact: SourceArtifact) async -> [ArtifactAction] {
        await pluginHost.availableArtifactActions(for: artifact)
    }

    func perform(_ action: ArtifactAction, for artifact: SourceArtifact) async throws {
        try await pluginHost.perform(action, for: artifact)
        if action.kind == .open {
            recentAccesses.markAccessed(artifact.id)
            refreshRecent()
        }
    }

    func supportedTaskStates(for task: AnchorTask) async -> Set<SourceTaskState> {
        guard let artifact = snapshot?.artifacts.first(where: { $0.id == task.artifactID }),
              let sourceTask = artifact.metadata.tasks.first(where: { $0.id == task.taskID }) else { return [] }
        return await pluginHost.supportedTaskStates(for: sourceTask, in: artifact)
    }

    func setTaskState(_ newState: SourceTaskState, for task: AnchorTask) async throws {
        guard let artifact = snapshot?.artifacts.first(where: { $0.id == task.artifactID }),
              let sourceTask = artifact.metadata.tasks.first(where: { $0.id == task.taskID }) else {
            throw PluginHostError.noTaskMutation
        }
        let outcome = try await pluginHost.setTaskState(newState, for: sourceTask, in: artifact)
        await updateSourcePresentation()
        providerLifecycle.finishProvider(
            outcome.source.pluginID,
            outcomes: [outcome],
            currentSources: contextSources.filter { $0.descriptor.id.pluginID == outcome.source.pluginID }
        )
        if let workspace = outcome.workspace { await installWorkspace(workspace) }
        if case let .stale(message) = outcome.sourceState.health {
            state = .stale(message)
        } else {
            state = .ready
        }
    }

    func ignore(_ anchorID: String) {
        ignoredAnchorIDs.insert(anchorID)
        persistIgnored()
        refreshGraph()
    }

    func restore(_ anchorID: String) {
        ignoredAnchorIDs.remove(anchorID)
        persistIgnored()
        refreshGraph()
    }

    func forget() async {
        await forgetFolder()
    }

    func remove(_ sourceID: PluginSourceIdentifier) async {
        guard let provider = providerDescriptors.first(where: { $0.id == sourceID.pluginID }) else { return }
        if directorySourceManagers[sourceID.pluginID] != nil {
            await forgetDirectory(providerID: sourceID.pluginID)
        } else if provider.capabilities.contains(.connection) {
            await disconnect(provider.id)
        } else {
            do {
                try await pluginHost.removeSource(sourceID)
                await onRemoveSource?(sourceID.rawValue)
                await updateSourcePresentation()
                if let workspace = await pluginHost.workspaceSnapshot() {
                    await installWorkspace(workspace)
                    state = .ready
                } else {
                    install(nil)
                    state = .unconfigured
                }
            } catch {
                state = snapshot == nil ? .failed(error.localizedDescription) : .stale(error.localizedDescription)
            }
        }
    }

    /// Forgetting a folder is deliberately scoped: connected libraries and
    /// their independent cache remain available.
    func forgetFolder() async {
        await forgetDirectory(providerID: configuredDirectoryProviderID)
    }

    private func forgetDirectory(providerID: PluginIdentifier) async {
        guard let manager = directorySourceManagers[providerID],
              providerID == configuredDirectoryProviderID else { return }
        // Ignore state is currently persisted as a legacy flat set. Only
        // remove anchors supplied by the folder being forgotten; a connected
        // source can remain active and must keep its hidden contexts hidden.
        let removedSourceID = sourceConfiguration.map {
            directorySourceIdentifier(for: $0, providerID: providerID)
        }
        let forgottenAnchorIDs = Set(contextSources.lazy
            .filter { $0.descriptor.id == removedSourceID }
            .flatMap { $0.snapshot?.anchors.map(\.id) ?? [] })
        do {
            if let removedSourceID {
                try await pluginHost.removeSource(removedSourceID)
            }
        } catch {
            state = snapshot == nil ? .failed("Could not erase the folder cache: \(error.localizedDescription)") : .stale("Could not erase the folder cache: \(error.localizedDescription)")
            return
        }

        if let removedSourceID {
            manager.remove(sourceID: removedSourceID)
        }
        sourceConfiguration = nil
        configuredDirectoryProviderID = defaultDirectoryProviderID
        defaults.removeObject(forKey: "configuredDirectoryProviderID")
        if let removedSourceID { await onRemoveSource?(removedSourceID.rawValue) }
        ignoredAnchorIDs.subtract(forgottenAnchorIDs)
        persistIgnored()
        configurations.clear()
        await updateSourcePresentation()
        if let workspace = await pluginHost.workspaceSnapshot() {
            await installWorkspace(workspace)
            state = .ready
        } else {
            install(nil)
            state = .unconfigured
        }
        do {
            try await repository.delete()
        } catch {
            state = snapshot == nil
                ? .failed("The folder was forgotten, but one of its caches could not be erased: \(error.localizedDescription)")
                : .stale("The folder was forgotten, but one of its caches could not be erased: \(error.localizedDescription)")
        }
    }

    func connect(_ pluginID: PluginIdentifier) async {
        guard connectionStatuses[pluginID]?.state != .connecting else { return }
        connectionStatuses[pluginID] = .init(state: .connecting)
        do {
            try await providerLifecycle.connect(pluginID)
            await updateSourcePresentation()
            let pluginSources = contextSources.filter { $0.descriptor.id.pluginID == pluginID }
            guard !pluginSources.isEmpty else {
                let message = "The connected provider did not configure a context source."
                providerLifecycle.fail(pluginID, message: message)
                state = snapshot == nil ? .failed(message) : .stale(message)
                return
            }
            let outcomes = await providerLifecycle.refreshProvider(
                pluginID,
                sourceIDs: pluginSources.map(\.descriptor.id).sorted(),
                presentation: .visible
            )
            await updateSourcePresentation()
            providerLifecycle.finishProvider(
                pluginID,
                outcomes: outcomes,
                currentSources: contextSources.filter { $0.descriptor.id.pluginID == pluginID }
            )
            if await retireOnboardingIfRealSourceIsUsable() { return }
            if let workspace = await pluginHost.workspaceSnapshot() {
                await installWorkspace(workspace)
                state = contextSources.contains { if case .stale = $0.health { return true }; return false } ? .stale("One or more context sources could not refresh.") : .ready
            }
        } catch {
            await updateSourcePresentation()
            state = snapshot == nil ? .failed(error.localizedDescription) : .stale(error.localizedDescription)
        }
    }

    func disconnect(_ pluginID: PluginIdentifier) async {
        let removedSourceIDs = contextSources
            .filter { $0.descriptor.id.pluginID == pluginID }
            .map { $0.descriptor.id.rawValue }
        do { try await providerLifecycle.disconnect(pluginID) }
        catch {
            // Local cache deletion is a precondition for claiming a source is
            // disconnected. Keep it visible and retryable if it fails.
            state = snapshot == nil ? .failed(error.localizedDescription) : .stale(error.localizedDescription)
            await updateSourcePresentation()
            return
        }
        for sourceID in removedSourceIDs { await onRemoveSource?(sourceID) }
        await updateSourcePresentation()
        if let workspace = await pluginHost.workspaceSnapshot() {
            await installWorkspace(workspace)
            state = .ready
        } else {
            install(nil)
            do { try await repository.delete() }
            catch {
                state = .failed("Could not erase obsolete context cache: \(error.localizedDescription)")
                return
            }
            state = .unconfigured
        }
    }

    func refresh(_ sourceID: PluginSourceIdentifier) async {
        let outcomes = await providerLifecycle.refreshProvider(
            sourceID.pluginID,
            sourceIDs: [sourceID],
            presentation: .silent
        )
        await updateSourcePresentation()
        providerLifecycle.finishProvider(
            sourceID.pluginID,
            outcomes: outcomes,
            currentSources: contextSources.filter { $0.descriptor.id.pluginID == sourceID.pluginID }
        )
        if let workspace = await pluginHost.workspaceSnapshot() {
            await installWorkspace(workspace)
            state = contextSources.contains { if case .stale = $0.health { return true }; return false } ? .stale("One or more context sources could not refresh.") : .ready
        } else {
            state = .failed("No source produced a valid snapshot.")
        }
    }

    private func install(
        _ snapshot: ContextSnapshot?,
        graph suppliedGraph: ContextGraph? = nil,
        search suppliedSearch: GraphContextSearch? = nil,
        summaries suppliedSummaries: [AnchorSummary]? = nil,
        recent suppliedRecent: [RecentArtifact]? = nil
    ) {
        guard let snapshot else {
            self.snapshot = nil
            graph = nil
            graphSearch = nil
            summaries = []
            unassignedArtifacts = []
            recent = []
            return
        }
        let projected = suppliedGraph ?? graphProjector.project(snapshot, ignoring: ignoredAnchorIDs)
        let search = suppliedSearch ?? GraphContextSearch(graph: projected, snapshot: snapshot)
        graphSearch = search
        graph = projected
        summaries = suppliedSummaries ?? search.homeSummaries(in: snapshot)
        let rootSourceIDs = Set(contextSources.compactMap { source in
            source.descriptor.presentsUnassignedArtifactsAtRoot ? source.descriptor.id.rawValue : nil
        })
        unassignedArtifacts = LinearContextSearch().unassignedArtifacts(in: snapshot).filter { artifact in
            artifact.provider?.sourceID.map { rootSourceIDs.contains($0) } ?? false
        }
        recent = suppliedRecent ?? LinearContextSearch().recent(in: snapshot, accessedAt: recentAccesses.accessDates())
        self.snapshot = snapshot
    }

    private func refreshRecent() {
        guard let snapshot else { recent = []; return }
        recent = LinearContextSearch().recent(in: snapshot, accessedAt: recentAccesses.accessDates())
    }

    private func refreshGraph() {
        guard let snapshot else { return }
        install(snapshot)
    }

    private func configureDirectory(
        url: URL,
        configuration: SourceConfiguration,
        providerID: PluginIdentifier
    ) async {
        guard let manager = directorySourceManagers[providerID] else { return }
        let sourceID = directorySourceIdentifier(for: configuration, providerID: providerID)
        manager.configure(
            source: .init(
                id: sourceID,
                displayName: URL(fileURLWithPath: configuration.displayPath).lastPathComponent,
                kind: configuration.sourceType.lowercased(),
                detail: configuration.displayPath,
                isOnboarding: isManagedSampleVaultPath(configuration.displayPath)
            ),
            rootURL: url
        )
        startWorkspaceObservation()
    }

    private func directorySourceIdentifier(
        for configuration: SourceConfiguration,
        providerID: PluginIdentifier
    ) -> PluginSourceIdentifier {
        .init(pluginID: providerID, sourceID: configuration.id)
    }

    private func startWorkspaceObservation() {
        let host = pluginHost
        if workspaceTask == nil {
            workspaceTask = Task { [weak self] in
                let updates = await host.workspaceUpdates()
                for await workspace in updates {
                    guard let self, !Task.isCancelled else { return }
                    await self.updateSourcePresentation()
                    if await self.retireOnboardingIfRealSourceIsUsable() { continue }
                    await self.installWorkspace(workspace)
                    if self.state != .indexing { self.state = .ready }
                }
            }
        }
        if sourceStateTask == nil {
            sourceStateTask = Task { [weak self] in
                let updates = await host.sourceStateUpdates()
                for await sources in updates {
                    guard let self, !Task.isCancelled else { return }
                    self.contextSources = sources
                    self.providerLifecycle.reconcileProviderActivity(with: sources)
                }
            }
        }
    }

    /// The sample is disposable scaffolding. Any non-onboarding source that has
    /// published a usable snapshot is sufficient to replace it, regardless of
    /// which provider supplied that source.
    @discardableResult
    private func retireOnboardingIfRealSourceIsUsable() async -> Bool {
        guard isUsingSampleVault, !isRetiringOnboarding else { return false }
        let hasUsableRealSource = contextSources.contains { source in
            !source.descriptor.isOnboarding && source.snapshot != nil
        }
        guard hasUsableRealSource else { return false }
        isRetiringOnboarding = true
        defer { isRetiringOnboarding = false }
        await forgetFolder()
        return true
    }

    private func updateSourcePresentation() async {
        contextSources = await pluginHost.sourceStates()
        providerLifecycle.reconcileProviderActivity(with: contextSources)
        let descriptors = await pluginHost.registeredPlugins()
        providerDescriptors = descriptors
        connectionPlugins = descriptors.filter { $0.capabilities.contains(.connection) }
        var statuses: [PluginIdentifier: PluginConnectionStatus] = [:]
        for descriptor in connectionPlugins {
            if let status = await pluginHost.connectionStatus(for: descriptor.id) { statuses[descriptor.id] = status }
        }
        connectionStatuses = statuses
    }

    private func installWorkspace(_ workspace: ContextSnapshot) async {
        let graphProjector = self.graphProjector
        let ignored = self.ignoredAnchorIDs
        let accessDates = recentAccesses.accessDates()
        let prepared = await Task.detached(priority: .utility) {
            let graph = graphProjector.project(workspace, ignoring: ignored)
            let search = GraphContextSearch(graph: graph, snapshot: workspace)
            return (workspace, graph, search, search.homeSummaries(in: workspace), LinearContextSearch().recent(in: workspace, accessedAt: accessDates))
        }.value
        install(prepared.0, graph: prepared.1, search: prepared.2, summaries: prepared.3, recent: prepared.4)
    }

    private func persistIgnored() { defaults.set(ignoredAnchorIDs.sorted(), forKey: "ignoredAnchorIDs") }

    private func deleteObsoleteCredentials() {
        guard defaults.bool(forKey: "removedLegacyConnectionFile") == false else { return }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let old = root?.appendingPathComponent("embers", isDirectory: true).appendingPathComponent("connection.json")
        if let old, FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.removeItem(at: old) }
        defaults.set(true, forKey: "removedLegacyConnectionFile")
    }
}
