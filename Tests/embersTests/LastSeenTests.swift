import XCTest
@testable import embers

final class LastSeenTests: XCTestCase {
    func testInMemoryRoundTrip() {
        let store = InMemoryLastSeen()
        XCTAssertNil(store.lastSeen("pitch-1-pager"))
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        store.markSeen("pitch-1-pager", at: t)
        XCTAssertEqual(store.lastSeen("pitch-1-pager"), t)
        XCTAssertNil(store.lastSeen("other"))
    }

    func testUserDefaultsPersistsAndIsolatesKeys() throws {
        let suite = UserDefaults(suiteName: "embers.test.\(UUID().uuidString)")!
        let store = UserDefaultsLastSeen(suite)
        XCTAssertNil(store.lastSeen("p"))
        let t = Date(timeIntervalSince1970: 1_650_000_000)
        store.markSeen("p", at: t)
        // A fresh instance over the same suite reads the persisted value.
        let reopened = UserDefaultsLastSeen(suite)
        let got = try XCTUnwrap(reopened.lastSeen("p"))
        XCTAssertEqual(got.timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 1)
    }
}
