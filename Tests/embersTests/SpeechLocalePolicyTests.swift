import XCTest
@testable import embers

final class SpeechLocalePolicyTests: XCTestCase {
    func testCanonicalizesIdentifiersToBCP47() {
        XCTAssertEqual(SpeechLocalePolicy.canonicalIdentifier("en_US"), "en-US")
        XCTAssertEqual(SpeechLocalePolicy.canonicalIdentifier("zh_hans_cn"), "zh-Hans-CN")
        XCTAssertNil(SpeechLocalePolicy.canonicalIdentifier("   "))
    }

    func testEnglishOnlyPrefersExactSystemLocaleThenEnglishFallback() {
        let exact = SpeechLocalePolicy.resolve(
            supportedIdentifiers: ["fr-FR", "en-AU", "en-US"],
            systemIdentifier: "en-AU"
        )
        XCTAssertEqual(exact.effectiveIdentifier, "en-AU")
        XCTAssertEqual(exact.recommendedIdentifier, "en-AU")
        XCTAssertEqual(exact.supportedIdentifiers, ["en-AU", "en-US"])

        let languageFallback = SpeechLocalePolicy.resolve(
            supportedIdentifiers: ["fr-FR", "en-US"],
            systemIdentifier: "en-AU"
        )
        XCTAssertEqual(languageFallback.effectiveIdentifier, "en-US")
        XCTAssertFalse(languageFallback.selectedLocaleIsUnsupported)
    }

    func testNonEnglishSystemUsesMatchingEnglishRegion() {
        let resolution = SpeechLocalePolicy.resolve(
            supportedIdentifiers: ["en-US", "en-AU", "fr-AU"],
            systemIdentifier: "fr-AU"
        )

        XCTAssertEqual(resolution.effectiveIdentifier, "en-AU")
        XCTAssertEqual(resolution.recommendedIdentifier, "en-AU")
        XCTAssertFalse(resolution.selectedLocaleIsUnsupported)
    }

    func testNoInstalledEnglishRecognizerFailsClosed() {
        let resolution = SpeechLocalePolicy.resolve(
            supportedIdentifiers: ["ja-JP", "fr-FR"],
            systemIdentifier: "fr-FR"
        )

        XCTAssertNil(resolution.effectiveIdentifier)
        XCTAssertFalse(resolution.selectedLocaleIsUnsupported)
        XCTAssertNil(resolution.recommendedIdentifier)
        XCTAssertTrue(resolution.supportedIdentifiers.isEmpty)
    }

    func testAuthorizationStateCallsOutUnsupportedLanguage() {
        let state = SpeechAuthorizationState.evaluate(
            microphone: .authorized,
            speechRecognition: .authorized,
            recognizerAvailable: false,
            supportsOnDeviceRecognition: false,
            selectedLocaleIsUnsupported: true
        )

        XCTAssertEqual(state.capability, .selectedLocaleUnsupported)
        XCTAssertFalse(state.canStart)
        XCTAssertTrue(state.detail.contains("not fall back"))
    }
}
