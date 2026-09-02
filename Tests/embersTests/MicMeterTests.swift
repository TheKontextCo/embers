import XCTest
@testable import embers

final class MicMeterTests: XCTestCase {
    func testRMSOfConstantAndSilence() {
        var silence = [Float](repeating: 0, count: 64)
        XCTAssertEqual(MicMeter.rms(&silence, 64), 0, accuracy: 1e-6)

        var half = [Float](repeating: 0.5, count: 64)
        XCTAssertEqual(MicMeter.rms(&half, 64), 0.5, accuracy: 1e-6)   // RMS of a constant = |constant|

        XCTAssertEqual(MicMeter.rms(&half, 0), 0)                       // empty guard
    }

    func testLevelRisesTowardLoudAndDecaysToSilence() {
        var m = MicMeter()
        // sustained loud input climbs toward 1
        for _ in 0..<20 { m.push(rms: 1.0) }
        XCTAssertGreaterThan(m.level, 0.9)
        // then silence decays back down (monotonically)
        var prev = m.level
        for _ in 0..<40 {
            let l = m.push(rms: 0)
            XCTAssertLessThanOrEqual(l, prev + 1e-6)
            prev = l
        }
        XCTAssertLessThan(m.level, 0.1)
    }

    func testAttackIsFasterThanDecay() {
        var up = MicMeter(); up.push(rms: 1.0)        // one loud frame
        var down = MicMeter()
        for _ in 0..<5 { down.push(rms: 1.0) }         // settle high
        let beforeDecay = down.level
        down.push(rms: 0)                              // one silent frame
        let attackJump = up.level                      // 0 → attack
        let decayDrop = beforeDecay - down.level       // high → one decay step
        XCTAssertGreaterThan(attackJump, decayDrop)    // attack moves more per step than decay
    }

    func testResetZeroesLevel() {
        var m = MicMeter(); m.push(rms: 1.0)
        m.reset()
        XCTAssertEqual(m.level, 0)
    }
}
