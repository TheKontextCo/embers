import Foundation
import EmbersLocal
import XCTest
@testable import embers

@MainActor
final class VoiceRoutingPreferenceStateTests: XCTestCase {
    func testReadFailurePreservesLastGoodSummaryAndExposesError() {
        let state = VoiceRoutingPreferenceState()
        let summary = VoiceRoutingPreferenceSummary(
            sourceID: "folder:a",
            associationCount: 2,
            totalOpenCount: 3,
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        state.install(sourceSummaries: [summary.sourceID: summary])

        state.report(error: "Could not load voice learning")

        XCTAssertEqual(state.sourceSummaries, [summary.sourceID: summary])
        XCTAssertEqual(state.error, "Could not load voice learning")
        XCTAssertEqual(state.detail, "Could not load voice learning")
    }

    func testFinishingCanceledResetAlwaysClearsSpinnerWithoutDiscardingSummary() {
        let state = VoiceRoutingPreferenceState()
        let summary = VoiceRoutingPreferenceSummary(
            sourceID: "folder:a",
            associationCount: 1,
            totalOpenCount: 1,
            lastOpenedAt: nil
        )
        state.install(sourceSummaries: [summary.sourceID: summary])
        state.resetAction = {}
        state.beginReset()
        XCTAssertTrue(state.isResetting)

        state.finishReset()

        XCTAssertFalse(state.isResetting)
        XCTAssertEqual(state.sourceSummaries, [summary.sourceID: summary])
        XCTAssertTrue(state.canReset)
    }

    func testPresentationAggregatesEveryActiveSourceWithoutChoosingAProvider() {
        let state = VoiceRoutingPreferenceState()
        let first = VoiceRoutingPreferenceSummary(
            sourceID: "alpha:source:one",
            associationCount: 1,
            totalOpenCount: 2,
            lastOpenedAt: nil
        )
        let second = VoiceRoutingPreferenceSummary(
            sourceID: "beta:source:two",
            associationCount: 2,
            totalOpenCount: 3,
            lastOpenedAt: nil
        )

        state.install(sourceSummaries: [first.sourceID: first, second.sourceID: second])

        XCTAssertEqual(state.detail, "3 learned choices · 5 opens")
        XCTAssertTrue(state.canReset)
    }
}
