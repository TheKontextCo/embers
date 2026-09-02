import Combine
import EmbersCore
import EmbersLocal
import EmbersPluginHost
import EmbersPluginKit
import Foundation
import XCTest

@testable import embers

@MainActor
final class DirectorySourceRoutingTests: XCTestCase {
    func testDescriptorDeclaredDirectorySetupAndRemovalRouteByProviderIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-directory-routing-\(UUID().uuidString)", isDirectory: true)
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultsName = "embers.directory-routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let alpha = RecordingDirectoryProvider(id: "alpha-directory")
        let beta = RecordingDirectoryProvider(id: "beta-directory")
        let peer = beta.seedSource(sourceID: "peer")
        let host = try PluginHost(
            plugins: [alpha, beta],
            repository: DirectoryMemoryRepository()
        )
        let registry = ProviderRegistry(
            host: host,
            directorySourceManagers: [alpha, beta],
            defaultDirectoryProviderID: alpha.descriptor.id
        )
        let controller = ContextIndexController(
            repository: JSONSnapshotRepository(fileURL: root.appendingPathComponent("legacy.json")),
            configurations: SourceConfigurationStore(defaults: defaults),
            defaults: defaults,
            recentAccesses: UserDefaultsRecentAccess(defaults),
            providerRegistry: registry,
            providerLifecycle: ProviderLifecycleCoordinator(host: host)
        )
        var providerPhases: [ProviderActivityPhase] = []
        var indexingStates: [IndexingState] = []
        let activityObservation = controller.$providerActivity.sink { activity in
            if let phase = activity[beta.descriptor.id]?.phase {
                providerPhases.append(phase)
            }
        }
        let stateObservation = controller.$state.sink { indexingStates.append($0) }
        defer {
            activityObservation.cancel()
            stateObservation.cancel()
        }

        try await controller.chooseDirectory(selected, for: beta.descriptor.id)

        XCTAssertTrue(providerPhases.contains(.indexing), "Selecting a new folder must retain the one foreground indexing experience.")
        XCTAssertNil(alpha.lastConfiguredSource)
        let configured = try XCTUnwrap(beta.lastConfiguredSource)
        XCTAssertEqual(configured.id.pluginID, beta.descriptor.id)
        XCTAssertEqual(Set(controller.contextSources.map(\.descriptor.id)), [peer.id, configured.id])

        providerPhases.removeAll()
        indexingStates.removeAll()
        await controller.reindex(presentation: .silent)

        XCTAssertFalse(providerPhases.contains(.indexing), "A background refresh must not present provider indexing.")
        XCTAssertFalse(indexingStates.contains(.indexing), "A background refresh must not replace the workspace with indexing.")
        XCTAssertNil(controller.activeProviderActivity)

        await controller.remove(configured.id)

        XCTAssertEqual(beta.removedSourceIDs, [configured.id])
        XCTAssertEqual(controller.contextSources.map(\.descriptor.id), [peer.id])
        XCTAssertEqual(beta.sourceIDs, [peer.id])
        XCTAssertNil(alpha.lastConfiguredSource)
    }
}

private final class RecordingDirectoryProvider: PluginSourceProviding, PluginRefreshing, DirectorySourceManaging, @unchecked Sendable {
    let descriptor: PluginDescriptor
    private let lock = NSLock()
    private var configuredSources: [PluginSourceIdentifier: PluginSourceDescriptor] = [:]
    private var configurationHistory: [PluginSourceDescriptor] = []
    private var removals: [PluginSourceIdentifier] = []

    init(id: String) {
        descriptor = .init(
            id: PluginIdentifier(rawValue: id)!,
            displayName: id,
            version: "1",
            capabilities: [.sourceRefresh],
            presentation: .init(),
            sourceSetup: .directoryPicker
        )
    }

    var lastConfiguredSource: PluginSourceDescriptor? {
        lock.withLock { configurationHistory.last }
    }

    var sourceIDs: [PluginSourceIdentifier] {
        lock.withLock { configuredSources.keys.sorted { $0.rawValue < $1.rawValue } }
    }

    var removedSourceIDs: [PluginSourceIdentifier] {
        lock.withLock { removals }
    }

    func configure(source descriptor: PluginSourceDescriptor, rootURL: URL) {
        precondition(descriptor.id.pluginID == self.descriptor.id)
        lock.withLock {
            configuredSources[descriptor.id] = descriptor
            configurationHistory.append(descriptor)
        }
    }

    func seedSource(sourceID: String) -> PluginSourceDescriptor {
        let source = PluginSourceDescriptor(
            id: .init(pluginID: descriptor.id, sourceID: sourceID),
            displayName: sourceID,
            kind: "synthetic"
        )
        lock.withLock { configuredSources[source.id] = source }
        return source
    }

    func remove(sourceID: PluginSourceIdentifier) {
        lock.withLock {
            removals.append(sourceID)
            configuredSources.removeValue(forKey: sourceID)
        }
    }

    func sources() async throws -> [PluginSourceDescriptor] {
        lock.withLock { configuredSources.values.sorted { $0.id.rawValue < $1.id.rawValue } }
    }

    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        .init(
            source: source,
            snapshot: ContextSnapshot(
                sourceID: source.id.rawValue,
                revision: "revision-\(source.id.rawValue)",
                artifacts: [],
                anchors: [],
                relations: [],
                diagnostics: [],
                indexedAt: .now
            )
        )
    }
}

private actor DirectoryMemoryRepository: PluginSnapshotRepository {
    private var snapshots: [PluginSourceIdentifier: ContextSnapshot] = [:]

    func load(for source: PluginSourceIdentifier) async -> ContextSnapshot? { snapshots[source] }
    func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws { snapshots[source] = snapshot }
    func remove(source: PluginSourceIdentifier) async throws { snapshots.removeValue(forKey: source) }
}
