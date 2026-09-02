import XCTest
@testable import EmbersCore

final class VoiceRoutingSeedTests: XCTestCase {
    func testSeedsAreParentFirstAndContainOnlyDirectGroundedEvidence() throws {
        let artifacts = [
            SourceArtifact(
                id: "overview",
                relativePath: "Personal/Overview.md",
                mediaKind: .markdown,
                title: "Overview",
                extractedText: "---\nsecret: hidden\n---\n## Overview\n> Template guidance should not become evidence.\nA personal overview describes a trusted external system for useful knowledge. https://example.com/private",
                modifiedAt: .distantPast,
                contentHash: "overview",
                metadata: .init(tags: ["life"], headings: ["Focus", "source: private", "https://example.com/path"])
            ),
            SourceArtifact(
                id: "entry",
                relativePath: "Personal/Journal/Today.md",
                mediaKind: .markdown,
                title: "Today",
                extractedText: "A private journal entry.",
                modifiedAt: .distantPast,
                contentHash: "entry",
                metadata: .init(tags: ["diary"], headings: ["Reflection"])
            ),
        ]
        let snapshot = try DeterministicGraphBuilder().build(from: .init(
            sourceID: "fixture",
            artifacts: artifacts,
            manifest: nil,
            diagnostics: [],
            indexedAt: .distantPast
        ))
        let graph = DeterministicContextGraphProjector().project(snapshot)

        let first = VoiceRoutingSeedBuilder().build(graph: graph, snapshot: snapshot)
        let second = VoiceRoutingSeedBuilder().build(graph: graph, snapshot: snapshot)
        XCTAssertEqual(first, second)

        let personal = try XCTUnwrap(first.first { $0.canonicalName == "Personal" })
        let journal = try XCTUnwrap(first.first { $0.canonicalName == "Journal" })
        XCTAssertEqual(personal.kind, "folder")
        XCTAssertEqual(journal.kind, "folder")
        XCTAssertLessThan(try XCTUnwrap(first.firstIndex(of: personal)), try XCTUnwrap(first.firstIndex(of: journal)))
        XCTAssertEqual(personal.contextOnlyChildNames, ["Journal"])
        XCTAssertEqual(personal.directArtifactTitles, ["Overview"])
        XCTAssertFalse(personal.directHeadingsAndTags.contains(where: { $0.contains("private") || $0.contains("example.com") }))
        XCTAssertFalse(personal.directArtifactTitles.contains("Today"))
        XCTAssertEqual(journal.contextOnlyAncestry, ["Personal"])
        XCTAssertEqual(journal.directArtifactTitles, ["Today"])
        XCTAssertTrue(journal.directHeadingsAndTags.contains("diary"))
        XCTAssertFalse(personal.directExcerpts.joined().contains("secret"))
        XCTAssertFalse(personal.directExcerpts.joined().contains("Template guidance"))
        XCTAssertTrue(personal.directExcerpts.joined().contains("trusted external system"))
        XCTAssertFalse(personal.directExcerpts.joined().contains("https://"))
    }

    func testMismatchedSnapshotRevisionProducesNoSeeds() {
        let graph = ContextGraph(revision: "new", nodes: [], edges: [])
        let snapshot = ContextSnapshot(
            sourceID: "fixture",
            revision: "old",
            artifacts: [],
            anchors: [],
            relations: [],
            diagnostics: [],
            indexedAt: .distantPast
        )
        XCTAssertTrue(VoiceRoutingSeedBuilder().build(graph: graph, snapshot: snapshot).isEmpty)
    }

    func testTaskStateOnlyRevisionChangePreservesVoiceEvidence() throws {
        func makeSnapshot(revision: String, taskState: SourceTaskState) -> ContextSnapshot {
            let artifact = SourceArtifact(
                id: "project-note",
                relativePath: "Projects/Embers.md",
                mediaKind: .markdown,
                title: "Embers",
                extractedText: "A local-first context engine.",
                modifiedAt: .distantPast,
                contentHash: "content-\(revision)",
                metadata: .init(
                    tags: ["product"],
                    headings: ["Overview"],
                    tasks: [.init(id: "ship", text: "Ship the release", state: taskState)]
                )
            )
            let anchor = Anchor(
                id: "projects",
                canonicalName: "Projects",
                provenance: [.folder],
                evidence: .init(folder: true),
                memberArtifactIDs: [artifact.id],
                scopePath: "Projects"
            )
            return ContextSnapshot(
                sourceID: "fixture",
                revision: revision,
                artifacts: [artifact],
                anchors: [anchor],
                relations: [],
                diagnostics: [],
                indexedAt: .distantPast
            )
        }

        let before = makeSnapshot(revision: "before-task-check", taskState: .open)
        let after = makeSnapshot(revision: "after-task-check", taskState: .completed)
        let beforeSeeds = VoiceRoutingSeedBuilder().build(
            graph: DeterministicContextGraphProjector().project(before),
            snapshot: before
        )
        let afterSeeds = VoiceRoutingSeedBuilder().build(
            graph: DeterministicContextGraphProjector().project(after),
            snapshot: after
        )

        XCTAssertEqual(beforeSeeds.map(\.nodeID), afterSeeds.map(\.nodeID))
        XCTAssertEqual(beforeSeeds.map(\.evidenceHash), afterSeeds.map(\.evidenceHash))
        XCTAssertEqual(
            VoiceRoutingInputRevision.make(beforeSeeds),
            VoiceRoutingInputRevision.make(afterSeeds)
        )
    }

    func testAddressabilityExcludesProvenTemplatePlaceholdersWithoutNameHeuristics() {
        let template = SourceArtifact(
            id: "template",
            relativePath: "_Scaffolding/Schema.md",
            mediaKind: .markdown,
            title: "Schema",
            extractedText: "",
            modifiedAt: .distantPast,
            contentHash: "template",
            metadata: .init(tags: ["Schema"], headings: ["Overview", "Details", "See Also"])
        )
        let copiedTemplate = SourceArtifact(
            id: "copied-template",
            relativePath: "Projects/Concrete Example.md",
            mediaKind: .markdown,
            title: "Concrete Example",
            extractedText: "",
            modifiedAt: .distantPast,
            contentHash: "copied-template",
            metadata: .init(
                tags: ["Schema", "Independent-Topic"],
                headings: ["Overview", "Project Notes", "Details", "See Also"]
            )
        )
        let readme = SourceArtifact(
            id: "readme",
            relativePath: "README.md",
            mediaKind: .markdown,
            title: "Readme",
            extractedText: "",
            modifiedAt: .distantPast,
            contentHash: "readme"
        )
        let placeholder = Anchor(
            id: "virtual-placeholder",
            canonicalName: "Arbitrary Label",
            provenance: [.unresolvedLink],
            evidence: .init(inboundLinkCount: 3, exactMentionCount: 7)
        )
        let syntaxOnly = Anchor(
            id: "virtual-syntax",
            canonicalName: "Another Arbitrary Label",
            provenance: [.unresolvedLink],
            evidence: .init(inboundLinkCount: 3, exactMentionCount: 0)
        )
        let grounded = Anchor(
            id: "virtual-grounded",
            canonicalName: "Useful Concept",
            provenance: [.unresolvedLink],
            evidence: .init(inboundLinkCount: 3, exactMentionCount: 2)
        )
        let mixed = Anchor(
            id: "virtual-mixed",
            canonicalName: "Mixed Provenance Concept",
            provenance: [.unresolvedLink],
            evidence: .init(inboundLinkCount: 3, exactMentionCount: 1)
        )
        let inheritedOnly = Anchor(
            id: "virtual-inherited-only",
            canonicalName: "Copied Schema Slot",
            provenance: [.unresolvedLink],
            evidence: .init(inboundLinkCount: 2, exactMentionCount: 2)
        )
        let copiedButIndependent = Anchor(
            id: "virtual-copied-independent",
            canonicalName: "Independent Addition",
            provenance: [.unresolvedLink],
            evidence: .init(inboundLinkCount: 1, exactMentionCount: 1)
        )
        let folder = Anchor(
            id: "folder",
            canonicalName: "_Scaffolding",
            provenance: [.folder],
            evidence: .init(folder: true),
            memberArtifactIDs: ["template"],
            scopePath: "_Scaffolding"
        )
        let snapshot = ContextSnapshot(
            sourceID: "fixture",
            revision: "revision",
            artifacts: [template, copiedTemplate, readme],
            anchors: [placeholder, syntaxOnly, grounded, mixed, inheritedOnly, copiedButIndependent, folder],
            relations: [
                .init(source: "artifact:template", target: placeholder.id, kind: "links-to", provenance: .init(artifactID: template.id)),
                .init(source: "artifact:readme", target: syntaxOnly.id, kind: "links-to", provenance: .init(artifactID: readme.id)),
                .init(source: "artifact:readme", target: grounded.id, kind: "links-to", provenance: .init(artifactID: readme.id)),
                .init(source: "artifact:template", target: mixed.id, kind: "links-to", provenance: .init(artifactID: template.id)),
                .init(source: "artifact:copied-template", target: mixed.id, kind: "links-to", provenance: .init(artifactID: copiedTemplate.id)),
                .init(source: "artifact:readme", target: mixed.id, kind: "links-to", provenance: .init(artifactID: readme.id)),
                .init(source: "artifact:template", target: inheritedOnly.id, kind: "links-to", provenance: .init(artifactID: template.id)),
                .init(source: "artifact:copied-template", target: inheritedOnly.id, kind: "links-to", provenance: .init(artifactID: copiedTemplate.id)),
                .init(source: "artifact:copied-template", target: copiedButIndependent.id, kind: "links-to", provenance: .init(artifactID: copiedTemplate.id)),
            ],
            diagnostics: [],
            indexedAt: .distantPast
        )
        let graph = ContextGraph(
            revision: snapshot.revision,
            nodes: [placeholder, syntaxOnly, grounded, mixed, inheritedOnly, copiedButIndependent, folder].map {
                GraphNode(id: $0.id, name: $0.canonicalName, role: .context, activationEligible: true, voiceEligible: true, importance: 1, referenceID: $0.id)
            },
            edges: []
        )

        let addressable = VoiceRoutingAddressabilityPolicy().nodes(in: graph, snapshot: snapshot)

        XCTAssertEqual(
            Set(addressable.map(\.id)),
            [syntaxOnly.id, grounded.id, mixed.id, copiedButIndependent.id, folder.id]
        )
        XCTAssertEqual(
            Set(VoiceRoutingSeedBuilder().build(graph: graph, snapshot: snapshot).map(\.nodeID)),
            [folder.id, syntaxOnly.id, grounded.id, mixed.id, copiedButIndependent.id]
        )
    }
}
