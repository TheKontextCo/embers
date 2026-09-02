import CoreGraphics
import XCTest
@testable import embers

final class NotchProgressPerimeterContractTests: XCTestCase {
    private let perimeter = NotchProgressPerimeter(width: 180, height: 30, inset: 1)

    func testZeroBeginsAtTopLeftWithoutDrawingAnInactiveTrack() {
        XCTAssertEqual(perimeter.endpoint(at: 0), CGPoint(x: 1, y: 0))
        XCTAssertTrue(perimeter.visibleSegments(at: 0).isEmpty)
    }

    func testFirstLegDescendsTheLeftEdge() {
        let progress = perimeter.leftVerticalCompletion / 2
        let endpoint = perimeter.endpoint(at: progress)

        XCTAssertEqual(endpoint.x, 1, accuracy: 0.001)
        XCTAssertGreaterThan(endpoint.y, 0)
        XCTAssertLessThan(endpoint.y, 30)
    }

    func testSecondLegCrossesTheBottomFromLeftToRight() {
        let progress = (perimeter.leftEdgeCompletion + perimeter.bottomStraightCompletion) / 2
        let endpoint = perimeter.endpoint(at: progress)

        XCTAssertEqual(endpoint, CGPoint(x: 90, y: 30))
    }

    func testFinalLegRisesTheRightEdge() {
        let progress = (perimeter.bottomEdgeCompletion + 1) / 2
        let endpoint = perimeter.endpoint(at: progress)

        XCTAssertEqual(endpoint.x, 179, accuracy: 0.001)
        XCTAssertGreaterThan(endpoint.y, 0)
        XCTAssertLessThan(endpoint.y, 30)
    }

    func testOneHundredPercentEndsAtTopRightAfterAllThreeSides() {
        XCTAssertEqual(perimeter.endpoint(at: 1), CGPoint(x: 179, y: 0))
        let segments = perimeter.visibleSegments(at: 1)
        XCTAssertGreaterThan(segments.count, 3, "Rounded corners must be part of the visible route")
        XCTAssertEqual(segments.first?.start, CGPoint(x: 1, y: 0))
        XCTAssertEqual(segments.last?.end, CGPoint(x: 179, y: 0))
        for pair in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(pair.0.end, pair.1.start)
        }
    }

    func testLegTransitionsFollowThePhysicalFourteenPointBottomGroove() {
        assertPoint(
            perimeter.endpoint(at: perimeter.leftVerticalCompletion),
            CGPoint(x: 1, y: 16)
        )
        assertPoint(
            perimeter.endpoint(at: perimeter.leftEdgeCompletion),
            CGPoint(x: 15, y: 30)
        )
        assertPoint(
            perimeter.endpoint(at: perimeter.bottomStraightCompletion),
            CGPoint(x: 165, y: 30)
        )
        assertPoint(
            perimeter.endpoint(at: perimeter.bottomEdgeCompletion),
            CGPoint(x: 179, y: 16)
        )
    }

    func testBothBottomTransitionsAreCurvesRatherThanRightAngles() {
        let leftCurve = perimeter.endpoint(
            at: (perimeter.leftVerticalCompletion + perimeter.leftEdgeCompletion) / 2
        )
        let rightCurve = perimeter.endpoint(
            at: (perimeter.bottomStraightCompletion + perimeter.bottomEdgeCompletion) / 2
        )

        XCTAssertGreaterThan(leftCurve.x, 1)
        XCTAssertLessThan(leftCurve.x, 15)
        XCTAssertGreaterThan(leftCurve.y, 16)
        XCTAssertLessThan(leftCurve.y, 30)
        XCTAssertGreaterThan(rightCurve.x, 165)
        XCTAssertLessThan(rightCurve.x, 179)
        XCTAssertGreaterThan(rightCurve.y, 16)
        XCTAssertLessThan(rightCurve.y, 30)
    }

    func testFutureSidesRemainAbsentUntilProgressReachesThem() {
        let leftOnly = perimeter.visibleSegments(at: perimeter.leftVerticalCompletion / 2)
        let throughBottom = perimeter.visibleSegments(
            at: (perimeter.leftEdgeCompletion + perimeter.bottomStraightCompletion) / 2
        )
        let throughRight = perimeter.visibleSegments(
            at: (perimeter.bottomEdgeCompletion + 1) / 2
        )

        XCTAssertTrue(leftOnly.allSatisfy { $0.start.x == 1 && $0.end.x == 1 })
        XCTAssertEqual(throughBottom.last?.end.y, 30)
        XCTAssertLessThan(throughBottom.last?.end.x ?? 0, 165)
        XCTAssertEqual(throughRight.last?.end.x, 179)
        XCTAssertLessThan(throughRight.last?.end.y ?? 30, 16)
    }

    func testRouteUsesTheMeasuredPhysicalNotchDimensions() {
        let measured = NotchProgressPerimeter(width: 212, height: 34, inset: 1)

        XCTAssertEqual(measured.endpoint(at: 0), CGPoint(x: 1, y: 0))
        assertPoint(
            measured.endpoint(at: measured.leftEdgeCompletion),
            CGPoint(x: 15, y: 34)
        )
        assertPoint(
            measured.endpoint(at: measured.bottomStraightCompletion),
            CGPoint(x: 197, y: 34)
        )
        assertPoint(
            measured.endpoint(at: measured.bottomEdgeCompletion),
            CGPoint(x: 211, y: 20)
        )
        XCTAssertEqual(measured.endpoint(at: 1), CGPoint(x: 211, y: 0))
    }

    func testProgressClampsToTheVisiblePerimeterContract() {
        XCTAssertEqual(perimeter.endpoint(at: -1), perimeter.endpoint(at: 0))
        XCTAssertEqual(perimeter.endpoint(at: 2), perimeter.endpoint(at: 1))
        XCTAssertTrue(perimeter.visibleSegments(at: -1).isEmpty)
        XCTAssertEqual(perimeter.visibleSegments(at: 2), perimeter.visibleSegments(at: 1))
    }

    func testStatusCopyAlwaysClearsThePhysicalNotchAndFitsInsideTheHeader() {
        for notchHeight: CGFloat in [30, 34, 42] {
            let layout = ContextActivityLayout(notchHeight: notchHeight)

            XCTAssertGreaterThan(layout.statusTop, notchHeight)
            XCTAssertGreaterThanOrEqual(
                layout.headerHeight,
                layout.statusTop + ContextActivityLayout.statusHeight
            )
        }
    }

    func testProgressStrokeUsesSystemExclusionAndSitsOutsideCameraSpace() {
        let placement = NotchProgressPlacement(
            physicalExclusionSize: CGSize(width: 185, height: 32)
        )

        XCTAssertEqual(placement.pathSize, CGSize(width: 187, height: 33))
        XCTAssertEqual(placement.cornerRadius, 15)

        let perimeter = NotchProgressPerimeter(
            width: placement.pathSize.width,
            height: placement.pathSize.height,
            inset: 0,
            cornerRadius: placement.cornerRadius
        )
        XCTAssertEqual(perimeter.endpoint(at: 0), CGPoint(x: 0, y: 0))
        XCTAssertEqual(perimeter.endpoint(at: 1), CGPoint(x: 187, y: 0))
        assertPoint(
            perimeter.endpoint(at: perimeter.leftVerticalCompletion),
            CGPoint(x: 0, y: 18)
        )
        assertPoint(
            perimeter.endpoint(at: perimeter.leftEdgeCompletion),
            CGPoint(x: 15, y: 33)
        )
    }

    private func assertPoint(
        _ actual: CGPoint,
        _ expected: CGPoint,
        accuracy: CGFloat = 0.001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
    }
}
