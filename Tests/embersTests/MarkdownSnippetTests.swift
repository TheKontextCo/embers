import XCTest
@testable import embers

final class MarkdownSnippetTests: XCTestCase {
    func testRendersHeadingAndEmphasisMarkersAsInlineContent() {
        let rendered = markdownSnippet(#"# Antifragility *survives* and gets **stronger**."#)

        XCTAssertEqual(String(rendered.characters), "Antifragility survives and gets stronger.")
    }

    func testFallsBackToReadableTextForIncompleteMarkdown() {
        let rendered = markdownSnippet("## A preview with **truncated emphasis")

        XCTAssertFalse(String(rendered.characters).hasPrefix("## "))
        XCTAssertTrue(String(rendered.characters).contains("A preview"))
    }
}
