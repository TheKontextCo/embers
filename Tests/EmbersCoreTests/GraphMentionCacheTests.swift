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

    func testExactMentionOwnerUsesRankAndIsIndependentOfArtifactInputOrder() throws {
        let older = artifact("owner-old", title: "Apollo", text: "", date: 10)
        let newer = artifact("owner-new", title: "Apollo", text: "", date: 20)
        let speaker = artifact("speaker", title: "Speaker", text: "Apollo", date: 30)
        let builder = DeterministicGraphBuilder()
        let first = try builder.build(from: .init(sourceID: "fixture", artifacts: [older, newer, speaker], declarations: nil, diagnostics: [], indexedAt: .distantPast))
        let second = try builder.build(from: .init(sourceID: "fixture", artifacts: [speaker, older, newer], declarations: nil, diagnostics: [], indexedAt: .distantPast))

        XCTAssertEqual(first.revision, second.revision)
        XCTAssertEqual(first.anchors, second.anchors)
        XCTAssertEqual(first.relations, second.relations)
        XCTAssertTrue(first.relations.contains { $0.source == "artifact:speaker" && $0.target == "owner-new" && $0.kind == "mentions" })
        XCTAssertFalse(first.relations.contains { $0.source == "artifact:speaker" && $0.target == "owner-old" && $0.kind == "mentions" })
    }

    func testExactMentionCanonicalNameWinsBeforeARecentAlias() throws {
        let canonical = artifact("canonical", title: "Apollo", text: "", date: 10)
        var alias = artifact("alias", title: "Mission", text: "", date: 30)
        alias.metadata.aliases = ["Apollo"]
        let speaker = artifact("speaker", title: "Speaker", text: "Apollo", date: 20)
        let snapshot = try DeterministicGraphBuilder().build(from: .init(sourceID: "fixture", artifacts: [canonical, alias, speaker], declarations: nil, diagnostics: [], indexedAt: .distantPast))

        XCTAssertTrue(snapshot.relations.contains { $0.source == "artifact:speaker" && $0.target == "canonical" && $0.kind == "mentions" })
        XCTAssertFalse(snapshot.relations.contains { $0.source == "artifact:speaker" && $0.target == "alias" && $0.kind == "mentions" })
    }

    func testExactMentionsRespectLexicalBoundariesForOverlappingPhrases() throws {
        let alpha = artifact("alpha", title: "Alpha", text: "", date: 10)
        let alphanumeric = artifact("alphanumeric", title: "Alphanumeric", text: "", date: 20)
        let speaker = artifact("speaker", title: "Speaker", text: "Alphanumeric Alpha alphabet", date: 30)
        let snapshot = try DeterministicGraphBuilder().build(from: .init(sourceID: "fixture", artifacts: [alpha, alphanumeric, speaker], declarations: nil, diagnostics: [], indexedAt: .distantPast))

        XCTAssertEqual(snapshot.relations.first { $0.source == "artifact:speaker" && $0.target == "alpha" && $0.kind == "mentions" }?.provenance.detail, "count:1")
        XCTAssertEqual(snapshot.relations.first { $0.source == "artifact:speaker" && $0.target == "alphanumeric" && $0.kind == "mentions" }?.provenance.detail, "count:1")
    }

    private func artifact(_ id: String, title: String, text: String, date: TimeInterval) -> SourceArtifact {
        .init(id: id, relativePath: "Notes/\(id).md", mediaKind: .markdown, title: title,
              extractedText: text, modifiedAt: Date(timeIntervalSince1970: date), contentHash: id,
              metadata: .init(explicitID: id, declaredTitle: title))
    }
}
