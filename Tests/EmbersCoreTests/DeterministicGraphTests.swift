import XCTest
@testable import EmbersCore

final class DeterministicGraphTests: XCTestCase {
    func testIdenticalInputProducesIdenticalRevisionAndRanking() throws {
        let date = Date(timeIntervalSince1970: 100)
        let artifact = SourceArtifact(id: "a", relativePath: "Projects/Apollo.md", mediaKind: .markdown, title: "Apollo", extractedText: "Apollo links [[Sarah]]", modifiedAt: date, contentHash: "hash", localURL: URL(fileURLWithPath: "/tmp/Apollo.md"), metadata: .init(declaredTitle: "Apollo", aliases: ["Launch"], links: [.init(target: "Sarah", kind: .wiki)]))
        let scan = SourceScan(sourceID: "source", artifacts: [artifact], manifest: nil, diagnostics: [], indexedAt: date)
        let first = try DeterministicGraphBuilder().build(from: scan)
        let second = try DeterministicGraphBuilder().build(from: scan)
        XCTAssertEqual(first.revision, second.revision)
        XCTAssertEqual(first.anchors.map(\.id), second.anchors.map(\.id))
        XCTAssertTrue(first.anchors.contains(where: { $0.canonicalName == "Sarah" }))
        XCTAssertEqual(first.anchors.first(where: { $0.canonicalName == "Apollo" })?.evidence.exactMentionCount, 1)
    }

    func testCanonicalCollisionWinsBeforeAlias() throws {
        let date = Date(timeIntervalSince1970: 100)
        let canonical = Anchor(id: "canonical", canonicalName: "Apollo", provenance: [.manifest], evidence: .init(manifest: true))
        let alias = Anchor(id: "alias", canonicalName: "Moonshot", aliases: ["Apollo"], provenance: [.folder], evidence: .init(folder: true))
        let snapshot = ContextSnapshot(sourceID: "s", revision: "r", artifacts: [], anchors: [alias, canonical], relations: [], diagnostics: [], indexedAt: date)
        XCTAssertEqual(LinearContextSearch().match("tell me about Apollo", in: snapshot)?.id, "canonical")
    }

    func testContextProjectionSuppressesWeakAndDuplicateAnchorsWithoutRemovingMatching() throws {
        let date = Date(timeIntervalSince1970: 100)
        let anchors = [
            Anchor(id: "winner", canonicalName: "Apollo", provenance: [.frontmatter], evidence: .init(frontmatter: true), memberArtifactIDs: ["a"]),
            Anchor(id: "duplicate", canonicalName: "apollo", provenance: [.frontmatter], memberArtifactIDs: ["b"]),
            Anchor(id: "single-folder", canonicalName: "Scratch", provenance: [.folder], evidence: .init(folder: true), memberArtifactIDs: ["a"]),
            Anchor(id: "useful-folder", canonicalName: "Work", provenance: [.folder], evidence: .init(folder: true), memberArtifactIDs: ["a", "b"]),
            Anchor(id: "single-tag", canonicalName: "Later", kind: "tag", provenance: [.tag], memberArtifactIDs: ["a"])
        ]
        let snapshot = ContextSnapshot(sourceID: "s", revision: "r", artifacts: [], anchors: anchors, relations: [], diagnostics: [], indexedAt: date)
        let search = LinearContextSearch()

        XCTAssertEqual(search.summaries(in: snapshot).map(\.name), ["Apollo", "Work"])
        XCTAssertEqual(search.vocabulary(in: snapshot), ["Apollo", "Work"])
        XCTAssertEqual(search.match("open Scratch", in: snapshot)?.id, "single-folder")

        let graphSearch = GraphContextSearch(graph: DeterministicContextGraphProjector().project(snapshot))
        XCTAssertFalse(graphSearch.activationNodes.contains { $0.id == "single-folder" })
        XCTAssertTrue(graphSearch.voiceNodes.contains { $0.id == "single-folder" })
        XCTAssertEqual(graphSearch.resolve("open Scratch")?.nodeID, "single-folder")
    }

    func testTitleOnlyFrontmatterDoesNotOutrankFolderEvidence() throws {
        let date = Date(timeIntervalSince1970: 100)
        let titled = SourceArtifact(id: "a", relativePath: "Docs/Example.md", mediaKind: .markdown, title: "Example", extractedText: "", modifiedAt: date, contentHash: "a", localURL: URL(fileURLWithPath: "/tmp/Example.md"), metadata: .init(declaredTitle: "Example"))
        let sibling = SourceArtifact(id: "b", relativePath: "Docs/Other.md", mediaKind: .markdown, title: "Other", extractedText: "", modifiedAt: date, contentHash: "b", localURL: URL(fileURLWithPath: "/tmp/Other.md"))
        let snapshot = try DeterministicGraphBuilder().build(from: .init(sourceID: "s", artifacts: [titled, sibling], manifest: nil, diagnostics: [], indexedAt: date))

        XCTAssertEqual(snapshot.anchors.first?.canonicalName, "Docs")
        XCTAssertFalse(try XCTUnwrap(snapshot.anchors.first(where: { $0.canonicalName == "Example" })).evidence.frontmatter)
    }

    func testExactMentionsBecomePerDocumentGraphEdges() throws {
        let date = Date(timeIntervalSince1970: 100)
        let artifact = SourceArtifact(id: "d", relativePath: "Notes/Weekly.md", mediaKind: .markdown, title: "Weekly", extractedText: "Apollo met Apollo yesterday.", modifiedAt: date, contentHash: "h", localURL: URL(fileURLWithPath: "/tmp/Weekly.md"))
        let manifest = ContextManifest(version: 1, anchors: [.init(id: "apollo", name: "Apollo", paths: ["Notes/Weekly.md"])])
        let snapshot = try DeterministicGraphBuilder().build(from: .init(sourceID: "s", artifacts: [artifact], manifest: manifest, diagnostics: [], indexedAt: date))
        let mention = try XCTUnwrap(snapshot.relations.first { $0.kind == "mentions" && $0.target == "apollo" })

        XCTAssertEqual(mention.source, "artifact:d")
        XCTAssertEqual(mention.provenance.detail, "count:2")
        XCTAssertEqual(mention.evidence, .extracted)
        XCTAssertEqual(mention.weight, 0.75)
    }

    func testEvidenceNodeResolvesToNearestActivationNode() throws {
        let date = Date(timeIntervalSince1970: 100)
        let artifact = SourceArtifact(id: "d", relativePath: "Weekly.md", mediaKind: .markdown, title: "Weekly", extractedText: "Apollo launch schedule", modifiedAt: date, contentHash: "h", localURL: URL(fileURLWithPath: "/tmp/Weekly.md"))
        let apollo = Anchor(id: "apollo", canonicalName: "Apollo", provenance: [.manifest], evidence: .init(manifest: true), memberArtifactIDs: ["d"])
        let launch = Anchor(id: "launch", canonicalName: "Launch", provenance: [.unresolvedLink], evidence: .init(inboundLinkCount: 2))
        let snapshot = ContextSnapshot(sourceID: "s", revision: "r", artifacts: [artifact], anchors: [apollo, launch], relations: [
            .init(source: "artifact:d", target: "launch", kind: "mentions", provenance: .init(artifactID: "d"), evidence: .extracted, weight: 0.75)
        ], diagnostics: [], indexedAt: date)
        let graph = DeterministicContextGraphProjector().project(snapshot)
        let search = GraphContextSearch(graph: graph)

        XCTAssertEqual(search.resolve("show me Apollo")?.nodeID, "apollo")
        XCTAssertEqual(search.nearestActivation(toEvidenceNode: "artifact:d")?.nodeID, "apollo")
        XCTAssertTrue(try XCTUnwrap(search.detail(nodeID: "apollo", in: snapshot)).relatedAnchors.contains { $0.id == "launch" })
    }

    func testGeneratedUntitledNodeIsNotVoiceEligible() {
        for name in ["Untitled 14", "Untitled 324e-6a28"] {
            let anchor = Anchor(id: "untitled", canonicalName: name, provenance: [.linkedDocument], memberArtifactIDs: ["d"])
            let artifact = SourceArtifact(id: "d", relativePath: "\(name).md", mediaKind: .markdown, title: name, extractedText: "", modifiedAt: .distantPast, contentHash: "h", localURL: URL(fileURLWithPath: "/tmp/\(name).md"))
            let snapshot = ContextSnapshot(sourceID: "s", revision: "r", artifacts: [artifact], anchors: [anchor], relations: [], diagnostics: [], indexedAt: .distantPast)

            XCTAssertTrue(DeterministicContextGraphProjector().project(snapshot).activationNodes.isEmpty)
        }
    }

    func testEmbedsConnectDocumentsWithoutPromotingAttachmentAnchor() throws {
        let source = SourceArtifact(id: "note", relativePath: "Note.md", mediaKind: .markdown, title: "Note", extractedText: "![[image.png]]", modifiedAt: .distantPast, contentHash: "n", localURL: URL(fileURLWithPath: "/tmp/Note.md"), metadata: .init(links: [.init(target: "image.png", kind: .embed)]))
        let image = SourceArtifact(id: "image", relativePath: "image.png", mediaKind: .other, title: "image.png", extractedText: "", modifiedAt: .distantPast, contentHash: "i", localURL: URL(fileURLWithPath: "/tmp/image.png"))
        let snapshot = try DeterministicGraphBuilder().build(from: .init(sourceID: "s", artifacts: [source, image], manifest: nil, diagnostics: [], indexedAt: .distantPast))

        XCTAssertFalse(snapshot.anchors.contains { $0.canonicalName == "image.png" })
        XCTAssertTrue(snapshot.relations.contains { $0.source == "artifact:note" && $0.target == "artifact:image" && $0.kind == "embeds" })
    }

    func testManifestPathsCannotEscapeRootAndInvalidRelationsAreNonFatal() throws {
        let artifact = SourceArtifact(id: "a", relativePath: "Notes/A.md", mediaKind: .markdown, title: "A", extractedText: "", modifiedAt: .distantPast, contentHash: "h", localURL: URL(fileURLWithPath: "/tmp/A.md"))
        let manifest = ContextManifest(version: 1, anchors: [.init(id: "safe", name: "Safe", paths: ["../secret", "Missing"]), .init(id: "safe", name: "Duplicate")], relations: [.init(from: "safe", to: "missing", kind: "involves")])
        let snapshot = try DeterministicGraphBuilder().build(from: .init(sourceID: "s", artifacts: [artifact], manifest: manifest, diagnostics: [], indexedAt: .distantPast))
        XCTAssertNotNil(snapshot.anchors.first(where: { $0.id == "safe" }))
        XCTAssertTrue(snapshot.diagnostics.contains(where: { $0.message.contains("outside") }))
        XCTAssertTrue(snapshot.diagnostics.contains(where: { $0.message.contains("duplicate") }))
        XCTAssertTrue(snapshot.relations.isEmpty)
    }

    func testRetrievalOrdersMembershipBeforeLinksBeforeMentionsAndCapsResults() throws {
        let date = Date(timeIntervalSince1970: 200)
        let artifacts = (0..<15).map { index in
            SourceArtifact(id: "d\(index)", relativePath: "d\(index).md", mediaKind: .markdown, title: "Doc \(index)", extractedText: "Apollo appears here with enough context for a useful snippet.", modifiedAt: date.addingTimeInterval(Double(index)), contentHash: "h\(index)", localURL: URL(fileURLWithPath: "/tmp/d\(index).md"), metadata: .init(uncheckedTasks: [.init(text: "Task \(index)", line: 1)]))
        }
        let anchor = Anchor(id: "apollo", canonicalName: "Apollo", provenance: [.manifest], evidence: .init(manifest: true), memberArtifactIDs: ["d0"])
        let snapshot = ContextSnapshot(sourceID: "s", revision: "r", artifacts: artifacts, anchors: [anchor], relations: [.init(source: "artifact:d1", target: "apollo", kind: "links-to", provenance: .init(artifactID: "d1"))], diagnostics: [], indexedAt: date)
        let detail = try XCTUnwrap(LinearContextSearch().detail(anchorID: "apollo", in: snapshot, lastSeen: date))
        XCTAssertEqual(detail.hits.count, 12)
        XCTAssertEqual(detail.hits[0].id, "d0")
        XCTAssertEqual(detail.hits[1].id, "d1")
        XCTAssertEqual(detail.tasks.count, 10)
        XCTAssertTrue(detail.hits.contains(where: \.changedSinceLastPeek))
    }

    func testProjectTasksAreSelectedIndependentlyFromVisibleDocumentHits() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let documents = (0..<13).map { index in
            SourceArtifact(
                id: "document-\(index)",
                relativePath: "Documents/\(index).md",
                mediaKind: .markdown,
                title: "Document \(index)",
                extractedText: "Apollo project documentation with detailed prose. " + String(repeating: "context ", count: 40),
                modifiedAt: date.addingTimeInterval(Double(100 + index)),
                contentHash: "document-\(index)",
                localURL: URL(fileURLWithPath: "/tmp/document-\(index).md")
            )
        }
        let taskArtifacts = (0..<11).map { index in
            SourceArtifact(
                id: "task-\(index)",
                relativePath: "Tasks/\(index).md",
                mediaKind: .markdown,
                title: "Task \(index)",
                extractedText: "Apollo",
                modifiedAt: date.addingTimeInterval(Double(index)),
                contentHash: "task-\(index)",
                localURL: URL(fileURLWithPath: "/tmp/task-\(index).md"),
                metadata: .init(uncheckedTasks: [.init(id: "open-\(index)", text: "Open task \(index)")])
            )
        }
        let artifacts = documents + taskArtifacts
        let anchor = Anchor(
            id: "apollo",
            canonicalName: "Apollo",
            provenance: [.manifest],
            evidence: .init(manifest: true),
            memberArtifactIDs: Set(artifacts.map(\.id))
        )
        let snapshot = ContextSnapshot(
            sourceID: "s",
            revision: "r",
            artifacts: artifacts,
            anchors: [anchor],
            relations: [],
            diagnostics: [],
            indexedAt: date
        )
        let graph = DeterministicContextGraphProjector().project(snapshot)
        let details = [
            try XCTUnwrap(LinearContextSearch().detail(anchorID: anchor.id, in: snapshot)),
            try XCTUnwrap(GraphContextSearch(graph: graph, snapshot: snapshot).detail(nodeID: anchor.id, in: snapshot)),
        ]

        for detail in details {
            XCTAssertEqual(detail.hits.count, 12)
            XCTAssertTrue(detail.hits.allSatisfy { $0.id.hasPrefix("document-") })
            XCTAssertEqual(detail.tasks.map(\.taskID), (1...10).reversed().map { "open-\($0)" })
        }
    }

    func testFolderProjectionKeepsImmediateHierarchyAndDescendantCounts() throws {
        let artifacts = [
            SourceArtifact(id: "direct", relativePath: "Personal/Overview.md", mediaKind: .markdown, title: "Overview", extractedText: "A useful personal overview.", modifiedAt: .distantPast, contentHash: "d", localURL: URL(fileURLWithPath: "/tmp/Overview.md")),
            SourceArtifact(id: "j1", relativePath: "Personal/Journal/One.md", mediaKind: .markdown, title: "One", extractedText: "A first journal entry with prose.", modifiedAt: .distantPast, contentHash: "j1", localURL: URL(fileURLWithPath: "/tmp/One.md")),
            SourceArtifact(id: "j2", relativePath: "Personal/Journal/Two.md", mediaKind: .markdown, title: "Two", extractedText: "A second journal entry with prose.", modifiedAt: .distantPast, contentHash: "j2", localURL: URL(fileURLWithPath: "/tmp/Two.md")),
        ]
        let snapshot = try DeterministicGraphBuilder().build(from: .init(sourceID: "s", artifacts: artifacts, manifest: nil, diagnostics: [], indexedAt: .distantPast))
        let personal = try XCTUnwrap(snapshot.anchors.first { $0.canonicalName == "Personal" })
        let journal = try XCTUnwrap(snapshot.anchors.first { $0.canonicalName == "Journal" })
        let graph = DeterministicContextGraphProjector().project(snapshot)
        let search = GraphContextSearch(graph: graph)
        let detail = try XCTUnwrap(search.detail(nodeID: personal.id, in: snapshot))

        XCTAssertEqual(detail.subcontexts.map(\.id), [journal.id])
        XCTAssertEqual(detail.hits.map(\.id), ["direct"])
        XCTAssertEqual(search.summaries(in: snapshot).first(where: { $0.id == personal.id })?.documentCount, 3)
        XCTAssertFalse(graph.edges.contains { $0.source == personal.id && $0.target == "artifact:j1" })
        XCTAssertTrue(graph.edges.contains { $0.source == personal.id && $0.target == journal.id && $0.kind == "contains-context" })
    }

    func testHomeProjectionPromotesMeaningfulDestinationsWithoutFlatteningTheirChildren() throws {
        let artifacts = [
            SourceArtifact(id: "apollo-overview", relativePath: "Projects/Apollo/Overview.md", mediaKind: .markdown, title: "Overview", extractedText: "Apollo overview.", modifiedAt: .distantPast, contentHash: "a1", localURL: URL(fileURLWithPath: "/tmp/Overview.md")),
            SourceArtifact(id: "apollo-brief", relativePath: "Projects/Apollo/Brief.md", mediaKind: .markdown, title: "Brief", extractedText: "Apollo brief.", modifiedAt: .distantPast, contentHash: "a2", localURL: URL(fileURLWithPath: "/tmp/Brief.md")),
            SourceArtifact(id: "launch-one", relativePath: "Projects/Apollo/Launch/One.md", mediaKind: .markdown, title: "One", extractedText: "Launch one.", modifiedAt: .distantPast, contentHash: "l1", localURL: URL(fileURLWithPath: "/tmp/One.md")),
            SourceArtifact(id: "launch-two", relativePath: "Projects/Apollo/Launch/Two.md", mediaKind: .markdown, title: "Two", extractedText: "Launch two.", modifiedAt: .distantPast, contentHash: "l2", localURL: URL(fileURLWithPath: "/tmp/Two.md")),
            SourceArtifact(id: "northstar-one", relativePath: "Projects/Northstar/One.md", mediaKind: .markdown, title: "One", extractedText: "Northstar one.", modifiedAt: .distantPast, contentHash: "n1", localURL: URL(fileURLWithPath: "/tmp/Northstar-One.md")),
            SourceArtifact(id: "northstar-two", relativePath: "Projects/Northstar/Two.md", mediaKind: .markdown, title: "Two", extractedText: "Northstar two.", modifiedAt: .distantPast, contentHash: "n2", localURL: URL(fileURLWithPath: "/tmp/Northstar-Two.md")),
        ]
        let snapshot = try DeterministicGraphBuilder().build(from: .init(sourceID: "s", artifacts: artifacts, manifest: nil, diagnostics: [], indexedAt: .distantPast))
        let graph = DeterministicContextGraphProjector().project(snapshot)
        let search = GraphContextSearch(graph: graph, snapshot: snapshot)

        XCTAssertEqual(search.homeSummaries(in: snapshot).map(\.name), ["Apollo", "Northstar"])
        XCTAssertTrue(search.voiceNodes.contains { $0.name == "Projects" })
        XCTAssertTrue(search.voiceNodes.contains { $0.name == "Launch" })
        let apollo = try XCTUnwrap(graph.nodes.first { $0.name == "Apollo" })
        XCTAssertEqual(try XCTUnwrap(search.detail(nodeID: apollo.id, in: snapshot)).subcontexts.map(\.name), ["Launch"])
    }

    func testImportPathsAndFrontmatterDoNotBecomeSemanticMentions() throws {
        let artifacts = [
            SourceArtifact(id: "p1", relativePath: "Personal/A.md", mediaKind: .markdown, title: "A", extractedText: "One readable note.", modifiedAt: .distantPast, contentHash: "p1", localURL: URL(fileURLWithPath: "/tmp/A.md")),
            SourceArtifact(id: "p2", relativePath: "Personal/B.md", mediaKind: .markdown, title: "B", extractedText: "Another readable note.", modifiedAt: .distantPast, contentHash: "p2", localURL: URL(fileURLWithPath: "/tmp/B.md")),
            SourceArtifact(id: "outside", relativePath: "Elsewhere/Index.md", mediaKind: .markdown, title: "Index", extractedText: "---\ncategory: Personal\n---\n[[Export/Personal/Investments/Gold.md]]", modifiedAt: .distantPast, contentHash: "o", localURL: URL(fileURLWithPath: "/tmp/Index.md")),
        ]
        let snapshot = try DeterministicGraphBuilder().build(from: .init(sourceID: "s", artifacts: artifacts, manifest: nil, diagnostics: [], indexedAt: .distantPast))
        let personal = try XCTUnwrap(snapshot.anchors.first { $0.canonicalName == "Personal" })

        XCTAssertFalse(snapshot.relations.contains { $0.source == "artifact:outside" && $0.target == personal.id && $0.kind == "mentions" })
    }

    func testLiteralSearchFindsFactualFileFromQuestionWords() {
        let date = Date(timeIntervalSince1970: 100)
        let passport = SourceArtifact(
            id: "identity",
            relativePath: "Private/Identity.md",
            mediaKind: .markdown,
            title: "Identity",
            extractedText: "# Identity\n\nPassport number: TEST-1234-5678\nIssued by the synthetic fixture office.",
            modifiedAt: date,
            contentHash: "identity",
            localURL: URL(fileURLWithPath: "/tmp/Identity.md")
        )
        let unrelated = SourceArtifact(
            id: "travel",
            relativePath: "Travel/Plans.md",
            mediaKind: .markdown,
            title: "Travel plans",
            extractedText: "A trip needs a passport and a valid document.",
            modifiedAt: date,
            contentHash: "travel",
            localURL: URL(fileURLWithPath: "/tmp/Plans.md")
        )
        let snapshot = ContextSnapshot(sourceID: "s", revision: "r", artifacts: [unrelated, passport], anchors: [], relations: [], diagnostics: [], indexedAt: date)
        let search = GraphContextSearch(graph: .init(revision: "r", nodes: [], edges: []), snapshot: snapshot)

        let hits = search.literalSearch("what's my passport number?", in: snapshot)

        XCTAssertEqual(hits.first?.id, "identity")
        XCTAssertTrue(hits.first?.snippet.contains("Passport number: TEST-1234-5678") == true)
    }

    func testLiteralSearchUsesVisibleFileMetadataButIgnoresLinkTargetsAndStopWords() {
        let date = Date(timeIntervalSince1970: 100)
        let namedFile = SourceArtifact(
            id: "named-file",
            relativePath: "Identity/Passport number.md",
            mediaKind: .markdown,
            title: "Passport number",
            extractedText: "",
            modifiedAt: date,
            contentHash: "named",
            localURL: URL(fileURLWithPath: "/tmp/passport.md")
        )
        let linkOnly = SourceArtifact(
            id: "link-only",
            relativePath: "Notes.md",
            mediaKind: .markdown,
            title: "Notes",
            extractedText: "---\ncategory: passport\n---\n[[Passport/number.md]]",
            modifiedAt: date,
            contentHash: "link",
            localURL: URL(fileURLWithPath: "/tmp/notes.md")
        )
        let snapshot = ContextSnapshot(sourceID: "s", revision: "r", artifacts: [linkOnly, namedFile], anchors: [], relations: [], diagnostics: [], indexedAt: date)
        let search = GraphContextSearch(graph: .init(revision: "r", nodes: [], edges: []), snapshot: snapshot)

        XCTAssertTrue(search.literalSearch("what is my", in: snapshot).isEmpty)
        XCTAssertEqual(search.literalSearch("passport number", in: snapshot).map(\.id), ["named-file"])
    }
}
