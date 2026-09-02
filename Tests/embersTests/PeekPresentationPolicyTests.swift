import Foundation
import XCTest
@testable import embers

final class PeekPresentationPolicyTests: XCTestCase {
    func testClosedNotchDisplaysUniqueAndSharedPeeksInQueueOrder() {
        let peeks = [
            peek(id: "unique-a"),
            peek(id: "shared-a", conceptID: "concept-a"),
            peek(id: "unique-b"),
        ]

        let displayed = PeekPresentationPolicy().displayedPeeks(peeks, notchIsOpen: false)

        XCTAssertEqual(displayed.map(\.id), peeks.map(\.id))
    }

    func testOpeningDetailHidesAllPeeksAndClosingRestoresQueueOrder() {
        let peeks = [
            peek(id: "unique-a"),
            peek(id: "shared-a", conceptID: "concept-a"),
            peek(id: "unique-b"),
            peek(id: "shared-b", conceptID: "concept-a"),
        ]

        let policy = PeekPresentationPolicy()
        XCTAssertEqual(policy.displayedPeeks(peeks, notchIsOpen: false).map(\.id), peeks.map(\.id))

        XCTAssertTrue(policy.displayedPeeks(peeks, notchIsOpen: true).isEmpty,
                      "Shared candidates must not overlay the expanded detail.")
        XCTAssertEqual(policy.displayedPeeks(peeks, notchIsOpen: false).map(\.id), peeks.map(\.id))
        XCTAssertEqual(peeks.map(\.id), ["unique-a", "shared-a", "unique-b", "shared-b"])
    }

    func testSharedCandidatesArrivingWhileDetailIsOpenRemainHidden() {
        let policy = PeekPresentationPolicy()
        var peeks = [peek(id: "unique-a")]
        XCTAssertTrue(policy.displayedPeeks(peeks, notchIsOpen: true).isEmpty)

        peeks.append(peek(id: "shared-a", conceptID: "concept-a"))
        peeks.append(peek(id: "shared-b", conceptID: "concept-a"))

        XCTAssertTrue(policy.displayedPeeks(peeks, notchIsOpen: true).isEmpty,
                      "New shared candidates must not recreate a row over the expanded detail.")
        XCTAssertEqual(policy.displayedPeeks(peeks, notchIsOpen: false).map(\.id),
                       ["unique-a", "shared-a", "shared-b"])
    }

    func testOpenNotchDisplaysNoRowForUniqueOnlyQueue() {
        let displayed = PeekPresentationPolicy().displayedPeeks(
            [peek(id: "unique-a"), peek(id: "unique-b")],
            notchIsOpen: true
        )

        XCTAssertTrue(displayed.isEmpty)
    }

    private func peek(id: String, conceptID: String? = nil) -> Peek {
        Peek(
            id: id,
            target: .init(
                phrase: id,
                ref: .node("node-\(id)"),
                title: id,
                conceptID: conceptID
            ),
            title: id,
            bornAt: Date(timeIntervalSince1970: 0)
        )
    }
}
