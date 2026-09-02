import AppKit
import XCTest
@testable import embers

@MainActor
final class KeyMonitorTests: XCTestCase {
    func testUsesOneLocalMonitorAndForwardsOnlyNavigationKeys() {
        let token = NSObject()
        var installed: ((NSEvent) -> NSEvent?)?
        var removed: [AnyObject] = []
        var received: [KeyMonitor.Key] = []
        let monitor = KeyMonitor(
            addLocalMonitor: { handler in
                installed = handler
                return token
            },
            removeMonitor: { removed.append($0 as AnyObject) }
        )

        monitor.start { received.append($0) }
        monitor.start { received.append($0) }

        for (keyCode, expected) in [(123, KeyMonitor.Key.left), (124, .right), (125, .down), (126, .up), (53, .escape)] {
            XCTAssertNil(installed?(keyEvent(UInt16(keyCode))))
            XCTAssertEqual(received.last, expected)
        }
        XCTAssertEqual(received.count, 5)

        let ordinary = keyEvent(0)
        XCTAssertTrue(installed?(ordinary) === ordinary)
        XCTAssertEqual(received.count, 5)

        monitor.stop()
        XCTAssertEqual(removed.count, 1)
        XCTAssertTrue(removed.first === token)
    }

    func testStopIsIdempotentAndDoesNotLeaveAHandler() {
        let token = NSObject()
        var installed: ((NSEvent) -> NSEvent?)?
        var removeCount = 0
        var received = 0
        let monitor = KeyMonitor(
            addLocalMonitor: { handler in
                installed = handler
                return token
            },
            removeMonitor: { _ in removeCount += 1 }
        )

        monitor.start { _ in received += 1 }
        monitor.stop()
        monitor.stop()
        _ = installed?(keyEvent(53))

        XCTAssertEqual(removeCount, 1)
        XCTAssertEqual(received, 0)
    }

    private func keyEvent(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
