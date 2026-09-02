import EmbersCore
import EmbersLocal
import EmbersPluginHost
import EmbersPluginKit
import Foundation
import XCTest

@testable import embers

/// Characterizes the user-visible voice seam across graph publication, cumulative speech,
/// routing, peek presentation, and guarded opening. Apple recognition and window activation
/// remain signed-app tests; this suite drives the same transcript callback they feed.
@MainActor
final class AppStateVoiceJourneyTests: XCTestCase {
    func testSoleOpenKeywordIsDisabledByDefault() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState()
        try await fixture.waitForContext(in: app.context)
        let utteranceID = UUID()

        app.speech.onTranscript?(.init(text: "show me Apollo", isFinal: false, utteranceID: utteranceID))
        let surfaced = try await waitForSolePeek(in: app.peeks)

        app.speech.onTranscript?(.init(
            text: "show me Apollo, open",
            isFinal: true,
            utteranceID: utteranceID
        ))

        XCTAssertEqual(app.notch.state, .closed)
        XCTAssertEqual(app.peeks.peeks.map(\.id), [surfaced.id])
    }

    func testEnabledSoleOpenKeywordOpensTheExactContext() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState(
            featureFlags: AppFeatureFlags(voiceOpenSinglePeek: true)
        )
        try await fixture.waitForContext(in: app.context)
        let utteranceID = UUID()

        app.speech.onTranscript?(.init(text: "show me Apollo", isFinal: false, utteranceID: utteranceID))
        let surfaced = try await waitForSolePeek(in: app.peeks)

        app.speech.onTranscript?(.init(
            text: "show me Apollo, open",
            isFinal: true,
            utteranceID: utteranceID
        ))

        XCTAssertEqual(app.notch.state, .open)
        guard case .node(let nodeID) = surfaced.target.ref else {
            return XCTFail("The folder anchor must route to a node.")
        }
        XCTAssertEqual(app.notch.focus, .entity(nodeID))
    }

    func testStablePartialOpenFailsClosedWhenTheCandidateChangesBeforeExecution() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState(
            featureFlags: AppFeatureFlags(voiceOpenSinglePeek: true)
        )
        try await fixture.waitForContext(in: app.context)
        let utteranceID = UUID()

        app.speech.onTranscript?(.init(text: "Apollo", isFinal: false, utteranceID: utteranceID))
        _ = try await waitForSolePeek(in: app.peeks)
        app.speech.onTranscript?(.init(text: "Apollo open", isFinal: false, utteranceID: utteranceID))

        app.peeks.clear()
        app.peeks.push(.init(phrase: "Journal", ref: .node("replacement"), title: "Journal"))
        try await Task.sleep(for: .milliseconds(850))

        XCTAssertEqual(app.notch.state, .closed)
        XCTAssertEqual(app.peeks.peeks.map(\.title), ["Journal"])
    }

    func testCorrectedPartialCancelsPendingOpenBeforeTheStabilityWindow() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState(
            featureFlags: AppFeatureFlags(voiceOpenSinglePeek: true)
        )
        try await fixture.waitForContext(in: app.context)
        let utteranceID = UUID()

        app.speech.onTranscript?(.init(text: "Apollo", isFinal: false, utteranceID: utteranceID))
        _ = try await waitForSolePeek(in: app.peeks)
        app.speech.onTranscript?(.init(text: "Apollo open", isFinal: false, utteranceID: utteranceID))
        app.speech.onTranscript?(.init(text: "Apollo opening", isFinal: false, utteranceID: utteranceID))
        try await Task.sleep(for: .milliseconds(850))

        XCTAssertEqual(app.notch.state, .closed)
        XCTAssertEqual(app.peeks.peeks.map(\.title), ["Apollo"])
    }

    func testAmbiguousOpenWithTwoVisiblePeeksAbstains() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState(
            featureFlags: AppFeatureFlags(voiceOpenSinglePeek: true)
        )
        try await fixture.waitForContext(in: app.context)
        app.peeks.push(.init(phrase: "Apollo", ref: .node("apollo"), title: "Apollo"))
        app.peeks.push(.init(phrase: "Journal", ref: .node("journal"), title: "Journal"))

        app.speech.onTranscript?(.init(text: "open", isFinal: true))

        XCTAssertEqual(app.notch.state, .closed)
        XCTAssertEqual(app.peeks.peeks.count, 2)
    }

    func testUnrelatedPartialPreservesTheVisiblePeekItNoLongerMentions() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState()
        try await fixture.waitForContext(in: app.context)
        let utteranceID = UUID()

        app.speech.onTranscript?(.init(text: "Apollo", isFinal: false, utteranceID: utteranceID))
        _ = try await waitForSolePeek(in: app.peeks)
        app.speech.onTranscript?(.init(
            text: "I meant something unrelated",
            isFinal: false,
            utteranceID: utteranceID
        ))

        XCTAssertEqual(app.peeks.peeks.map(\.title), ["Apollo"])
        XCTAssertEqual(app.notch.state, .closed)
    }

    func testMatchWhileNotchIsOpenNavigatesDirectlyWithoutAddingAPeek() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState()
        try await fixture.waitForContext(in: app.context)
        app.notch.open()

        app.speech.onTranscript?(.init(text: "Apollo", isFinal: false))

        XCTAssertEqual(app.notch.focus, .hybrid)
        XCTAssertTrue(app.peeks.peeks.isEmpty)
        try await waitForSelection("apollo", in: app.dash)
    }

    private func waitForSolePeek(in queue: PeekQueue) async throws -> Peek {
        for _ in 0..<100 {
            if queue.peeks.count == 1 { return queue.peeks[0] }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(queue.peeks.first, "Expected voice routing to publish one peek.")
    }

    private func waitForSelection(_ nodeID: String, in dashboard: DashboardViewModel) async throws {
        for _ in 0..<100 {
            if dashboard.selected == nodeID { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(dashboard.selected, nodeID)
    }
}

private struct AppStateVoiceFixture {
    let rootURL: URL
    let defaults: UserDefaults
    let defaultsName: String

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-app-state-voice-\(UUID().uuidString)", isDirectory: true)
        defaultsName = "embers.app-state-voice.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    @MainActor
    func makeAppState(featureFlags: AppFeatureFlags = AppFeatureFlags()) -> AppState {
        let plugin = VoiceJourneyProvider()
        let snapshotRepository = VoiceJourneyMemoryRepository()
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
        let voiceRouting = VoiceRoutingCoordinator(
            context: controller,
            speech: speech,
            notch: notch,
            peeks: peeks,
            packLifecycle: packLifecycle,
            preferences: preferences,
            featureFlags: featureFlags
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
        XCTFail("Expected the synthetic voice source to publish a ready graph.")
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class VoiceJourneyProvider: PluginSourceProviding, PluginRefreshing, DirectorySourceManaging, @unchecked Sendable {
    let descriptor = PluginDescriptor(
        id: PluginIdentifier(rawValue: "voice-journey")!,
        displayName: "Voice Journey",
        version: "1",
        capabilities: [.sourceRefresh],
        presentation: .init(),
        sourceSetup: .directoryPicker
    )

    private var source: PluginSourceDescriptor {
        PluginSourceDescriptor(
            id: .init(pluginID: descriptor.id, sourceID: "fixture"),
            displayName: "Voice Fixture",
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
        let apolloArtifact = SourceArtifact(
            id: "artifact-apollo",
            relativePath: "Projects/Apollo/Brief.md",
            mediaKind: .markdown,
            title: "Brief",
            extractedText: "Apollo project evidence.",
            modifiedAt: .distantPast,
            contentHash: "apollo-v1",
            provider: provider
        )
        let journalArtifact = SourceArtifact(
            id: "artifact-journal",
            relativePath: "Areas/Journal/Today.md",
            mediaKind: .markdown,
            title: "Today",
            extractedText: "Journal evidence.",
            modifiedAt: .distantPast,
            contentHash: "journal-v1",
            provider: provider
        )
        return .init(
            source: source,
            snapshot: ContextSnapshot(
                sourceID: source.id.rawValue,
                revision: "voice-fixture-v1",
                artifacts: [apolloArtifact, journalArtifact],
                anchors: [
                    Anchor(
                        id: "apollo",
                        canonicalName: "Apollo",
                        provenance: [.folder],
                        memberArtifactIDs: [apolloArtifact.id]
                    ),
                    Anchor(
                        id: "journal",
                        canonicalName: "Journal",
                        provenance: [.folder],
                        memberArtifactIDs: [journalArtifact.id]
                    ),
                ],
                relations: [],
                diagnostics: [],
                indexedAt: .now
            )
        )
    }
}

private actor VoiceJourneyMemoryRepository: PluginSnapshotRepository {
    private var snapshots: [PluginSourceIdentifier: ContextSnapshot] = [:]

    func load(for source: PluginSourceIdentifier) async -> ContextSnapshot? { snapshots[source] }
    func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws {
        snapshots[source] = snapshot
    }
    func remove(source: PluginSourceIdentifier) async throws { snapshots.removeValue(forKey: source) }
}
