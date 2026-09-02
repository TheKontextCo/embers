import XCTest
import EmbersCore
@testable import embers

final class ContextChangeSummaryPresentationTests: XCTestCase {
    func testRemovalOnlyChangeBecomesAnHonestNonArtifactRow() throws {
        let rows = ContextChangeSummaryPresentation.rows(
            from: .init(removedArtifactIDs: ["gone"], membershipChanged: true),
            isOnboarding: false
        )

        let row = try XCTUnwrap(rows.single())
        XCTAssertEqual(row.kind, .removedArtifacts)
        XCTAssertEqual(row.count, 1)
        XCTAssertEqual(row.message, "1 document removed from this context")
        XCTAssertEqual(row.systemImage, "minus.circle")
    }

    func testMultipleRemovalsAreSummarizedWithoutDocumentRows() throws {
        let rows = ContextChangeSummaryPresentation.rows(
            from: .init(removedArtifactIDs: ["one", "two", "three"], membershipChanged: true),
            isOnboarding: false
        )

        let row = try XCTUnwrap(rows.single())
        XCTAssertEqual(row.count, 3)
        XCTAssertEqual(row.message, "3 documents removed from this context")
    }

    func testMembershipOnlyChangeBecomesAStructuralRow() throws {
        let row = try XCTUnwrap(
            ContextChangeSummaryPresentation.rows(
                from: .init(membershipChanged: true),
                isOnboarding: false
            ).single()
        )

        XCTAssertEqual(row.kind, .membershipChanged)
        XCTAssertEqual(row.message, "Context membership changed")
    }

    func testOnboardingDoesNotInventNonArtifactSummaries() {
        XCTAssertTrue(
            ContextChangeSummaryPresentation.rows(
                from: .init(),
                isOnboarding: true
            ).isEmpty
        )
    }

    func testOnboardingDoesNotAlterRealStructuralSummaries() {
        let changes = ContextChangeSet(removedArtifactIDs: ["gone"], membershipChanged: true)

        XCTAssertEqual(
            ContextChangeSummaryPresentation.rows(from: changes, isOnboarding: true),
            ContextChangeSummaryPresentation.rows(from: changes, isOnboarding: false)
        )
    }
}

private extension Array {
    func single() -> Element? {
        count == 1 ? first : nil
    }
}
