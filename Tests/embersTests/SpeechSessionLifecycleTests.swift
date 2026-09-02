import XCTest
@testable import embers

final class SpeechSessionLifecycleTests: XCTestCase {
    func testInternalReplacementPreservesListeningIntentAndInvalidatesTheOldSession() {
        var lifecycle = SpeechSessionLifecycle()
        let originalSession = lifecycle.beginUserSession()

        let replacementSession = lifecycle.beginReplacement()

        XCTAssertTrue(lifecycle.isListening)
        XCTAssertNotNil(replacementSession)
        XCTAssertFalse(lifecycle.acceptsCallback(for: originalSession))
        XCTAssertTrue(lifecycle.acceptsCallback(for: replacementSession!))
    }

    func testStaleSessionErrorCannotStopTheReplacementSession() {
        var lifecycle = SpeechSessionLifecycle()
        let staleSession = lifecycle.beginUserSession()
        let replacementSession = lifecycle.beginReplacement()!

        if lifecycle.acceptsCallback(for: staleSession) {
            lifecycle.stop()
        }

        XCTAssertTrue(lifecycle.isListening)
        XCTAssertTrue(lifecycle.acceptsCallback(for: replacementSession))
    }

    func testUserStopInvalidatesAPendingReplacement() {
        var lifecycle = SpeechSessionLifecycle()
        _ = lifecycle.beginUserSession()
        let pendingReplacement = lifecycle.beginReplacement()!

        lifecycle.stop()

        XCTAssertFalse(lifecycle.isListening)
        XCTAssertFalse(lifecycle.acceptsCallback(for: pendingReplacement))
    }

    func testReplacementIsIgnoredWhenTheUserIsNotListening() {
        var lifecycle = SpeechSessionLifecycle()

        XCTAssertNil(lifecycle.beginReplacement())
        XCTAssertFalse(lifecycle.isListening)
    }

    func testOnlyTheNewestOfSeveralReplacementSessionsCanPublish() {
        var lifecycle = SpeechSessionLifecycle()
        let original = lifecycle.beginUserSession()
        let firstReplacement = lifecycle.beginReplacement()!
        let newestReplacement = lifecycle.beginReplacement()!

        XCTAssertFalse(lifecycle.acceptsCallback(for: original))
        XCTAssertFalse(lifecycle.acceptsCallback(for: firstReplacement))
        XCTAssertTrue(lifecycle.acceptsCallback(for: newestReplacement))
        XCTAssertTrue(lifecycle.isListening)
    }

    func testStartingAgainAfterUserStopCreatesANewAcceptedSession() {
        var lifecycle = SpeechSessionLifecycle()
        let stoppedSession = lifecycle.beginUserSession()
        lifecycle.stop()

        let restartedSession = lifecycle.beginUserSession()

        XCTAssertFalse(lifecycle.acceptsCallback(for: stoppedSession))
        XCTAssertTrue(lifecycle.acceptsCallback(for: restartedSession))
        XCTAssertTrue(lifecycle.isListening)
    }
}
