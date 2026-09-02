import XCTest
@testable import embers

final class AudioInputFormatPolicyTests: XCTestCase {
    func testAcceptsUsableInputFormat() {
        XCTAssertTrue(AudioInputFormatPolicy.isUsable(sampleRate: 48_000, channelCount: 1))
    }

    func testRejectsUnavailableOrInvalidInputFormatsBeforeTapInstallation() {
        XCTAssertFalse(AudioInputFormatPolicy.isUsable(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(AudioInputFormatPolicy.isUsable(sampleRate: 48_000, channelCount: 0))
        XCTAssertFalse(AudioInputFormatPolicy.isUsable(sampleRate: .nan, channelCount: 1))
    }
}
