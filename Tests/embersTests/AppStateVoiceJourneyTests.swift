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

    func testOpenedVoicePeekCanBeRejectedOnceAndUndone() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState()
        try await fixture.waitForContext(in: app.context)

        app.speech.onTranscript?(.init(text: "Apollo", isFinal: false, utteranceID: UUID()))
        let peek = try await waitForSolePeek(in: app.peeks)
        XCTAssertNotNil(peek.routeEvidence)

        app.openPeek(peek)
        XCTAssertNotNil(app.voiceLearning.activeJourney)
        XCTAssertTrue(app.rejectActivePeekJourney())
        XCTAssertFalse(app.rejectActivePeekJourney(), "The same visible journey must be consumed only once.")
        try await waitForExclusionCount(1, in: app.voiceLearning)
        XCTAssertEqual(app.voiceLearning.notice?.message, "Not this — learned")
        XCTAssertTrue(app.peeks.peeks.isEmpty)

        app.undoVoiceRejection()
        try await waitForExclusionCount(0, in: app.voiceLearning)
        XCTAssertNil(app.voiceLearning.notice)
    }

    func testRejectedVoiceRouteStaysExcludedAfterAnOlderReloadCompletes() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let store = DelayedSnapshotVoiceLearningStore()
        let app = fixture.makeAppState(learningStore: store)
        try await fixture.waitForContext(in: app.context)
        await store.waitForFirstSnapshotToStart()

        app.speech.onTranscript?(.init(text: "Apollo", isFinal: false, utteranceID: UUID()))
        let peek = try await waitForSolePeek(in: app.peeks)
        app.openPeek(peek)
        XCTAssertTrue(app.rejectActivePeekJourney())
        try await waitForExclusionCount(1, in: app.voiceLearning)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(app.voiceLearning.snapshot.exclusions.count, 1)
        app.closeNotch(immediately: true)
        app.peeks.clear()
        app.speech.onTranscript?(.init(text: "Apollo", isFinal: false, utteranceID: UUID()))
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(app.peeks.peeks.isEmpty, "Speaking the rejected phrase again must abstain.")
    }

    func testEscapeDismissesWithoutPersistingVoiceFeedback() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState()
        try await fixture.waitForContext(in: app.context)

        app.speech.onTranscript?(.init(text: "Apollo", isFinal: false, utteranceID: UUID()))
        let peek = try await waitForSolePeek(in: app.peeks)
        app.openPeek(peek)
        try await waitForSelection("apollo", in: app.dash)
        XCTAssertNotNil(app.voiceLearning.activeJourney)

        app.handleKey(.escape)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(app.voiceLearning.activeJourney)
        XCTAssertTrue(app.voiceLearning.snapshot.exclusions.isEmpty)
        XCTAssertNil(app.voiceLearning.notice)
    }

    func testFailedPersistenceShowsErrorWithoutClaimingLearning() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState(learningStore: FailingVoiceLearningStore())
        try await fixture.waitForContext(in: app.context)

        app.speech.onTranscript?(.init(text: "Apollo", isFinal: false, utteranceID: UUID()))
        let peek = try await waitForSolePeek(in: app.peeks)
        app.openPeek(peek)
        XCTAssertTrue(app.rejectActivePeekJourney())
        try await waitForNotice("Couldn’t save voice feedback", in: app.voiceLearning)

        XCTAssertTrue(app.voiceLearning.snapshot.exclusions.isEmpty)
        XCTAssertFalse(try XCTUnwrap(app.voiceLearning.notice).canUndo)
    }

    func testSourceScopedResetProvidesDurableRecoveryIndependentOfNoticeUndo() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState()
        try await fixture.waitForContext(in: app.context)

        app.speech.onTranscript?(.init(text: "Apollo", isFinal: false, utteranceID: UUID()))
        let peek = try await waitForSolePeek(in: app.peeks)
        let sourceID = try XCTUnwrap(peek.routeEvidence?.exclusionKey.sourceID)
        app.openPeek(peek)
        XCTAssertTrue(app.rejectActivePeekJourney())
        try await waitForExclusionCount(1, in: app.voiceLearning)
        XCTAssertTrue(app.voiceLearning.canReset(sourceID: sourceID))

        app.voiceLearning.reset(sourceID: sourceID)
        try await waitForExclusionCount(0, in: app.voiceLearning)
        try await waitForNotice("Voice feedback reset", in: app.voiceLearning)

        XCTAssertFalse(app.voiceLearning.canReset(sourceID: sourceID))
        XCTAssertFalse(try XCTUnwrap(app.voiceLearning.notice).canUndo)
    }

    func testManualContextOpenCannotCreateNegativeVoiceLearning() async throws {
        let fixture = try AppStateVoiceFixture()
        defer { fixture.cleanUp() }
        let app = fixture.makeAppState()
        try await fixture.waitForContext(in: app.context)

        app.openMatch(.init(phrase: "Apollo", ref: .node("apollo"), title: "Apollo"))

        XCTAssertNil(app.voiceLearning.activeJourney)
        XCTAssertFalse(app.rejectActivePeekJourney())
        XCTAssertTrue(app.voiceLearning.snapshot.exclusions.isEmpty)
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

    private func waitForExclusionCount(
        _ count: Int,
        in learning: VoiceLearningCoordinator
    ) async throws {
        for _ in 0..<100 {
            if learning.snapshot.exclusions.count == count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(learning.snapshot.exclusions.count, count)
    }

    private func waitForNotice(
        _ message: String,
        in learning: VoiceLearningCoordinator
    ) async throws {
        for _ in 0..<100 {
            if learning.notice?.message == message { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(learning.notice?.message, message)
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
    func makeAppState(
        featureFlags: AppFeatureFlags = AppFeatureFlags(),
        learningStore: (any VoiceLearningStoring)? = nil
    ) -> AppState {
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
        let resolvedLearningStore: any VoiceLearningStoring
        if let learningStore {
            resolvedLearningStore = learningStore
        } else {
            resolvedLearningStore = VoiceLearningStore(
                fileURL: rootURL.appendingPathComponent("voice-learning.json")
            )
        }
        let voiceLearning = VoiceLearningCoordinator(store: resolvedLearningStore)
        let voiceRouting = VoiceRoutingCoordinator(
            context: controller,
            speech: speech,
            notch: notch,
            peeks: peeks,
            packLifecycle: packLifecycle,
            preferences: preferences,
            learning: voiceLearning,
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

private actor DelayedSnapshotVoiceLearningStore: VoiceLearningStoring {
    private var exclusions: [VoiceRouteExclusionKey: VoiceRouteExclusion] = [:]
    private var snapshotCallCount = 0
    private var firstSnapshotStarted = false

    func waitForFirstSnapshotToStart() async {
        while !firstSnapshotStarted { await Task.yield() }
    }

    func snapshot(sourceIDs: Set<String>) async throws -> VoiceLearningSnapshot {
        snapshotCallCount += 1
        let call = snapshotCallCount
        let captured = exclusions.filter { sourceIDs.contains($0.key.sourceID) }
        if call == 1 {
            firstSnapshotStarted = true
            try? await Task.sleep(for: .milliseconds(240))
        } else {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return VoiceLearningSnapshot(sourceIDs: sourceIDs, exclusions: captured)
    }

    func recordExclusion(
        _ key: VoiceRouteExclusionKey,
        at date: Date,
        sourceGeneration: UInt64
    ) async throws -> VoiceLearningSnapshot {
        exclusions[key] = .init(key: key, rejectedAt: date)
        return .init(sourceIDs: [key.sourceID], exclusions: exclusions)
    }

    func removeExclusion(
        _ key: VoiceRouteExclusionKey,
        sourceGeneration: UInt64
    ) async throws -> VoiceLearningSnapshot {
        exclusions[key] = nil
        return .init(sourceIDs: [key.sourceID], exclusions: exclusions)
    }

    func delete(sourceID: String, sourceGeneration: UInt64) async throws {
        exclusions = exclusions.filter { $0.key.sourceID != sourceID }
    }
}

private actor FailingVoiceLearningStore: VoiceLearningStoring {
    enum Failure: Error { case save }

    func snapshot(sourceIDs: Set<String>) async throws -> VoiceLearningSnapshot {
        .init(sourceIDs: sourceIDs, exclusions: [:])
    }

    func recordExclusion(
        _ key: VoiceRouteExclusionKey,
        at date: Date,
        sourceGeneration: UInt64
    ) async throws -> VoiceLearningSnapshot {
        throw Failure.save
    }

    func removeExclusion(
        _ key: VoiceRouteExclusionKey,
        sourceGeneration: UInt64
    ) async throws -> VoiceLearningSnapshot {
        throw Failure.save
    }

    func delete(sourceID: String, sourceGeneration: UInt64) async throws {
        throw Failure.save
    }
}
