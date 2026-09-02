import XCTest
@testable import embers

final class SignalOutlineMotionPolicyTests: XCTestCase {
    func testOutlineMotionPolicyCoversEveryStateCombination() {
        for isListening in [false, true] {
            for supportsListeningTravel in [false, true] {
                for motionEnabled in [false, true] {
                    for reduceMotion in [false, true] {
                        XCTAssertEqual(
                            SignalOutlineMotionPolicy.shouldAnimate(
                                isListening: isListening,
                                supportsListeningTravel: supportsListeningTravel,
                                motionEnabled: motionEnabled,
                                reduceMotion: reduceMotion
                            ),
                            isListening && supportsListeningTravel && motionEnabled && !reduceMotion
                        )
                    }
                }
            }
        }
    }

    func testIdleOutlineDoesNotRequestContinuousFrames() {
        XCTAssertFalse(SignalOutlineMotionPolicy.shouldAnimate(
            isListening: false,
            supportsListeningTravel: true,
            motionEnabled: true,
            reduceMotion: false
        ))
    }

    func testContextLensBuildDoesNotAnimateTheOuterNotch() {
        XCTAssertFalse(SignalOutlineMotionPolicy.shouldAnimate(
            isListening: false,
            supportsListeningTravel: false,
            motionEnabled: true,
            reduceMotion: false
        ))
    }

    func testListeningStillAnimatesOnTravelingScales() {
        XCTAssertTrue(SignalOutlineMotionPolicy.shouldAnimate(
            isListening: true,
            supportsListeningTravel: true,
            motionEnabled: true,
            reduceMotion: false
        ))
    }

    func testReducedMotionAndDisabledMotionPauseTheTimeline() {
        XCTAssertFalse(SignalOutlineMotionPolicy.shouldAnimate(
            isListening: false,
            supportsListeningTravel: false,
            motionEnabled: true,
            reduceMotion: true
        ))
        XCTAssertFalse(SignalOutlineMotionPolicy.shouldAnimate(
            isListening: false,
            supportsListeningTravel: false,
            motionEnabled: false,
            reduceMotion: false
        ))
    }

    func testContextActivityOnlyAnimatesInsideTheOpenApp() {
        for isAppOpen in [false, true] {
            for reduceMotion in [false, true] {
                XCTAssertEqual(
                    ContextActivityMotionPolicy.shouldAnimate(
                        isAppOpen: isAppOpen,
                        reduceMotion: reduceMotion
                    ),
                    isAppOpen && !reduceMotion
                )
            }
        }
    }
}
