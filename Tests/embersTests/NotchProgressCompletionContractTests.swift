import CoreGraphics
import XCTest
@testable import embers

final class NotchProgressCompletionContractTests: XCTestCase {
    func testBuildingProgressHasOneOrangeFuseWithAnEmberAtItsLeadingEdge() {
        let state = NotchProgressVisualState(progress: 0.42, completionSweep: 0)

        XCTAssertEqual(state.orangeRange, 0...0.42)
        XCTAssertNil(state.greenRange)
        XCTAssertEqual(state.tip, .ember(progress: 0.42))
    }

    func testCompletionSweepReplacesOrangeBehindItsGreenLeadingEdge() {
        let state = NotchProgressVisualState(progress: 1, completionSweep: 0.4)

        XCTAssertEqual(state.orangeRange, 0.4...1)
        XCTAssertEqual(state.greenRange, 0...0.4)
        XCTAssertEqual(state.tip, .success(progress: 0.4))
    }

    func testFinishedSweepLeavesOneCompleteGreenLineWithoutAFuseTip() {
        let state = NotchProgressVisualState(progress: 1, completionSweep: 1)

        XCTAssertNil(state.orangeRange)
        XCTAssertEqual(state.greenRange, 0...1)
        XCTAssertNil(state.tip)
    }

    func testVisualStateClampsBothInputsToTheVisibleRoute() {
        let building = NotchProgressVisualState(progress: -1, completionSweep: 0.5)
        let completing = NotchProgressVisualState(progress: 2, completionSweep: 3)

        XCTAssertNil(building.orangeRange)
        XCTAssertEqual(building.tip, .ember(progress: 0))
        XCTAssertNil(completing.orangeRange)
        XCTAssertEqual(completing.greenRange, 0...1)
        XCTAssertNil(completing.tip)
    }

    func testCompletionTimingIsFastAndTheStatusOutlivesTheSweep() {
        XCTAssertGreaterThan(ContextProgressCompletionTiming.sweepDuration, 0)
        XCTAssertLessThanOrEqual(ContextProgressCompletionTiming.sweepDuration, 0.25)
        XCTAssertGreaterThan(
            ContextProgressCompletionTiming.statusHoldDuration,
            ContextProgressCompletionTiming.sweepDuration
        )
    }

    func testReduceMotionCompletesWithoutPerimeterTravel() {
        XCTAssertEqual(ContextProgressCompletionTiming.sweepDuration(reduceMotion: true), 0)
        XCTAssertEqual(
            ContextProgressCompletionTiming.sweepDuration(reduceMotion: false),
            ContextProgressCompletionTiming.sweepDuration
        )
    }
}
