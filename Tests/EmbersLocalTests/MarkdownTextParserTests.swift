import XCTest
@testable import EmbersLocal
import EmbersCore

final class MarkdownTextParserTests: XCTestCase {
    func testParsesSupportedMarkdownAndIgnoresFences() throws {
        let markdown = """
        ---
        title: Apollo
        embers_id: apollo
        type: project
        aliases: [Moonshot, Apollo launch]
        tags: [launch]
        ---
        # Wrong title
        [[Sarah|Sarah Chen]] ![[Brief.pdf]] [Plan](plan.md) #active
        - [ ] Ship it
        ```md
        [[Ignored]] #ignored
        - [ ] ignored task
        ```
        """
        let input = ParseInput(url: URL(fileURLWithPath: "/tmp/Apollo.md"), relativePath: "Apollo.md", data: Data(markdown.utf8), modifiedAt: Date())
        let parsed = try MarkdownTextParser().parse(input)
        XCTAssertEqual(parsed.title, "Apollo")
        XCTAssertEqual(parsed.metadata.explicitID, "apollo")
        XCTAssertEqual(parsed.metadata.aliases, ["Moonshot", "Apollo launch"])
        XCTAssertEqual(parsed.metadata.links.count, 3)
        XCTAssertEqual(parsed.metadata.uncheckedTasks.map(\.text), ["Ship it"])
        XCTAssertFalse(parsed.metadata.tags.contains("ignored"))
        XCTAssertFalse(parsed.text.contains("embers_id"))
        XCTAssertFalse(parsed.text.contains("title: Apollo"))
    }

    func testTextUsesFilenameAsTitle() throws {
        let input = ParseInput(url: URL(fileURLWithPath: "/tmp/Notes.txt"), relativePath: "Notes.txt", data: Data("Hello".utf8), modifiedAt: Date())
        XCTAssertEqual(try MarkdownTextParser().parse(input).title, "Notes")
    }


    func testTitlePrecedenceFallsBackFromH1ToFilename() throws {
        let h1 = ParseInput(url: URL(fileURLWithPath: "/tmp/File.md"), relativePath: "File.md", data: Data("# Heading\nBody".utf8), modifiedAt: Date())
        XCTAssertEqual(try MarkdownTextParser().parse(h1).title, "Heading")
        let filename = ParseInput(url: URL(fileURLWithPath: "/tmp/File.md"), relativePath: "File.md", data: Data("Body".utf8), modifiedAt: Date())
        XCTAssertEqual(try MarkdownTextParser().parse(filename).title, "File")
    }

    func testParsesMultilineFrontmatterLists() throws {
        let markdown = """
        ---
        aliases:
          - Moonshot
          - Apollo launch
        tags:
          - launch
        ---
        # Apollo
        """
        let input = ParseInput(url: URL(fileURLWithPath: "/tmp/Apollo.md"), relativePath: "Apollo.md", data: Data(markdown.utf8), modifiedAt: Date())
        let parsed = try MarkdownTextParser().parse(input)
        XCTAssertEqual(parsed.metadata.aliases, ["Moonshot", "Apollo launch"])
        XCTAssertEqual(parsed.metadata.tags, ["launch"])
    }

    func testTasksPreserveSourceLinesStateAndMutationFingerprintAcrossFrontmatter() throws {
        let markdown = """
        ---
        title: Tasks
        ---
        - [ ] Ship the app
        - [x] Write the notes
        """
        let input = ParseInput(url: URL(fileURLWithPath: "/tmp/Tasks.md"), relativePath: "Tasks.md", data: Data(markdown.utf8), modifiedAt: Date())
        let tasks = try MarkdownTextParser().parse(input).metadata.tasks

        XCTAssertEqual(tasks.map(\.line), [4, 5])
        XCTAssertEqual(tasks.map(\.state), [.open, .completed])
        XCTAssertEqual(tasks.map(\.id), ["markdown-line:4", "markdown-line:5"])
        XCTAssertEqual(tasks[0].mutationToken, StableHash.hex("- [ ] Ship the app"))
    }

    func testManifestKeepsValidEntriesWhenAnotherEntryIsMalformed() {
        let data = Data(#"{"version":1,"anchors":[{"id":"a","name":"A"},{"name":"bad"}],"relations":[]}"#.utf8)
        let loaded = ManifestLoader().load(data)
        XCTAssertEqual(loaded.0?.anchors.map(\.id), ["a"])
        XCTAssertEqual(loaded.1.count, 1)
    }
}
