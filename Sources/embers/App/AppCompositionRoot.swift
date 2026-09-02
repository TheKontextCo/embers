import EmbersCore
import AppKit
import EmbersLocal
import Foundation

/// Owns the production object graph. Feature objects receive ready dependencies
/// and never decide which persistent stores or providers ship with the app.
@MainActor
enum AppCompositionRoot {
    static let oauthBrowser = DefaultBrowserOAuthSession(prepareCallback: { scheme in
        guard scheme == "embers", Bundle.main.bundleURL.pathExtension == "app" else {
            throw OAuthError.invalidConfiguration("Sign-in requires the Embers app bundle.")
        }
        // Multiple installed/development copies can own the same scheme. Bind only
        // our callback scheme to this bundle before login; never change the browser.
        let callback = URL(string: "embers://oauth/callback")!
        if NSWorkspace.shared.urlForApplication(toOpen: callback)?.standardizedFileURL
            != Bundle.main.bundleURL.standardizedFileURL {
            try await NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
        }
    })
    static let app: AppState = {
        let defaults = UserDefaults.standard
        let featureFlags = AppFeatureFlags.from(environment: ProcessInfo.processInfo.environment)
        let pluginSnapshots = JSONPluginSnapshotRepository.applicationSupport()
        let registry: ProviderRegistry
        do {
            registry = try ProviderRegistry(
                builder: DeterministicGraphBuilder(),
                repository: pluginSnapshots,
                browser: oauthBrowser
            )
        } catch {
            preconditionFailure("Could not assemble the provider registry: \(error.localizedDescription)")
        }

        let providerLifecycle = ProviderLifecycleCoordinator(host: registry.host)
        let context = ContextIndexController(
            repository: JSONSnapshotRepository.applicationSupport(),
            configurations: SourceConfigurationStore(defaults: defaults),
            defaults: defaults,
            graphProjector: DeterministicContextGraphProjector(),
            recentAccesses: UserDefaultsRecentAccess(defaults),
            providerRegistry: registry,
            providerLifecycle: providerLifecycle
        )
        let speech = SpeechListener()
        let notch = NotchViewModel()
        let peeks = PeekQueue()
        let packLifecycle = VoiceRoutingPackCoordinator(
            store: VoiceRoutingStore.applicationSupport()
        )
        let preferences = VoiceRoutingPreferenceCoordinator(
            store: VoiceRoutingPreferenceStore.applicationSupport()
        )
        let voiceRouting = VoiceRoutingCoordinator(
            context: context,
            speech: speech,
            notch: notch,
            peeks: peeks,
            packLifecycle: packLifecycle,
            preferences: preferences,
            featureFlags: featureFlags
        )
        let changeBaselines = UserDefaultsChangeBaselineStore(defaults)
        let dashboardNavigation = DashboardNavigationCoordinator(
            context: context,
            speech: speech,
            changeBaselines: changeBaselines
        )
        let taskMutations = DashboardTaskMutationCoordinator(
            context: context,
            navigation: dashboardNavigation
        )
        return AppState(
            context: context,
            speech: speech,
            notch: notch,
            peeks: peeks,
            voiceRouting: voiceRouting,
            dashboardNavigation: dashboardNavigation,
            taskMutations: taskMutations,
            changeBaselines: changeBaselines
        )
    }()
}
