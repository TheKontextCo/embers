import AppKit
import XCTest
@testable import embers

@MainActor
final class NotchGeometryCharacterizationTests: XCTestCase {
    func testFixedMetricsDescribeTheOpenPanelAndClosedFallback() {
        XCTAssertEqual(NotchMetrics.openSize, CGSize(width: 720, height: 420))
        XCTAssertEqual(NotchMetrics.peekRow, 60)
        XCTAssertEqual(
            NotchMetrics.windowSize,
            CGSize(
                width: NotchMetrics.openSize.width,
                height: NotchMetrics.openSize.height + NotchMetrics.peekRow + 34
            )
        )

        XCTAssertEqual(NotchMetrics.closedRadii.top, 6)
        XCTAssertEqual(NotchMetrics.closedRadii.bottom, 14)
        XCTAssertEqual(NotchMetrics.openRadii.top, 22)
        XCTAssertEqual(NotchMetrics.openRadii.bottom, 30)
        XCTAssertEqual(NotchMetrics.fallbackClosed, CGSize(width: 200, height: 32))
    }

    func testClosedSizeWithoutAScreenUsesTheFixedFallback() {
        XCTAssertEqual(NotchMetrics.closedSize(for: nil), NotchMetrics.fallbackClosed)
    }

    func testClosedSizeForEveryAvailableDisplayReflectsItsPublicGeometry() throws {
        let screens = NSScreen.screens
        try XCTSkipIf(screens.isEmpty, "AppKit did not expose an available display")

        for screen in screens {
            let result = NotchMetrics.closedSize(for: screen)
            let measuredHeight = screen.safeAreaInsets.top > 0
                ? screen.safeAreaInsets.top
                : screen.frame.maxY - screen.visibleFrame.maxY

            XCTAssertEqual(result.height, max(measuredHeight, NotchMetrics.fallbackClosed.height))
            XCTAssertGreaterThanOrEqual(result.height, NotchMetrics.fallbackClosed.height)

            if let leftWidth = screen.auxiliaryTopLeftArea?.width,
               let rightWidth = screen.auxiliaryTopRightArea?.width {
                XCTAssertEqual(result.width, screen.frame.width - leftWidth - rightWidth + 4)
            } else {
                XCTAssertEqual(result.width, NotchMetrics.fallbackClosed.width)
            }
        }
    }

    func testOriginPinsAnArbitraryWindowToTheTopCenterOfEveryAvailableDisplay() throws {
        let screens = NSScreen.screens
        try XCTSkipIf(screens.isEmpty, "AppKit did not expose an available display")
        let window = NSWindow(
            contentRect: NSRect(x: 37, y: 41, width: 321, height: 123),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        for screen in screens {
            let origin = NotchMetrics.origin(for: window, on: screen)
            XCTAssertEqual(origin.x, screen.frame.midX - window.frame.width / 2)
            XCTAssertEqual(origin.y, screen.frame.maxY - window.frame.height)
            XCTAssertEqual(origin.x + window.frame.width / 2, screen.frame.midX)
            XCTAssertEqual(origin.y + window.frame.height, screen.frame.maxY)
        }
    }

    func testPanelPreservesItsContentRectAndObservableStyleMask() {
        let contentRect = NSRect(x: 13, y: 17, width: 321, height: 123)
        let panel = NotchWindow(contentRect: contentRect)

        XCTAssertEqual(panel.frame, contentRect)
        XCTAssertEqual(panel.contentRect(forFrameRect: panel.frame), contentRect)
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        // AppKit normalizes the requested utility-window bit away for this borderless panel.
        XCTAssertFalse(panel.styleMask.contains(.utilityWindow))
        XCTAssertTrue(panel.styleMask.contains(.hudWindow))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertFalse(panel.styleMask.contains(.closable))
        XCTAssertFalse(panel.styleMask.contains(.miniaturizable))
        XCTAssertFalse(panel.styleMask.contains(.resizable))
    }

    func testPanelConfigurationKeepsItTransparentFloatingAndSpaceIndependent() {
        let panel = NotchWindow(contentRect: NSRect(origin: .zero, size: NotchMetrics.windowSize))

        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.isMovable)
        XCTAssertEqual(panel.titleVisibility, .hidden)
        XCTAssertTrue(panel.titlebarAppearsTransparent)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertEqual(panel.level, .mainMenu + 3)
        XCTAssertEqual(panel.appearance?.name, .darkAqua)
        XCTAssertEqual(
            panel.collectionBehavior,
            [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        )
    }

    func testPanelCanBecomeKeyButNeverMain() {
        let panel = NotchWindow(contentRect: NSRect(origin: .zero, size: NotchMetrics.windowSize))

        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }
}
