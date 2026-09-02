import XCTest
@testable import EmbersCore

final class GraphMentionCacheTests: XCTestCase {
    func testCachedBuildMatchesFullBuildAfterTextOwnershipAndMembershipChanges() throws {
        let cache = GraphMentionCache()
        let builder = DeterministicGraphBuilder()
        var artifacts = [
            artifact("a", title: "Apollo", text: "Apollo Apollo", date: 10),
            artifact("b", title: "Apollo", text: "Apollo", date: 20),
            artifact("c", title: "Other", text: "Apollo and Other", date: 30),
        ]
        func verify() throws {
            let scan = SourceScan(sourceID: "fixture", artifacts: artifacts,
                                  declarations: nil, diagnostics: [], indexedAt: .distantPast)
            let incremental = try builder.build(from: scan, mentionCache: cache)
            let full = try builder.build(from: scan)
            XCTAssertEqual(incremental.revision, full.revision)
            XCTAssertEqual(incremental.artifacts, full.artifacts)
            XCTAssertEqual(incremental.anchors, full.anchors)
            XCTAssertEqual(incremental.relations, full.relations)
            XCTAssertEqual(incremental.diagnostics, full.diagnostics)
        }
        try verify()
        try verify()
        // Same phrase set, different winning owner due to an edited document's recency.
        artifacts[0].modifiedAt = Date(timeIntervalSince1970: 40)
        try verify()
        // Changed text must invalidate counts even if a caller reused a content hash.
        artifacts[2].extractedText = "Other only"
        try verify()
        artifacts[0].title = "Renamed"
        artifacts[0].metadata.aliases = ["Apollo"]
        try verify()
        artifacts.remove(at: 1)
        try verify()
        artifacts.removeAll()
        try verify()
        artifacts = [artifact("a", title: "New", text: "New New", date: 50)]
        try verify()
    }

    private func artifact(_ id: String, title: String, text: String, date: TimeInterval) -> SourceArtifact {
        .init(id: id, relativePath: "Notes/\(id).md", mediaKind: .markdown, title: title,
              extractedText: text, modifiedAt: Date(timeIntervalSince1970: date), contentHash: id,
              metadata: .init(explicitID: id, declaredTitle: title))
    }
}
