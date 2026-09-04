import EmbersCore
import EmbersLocal
import EmbersPluginHost
import EmbersPluginKit
import Combine
import Foundation
import XCTest

@testable import embers

@MainActor
final class AppStateMultiPeekBaselineTests: XCTestCase {
    func testTitleFragmentsAccumulateThreePeeksWithoutTransientRemoval() async throws {
        let titles = ["San Francisco Trip", "Building a Second Brain", "No Local Model Required"]
        for texts in [["san francisco", "second brain", "local model"],
                      ["san francisco", "san francisco second brain", "san francisco second brain local model"]] {
            let utteranceID = UUID()
            try await assertStablePeekAccumulation(texts.enumerated().map { index, text in
                .init(text: text, utteranceID: utteranceID, expectedTitles: Set(titles.prefix(index + 1)))
            }, titles: titles)
        }
    }

    func testSharedTitleFragmentShowsThreePeeksTogether() async throws {
        let titles = ["America Trip", "America Notes", "America Photos"]
        try await assertStablePeekAccumulation([
            .init(text: "america", utteranceID: UUID(), expectedTitles: Set(titles)),
        ], titles: titles)
    }

    func testReplacementPartialsLeaveThreeProjectPeeksVisible() async throws {
        let utteranceID = UUID()
        try await assertStablePeekAccumulation([
            .init(text: "Kontext", utteranceID: utteranceID, expectedTitles: ["Kontext"]),
            .init(text: "Skippy", utteranceID: utteranceID, expectedTitles: ["Kontext", "Skippy"]),
            .init(text: "Apollo", utteranceID: utteranceID, expectedTitles: ["Kontext", "Skippy", "Apollo"]),
        ])
    }

    func testCumulativePartialsLeaveThreeProjectPeeksVisible() async throws {
        let utteranceID = UUID()
        try await assertStablePeekAccumulation([
            .init(text: "Kontext", utteranceID: utteranceID, expectedTitles: ["Kontext"]),
            .init(text: "Kontext Skippy", utteranceID: utteranceID, expectedTitles: ["Kontext", "Skippy"]),
            .init(text: "Kontext Skippy Apollo", utteranceID: utteranceID, expectedTitles: ["Kontext", "Skippy", "Apollo"]),
        ])
    }

    func testNoMatchPartialsNeverRemoveEarlierProjectPeeks() async throws {
        let utteranceID = UUID()
        try await assertStablePeekAccumulation([
            .init(text: "Kontext", utteranceID: utteranceID, expectedTitles: ["Kontext"]),
            .init(text: "something unrelated", utteranceID: utteranceID, expectedTitles: ["Kontext"]),
            .init(text: "Skippy", utteranceID: utteranceID, expectedTitles: ["Kontext", "Skippy"]),
            .init(text: "", utteranceID: utteranceID, expectedTitles: ["Kontext", "Skippy"]),
            .init(text: "Apollo", utteranceID: utteranceID, expectedTitles: ["Kontext", "Skippy", "Apollo"]),
        ])
    }

    func testSeparateUtterancesLeaveThreeProjectPeeksVisible() async throws {
        try await assertStablePeekAccumulation([
            .init(text: "Kontext", utteranceID: UUID(), expectedTitles: ["Kontext"]),
            .init(text: "Skippy", utteranceID: UUID(), expectedTitles: ["Kontext", "Skippy"]),
            .init(text: "Apollo", utteranceID: UUID(), expectedTitles: ["Kontext", "Skippy", "Apollo"]),
        ])
    }

    private func assertStablePeekAccumulation(
        _ steps: [MultiPeekTranscriptStep],
        titles: [String] = ["Kontext", "Skippy", "Apollo"],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try MultiPeekAppStateFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState(titles: titles)
        try await fixture.waitForContext(in: app.context)
        var publications: [Set<String>] = []
        let observation = app.peeks.$peeks.sink { peeks in
            publications.append(Set(peeks.map(\.title)))
        }
        defer { observation.cancel() }

        for step in steps {
            app.speech.onTranscript?(.init(
                text: step.text,
                isFinal: false,
                utteranceID: step.utteranceID
            ))

            XCTAssertEqual(
                Set(app.peeks.peeks.map(\.title)),
                step.expectedTitles,
                "Unexpected visible peeks after transcript: \(step.text)",
                file: file,
                line: line
            )
            XCTAssertEqual(app.notch.state, .closed, file: file, line: line)
        }

        for (previous, current) in zip(publications, publications.dropFirst()) {
            XCTAssertTrue(
                previous.isSubset(of: current),
                "Peek publication removed \(previous.subtracting(current)) before the next project was presented.",
                file: file,
                line: line
            )
        }
    }
}

private struct MultiPeekTranscriptStep {
    let text: String
    let utteranceID: UUID
    let expectedTitles: Set<String>
}

private struct MultiPeekAppStateFixture {
    let rootURL: URL
    let defaults: UserDefaults
    let defaultsName: String

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-multi-peek-baseline-\(UUID().uuidString)", isDirectory: true)
        defaultsName = "embers.multi-peek-baseline.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    @MainActor
    func makeAppState(titles: [String]) -> AppState {
        let plugin = MultiPeekSyntheticProvider(titles: titles)
        let snapshotRepository = MultiPeekMemoryRepository()
        let host = try! PluginHost(plugins: [plugin], repository: snapshotRepository)
        let registry = ProviderRegistry(
            host: host,
            directorySourceManagers: [plugin],
            defaultDirectoryProviderID: plugin.descriptor.id
        )
        let controller = ContextIndexController(
            repository: JSONSnapshotRepository(fileURL: rootURL.appendingPathComponent("legacy.json")),
            configurations: SourceConfigurationStore(defaults: defaults),
            defaults: defaults,
            recentAccesses: UserDefaultsRecentAccess(defaults),
            providerRegistry: registry,
            providerLifecycle: ProviderLifecycleCoordinator(host: host)
        )
        let speech = SpeechListener()
        let notch = NotchViewModel()
        let peeks = PeekQueue()
        let packLifecycle = VoiceRoutingPackCoordinator(
            store: VoiceRoutingStore(fileURL: rootURL.appendingPathComponent("voice-routing.json"))
        )
        let preferences = VoiceRoutingPreferenceCoordinator(
            store: VoiceRoutingPreferenceStore(
                fileURL: rootURL.appendingPathComponent("voice-preferences.json")
            )
        )
        let voiceLearning = VoiceLearningCoordinator(
            store: VoiceLearningStore(
                fileURL: rootURL.appendingPathComponent("voice-learning.json")
            )
        )
        let voiceRouting = VoiceRoutingCoordinator(
            context: controller,
            speech: speech,
            notch: notch,
            peeks: peeks,
            packLifecycle: packLifecycle,
            preferences: preferences,
            learning: voiceLearning
        )
        let changeBaselines = UserDefaultsChangeBaselineStore(
            defaults,
            storageKey: "test.changed-since-last-peek"
        )
        let navigation = DashboardNavigationCoordinator(
            context: controller,
            speech: speech,
            changeBaselines: changeBaselines
        )
        return AppState(
            context: controller,
            speech: speech,
            notch: notch,
            peeks: peeks,
            voiceRouting: voiceRouting,
            voiceLearning: voiceLearning,
            dashboardNavigation: navigation,
            taskMutations: DashboardTaskMutationCoordinator(context: controller, navigation: navigation),
            changeBaselines: changeBaselines
        )
    }

    @MainActor
    func waitForContext(in controller: ContextIndexController) async throws {
        for _ in 0..<100 {
            if controller.graphSearch != nil, controller.state == .ready { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected the synthetic source to publish a ready graph.")
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class MultiPeekSyntheticProvider: PluginSourceProviding, PluginRefreshing, DirectorySourceManaging, @unchecked Sendable {
    let titles: [String]

    init(titles: [String]) { self.titles = titles }

    let descriptor = PluginDescriptor(
        id: PluginIdentifier(rawValue: "multi-peek-baseline")!,
        displayName: "Multi-Peek Baseline",
        version: "1",
        capabilities: [.sourceRefresh],
        presentation: .init(),
        sourceSetup: .directoryPicker
    )

    private var source: PluginSourceDescriptor {
        PluginSourceDescriptor(
            id: .init(pluginID: descriptor.id, sourceID: "fixture"),
            displayName: "Synthetic Projects",
            kind: "synthetic"
        )
    }

    func configure(source: PluginSourceDescriptor, rootURL: URL) {}
    func remove(sourceID: PluginSourceIdentifier) {}
    func sources() async throws -> [PluginSourceDescriptor] { [source] }

    func refresh(_ source: PluginSourceDescriptor) async throws -> PluginRefreshResult {
        let provider = ArtifactProviderReference(
            pluginID: descriptor.id.rawValue,
            sourceID: source.id.rawValue
        )
        let projects = titles.enumerated().map { (id: String($0.offset), title: $0.element) }
        let artifacts = projects.map { project in
            SourceArtifact(
                id: "artifact-\(project.id)",
                relativePath: "Projects/\(project.title)/Brief.md",
                mediaKind: .markdown,
                title: "Brief",
                extractedText: "Synthetic evidence for \(project.title).",
                modifiedAt: .distantPast,
                contentHash: "\(project.id)-v1",
                provider: provider
            )
        }
        let anchors = projects.map { project in
            Anchor(
                id: project.id,
                canonicalName: project.title,
                provenance: [.folder],
                memberArtifactIDs: ["artifact-\(project.id)"]
            )
        }
        return .init(
            source: source,
            snapshot: ContextSnapshot(
                sourceID: source.id.rawValue,
                revision: "multi-peek-baseline-v1",
                artifacts: artifacts,
                anchors: anchors,
                relations: [],
                diagnostics: [],
                indexedAt: .now
            )
        )
    }
}

private actor MultiPeekMemoryRepository: PluginSnapshotRepository {
    private var snapshots: [PluginSourceIdentifier: ContextSnapshot] = [:]

    func load(for source: PluginSourceIdentifier) async -> ContextSnapshot? { snapshots[source] }

    func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws {
        snapshots[source] = snapshot
    }

    func remove(source: PluginSourceIdentifier) async throws {
        snapshots.removeValue(forKey: source)
    }
}
