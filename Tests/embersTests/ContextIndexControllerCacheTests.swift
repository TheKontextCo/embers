import XCTest
import EmbersCore
import EmbersLocal
import EmbersPluginHost
import FolderPlugin
@testable import embers

@MainActor
final class ContextIndexControllerCacheTests: XCTestCase {
    private struct SyntheticDeleteFailure: Error {}
    private struct TestTimeout: Error {}

    private actor FailingDeleteRepository: ContextRepository {
        private var snapshot: ContextSnapshot?

        func load() async -> ContextSnapshot? { snapshot }
        func replace(with snapshot: ContextSnapshot) async throws { self.snapshot = snapshot }
        func delete() async throws { throw SyntheticDeleteFailure() }
    }

    func testManagedSampleVaultRecognitionUsesFilesystemIdentity() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-sample-identity-\(UUID().uuidString)", isDirectory: true)
        let canonicalRoot = parent.appendingPathComponent("Embers", isDirectory: true)
        let aliasRoot = parent.appendingPathComponent("embers-alias", isDirectory: true)
        let sample = canonicalRoot.appendingPathComponent("SampleVault-v4", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        try FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: canonicalRoot)

        XCTAssertTrue(
            ManagedSampleVaultPath.matches(
                aliasRoot.appendingPathComponent("SampleVault-v4", isDirectory: true),
                root: canonicalRoot
            )
        )
        XCTAssertFalse(
            ManagedSampleVaultPath.matches(
                aliasRoot.appendingPathComponent("Other", isDirectory: true),
                root: canonicalRoot
            )
        )
    }

    func testExplicitSampleCreationReplacesCompletedTasksWithBundledOpenTasks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-sample-reset-\(UUID().uuidString)", isDirectory: true)
        let bundled = root.appendingPathComponent("BundledSample", isDirectory: true)
        let managed = root.appendingPathComponent("SampleVault-v7", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data("# Demo\n- [ ] Try Embers\n".utf8)
            .write(to: bundled.appendingPathComponent("Demo.md"))
        try Data("# Demo\n- [x] Try Embers\n".utf8)
            .write(to: managed.appendingPathComponent("Demo.md"))
        try Data("old state".utf8).write(to: managed.appendingPathComponent("Stale.md"))

        try ManagedSampleVaultInstaller.prepare(
            bundled: bundled,
            managed: managed,
            replacingExisting: true
        )

        XCTAssertEqual(
            try String(contentsOf: managed.appendingPathComponent("Demo.md"), encoding: .utf8),
            "# Demo\n- [ ] Try Embers\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed.appendingPathComponent("Stale.md").path))
    }

    func testSampleRestorationOnLaunchPreservesExistingTaskState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-sample-preserve-\(UUID().uuidString)", isDirectory: true)
        let bundled = root.appendingPathComponent("BundledSample", isDirectory: true)
        let managed = root.appendingPathComponent("SampleVault-v7", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try Data("# Demo\n- [ ] Try Embers\n".utf8)
            .write(to: bundled.appendingPathComponent("Demo.md"))
        try Data("# Demo\n- [x] Try Embers\n".utf8)
            .write(to: managed.appendingPathComponent("Demo.md"))

        try ManagedSampleVaultInstaller.prepare(
            bundled: bundled,
            managed: managed,
            replacingExisting: false
        )

        XCTAssertEqual(
            try String(contentsOf: managed.appendingPathComponent("Demo.md"), encoding: .utf8),
            "# Demo\n- [x] Try Embers\n"
        )
    }

    func testBootstrapDoesNotPresentOrRetainLegacyComposedSnapshotForCurrentFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("embers-controller-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("current", isDirectory: true)
        let legacyURL = root.appendingPathComponent("context-snapshot.json")
        let pluginCacheURL = root.appendingPathComponent("plugin-snapshots", isDirectory: true)
        let defaultsName = "embers-controller-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# Current\nThe current folder has the only valid content.".utf8)
            .write(to: folder.appendingPathComponent("current.md"))

        let configurations = SourceConfigurationStore(defaults: defaults)
        _ = try configurations.save(url: folder, sourceType: "Folder")
        let legacy = JSONSnapshotRepository(fileURL: legacyURL)
        try await legacy.replace(with: ContextSnapshot(
            sourceID: PluginHost.workspaceSourceID,
            revision: "legacy",
            artifacts: [artifact(id: "old", text: "The removed folder must not reappear.")],
            anchors: [],
            relations: [],
            diagnostics: [],
            indexedAt: .distantPast
        ))
        let pluginSnapshots = JSONPluginSnapshotRepository(directoryURL: pluginCacheURL)
        let registry = try ProviderRegistry(builder: .init(), repository: pluginSnapshots)
        let controller = ContextIndexController(
            repository: legacy,
            configurations: configurations,
            defaults: defaults,
            recentAccesses: UserDefaultsRecentAccess(defaults),
            providerRegistry: registry,
            providerLifecycle: ProviderLifecycleCoordinator(host: registry.host)
        )

        await controller.bootstrap()

        let retainedLegacy = await legacy.load()
        XCTAssertNil(retainedLegacy)
        XCTAssertEqual(controller.snapshot?.artifacts.map(\.title), ["Current"])
        XCTAssertFalse(controller.snapshot?.artifacts.contains(where: { $0.id == "old" }) ?? true)
    }

    func testSwitchingToUnavailableFolderDoesNotLeavePreviousFolderVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("embers-controller-switch-\(UUID().uuidString)", isDirectory: true)
        let oldFolder = root.appendingPathComponent("old", isDirectory: true)
        let unavailableFolder = root.appendingPathComponent("missing", isDirectory: true)
        let defaultsName = "embers-controller-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try Data("# Old\nThis folder will be removed.".utf8).write(to: oldFolder.appendingPathComponent("old.md"))
        let pluginSnapshots = JSONPluginSnapshotRepository(
            directoryURL: root.appendingPathComponent("plugin-snapshots", isDirectory: true)
        )
        let registry = try ProviderRegistry(builder: .init(), repository: pluginSnapshots)
        let controller = ContextIndexController(
            repository: JSONSnapshotRepository(fileURL: root.appendingPathComponent("context-snapshot.json")),
            configurations: .init(defaults: defaults),
            defaults: defaults,
            recentAccesses: UserDefaultsRecentAccess(defaults),
            providerRegistry: registry,
            providerLifecycle: ProviderLifecycleCoordinator(host: registry.host)
        )

        try await controller.chooseFolder(oldFolder)
        XCTAssertEqual(controller.snapshot?.artifacts.map(\.title), ["Old"])
        do {
            try await controller.chooseFolder(unavailableFolder)
            XCTFail("Choosing a missing folder should fail.")
        } catch {}

        XCTAssertNil(controller.snapshot)
        guard case .failed = controller.state else {
            return XCTFail("Expected the unavailable replacement to be visible as a failure.")
        }
    }

    func testForgetClearsFolderIdentityAndPresentationWhenSecondaryCacheDeletionFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("embers-controller-forget-failure-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let defaultsName = "embers-controller-forget-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("# Private\nThis content must disappear even when cleanup fails.".utf8)
            .write(to: folder.appendingPathComponent("private.md"))

        let configurations = SourceConfigurationStore(defaults: defaults)
        let pluginSnapshots = JSONPluginSnapshotRepository(
            directoryURL: root.appendingPathComponent("plugin-snapshots", isDirectory: true)
        )
        let registry = try ProviderRegistry(builder: .init(), repository: pluginSnapshots)
        let controller = ContextIndexController(
            repository: FailingDeleteRepository(),
            configurations: configurations,
            defaults: defaults,
            recentAccesses: UserDefaultsRecentAccess(defaults),
            providerRegistry: registry,
            providerLifecycle: ProviderLifecycleCoordinator(host: registry.host)
        )
        try await controller.chooseFolder(folder)
        XCTAssertNotNil(controller.snapshot)

        await controller.forgetFolder()

        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.sourceConfiguration)
        XCTAssertNil(configurations.loadConfiguration())
        XCTAssertFalse(controller.contextSources.contains { $0.descriptor.id.pluginID == FolderPlugin.identifier })
        guard case .failed = controller.state else {
            return XCTFail("Expected the incomplete secondary cache cleanup to remain visible.")
        }
    }

    func testSwitchRetiresOldFolderBeforeSecondaryCacheDeletionFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("embers-controller-switch-cache-failure-\(UUID().uuidString)", isDirectory: true)
        let oldFolder = root.appendingPathComponent("old", isDirectory: true)
        let replacement = root.appendingPathComponent("replacement", isDirectory: true)
        let defaultsName = "embers-controller-switch-cache-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("# Old\nPrivate old content.".utf8).write(to: oldFolder.appendingPathComponent("old.md"))
        try Data("# New\nReplacement content.".utf8).write(to: replacement.appendingPathComponent("new.md"))

        let configurations = SourceConfigurationStore(defaults: defaults)
        let pluginSnapshots = JSONPluginSnapshotRepository(
            directoryURL: root.appendingPathComponent("plugin-snapshots", isDirectory: true)
        )
        let registry = try ProviderRegistry(builder: .init(), repository: pluginSnapshots)
        let controller = ContextIndexController(
            repository: FailingDeleteRepository(),
            configurations: configurations,
            defaults: defaults,
            recentAccesses: UserDefaultsRecentAccess(defaults),
            providerRegistry: registry,
            providerLifecycle: ProviderLifecycleCoordinator(host: registry.host)
        )
        try await controller.chooseFolder(oldFolder)

        do {
            try await controller.chooseFolder(replacement)
            XCTFail("Expected secondary cache cleanup to fail.")
        } catch {}

        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.sourceConfiguration)
        XCTAssertNil(configurations.loadConfiguration())
        XCTAssertFalse(controller.contextSources.contains { $0.descriptor.id.pluginID == FolderPlugin.identifier })
    }

    func testChooseSwitchForgetFlowNeverPresentsRetiredFolderContent() async throws {
        let fixture = try makeFixture(name: "lifecycle")
        defer { fixture.cleanUp() }
        let firstFolder = fixture.root.appendingPathComponent("first", isDirectory: true)
        let secondFolder = fixture.root.appendingPathComponent("second", isDirectory: true)
        try writeNote(title: "First Private", body: "Retired content.", to: firstFolder)
        try writeNote(title: "Second Current", body: "Current content.", to: secondFolder)
        let controller = try fixture.makeController()

        try await controller.chooseFolder(firstFolder)
        XCTAssertEqual(controller.snapshot?.artifacts.map(\.title), ["First Private"])
        let firstSourceID = try XCTUnwrap(controller.sourceConfiguration?.id)

        try await controller.chooseFolder(secondFolder)
        XCTAssertEqual(controller.snapshot?.artifacts.map(\.title), ["Second Current"])
        XCTAssertFalse(controller.snapshot?.artifacts.contains { $0.title == "First Private" } ?? true)
        XCTAssertNotEqual(controller.sourceConfiguration?.id, firstSourceID)

        await controller.forgetFolder()
        try await waitUntil { controller.contextSources.isEmpty }
        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.sourceConfiguration)
        XCTAssertNil(fixture.configurations.loadConfiguration())
        XCTAssertTrue(controller.contextSources.isEmpty)
        XCTAssertEqual(try cacheFileNames(in: fixture.pluginCache), [])
        guard case .unconfigured = controller.state else {
            return XCTFail("A successfully forgotten sole folder should return to unconfigured state.")
        }
    }

    func testBootstrapRestoresPersistedFolderAndReindexesItsCurrentContents() async throws {
        let fixture = try makeFixture(name: "restore")
        defer { fixture.cleanUp() }
        let folder = fixture.root.appendingPathComponent("vault", isDirectory: true)
        try writeNote(title: "Before Relaunch", body: "Initial content.", to: folder)

        let firstController = try fixture.makeController()
        try await firstController.chooseFolder(folder)
        let persistedID = try XCTUnwrap(firstController.sourceConfiguration?.id)
        try writeNote(title: "After Relaunch", body: "Updated on disk.", to: folder)

        let restoredController = try fixture.makeController()
        await restoredController.bootstrap()
        try await waitUntil {
            restoredController.contextSources.count == 1 && restoredController.state == .ready
        }

        XCTAssertEqual(restoredController.sourceConfiguration?.id, persistedID)
        XCTAssertEqual(Set(restoredController.snapshot?.artifacts.map(\.title) ?? []), ["Before Relaunch", "After Relaunch"])
        XCTAssertEqual(restoredController.contextSources.count, 1)
        guard case .ready = restoredController.state else {
            return XCTFail("A resolvable persisted folder should be ready after bootstrap.")
        }
    }

    func testRefreshFailureKeepsLastGoodFolderSnapshotVisibleAndMarksItStale() async throws {
        let fixture = try makeFixture(name: "last-good")
        defer { fixture.cleanUp() }
        let folder = fixture.root.appendingPathComponent("vault", isDirectory: true)
        try writeNote(title: "Last Good", body: "Must remain visible.", to: folder)
        let controller = try fixture.makeController()

        try await controller.chooseFolder(folder)
        let revision = try XCTUnwrap(controller.snapshot?.revision)
        try FileManager.default.removeItem(at: folder)

        await controller.reindex(presentation: .silent)

        XCTAssertEqual(controller.snapshot?.revision, revision)
        XCTAssertEqual(controller.snapshot?.artifacts.map(\.title), ["Last Good"])
        guard case .stale = controller.state else {
            return XCTFail("An unavailable configured folder should retain its last good snapshot as stale.")
        }
    }

    private func artifact(id: String, text: String) -> SourceArtifact {
        .init(id: id, relativePath: "old.md", mediaKind: .markdown, title: "old", extractedText: text, modifiedAt: .distantPast, contentHash: StableHash.hex(text), localURL: URL(fileURLWithPath: "/tmp/old.md"))
    }

    private struct Fixture {
        let root: URL
        let defaultsName: String
        let defaults: UserDefaults
        let configurations: SourceConfigurationStore
        let pluginCache: URL

        @MainActor
        func makeController() throws -> ContextIndexController {
            let snapshotRepository = JSONPluginSnapshotRepository(directoryURL: pluginCache)
            let folder = FolderPlugin()
            let host = try PluginHost(plugins: [folder], repository: snapshotRepository)
            let registry = ProviderRegistry(
                host: host,
                directorySourceManagers: [folder],
                defaultDirectoryProviderID: FolderPlugin.identifier
            )
            return ContextIndexController(
                repository: JSONSnapshotRepository(fileURL: root.appendingPathComponent("legacy.json")),
                configurations: configurations,
                defaults: defaults,
                recentAccesses: UserDefaultsRecentAccess(defaults),
                providerRegistry: registry,
                providerLifecycle: ProviderLifecycleCoordinator(host: host)
            )
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(name: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-controller-\(name)-\(UUID().uuidString)", isDirectory: true)
        let defaultsName = "embers-controller-\(name)-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        return Fixture(
            root: root,
            defaultsName: defaultsName,
            defaults: defaults,
            configurations: SourceConfigurationStore(defaults: defaults),
            pluginCache: root.appendingPathComponent("plugin-snapshots", isDirectory: true)
        )
    }

    private func writeNote(title: String, body: String, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = title.lowercased().replacingOccurrences(of: " ", with: "-") + ".md"
        try Data("# \(title)\n\(body)".utf8).write(to: folder.appendingPathComponent(fileName))
    }

    private func cacheFileNames(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw TestTimeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
