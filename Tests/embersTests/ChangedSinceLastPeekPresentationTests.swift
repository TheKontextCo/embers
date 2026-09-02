import XCTest
import EmbersCore
@testable import embers

final class ChangedSinceLastPeekPresentationTests: XCTestCase {
    private let unchanged = ContextHit(
        artifact: SourceArtifact(
            id: "brief",
            relativePath: "Brief.md",
            mediaKind: .markdown,
            title: "Brief",
            extractedText: "A sample briefing.",
            modifiedAt: .distantPast,
            contentHash: "brief"
        ),
        snippet: "A sample briefing.",
        changedSinceLastPeek: false
    )

    func testOnboardingShowsARealDocumentWhenThereIsNoPriorPeek() {
        XCTAssertEqual(
            ChangedSinceLastPeekPresentation.hits(from: [unchanged], isOnboarding: true),
            [unchanged]
        )
    }

    func testNormalSourcesOnlyShowActualChanges() {
        XCTAssertTrue(
            ChangedSinceLastPeekPresentation.hits(from: [unchanged], isOnboarding: false).isEmpty
        )
    }

    func testActualChangesTakePrecedenceDuringOnboarding() {
        var changed = unchanged
        changed.changedSinceLastPeek = true

        XCTAssertEqual(
            ChangedSinceLastPeekPresentation.hits(
                from: [unchanged, changed],
                isOnboarding: true
            ),
            [changed]
        )
    }

    func testOnboardingWithNoEvidenceDoesNotInventAChange() {
        XCTAssertTrue(
            ChangedSinceLastPeekPresentation.hits(from: [], isOnboarding: true).isEmpty
        )
    }

    func testOnboardingOverrideIsPresentationOnlyAndDoesNotMutateChangeState() {
        let input = [unchanged]

        let firstPresentation = ChangedSinceLastPeekPresentation.hits(
            from: input,
            isOnboarding: true
        )
        let secondPresentation = ChangedSinceLastPeekPresentation.hits(
            from: input,
            isOnboarding: true
        )

        XCTAssertEqual(firstPresentation, [unchanged])
        XCTAssertEqual(secondPresentation, [unchanged])
        XCTAssertFalse(input[0].changedSinceLastPeek)
        XCTAssertFalse(firstPresentation[0].changedSinceLastPeek)
    }

    func testTurningOffOnboardingImmediatelyRestoresEvidenceOnlyPresentation() {
        XCTAssertEqual(
            ChangedSinceLastPeekPresentation.hits(from: [unchanged], isOnboarding: true),
            [unchanged]
        )
        XCTAssertTrue(
            ChangedSinceLastPeekPresentation.hits(from: [unchanged], isOnboarding: false).isEmpty
        )
    }

    func testRealNonArtifactChangeSuppressesTheOnboardingFallbackDocument() {
        XCTAssertTrue(
            ChangedSinceLastPeekPresentation.hits(
                from: [unchanged],
                isOnboarding: true,
                hasNonArtifactChanges: true
            ).isEmpty
        )
    }
}
