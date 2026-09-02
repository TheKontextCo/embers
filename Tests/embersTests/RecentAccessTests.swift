import XCTest
@testable import embers

final class RecentAccessTests: XCTestCase {
    func testUserDefaultsPersistsAccessTimes() throws {
        let suiteName = "embers.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        UserDefaultsRecentAccess(suite).markAccessed("kontext:document-1", at: date)

        let reopened = UserDefaultsRecentAccess(suite)
        XCTAssertEqual(try XCTUnwrap(reopened.accessDates()["kontext:document-1"]).timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
    }
}
