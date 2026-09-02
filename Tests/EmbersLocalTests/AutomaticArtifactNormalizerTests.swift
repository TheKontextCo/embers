import XCTest
@testable import EmbersCore
@testable import EmbersLocal

final class AutomaticArtifactNormalizerTests: XCTestCase {
    func testDetectsNotionExportStripsWrapperAndDistrustsCollapsedDates() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let artifacts = (0..<10).map { index in
            SourceArtifact(
                id: "d\(index)",
                relativePath: "vault/Export-12345678-abcd/Books/Reading List/Book \(index).md",
                mediaKind: .markdown,
                title: "Book \(index)",
                extractedText: "",
                modifiedAt: date,
                contentHash: "h\(index)",
                localURL: URL(fileURLWithPath: "/tmp/Book \(index).md")
            )
        }

        let normalized = AutomaticArtifactNormalizer().normalize(artifacts)

        XCTAssertEqual(normalized[0].graphRelativePath, "Books/Reading List/Book 0.md")
        XCTAssertEqual(normalized[0].metadata.importKind, "notion")
        XCTAssertFalse(try XCTUnwrap(normalized[0].metadata.modificationDateReliable))
        XCTAssertEqual(normalized[0].rankingModifiedAt, .distantPast)
    }

    func testLeavesOrdinaryFolderUntouched() {
        let artifact = SourceArtifact(id: "d", relativePath: "Notes/Apollo.md", mediaKind: .markdown, title: "Apollo", extractedText: "", modifiedAt: .distantPast, contentHash: "h", localURL: URL(fileURLWithPath: "/tmp/Apollo.md"))

        let normalized = AutomaticArtifactNormalizer().normalize([artifact])

        XCTAssertNil(normalized[0].metadata.logicalPath)
        XCTAssertNil(normalized[0].metadata.importKind)
        XCTAssertNil(normalized[0].metadata.modificationDateReliable)
    }
}
