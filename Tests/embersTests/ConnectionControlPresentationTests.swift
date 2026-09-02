import XCTest
import EmbersPluginKit
@testable import embers

final class ConnectionControlPresentationTests: XCTestCase {
    func testConnectingActionControlShowsProgressWithoutDuplicateStatusLabel() {
        let presentation = ConnectionControlPresentation(state: .connecting)

        XCTAssertNil(presentation.statusLabel)
        XCTAssertEqual(presentation.actionTitle, "Connecting…")
        XCTAssertTrue(presentation.isConnecting)
    }
}
