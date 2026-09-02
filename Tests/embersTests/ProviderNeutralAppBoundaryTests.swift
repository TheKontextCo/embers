import Foundation
import Testing

@testable import embers

/// Architecture characterization for the app/provider seam.
///
/// These checks deliberately inspect only the thin executable layer. Provider
/// packages are allowed to know their own concrete types; the app should know
/// them once, at composition, and consume descriptors/capabilities everywhere
/// else. Keeping these as source-boundary tests makes a synthetic third provider
/// a meaningful proof without requiring that provider to ship in the product.
struct ProviderNeutralAppBoundaryTests {
    @Test func productionOAuthUsesDefaultBrowserAndRoutesCallbacksToSameSession() throws {
        let root = try readSource("Sources/embers/App/AppCompositionRoot.swift")
        let registry = try readSource("Sources/embers/App/ProviderRegistry.swift")
        let delegate = try readSource("Sources/embers/App/AppDelegate.swift")
        let browser = try readSource("Sources/EmbersLocal/DefaultBrowserOAuthSession.swift")
        #expect(root.contains("static let oauthBrowser = DefaultBrowserOAuthSession("))
        #expect(root.contains("browser: oauthBrowser"))
        #expect(registry.contains("KontextPlugin(browser: browser)"))
        #expect(delegate.contains("AppCompositionRoot.oauthBrowser.handleCallback(url)"))
        #expect(browser.contains("NSWorkspace.shared.open($0)"))
        #expect(!browser.contains("withApplicationAt:") && !browser.contains("com.google.Chrome"))
    }

    @Test func productionServicesAreAssembledByOneCompositionRoot() throws {
        let files = try swiftSources(under: "Sources/embers")
        let applicationSupportFactory = try NSRegularExpression(
            pattern: #"\b\w+\.applicationSupport\(\)"#
        )
        let factoryOwners = try files.filter { file in
            let source = try String(contentsOf: file, encoding: .utf8)
            return applicationSupportFactory.firstMatch(
                in: source,
                range: NSRange(source.startIndex..., in: source)
            ) != nil
        }

        #expect(
            relativePaths(factoryOwners) == "Sources/embers/App/AppCompositionRoot.swift",
            "Production persistent-service factories belong in the sole composition root. Found: \(relativePaths(factoryOwners))"
        )

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !source.contains("AppState.shared"),
                "Feature and lifecycle code must receive the composed AppState instead of reaching through a global singleton: \(relativePath(file))"
            )
        }

        let root = try readSource("Sources/embers/App/AppCompositionRoot.swift")
        for construction in ["ProviderRegistry(", "ContextIndexController(", "AppState("] {
            #expect(
                root.contains(construction),
                "The composition root must explicitly own \(construction.dropLast()) construction."
            )
        }

        let appState = try readSource("Sources/embers/App/AppState.swift")
        #expect(
            !appState.contains("private convenience init()"),
            "AppState must not retain a hidden production constructor."
        )
        #expect(
            !appState.contains("ChangeBaselineStore ="),
            "AppState must receive its baseline store instead of constructing a production default."
        )

        let controller = try readSource("Sources/embers/Model/ContextIndexController.swift")
        let hiddenRegistryConstruction = try NSRegularExpression(
            pattern: #"try!\s*ProviderRegistry\s*\("#
        )
        #expect(
            hiddenRegistryConstruction.firstMatch(
                in: controller,
                range: NSRange(controller.startIndex..., in: controller)
            ) == nil,
            "ContextIndexController must receive an assembled ProviderRegistry instead of constructing one implicitly."
        )
        #expect(
            !controller.contains("providerRegistry suppliedRegistry")
                && !controller.contains("RecentAccessStore?"),
            "ContextIndexController must require its provider registry and recent-access store."
        )
    }

    @Test func appStateDelegatesVoiceOrchestrationToAnInjectedCoordinator() throws {
        let root = try readSource("Sources/embers/App/AppCompositionRoot.swift")
        let appState = try readSource("Sources/embers/App/AppState.swift")
        let coordinator = try readSource("Sources/embers/App/VoiceRoutingCoordinator.swift")
        let packLifecycle = try readSource("Sources/embers/App/VoiceRoutingPackCoordinator.swift")
        let preferences = try readSource("Sources/embers/App/VoiceRoutingPreferenceCoordinator.swift")

        for construction in [
            "VoiceRoutingCoordinator(",
            "VoiceRoutingPackCoordinator(",
            "VoiceRoutingPreferenceCoordinator(",
        ] {
            #expect(
                root.contains(construction),
                "The composition root must explicitly assemble \(construction.dropLast())."
            )
        }
        #expect(
            appState.contains("voiceRouting: VoiceRoutingCoordinator"),
            "AppState must receive voice orchestration instead of constructing its stores and compiler."
        )
        for ownership in ["VoiceRoutingStreamRouter", "peekOpenCommandTask"] {
            #expect(
                !appState.contains(ownership),
                "AppState must not retain voice-lifecycle ownership: \(ownership)"
            )
            #expect(
                coordinator.contains(ownership),
                "VoiceRoutingCoordinator must visibly own the extracted voice lifecycle: \(ownership)"
            )
        }
        for ownership in ["VoiceRoutingCompiler", "routingCompilationTask"] {
            #expect(!coordinator.contains(ownership), "The top-level coordinator must not own pack lifecycle state: \(ownership)")
            #expect(packLifecycle.contains(ownership), "VoiceRoutingPackCoordinator must own: \(ownership)")
        }
        for ownership in ["preferenceRecordTasks", "preferenceResetTask", "retiredPreferenceSourceIDs"] {
            #expect(!coordinator.contains(ownership), "The top-level coordinator must not own preference lifecycle state: \(ownership)")
            #expect(preferences.contains(ownership), "VoiceRoutingPreferenceCoordinator must own: \(ownership)")
        }
        for (name, source) in [
            ("VoiceRoutingCoordinator", coordinator),
            ("VoiceRoutingPackCoordinator", packLifecycle),
            ("VoiceRoutingPreferenceCoordinator", preferences),
        ] {
            #expect(source.contains("private var hasStarted = false"), "\(name) must retain durable startup state.")
            #expect(source.contains("precondition(!hasStarted"), "\(name) must reject a second start independently of weak delegate lifetime.")
            #expect(source.contains("hasStarted = true"), "\(name) must persist startup before installing callbacks or subscriptions.")
            #expect(!source.contains("precondition(self.delegate == nil"), "\(name) must not infer startup from a weak delegate reference.")
        }
    }

    @Test func appFacadesDelegateProviderNavigationAndTaskLifecycles() throws {
        let root = try readSource("Sources/embers/App/AppCompositionRoot.swift")
        let controller = try readSource("Sources/embers/Model/ContextIndexController.swift")
        let providers = try readSource("Sources/embers/Model/ProviderLifecycleCoordinator.swift")
        let dashboard = try readSource("Sources/embers/Notch/DashboardViewModel.swift")
        let navigation = try readSource("Sources/embers/Notch/DashboardNavigationCoordinator.swift")
        let tasks = try readSource("Sources/embers/Notch/DashboardTaskMutationCoordinator.swift")

        for construction in [
            "ProviderLifecycleCoordinator(",
            "DashboardNavigationCoordinator(",
            "DashboardTaskMutationCoordinator(",
        ] {
            #expect(root.contains(construction), "The composition root must explicitly assemble \(construction.dropLast()).")
        }
        for ownership in ["providerIndexingOperations"] {
            #expect(!controller.contains(ownership), "ContextIndexController must not retain provider lifecycle ownership: \(ownership)")
            #expect(providers.contains(ownership), "ProviderLifecycleCoordinator must own: \(ownership)")
        }
        for (facadeOwnership, collaboratorOwnership) in [
            ("private func refreshProvider(", "func refreshProvider("),
            ("private func reconcileProviderActivity", "func reconcileProviderActivity"),
            ("private func transitionProvider(", "private func transitionProvider("),
        ] {
            #expect(!controller.contains(facadeOwnership), "ContextIndexController must not retain provider lifecycle ownership: \(facadeOwnership)")
            #expect(providers.contains(collaboratorOwnership), "ProviderLifecycleCoordinator must own: \(collaboratorOwnership)")
        }
        for ownership in ["navigationRetention", "Task.detached(priority: .userInitiated)", "@Published private(set) var evidenceRevealNotBefore"] {
            #expect(!dashboard.contains(ownership), "DashboardViewModel must not retain navigation/detail-loading ownership: \(ownership)")
            #expect(navigation.contains(ownership), "DashboardNavigationCoordinator must own: \(ownership)")
        }
        for ownership in ["@Published private(set) var mutatingTaskIDs", "@Published private(set) var taskMutationError", "setTaskState(.completed"] {
            #expect(!dashboard.contains(ownership), "DashboardViewModel must not retain task-mutation ownership: \(ownership)")
            #expect(tasks.contains(ownership), "DashboardTaskMutationCoordinator must own: \(ownership)")
        }
    }

    @Test func concreteProvidersAreKnownOnlyByTheProviderRoster() throws {
        let files = try swiftSources(under: "Sources/embers")
        let concreteProviderPattern = try NSRegularExpression(
            pattern: #"\b(?:FolderPlugin|KontextPlugin)\b"#
        )

        let concreteFiles = try files.filter { file in
            let source = try String(contentsOf: file, encoding: .utf8)
            return concreteProviderPattern.firstMatch(
                in: source,
                range: NSRange(source.startIndex..., in: source)
            ) != nil
        }

        #expect(
            concreteFiles.count == 1,
            "Concrete providers belong in exactly one provider roster. Found: \(relativePaths(concreteFiles))"
        )
        if let root = concreteFiles.first {
            let relative = relativePath(root)
            #expect(
                relative == "Sources/embers/App/ProviderRegistry.swift",
                "The sole concrete-provider whitelist entry is Sources/embers/App/ProviderRegistry.swift, not feature code: \(relative)"
            )
        }
    }

    @Test func settingsHasNoProviderSpecificPresentationBranch() throws {
        let source = try readSource("Sources/embers/Views/SettingsView.swift")
        let providerSpecificTokens = [
            "FolderPlugin",
            "KontextPlugin",
            "sourceConfiguration",
            "localFolderCard",
            "folder.badge.plus",
            "Choose a Markdown folder or Obsidian vault",
            "Forget Folder",
        ]

        for token in providerSpecificTokens {
            #expect(
                !source.contains(token),
                "Settings must render provider descriptors/actions uniformly; found provider-specific token: \(token)"
            )
        }
        #expect(source.contains(".descriptor"), "Settings source cards must be derived from provider/source descriptors")
    }

    @Test func dashboardRoutesEveryArtifactActionThroughTheProviderHost() throws {
        let dashboard = try readSource("Sources/embers/Views/DashboardView.swift")
        let appActionLayer = try [
            "Sources/embers/Views/DashboardView.swift",
            "Sources/embers/Notch/DashboardViewModel.swift",
            "Sources/embers/Model/ContextIndexController.swift",
        ].map(readSource).joined(separator: "\n")

        #expect(!dashboard.contains("artifact.localURL"), "Dashboard must not infer provider actions from a local file URL")
        #expect(!dashboard.contains("activateFileViewerSelecting"), "Dashboard must not implement Reveal itself")
        #expect(
            appActionLayer.contains("availableArtifactActions"),
            "The app must ask the provider host which artifact actions are available"
        )
        #expect(
            appActionLayer.contains("ArtifactAction"),
            "The app must pass the provider-neutral ArtifactAction value through UI, view model, and controller"
        )
    }

    @Test func voicePreferenceScopesAreProviderNeutral() throws {
        let source = try [
            "Sources/embers/App/AppState.swift",
            "Sources/embers/Speech/VoiceRoutingPreferenceState.swift",
        ].map(readSource).joined(separator: "\n")
        let folderSpecificTokens = [
            "import FolderPlugin",
            "folderPreferenceSourceID",
            "resetFolderVoiceRoutingPreferences",
            "resetFolderAction",
            "folderSummary",
            "No local folder selected",
        ]

        for token in folderSpecificTokens {
            #expect(
                !source.contains(token),
                "Voice learning must scope/reset by generic source identity; found folder-specific token: \(token)"
            )
        }
        #expect(source.contains("sourceID"), "Voice preferences must remain source-scoped")
    }

    @Test func contextLensIsASourceScopedExportRatherThanANewModelOrProviderBranch() throws {
        let lens = try readSource("Sources/embers/Speech/ContextLens.swift")
        let settings = try readSource("Sources/embers/Views/SettingsView.swift")

        #expect(lens.contains("sourceID"), "Context Lens exports must remain source-scoped")
        #expect(lens.contains("writeAndOpen"), "Context Lens must export and open its JSON directly")
        #expect(!lens.contains("FoundationModels"), "Opening Context Lens must never invoke a model")
        #expect(!lens.contains("FolderPlugin"), "Context Lens must not branch for folder sources")
        #expect(!lens.contains("KontextPlugin"), "Context Lens must not branch for Kontext sources")
        #expect(
            settings.components(separatedBy: "Open Context Lens").count == 2,
            "Settings should add exactly one Context Lens command and no new inspection UI"
        )
    }

    @Test func onboardingRetirementDependsOnAnyUsableRealSource() throws {
        let source = try readSource("Sources/embers/Model/ContextIndexController.swift")

        #expect(!source.contains("hasKontextSnapshot"), "Sample retirement must not name one provider")
        #expect(
            !source.contains("pluginID == KontextPlugin.identifier"),
            "Any newly usable real source must retire onboarding, not only Kontext"
        )
        #expect(source.contains("isUsingSampleVault"), "Sample retirement must remain gated to onboarding")
        #expect(source.contains("snapshot != nil"), "A provider must publish usable evidence before it retires onboarding")
        #expect(source.contains("forgetFolder"), "Retiring onboarding must remove the managed sample source and its cache")
    }

    @Test func rootArtifactVisibilityIsDeclaredByEachProvider() throws {
        let contracts = try readSource("Sources/EmbersPluginKit/PluginContracts.swift")
        let controller = try readSource("Sources/embers/Model/ContextIndexController.swift")
        let declaration = "presentsUnassignedArtifactsAtRoot"

        #expect(
            contracts.contains(declaration),
            "Plugin source descriptors need an explicit \(declaration) declaration"
        )
        #expect(
            controller.contains(declaration),
            "Root artifact composition must read \(declaration) from source descriptors"
        )
        #expect(
            !controller.contains("ownedByPluginID: KontextPlugin.identifier"),
            "Root artifacts must not be restricted to Kontext in app code"
        )
    }

    @Test func genericRemovalTargetsOneExactSourceAndOneCleanupScope() throws {
        let controller = try readSource("Sources/embers/Model/ContextIndexController.swift")
        let start = try #require(controller.range(of: "func remove(_ sourceID: PluginSourceIdentifier) async"))
        let tail = controller[start.lowerBound...]
        let end = try #require(tail.range(of: "\n    /// Forgetting a folder"))
        let removal = String(tail[..<end.lowerBound])

        #expect(
            removal.contains("pluginHost.removeSource(sourceID)"),
            "A source-card removal must call the host's exact-source lifecycle API"
        )
        #expect(
            !removal.contains("removeSources(for: provider.id)"),
            "Removing one source must never widen into deleting every source from its provider"
        )
        #expect(
            removal.contains("onRemoveSource?(sourceID.rawValue)"),
            "App-owned baseline and voice cleanup must receive only the exact removed source identity"
        )
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftSources(under relativePath: String) throws -> [URL] {
        let root = repositoryRoot().appendingPathComponent(relativePath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func relativePaths(_ files: [URL]) -> String {
        files.map(relativePath).sorted().joined(separator: ", ")
    }

    private func relativePath(_ file: URL) -> String {
        let prefix = repositoryRoot().path + "/"
        return file.path.hasPrefix(prefix) ? String(file.path.dropFirst(prefix.count)) : file.path
    }

    private func repositoryRoot() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        preconditionFailure("Could not locate Package.swift from \(#filePath)")
    }
}
