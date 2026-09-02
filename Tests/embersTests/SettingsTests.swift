import XCTest
@testable import embers

@MainActor
final class SettingsTests: XCTestCase {
    private func freshSuite() -> UserDefaults { UserDefaults(suiteName: "embers.test.\(UUID().uuidString)")! }

    private final class FakeLaunchAtLoginService: LaunchAtLoginService {
        var currentLaunchAtLoginStatus: LaunchAtLoginStatus
        var registerError: Error?
        var unregisterError: Error?
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0

        init(status: LaunchAtLoginStatus) {
            currentLaunchAtLoginStatus = status
        }

        func register() throws {
            registerCalls += 1
            if let registerError { throw registerError }
        }

        func unregister() throws {
            unregisterCalls += 1
            if let unregisterError { throw unregisterError }
        }
    }

    private enum TestError: LocalizedError {
        case unavailable

        var errorDescription: String? { "Login Items is unavailable" }
    }

    func testDefaults() {
        let s = Settings(defaults: freshSuite())
        XCTAssertFalse(s.listenOnLaunch)
        XCTAssertTrue(s.muteHotkeyEnabled)
        XCTAssertEqual(s.displayIdentifier, "")
    }

    func testPersistsAcrossReopen() {
        let suite = freshSuite()
        let s = Settings(defaults: suite)
        s.listenOnLaunch = true
        s.muteHotkeyEnabled = false
        s.displayIdentifier = "display-uuid:built-in"

        let reopened = Settings(defaults: suite)
        XCTAssertTrue(reopened.listenOnLaunch)
        XCTAssertFalse(reopened.muteHotkeyEnabled)
        XCTAssertEqual(reopened.displayIdentifier, "display-uuid:built-in")
    }

    func testRemovesRetiredPreferences() {
        let suite = freshSuite()
        suite.set(true, forKey: "reduceMotion")
        suite.set(250, forKey: "hoverOpenMs")
        suite.set(60, forKey: "peekSeconds")
        suite.set(false, forKey: "semanticVoiceMatching")
        suite.set("fr-FR", forKey: "speechLocaleIdentifier")

        _ = Settings(defaults: suite)

        XCTAssertNil(suite.object(forKey: "reduceMotion"))
        XCTAssertNil(suite.object(forKey: "hoverOpenMs"))
        XCTAssertNil(suite.object(forKey: "peekSeconds"))
        XCTAssertNil(suite.object(forKey: "semanticVoiceMatching"))
        XCTAssertNil(suite.object(forKey: "speechLocaleIdentifier"))
    }

    func testMigratesUniqueLegacyDisplayNameToStableIdentifier() {
        let suite = freshSuite()
        suite.set("Studio Display", forKey: "displayID")
        let studioDisplay = DisplayPlacement(
            persistentIdentifier: "display-uuid:studio",
            localizedName: "Studio Display",
            displayNumber: 42
        )

        let settings = Settings(defaults: suite, displays: [studioDisplay])

        XCTAssertEqual(settings.displayIdentifier, "display-uuid:studio")
        XCTAssertEqual(suite.string(forKey: "displayIdentifier"), "display-uuid:studio")
    }

    func testDoesNotMigrateAmbiguousLegacyDisplayName() {
        let suite = freshSuite()
        suite.set("DELL U2720Q", forKey: "displayID")
        let displays = [
            DisplayPlacement(persistentIdentifier: "display-uuid:left", localizedName: "DELL U2720Q", displayNumber: 1),
            DisplayPlacement(persistentIdentifier: "display-uuid:right", localizedName: "DELL U2720Q", displayNumber: 2),
        ]

        let settings = Settings(defaults: suite, displays: displays)

        XCTAssertEqual(settings.displayIdentifier, "")
        XCTAssertNil(suite.string(forKey: "displayIdentifier"))
    }

    func testKeepsStableDisplayChoiceWhileItIsDisconnected() {
        let suite = freshSuite()
        suite.set("display-uuid:desk", forKey: "displayIdentifier")
        let laptop = DisplayPlacement(persistentIdentifier: "display-uuid:laptop", localizedName: "Built-in Display", displayNumber: 1)

        let settings = Settings(defaults: suite, displays: [laptop])

        XCTAssertEqual(settings.displayIdentifier, "display-uuid:desk")
        XCTAssertNil(DisplayPlacementPolicy.selectedDisplay(savedIdentifier: settings.displayIdentifier, displays: [laptop]))
    }

    func testMissingDisplayFallsBackAndReconnectRestoresTheStableChoice() {
        let laptop = DisplayPlacement(persistentIdentifier: "display-uuid:laptop", localizedName: "Built-in Display", displayNumber: 1)
        let desk = DisplayPlacement(persistentIdentifier: "display-uuid:desk", localizedName: "Studio Display", displayNumber: 2)

        XCTAssertEqual(
            DisplayPlacementPolicy.resolvedDisplay(
                savedIdentifier: desk.persistentIdentifier,
                displays: [laptop],
                automaticDisplay: laptop
            ),
            laptop
        )
        XCTAssertEqual(
            DisplayPlacementPolicy.resolvedDisplay(
                savedIdentifier: desk.persistentIdentifier,
                displays: [laptop, desk],
                automaticDisplay: laptop
            ),
            desk
        )
    }

    func testDuplicateDisplayNamesGetDistinctHumanReadableLabels() {
        let left = DisplayPlacement(persistentIdentifier: "display-uuid:left", localizedName: "DELL U2720Q", displayNumber: 1)
        let right = DisplayPlacement(persistentIdentifier: "display-uuid:right", localizedName: "DELL U2720Q", displayNumber: 2)

        XCTAssertEqual(DisplayPlacementPolicy.displayLabel(for: left, among: [left, right]), "DELL U2720Q • Display 1")
        XCTAssertEqual(DisplayPlacementPolicy.displayLabel(for: right, among: [left, right]), "DELL U2720Q • Display 2")
    }

    func testUnconfiguredIndexingLabelDoesNotAssumeAFolder() {
        XCTAssertEqual(IndexingState.unconfigured.label, "Choose a context source")
    }

    func testLaunchAtLoginUsesServiceStatusInsteadOfPersistedPreference() {
        let defaults = freshSuite()
        defaults.set(true, forKey: "launchAtLogin")
        let service = FakeLaunchAtLoginService(status: .notRegistered)

        let settings = Settings(defaults: defaults, appService: service)

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(settings.launchAtLoginStatus, .notRegistered)
    }

    func testLaunchAtLoginRefreshesAfterRegistering() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let settings = Settings(defaults: freshSuite(), appService: service)
        service.currentLaunchAtLoginStatus = .enabled

        settings.setLaunchAtLogin(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.launchAtLoginStatus, .enabled)
    }

    func testLaunchAtLoginFailureDoesNotClaimEnabled() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestError.unavailable
        let settings = Settings(defaults: freshSuite(), appService: service)

        settings.setLaunchAtLogin(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(settings.launchAtLoginStatus, .error("Login Items is unavailable"))
        XCTAssertTrue(settings.launchAtLoginStatus.shouldOfferLoginItemsSettings)
    }

    func testLaunchAtLoginUnregisterFailureKeepsTheSystemEnabledState() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.unregisterError = TestError.unavailable
        let settings = Settings(defaults: freshSuite(), appService: service)

        settings.setLaunchAtLogin(false)

        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.launchAtLoginStatus, .error("Login Items is unavailable"))

        settings.refreshLaunchAtLoginStatus()

        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.launchAtLoginStatus, .enabled)
    }

    func testLaunchAtLoginModelsSystemApprovalAndMissingStates() {
        let approval = Settings(
            defaults: freshSuite(),
            appService: FakeLaunchAtLoginService(status: .requiresApproval)
        )
        let missing = Settings(
            defaults: freshSuite(),
            appService: FakeLaunchAtLoginService(status: .notFound)
        )

        XCTAssertFalse(approval.launchAtLogin)
        XCTAssertTrue(approval.launchAtLoginStatus.shouldOfferLoginItemsSettings)
        XCTAssertFalse(missing.launchAtLogin)
        XCTAssertTrue(missing.launchAtLoginStatus.shouldOfferLoginItemsSettings)
    }
}
