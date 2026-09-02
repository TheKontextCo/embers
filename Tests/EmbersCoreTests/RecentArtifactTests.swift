import XCTest
@testable import EmbersCore

final class RecentArtifactTests: XCTestCase {
    func testRecentContainsOnlyAccessedArtifactsOrderedByAccessTime() {
        let old = SourceArtifact(id: "old", relativePath: "old.md", mediaKind: .markdown, title: "Old", extractedText: "Old", modifiedAt: Date(timeIntervalSince1970: 9_000), contentHash: "old")
        let new = SourceArtifact(id: "new", relativePath: "new.md", mediaKind: .markdown, title: "New", extractedText: "New", modifiedAt: Date(timeIntervalSince1970: 1), contentHash: "new")
        let untouched = SourceArtifact(id: "untouched", relativePath: "untouched.md", mediaKind: .markdown, title: "Untouched", extractedText: "Untouched", modifiedAt: Date(timeIntervalSince1970: 10_000), contentHash: "untouched")
        let snapshot = ContextSnapshot(sourceID: "s", revision: "r", artifacts: [old, new, untouched], anchors: [], relations: [], diagnostics: [], indexedAt: .distantPast)

        let recent = LinearContextSearch().recent(in: snapshot, accessedAt: [
            old.id: Date(timeIntervalSince1970: 100),
            new.id: Date(timeIntervalSince1970: 200),
            "missing": Date(timeIntervalSince1970: 300),
        ])

        XCTAssertEqual(recent.map(\.id), ["new", "old"])
        XCTAssertEqual(recent.map(\.accessedAt), [Date(timeIntervalSince1970: 200), Date(timeIntervalSince1970: 100)])
    }
}
