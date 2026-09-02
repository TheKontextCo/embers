import XCTest
@testable import embers

final class PhraseMatcherTests: XCTestCase {
    func testNormalizesPunctuationAndUsesWholeWords() {
        let target = MatchTarget(phrase: "Pitch - 1 Pager", ref: .node("pitch"), title: "Pitch")
        XCTAssertEqual(PhraseMatcher(targets: [target]).matches(in: "Open the pitch 1 pager").map(\.title), ["Pitch"])
        let art = MatchTarget(phrase: "art", ref: .node("art"), title: "Art")
        XCTAssertTrue(PhraseMatcher(targets: [art]).matches(in: "start with art").count == 1)
        XCTAssertTrue(PhraseMatcher(targets: [art]).matches(in: "start only").isEmpty)
    }
}
