import Combine
import XCTest
@testable import embers

/// Exercises the real listener's orchestration. Only OS speech/audio and elapsed time are fake.
@MainActor
final class SpeechListenerRecoveryTests: XCTestCase {
    func testCurrentSessionErrorPreservesListeningAndRecovers() async {
        let harness = makeHarness()
        await harness.start()

        harness.backend.emit(error: transientError)

        XCTAssertTrue(harness.listener.isListening, "A recognition failure must not clear user intent")
        await harness.advanceRestart()
        XCTAssertEqual(harness.backend.sessions.count, 2, "A current-session error should replace recognition")
        XCTAssertTrue(harness.listener.isListening)
    }

    func testFinalResultWithAnErrorStillRecovers() async {
        let harness = makeHarness()
        var transcripts: [SpeechTranscript] = []
        harness.listener.onTranscript = { transcripts.append($0) }
        await harness.start()

        harness.backend.emit(text: "San Francisco", isFinal: true, error: transientError)

        XCTAssertEqual(transcripts.map(\.text), ["San Francisco"])
        XCTAssertTrue(harness.listener.isListening, "An error accompanying a final result must not disable listening")
        await harness.advanceRestart()
        XCTAssertEqual(harness.backend.sessions.count, 2)
    }

    func testRecognizerTemporarilyUnavailableDuringRestartRecoversWhenAvailable() async {
        let harness = makeHarness()
        await harness.start()
        harness.backend.emit(text: "Embers", isFinal: true)
        harness.backend.available = false

        await harness.advanceRestart()

        XCTAssertTrue(harness.listener.isListening, "Temporary unavailability must preserve listening intent")
        XCTAssertEqual(harness.backend.sessions.count, 1)
        harness.backend.available = true
        await harness.advanceRestart()
        XCTAssertEqual(harness.backend.sessions.count, 2, "Recovery must try again once recognition is available")
        XCTAssertTrue(harness.listener.isListening)
    }

    func testUnavailableMicrophoneDuringVocabularyReplacementRecovers() async {
        await assertVocabularyRestartRecovers(after: .microphoneInputUnavailable)
    }

    func testAudioEngineStartFailureDuringVocabularyReplacementRecovers() async {
        await assertVocabularyRestartRecovers(after: .engineStartFailed)
    }

    func testNormalFinalResultRestartsWithoutSwitchingListeningOff() async {
        let harness = makeHarness()
        var transcripts: [SpeechTranscript] = []
        harness.listener.onTranscript = { transcripts.append($0) }
        await harness.start()
        harness.backend.emit(text: "Embers", isFinal: true)

        XCTAssertTrue(harness.listener.isListening)
        await harness.advanceRestart()
        harness.backend.emit(text: "Second Brain")

        XCTAssertTrue(harness.listener.isListening)
        XCTAssertEqual(harness.backend.sessions.count, 2)
        XCTAssertEqual(transcripts.map(\.text), ["Embers", "Second Brain"])
        XCTAssertNotEqual(transcripts.first?.utteranceID, transcripts.last?.utteranceID)
    }

    func testVocabularyReplacementUsesLatestVocabularyAndPreservesListening() async {
        let harness = makeHarness()
        await harness.start()
        harness.listener.setBaseVocabulary(["Embers", "San Francisco"])

        XCTAssertTrue(harness.listener.isListening)
        await harness.advanceRestart()

        XCTAssertEqual(harness.backend.preparedVocabularies, [[], ["Embers", "San Francisco"]])
        XCTAssertEqual(harness.backend.sessions.count, 2)
        XCTAssertTrue(harness.listener.isListening)
    }

    func testStaleErrorDuringReplacementCannotStopListening() async {
        let harness = makeHarness()
        await harness.start()
        harness.listener.setBaseVocabulary(["Embers"])

        harness.backend.emit(error: transientError, session: 0)

        XCTAssertTrue(harness.listener.isListening)
        await harness.advanceRestart()
        XCTAssertEqual(harness.backend.sessions.count, 2)
        XCTAssertTrue(harness.listener.isListening)
    }

    func testStaleResultAndErrorCannotMutateReplacementSession() async {
        let harness = makeHarness()
        var transcripts: [SpeechTranscript] = []
        harness.listener.onTranscript = { transcripts.append($0) }
        await harness.start()
        harness.listener.setBaseVocabulary(["Embers"])
        await harness.advanceRestart()

        harness.backend.emit(text: "stale", isFinal: true, error: transientError, session: 0)
        harness.backend.emit(text: "Embers", session: 1)

        XCTAssertTrue(harness.listener.isListening)
        XCTAssertEqual(transcripts.map(\.text), ["Embers"])
        await harness.settle()
        XCTAssertEqual(harness.clock.pendingCount, 0)
    }

    func testExplicitStopCancelsPendingRestartEvenIfItsDelayCompletesLater() async {
        let harness = makeHarness()
        await harness.start()
        harness.backend.emit(text: "Embers", isFinal: true)
        await harness.settle()
        XCTAssertEqual(harness.clock.pendingCount, 1)

        harness.listener.stop()
        await harness.advanceRestart()
        harness.backend.emit(error: transientError, session: 0)

        XCTAssertFalse(harness.listener.isListening)
        XCTAssertEqual(harness.backend.sessions.count, 1)
        XCTAssertEqual(harness.clock.pendingCount, 0)
    }

    func testSupersededVocabularyRestartCannotStartAnExtraSession() async {
        let harness = makeHarness()
        await harness.start()
        harness.listener.setBaseVocabulary(["Embers"])
        await harness.settle()
        harness.listener.setBaseVocabulary(["Embers", "Second Brain"])
        await harness.settle()

        await harness.advanceRestart()

        XCTAssertEqual(harness.backend.sessions.count, 2)
        XCTAssertEqual(harness.backend.preparedVocabularies.last, ["Embers", "Second Brain"])
        XCTAssertTrue(harness.listener.isListening)
    }

    func testPermissionRevocationDuringRestartStopsWithoutPromptingOrRetrying() async {
        let harness = makeHarness()
        await harness.start()
        harness.backend.emit(text: "Embers", isFinal: true)
        harness.backend.microphonePermission = .denied

        await harness.advanceRestart()

        XCTAssertFalse(harness.listener.isListening)
        XCTAssertEqual(harness.backend.sessions.count, 1)
        XCTAssertEqual(harness.backend.permissionRequests, 0)
        XCTAssertEqual(harness.clock.pendingCount, 0)
    }

    func testBackgroundStartDoesNotPromptForMissingPermissions() async {
        let harness = makeHarness()
        harness.backend.microphonePermission = .notDetermined
        harness.backend.speechPermission = .notDetermined

        await harness.listener.startIfAuthorized()

        XCTAssertFalse(harness.listener.isListening)
        XCTAssertEqual(harness.backend.permissionRequests, 0)
        XCTAssertTrue(harness.backend.sessions.isEmpty)
    }

    func testUnsupportedOnDeviceRecognitionNeverStartsASession() async {
        let harness = makeHarness()
        harness.backend.supportsOnDeviceRecognition = false

        await harness.listener.startIfAuthorized()

        XCTAssertFalse(harness.listener.isListening)
        XCTAssertTrue(harness.backend.sessions.isEmpty)
        XCTAssertEqual(harness.clock.pendingCount, 0)
    }

    func testRecoveryNeverPublishesListeningOffWhileItCanRecover() async {
        let harness = makeHarness()
        await harness.start()
        var states: [Bool] = []
        let observation = harness.listener.$isListening.sink { states.append($0) }
        defer { observation.cancel() }

        harness.backend.emit(error: transientError)
        harness.backend.nextStartFailure = .engineStartFailed
        await harness.advanceRestart()
        await harness.advanceRestart()

        XCTAssertEqual(harness.backend.sessions.count, 2)
        XCTAssertFalse(states.contains(false), "Recovery must not flash the listening indicator off")
    }

    func testRepeatedSessionFailuresExhaustABoundedBackoffEvenWhenAudioStarts() async {
        let harness = makeHarness()
        await harness.start()

        for _ in 0..<5 {
            harness.backend.emit(error: transientError)
            await harness.advanceRestart()
        }
        XCTAssertEqual(harness.backend.sessions.count, 6)
        harness.backend.emit(error: transientError)
        await harness.advanceRestart()

        XCTAssertFalse(harness.listener.isListening)
        XCTAssertEqual(harness.backend.sessions.count, 6, "Starting audio alone must not reset the failure budget")
        XCTAssertEqual(harness.clock.requestedDelays, [.milliseconds(400), .milliseconds(800), .milliseconds(1600), .milliseconds(3200), .milliseconds(6400)])
        XCTAssertEqual(harness.clock.pendingCount, 0)
    }

    func testPersistentStartFailuresAlsoExhaustRecovery() async {
        let harness = makeHarness()
        await harness.start()
        harness.backend.available = false
        harness.backend.emit(error: transientError)

        for _ in 0..<6 { await harness.advanceRestart() }

        XCTAssertFalse(harness.listener.isListening)
        XCTAssertEqual(harness.backend.sessions.count, 1)
        XCTAssertEqual(harness.clock.requestedDelays.count, 5)
        XCTAssertEqual(harness.clock.pendingCount, 0)
    }

    func testRecognizedSpeechResetsRecoveryBudget() async {
        let harness = makeHarness()
        await harness.start()
        for _ in 0..<5 {
            harness.backend.emit(error: transientError)
            await harness.advanceRestart()
        }
        harness.backend.emit(text: "Embers")
        harness.backend.emit(error: transientError)
        await harness.advanceRestart()

        XCTAssertTrue(harness.listener.isListening)
        XCTAssertEqual(harness.backend.sessions.count, 7)
        XCTAssertEqual(harness.clock.requestedDelays.last, .milliseconds(400))
    }

    func testExplicitStopDuringErrorRecoveryPreventsAnyFurtherAttempt() async {
        let harness = makeHarness()
        await harness.start()
        harness.backend.emit(error: transientError)
        await harness.settle()
        XCTAssertEqual(harness.clock.pendingCount, 1)

        harness.listener.stop()
        await harness.advanceRestart()

        XCTAssertFalse(harness.listener.isListening)
        XCTAssertEqual(harness.backend.sessions.count, 1)
        XCTAssertEqual(harness.clock.pendingCount, 0)
    }

    func testSiriServiceInterruptionDoesNotPretendDictationIsDisabled() async {
        let harness = makeHarness()
        await harness.start()
        harness.backend.emit(error: NSError(domain: "kAFAssistantErrorDomain", code: 1107,
            userInfo: [NSLocalizedDescriptionKey: "Siri dictation service interrupted"]))
        await harness.advanceRestart()

        XCTAssertTrue(harness.listener.isListening)
        XCTAssertFalse(harness.listener.needsDictation)
        XCTAssertEqual(harness.backend.sessions.count, 2)
    }

    func testDocumentedFatalErrorsStopWithoutRetries() async {
        for (domain, code) in [("kLSRErrorDomain", 201), ("kLSRErrorDomain", 102), ("kAFAssistantErrorDomain", 1700)] {
            let harness = makeHarness()
            await harness.start()
            harness.backend.emit(error: NSError(domain: domain, code: code))
            await harness.advanceRestart()

            XCTAssertFalse(harness.listener.isListening)
            XCTAssertEqual(harness.backend.sessions.count, 1)
            XCTAssertEqual(harness.backend.permissionRequests, 0)
            XCTAssertEqual(harness.clock.pendingCount, 0)
            XCTAssertEqual(harness.listener.needsDictation, code == 201)
        }
    }

    func testNoSpeechSessionEndsDoNotExhaustRecoveryBudget() async {
        let harness = makeHarness()
        await harness.start()
        for _ in 0..<8 {
            harness.backend.emit(error: NSError(domain: "kAFAssistantErrorDomain", code: 1110))
            await harness.advanceRestart()
        }

        XCTAssertTrue(harness.listener.isListening, "A quiet room is not a persistent recognition failure")
        XCTAssertEqual(harness.backend.sessions.count, 9)
    }

    func testUserCanRetryAfterEnablingDictation() async {
        let harness = makeHarness()
        await harness.start()
        harness.backend.emit(error: NSError(domain: "kLSRErrorDomain", code: 201))

        await harness.listener.startFromUserAction()

        XCTAssertTrue(harness.listener.isListening)
        XCTAssertFalse(harness.listener.needsDictation)
        XCTAssertEqual(harness.backend.sessions.count, 2)
    }

    func testVocabularyChangesCannotResetAnExhaustedRecoveryBudget() async {
        let harness = makeHarness()
        await harness.start()
        for index in 0..<5 {
            harness.backend.emit(error: transientError)
            harness.listener.setBaseVocabulary(["Project \(index)"])
            await harness.advanceRestart()
        }
        harness.backend.emit(error: transientError)
        await harness.advanceRestart()

        XCTAssertFalse(harness.listener.isListening)
        XCTAssertEqual(harness.backend.sessions.count, 6)
    }

    func testErrorDeliveredWithTranscriptCannotStopANewlyReplacedSession() async {
        let harness = makeHarness()
        await harness.start()
        harness.listener.onTranscript = { [weak listener = harness.listener] _ in
            listener?.prioritizeVocabulary(["San Francisco"])
        }

        harness.backend.emit(text: "San Francisco", isFinal: true,
            error: NSError(domain: "kLSRErrorDomain", code: 201))
        await harness.advanceRestart()

        XCTAssertTrue(harness.listener.isListening)
        XCTAssertFalse(harness.listener.needsDictation, "The old callback lost ownership during transcript delivery")
        XCTAssertEqual(harness.backend.sessions.count, 2)
    }

    func testExplicitStartAfterExhaustionHasAFreshRetryBudget() async {
        let harness = makeHarness()
        await harness.start()
        harness.backend.available = false
        harness.backend.emit(error: transientError)
        for _ in 0..<6 { await harness.advanceRestart() }
        XCTAssertFalse(harness.listener.isListening)
        harness.backend.available = true

        await harness.listener.startFromUserAction()
        harness.backend.emit(error: transientError)
        await harness.advanceRestart()

        XCTAssertTrue(harness.listener.isListening)
        XCTAssertEqual(harness.backend.sessions.count, 3)
        XCTAssertEqual(harness.clock.requestedDelays.last, .milliseconds(400))
    }

    private var transientError: NSError {
        // Synthetic failure, not a claim about a particular Apple error code.
        NSError(domain: "SpeechRecoveryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Temporary recognition failure"])
    }

    private func makeHarness() -> Harness {
        let harness = Harness()
        addTeardownBlock { await harness.shutdown() }
        return harness
    }

    private func assertVocabularyRestartRecovers(
        after failure: SpeechAudioStartError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let harness = makeHarness()
        await harness.start()
        harness.backend.nextStartFailure = failure
        harness.listener.setBaseVocabulary(["San Francisco"])

        await harness.advanceRestart()

        XCTAssertTrue(harness.listener.isListening, "A temporary audio failure must preserve intent", file: file, line: line)
        XCTAssertEqual(harness.backend.sessions.count, 1, file: file, line: line)
        await harness.advanceRestart()
        XCTAssertEqual(harness.backend.sessions.count, 2, "The next attempt should recover", file: file, line: line)
        XCTAssertEqual(harness.backend.preparedVocabularies.count, 3, file: file, line: line)
        XCTAssertEqual(harness.backend.preparedVocabularies.last, ["San Francisco"], file: file, line: line)
        XCTAssertTrue(harness.listener.isListening, file: file, line: line)
    }
}

@MainActor
private final class Harness {
    let backend = FakeSpeechBackend()
    let clock = ManualRestartDelay()
    let listener: SpeechListener

    init() {
        let clock = clock
        listener = SpeechListener(backend: backend, restartDelay: { await clock.wait($0) })
    }

    func start(file: StaticString = #filePath, line: UInt = #line) async {
        await listener.startIfAuthorized()
        XCTAssertTrue(listener.isListening, file: file, line: line)
        XCTAssertEqual(backend.sessions.count, 1, file: file, line: line)
    }

    func settle() async {
        // Drain queued MainActor work without wall-clock sleeps or microphone access.
        for _ in 0..<20 { await Task.yield() }
    }

    func shutdown() async {
        listener.stop()
        await settle()
        clock.advance()
        await settle()
    }

    func advanceRestart() async {
        await settle()
        clock.advance()
        await settle()
    }
}

/// Intentionally allows cancelled waits to finish: the listener must fence stale work itself.
@MainActor
private final class ManualRestartDelay {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedDelays: [Duration] = []
    var pendingCount: Int { waiters.count }

    func wait(_ duration: Duration) async {
        requestedDelays.append(duration)
        await withCheckedContinuation { waiters.append($0) }
    }

    func advance() {
        let ready = waiters
        waiters.removeAll()
        ready.forEach { $0.resume() }
    }
}

@MainActor
private final class FakeSpeechBackend: SpeechRecognitionBackend {
    let supportedLocaleIdentifiers = ["en-US"]
    let effectiveLocaleIdentifier: String? = "en-US"
    var available = true
    var isAvailable: Bool { available }
    var supportsOnDeviceRecognition = true
    var microphonePermission: SpeechPermission = .authorized
    var speechPermission: SpeechPermission = .authorized
    var permissionRequests = 0
    var nextStartFailure: SpeechAudioStartError?
    var preparedVocabularies: [[String]] = []
    var sessions: [(@MainActor (SpeechRecognitionUpdate?, Error?) -> Void)] = []

    func authorizationState(isListening: Bool, needsDictation: Bool) -> SpeechAuthorizationState {
        .evaluate(
            microphone: microphonePermission,
            speechRecognition: speechPermission,
            recognizerAvailable: available,
            supportsOnDeviceRecognition: supportsOnDeviceRecognition,
            needsDictation: needsDictation
        )
    }

    func requestSpeechAuthorization() async { permissionRequests += 1 }
    func requestMicrophoneAuthorization() async { permissionRequests += 1 }

    func prepareAudio(vocabulary: [String], onLevel: @escaping @MainActor (Float) -> Void) throws {
        preparedVocabularies.append(vocabulary)
        if let failure = nextStartFailure {
            nextStartFailure = nil
            throw failure
        }
    }

    func beginRecognition(_ handler: @escaping @MainActor (SpeechRecognitionUpdate?, Error?) -> Void) {
        sessions.append(handler)
    }

    func stopAudio() {}

    func emit(text: String? = nil, isFinal: Bool = false, error: Error? = nil, session: Int? = nil) {
        let index = session ?? sessions.count - 1
        guard sessions.indices.contains(index) else {
            XCTFail("No recognition session exists to receive the event")
            return
        }
        sessions[index](text.map { SpeechRecognitionUpdate(text: $0, isFinal: isFinal) }, error)
    }
}
