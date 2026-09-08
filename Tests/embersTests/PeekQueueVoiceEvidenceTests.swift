import EmbersCore
import XCTest

@testable import embers

@MainActor
final class PeekQueueVoiceEvidenceTests: XCTestCase {
    func testRefreshPreservesTheOriginalPresentationCause() throws {
        let queue = PeekQueue()
        let target = MatchTarget(phrase: "Apollo", ref: .node("apollo"), title: "Apollo")
        let original = evidence(id: UUID())
        let later = evidence(id: UUID())

        queue.push(target, routeEvidence: original)
        queue.push(target, routeEvidence: later)

        let peek = try XCTUnwrap(queue.peeks.first)
        XCTAssertEqual(queue.peeks.count, 1)
        XCTAssertEqual(peek.routeEvidence, original)
        XCTAssertNotEqual(peek.routeEvidence, later)
    }

    private func evidence(id: UUID) -> RoutePresentationEvidence {
        .init(
            presentationID: id,
            exclusionKey: .init(
                sourceID: "folder:a",
                nodeID: "apollo",
                pattern: .init(kind: .phrase, normalizedTerms: ["apollo"])
            )
        )
    }
}
