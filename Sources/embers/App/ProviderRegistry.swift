import EmbersCore
import EmbersLocal
import EmbersPluginHost
import EmbersPluginKit
import FolderPlugin
import Foundation
import KontextPlugin

/// The production provider roster used by AppCompositionRoot. This is the only
/// executable-layer file that knows which concrete providers ship with Embers.
protocol DirectorySourceManaging: PluginDescribing {
    func configure(source descriptor: PluginSourceDescriptor, rootURL: URL)
    func remove(sourceID: PluginSourceIdentifier)
}

extension FolderPlugin: DirectorySourceManaging {}

struct ProviderRegistry {
    let host: PluginHost
    let directorySourceManagers: [PluginIdentifier: any DirectorySourceManaging]
    let defaultDirectoryProviderID: PluginIdentifier

    init(
        builder: DeterministicGraphBuilder,
        repository: any PluginSnapshotRepository,
        browser: any OAuthBrowserSession = SystemOAuthBrowserSession()
    ) throws {
        let directoryProvider = FolderPlugin(builder: builder)
        let providers: [any PluginSourceProviding & PluginRefreshing] = [
            directoryProvider,
            KontextPlugin(browser: browser),
        ]
        host = try PluginHost(plugins: providers, repository: repository)
        directorySourceManagers = [directoryProvider.descriptor.id: directoryProvider]
        defaultDirectoryProviderID = directoryProvider.descriptor.id
    }

    init(
        host: PluginHost,
        directorySourceManagers: [any DirectorySourceManaging],
        defaultDirectoryProviderID: PluginIdentifier
    ) {
        let managers = Dictionary(
            directorySourceManagers.map { ($0.descriptor.id, $0) },
            uniquingKeysWith: { _, replacement in replacement }
        )
        precondition(
            managers.count == directorySourceManagers.count,
            "Directory provider identifiers must be unique."
        )
        precondition(
            managers[defaultDirectoryProviderID] != nil,
            "The default directory provider must have a registered setup manager."
        )
        self.host = host
        self.directorySourceManagers = managers
        self.defaultDirectoryProviderID = defaultDirectoryProviderID
    }

    func directorySourceManager(for providerID: PluginIdentifier) -> (any DirectorySourceManaging)? {
        directorySourceManagers[providerID]
    }
}
