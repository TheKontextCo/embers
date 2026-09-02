import AppKit
import XCTest
@testable import embers

final class NotchPolicyTests: XCTestCase {
    private let policy = NotchPanelMetricsPolicy(
        fallbackClosedSize: CGSize(width: 200, height: 32),
        topExclusionAllowance: 4
    )

    func testMissingDisplayReturnsTheConfiguredFallback() {
        XCTAssertEqual(policy.closedSize(for: nil), CGSize(width: 200, height: 32))
    }

    func testSafeAreaAndPairedTopExclusionsDetermineClosedSize() {
        let display = NotchDisplayGeometry(
            frame: CGRect(x: 100, y: 40, width: 1_600, height: 900),
            visibleFrame: CGRect(x: 100, y: 40, width: 1_600, height: 840),
            safeAreaTopInset: 38,
            topExclusions: .init(leadingWidth: 692, trailingWidth: 692)
        )

        XCTAssertEqual(policy.closedSize(for: display), CGSize(width: 220, height: 38))
        XCTAssertEqual(
            policy.physicalExclusionSize(for: display),
            CGSize(width: 216, height: 38),
            "The physical exclusion must come directly from the system gap without Embers' container allowance"
        )
    }

    func testVisibleFrameFallbackAndMinimumHeightApplyWithoutTopExclusions() {
        let display = NotchDisplayGeometry(
            frame: CGRect(x: -800, y: 0, width: 800, height: 600),
            visibleFrame: CGRect(x: -800, y: 0, width: 800, height: 580),
            safeAreaTopInset: 0,
            topExclusions: nil
        )

        XCTAssertEqual(policy.closedSize(for: display), CGSize(width: 200, height: 32))
        XCTAssertNil(policy.physicalExclusionSize(for: display))
    }

    func testOriginUsesOnlyWindowSizeAndDisplayFrame() {
        let origin = policy.topCenteredOrigin(
            windowSize: CGSize(width: 720, height: 514),
            displayFrame: CGRect(x: 400, y: -200, width: 1_440, height: 900)
        )

        XCTAssertEqual(origin, CGPoint(x: 760, y: 186))
    }
}
