import XCTest
@testable import embers

final class OnboardingGateTests: XCTestCase {
    func testFirstRunAutoOpensOnceWithoutForcingReopen() {
        var gate = OnboardingGate()

        XCTAssertFalse(gate.shouldOpen(state: .loadingCache, hasSnapshot: false))
        XCTAssertTrue(gate.shouldOpen(state: .unconfigured, hasSnapshot: false))
        XCTAssertFalse(gate.shouldOpen(state: .indexing, hasSnapshot: false))
        XCTAssertFalse(gate.shouldOpen(state: .failed("Still unavailable"), hasSnapshot: false))
        XCTAssertFalse(gate.shouldOpen(state: .ready, hasSnapshot: true))
    }

    func testBootstrapFailureAlsoRequiresOnboarding() {
        var gate = OnboardingGate()

        XCTAssertTrue(gate.shouldOpen(state: .failed("Source unavailable"), hasSnapshot: false))
    }

    func testSampleVaultGuideStartsWithOneImmediateVoiceWin() {
        XCTAssertEqual(
            SampleVaultGuideCopy.instruction(selectedName: nil),
            "Say “San Francisco” to open the trip context."
        )
        XCTAssertEqual(
            SampleVaultGuideCopy.instruction(selectedName: "Embers"),
            "Embers was assembled from the Markdown evidence below."
        )
    }
}
