import XCTest
@testable import embers

final class SpeechAuthorizationStateTests: XCTestCase {
    func testNotDeterminedAccessIsRequestableButNeverStartable() {
        let state = SpeechAuthorizationState.evaluate(
            microphone: .notDetermined,
            speechRecognition: .notDetermined,
            recognizerAvailable: true,
            supportsOnDeviceRecognition: true
        )

        XCTAssertTrue(state.canRequestAuthorization)
        XCTAssertFalse(state.hasPermissions)
        XCTAssertFalse(state.canStart)
        XCTAssertEqual(state.label, "Microphone and Speech Recognition access required")
    }

    func testDeniedPermissionsExposeTheirIndividualRecoveryActions() {
        let microphoneDenied = SpeechAuthorizationState.evaluate(
            microphone: .denied,
            speechRecognition: .authorized,
            recognizerAvailable: true,
            supportsOnDeviceRecognition: true
        )
        XCTAssertTrue(microphoneDenied.needsMicrophoneSettings)
        XCTAssertFalse(microphoneDenied.needsSpeechRecognitionSettings)
        XCTAssertEqual(microphoneDenied.label, "Microphone access is off")

        let speechDenied = SpeechAuthorizationState.evaluate(
            microphone: .authorized,
            speechRecognition: .denied,
            recognizerAvailable: true,
            supportsOnDeviceRecognition: true
        )
        XCTAssertFalse(speechDenied.needsMicrophoneSettings)
        XCTAssertTrue(speechDenied.needsSpeechRecognitionSettings)
        XCTAssertEqual(speechDenied.label, "Speech Recognition access is off")
    }

    func testRestrictedAccessDoesNotPretendSettingsCanFixManagedPolicy() {
        let state = SpeechAuthorizationState.evaluate(
            microphone: .restricted,
            speechRecognition: .authorized,
            recognizerAvailable: true,
            supportsOnDeviceRecognition: true
        )

        XCTAssertFalse(state.canRequestAuthorization)
        XCTAssertFalse(state.needsMicrophoneSettings)
        XCTAssertTrue(state.detail.contains("Screen Time"))
    }

    func testOfflineCapabilityFailuresAreVisibleAfterAuthorization() {
        let unavailable = SpeechAuthorizationState.evaluate(
            microphone: .authorized,
            speechRecognition: .authorized,
            recognizerAvailable: false,
            supportsOnDeviceRecognition: false
        )
        XCTAssertFalse(unavailable.canStart)
        XCTAssertEqual(unavailable.label, "Speech recognition is currently unavailable")

        let unsupported = SpeechAuthorizationState.evaluate(
            microphone: .authorized,
            speechRecognition: .authorized,
            recognizerAvailable: true,
            supportsOnDeviceRecognition: false
        )
        XCTAssertEqual(unsupported.label, "This Mac does not support offline speech recognition")

        let dictation = SpeechAuthorizationState.evaluate(
            microphone: .authorized,
            speechRecognition: .authorized,
            recognizerAvailable: true,
            supportsOnDeviceRecognition: true,
            needsDictation: true
        )
        XCTAssertEqual(dictation.capability, .dictationDisabled)
        XCTAssertTrue(dictation.detail.contains("offline-only"))
    }
}
