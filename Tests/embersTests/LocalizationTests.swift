import XCTest
@testable import embers

final class LocalizationTests: XCTestCase {
    func testSettingsStringsResolveFromSwiftPackageResources() {
        XCTAssertEqual(L10n.string("settings.title"), "Settings")
        XCTAssertEqual(L10n.string("settings.general"), "GENERAL")
        XCTAssertEqual(L10n.string("settings.launchAtLogin"), "Launch at login")
        XCTAssertEqual(L10n.string("settings.launchAtLoginDetail"), "Keep Embers available after signing in")
        XCTAssertEqual(L10n.string("settings.listening"), "LISTENING & NOTCH")
    }
}
