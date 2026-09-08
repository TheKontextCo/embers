import EmbersCore
import EmbersLocal
import XCTest
@testable import embers

final class ContextLensTests: XCTestCase {
    func testRequestReadinessRequiresCoherentSnapshotsButDoesNotRequireAModelPack() throws {
        let snapshot = ContextSnapshot(sourceID: "workspace", revision: "revision", artifacts: [],
            anchors: [], relations: [], diagnostics: [], indexedAt: .distantPast)
        let graph = ContextGraph(revision: "revision", nodes: [], edges: [])
        let source = ContextSnapshot(sourceID: "folder:test", revision: "source-revision", artifacts: [],
            anchors: [], relations: [], diagnostics: [], indexedAt: .distantPast)
        func request(source: ContextSnapshot?, graph: ContextGraph?, snapshot: ContextSnapshot?,
                     pack: VoiceRoutingPack? = nil) -> ContextLensRequest? {
            ContextLensRequest(sourceID: "folder:test", sourceName: "Test", sourceSnapshot: source,
                graph: graph, snapshot: snapshot, pack: pack)
        }

        XCTAssertNotNil(request(source: source, graph: graph, snapshot: snapshot))
        XCTAssertNil(request(source: nil, graph: graph, snapshot: snapshot))
        XCTAssertNil(request(source: source, graph: nil, snapshot: snapshot))
        XCTAssertNil(request(source: source, graph: graph, snapshot: nil))
        var staleGraph = graph
        staleGraph.revision = "previous-revision"
        XCTAssertNil(request(source: source, graph: staleGraph, snapshot: snapshot))
        var pack = VoiceRoutingPack(graphRevision: "previous-revision", compilerVersion: "test",
            modelVersion: "test", generatedAt: .distantPast, cards: [])
        XCTAssertNil(request(source: source, graph: graph, snapshot: snapshot, pack: pack))
        pack.graphRevision = graph.revision
        XCTAssertNotNil(request(source: source, graph: graph, snapshot: snapshot, pack: pack))
    }

    func testBaselineOwnershipIncludesOtherSourcesWithoutExportingTheirModelInputs() throws {
        let local = Anchor(id: "local", canonicalName: "America Trip", provenance: [.folder], memberArtifactIDs: [])
        let remote = Anchor(id: "remote", canonicalName: "America Notes", provenance: [.manifest], memberArtifactIDs: [])
        let snapshot = ContextSnapshot(sourceID: "workspace", revision: "revision", artifacts: [],
            anchors: [local, remote], relations: [], diagnostics: [], indexedAt: .distantPast)
        let graph = ContextGraph(revision: snapshot.revision,
            nodes: [node(id: "trip", anchor: local), node(id: "notes", anchor: remote)], edges: [])
        let source = ContextSnapshot(sourceID: "folder:test", revision: "source", artifacts: [],
            anchors: [local], relations: [], diagnostics: [], indexedAt: .distantPast)
        let request = try XCTUnwrap(ContextLensRequest(
            sourceID: source.sourceID, sourceName: "Test", sourceSnapshot: source,
            graph: graph, snapshot: snapshot, pack: nil))
        let document = try XCTUnwrap(request.build())
        XCTAssertEqual(document.entries.map(\.nodeID), ["trip"])
        let america = try XCTUnwrap(document.entries.first?.deterministicDecision.baselineMatches.first {
            $0.trigger.pattern == .phrase("america")
        })
        XCTAssertTrue(america.isActive)
        XCTAssertEqual(america.ownerNodeIDs, ["notes", "trip"])
    }

    func testDocumentIncludesOnlyContextsOwnedByTheRequestedSource() throws {
        let folderAnchor = Anchor(
            id: "folder-anchor",
            canonicalName: "Garden",
            provenance: [.folder],
            memberArtifactIDs: ["folder-note"]
        )
        let kontextAnchor = Anchor(
            id: "kontext-anchor",
            canonicalName: "Embers",
            provenance: [.manifest],
            memberArtifactIDs: ["kontext-note"]
        )
        let folderArtifact = artifact(
            id: "folder-note",
            title: "Garden Notes",
            sourceID: "folder:vault"
        )
        let kontextArtifact = artifact(
            id: "kontext-note",
            title: "Open Source Plan",
            sourceID: "kontext:workspace"
        )
        let snapshot = ContextSnapshot(
            sourceID: "workspace",
            revision: "revision",
            artifacts: [folderArtifact, kontextArtifact],
            anchors: [folderAnchor, kontextAnchor],
            relations: [
                .init(source: folderAnchor.id, target: folderArtifact.id, kind: "contains-directly"),
                .init(source: kontextAnchor.id, target: kontextArtifact.id, kind: "contains-directly"),
            ],
            diagnostics: [],
            indexedAt: .init(timeIntervalSince1970: 1)
        )
        let graph = ContextGraph(
            revision: snapshot.revision,
            nodes: [
                node(id: "folder-node", anchor: folderAnchor),
                node(id: "kontext-node", anchor: kontextAnchor),
                documentNode(folderArtifact),
                documentNode(kontextArtifact),
            ],
            edges: [
                .init(id: "folder-edge", source: "folder-node", target: "folder-note", kind: "contains-directly", evidence: .authored, weight: 1),
                .init(id: "kontext-edge", source: "kontext-node", target: "kontext-note", kind: "contains-directly", evidence: .authored, weight: 1),
            ]
        )
        let pack = VoiceRoutingPack(
            graphRevision: snapshot.revision,
            compilerVersion: "compiler",
            modelVersion: "model",
            generatedAt: .init(timeIntervalSince1970: 2),
            cards: [
                card(nodeID: "folder-node", title: "Garden", alias: "my garden"),
                card(nodeID: "kontext-node", title: "Embers", alias: "open source work"),
            ]
        )

        let request = try XCTUnwrap(ContextLensRequest(
            sourceID: "folder:vault",
            sourceName: "My Obsidian Vault",
            sourceSnapshot: ContextSnapshot(
                sourceID: "folder:vault",
                revision: "folder-revision",
                artifacts: [folderArtifact],
                anchors: [folderAnchor],
                relations: [],
                diagnostics: [],
                indexedAt: .init(timeIntervalSince1970: 1)
            ),
            graph: graph,
            snapshot: snapshot,
            pack: pack
        ))
        let document = try XCTUnwrap(request.build())

        XCTAssertEqual(document.name, "Context Lens")
        XCTAssertEqual(document.source.id, "folder:vault")
        XCTAssertEqual(document.source.name, "My Obsidian Vault")
        XCTAssertEqual(document.entries.map(\.title), ["Garden"])
        XCTAssertEqual(document.entries[0].input.directArtifactTitles, ["Garden Notes"])
        XCTAssertEqual(document.entries[0].modelProposal.semanticAliases, ["my garden"])
        XCTAssertEqual(document.entries[0].deterministicDecision.acceptedTriggers.map(\.pattern.displayPhrase), ["my garden"])
    }

    func testExporterWritesReadableJSONAndOpensItWithTheDefaultApplication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-lens-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var openedURL: URL?
        let exporter = ContextLensFileExporter(
            directoryURL: root,
            openURL: { url in openedURL = url; return true }
        )
        let document = ContextLensDocument(
            source: .init(id: "kontext:workspace", name: "Kontext"),
            graphRevision: "revision",
            compilerVersion: "compiler",
            modelVersion: "model",
            generatedAt: .init(timeIntervalSince1970: 2),
            entries: []
        )

        let writtenURL = try exporter.write(document)
        XCTAssertNil(openedURL, "Background encoding and writing must not invoke the UI opener")
        let writtenDocument = try JSONDecoder.contextLens.decode(
            ContextLensDocument.self, from: Data(contentsOf: writtenURL))
        XCTAssertEqual(writtenDocument, document)

        let url = try exporter.writeAndOpen(document)
        XCTAssertEqual(url, writtenURL)

        XCTAssertEqual(openedURL, url)
        XCTAssertEqual(url.pathExtension, "json")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("context-lens-kontext-"))
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder.contextLens.decode(ContextLensDocument.self, from: data)
        XCTAssertEqual(decoded, document)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\n  \"compilerVersion\""))
    }

    func testDocumentExposesSelectedTitleWordAndDeterministicDecision() throws {
        let anchor = Anchor(
            id: "america-anchor",
            canonicalName: "America Trip",
            provenance: [.manifest],
            memberArtifactIDs: ["america-note"]
        )
        let sourceArtifact = artifact(
            id: "america-note",
            title: "America Trip itinerary",
            sourceID: "kontext:workspace"
        )
        let snapshot = ContextSnapshot(
            sourceID: "kontext:workspace",
            revision: "revision",
            artifacts: [sourceArtifact],
            anchors: [anchor],
            relations: [],
            diagnostics: [],
            indexedAt: .init(timeIntervalSince1970: 1)
        )
        let graph = ContextGraph(
            revision: snapshot.revision,
            nodes: [node(id: "america-node", anchor: anchor), documentNode(sourceArtifact)],
            edges: []
        )
        let titleWordTrigger = VoiceRoutingTrigger(
            pattern: .phrase("america"),
            origin: .shortenedCanonical,
            score: 0.94
        )
        let routingCard = VoiceRoutingCard(
            nodeID: "america-node",
            title: "America Trip",
            evidenceHash: "hash-america-node",
            canonicalPhrases: ["America Trip"],
            semanticAliases: ["america"],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            hardNegatives: [],
            confusableConcepts: [],
            activeTriggers: [titleWordTrigger]
        )
        let pack = VoiceRoutingPack(
            graphRevision: snapshot.revision,
            compilerVersion: "compiler",
            modelVersion: "model",
            generatedAt: .init(timeIntervalSince1970: 2),
            cards: [routingCard]
        )

        let document = try XCTUnwrap(ContextLensDocumentBuilder().build(
            sourceID: snapshot.sourceID,
            sourceName: "Kontext",
            sourceSnapshot: snapshot,
            graph: graph,
            snapshot: snapshot,
            pack: pack
        ))

        XCTAssertEqual(document.entries[0].modelProposal.semanticAliases, ["america"])
        XCTAssertEqual(document.entries[0].deterministicDecision.acceptedTriggers, [titleWordTrigger])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.contextLens.encode(document)) as? [String: Any])
        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        let decision = try XCTUnwrap(entries[0]["deterministicDecision"] as? [String: Any])
        let baseline = try XCTUnwrap(decision["baselineMatches"] as? [[String: Any]])
        XCTAssertTrue(baseline.contains { item in
            guard let trigger = item["trigger"] as? [String: Any],
                  let pattern = trigger["pattern"] as? [String: Any] else { return false }
            return trigger["origin"] as? String == "titleFragment"
                && pattern["phrase"] as? String == "america"
                && item["ownerNodeIDs"] as? [String] == ["america-node"]
                && item["isActive"] as? Bool == true
        })

        let withoutModel = try XCTUnwrap(ContextLensDocumentBuilder().build(
            sourceID: snapshot.sourceID, sourceName: "Kontext", sourceSnapshot: snapshot,
            graph: graph, snapshot: snapshot, pack: nil
        ))
        XCTAssertEqual(withoutModel.modelVersion, "unavailable")
        XCTAssertTrue(withoutModel.entries[0].modelProposal.semanticAliases.isEmpty)
        XCTAssertEqual(withoutModel.entries[0].deterministicDecision.baselineMatches,
                       document.entries[0].deterministicDecision.baselineMatches)
    }

    func testDocumentExposesOnlySourceScopedDeterministicRoutingExclusions() throws {
        let anchor = Anchor(
            id: "apollo-anchor",
            canonicalName: "Apollo",
            provenance: [.folder],
            memberArtifactIDs: []
        )
        let snapshot = ContextSnapshot(
            sourceID: "folder:a",
            revision: "revision",
            artifacts: [],
            anchors: [anchor],
            relations: [],
            diagnostics: [],
            indexedAt: .init(timeIntervalSince1970: 1)
        )
        let graph = ContextGraph(
            revision: snapshot.revision,
            nodes: [node(id: "apollo", anchor: anchor)],
            edges: []
        )
        let includedKey = VoiceRouteExclusionKey(
            sourceID: "folder:a",
            nodeID: "apollo",
            pattern: .init(kind: .phrase, normalizedTerms: ["apollo"])
        )
        let otherSourceKey = VoiceRouteExclusionKey(
            sourceID: "folder:b",
            nodeID: "apollo",
            pattern: .init(kind: .phrase, normalizedTerms: ["apollo"])
        )
        let learning = VoiceLearningSnapshot(
            sourceIDs: ["folder:a", "folder:b"],
            exclusions: [
                includedKey: .init(key: includedKey, rejectedAt: .init(timeIntervalSince1970: 3)),
                otherSourceKey: .init(key: otherSourceKey, rejectedAt: .init(timeIntervalSince1970: 4)),
            ]
        )

        let document = try XCTUnwrap(ContextLensDocumentBuilder().build(
            sourceID: "folder:a",
            sourceName: "Apollo Vault",
            sourceSnapshot: snapshot,
            graph: graph,
            snapshot: snapshot,
            pack: nil,
            learning: learning
        ))

        XCTAssertEqual(document.schemaVersion, 3)
        XCTAssertEqual(
            document.entries[0].deterministicDecision.routingExclusions,
            [.init(pattern: includedKey.pattern, rejectedAt: .init(timeIntervalSince1970: 3))]
        )
    }

    private func artifact(id: String, title: String, sourceID: String) -> SourceArtifact {
        SourceArtifact(
            id: id,
            relativePath: "\(title).md",
            mediaKind: .markdown,
            title: title,
            extractedText: "Evidence for \(title)",
            modifiedAt: .init(timeIntervalSince1970: 1),
            contentHash: "hash-\(id)",
            provider: .init(pluginID: sourceID.components(separatedBy: ":").first!, sourceID: sourceID),
            metadata: .init(tags: ["active"], headings: ["Status"])
        )
    }

    private func node(id: String, anchor: Anchor) -> GraphNode {
        .init(id: id, name: anchor.canonicalName, role: .context, activationEligible: true, importance: 1, referenceID: anchor.id)
    }

    private func documentNode(_ artifact: SourceArtifact) -> GraphNode {
        .init(id: artifact.id, name: artifact.title, role: .document, activationEligible: false, importance: 0, referenceID: artifact.id)
    }

    private func card(nodeID: String, title: String, alias: String) -> VoiceRoutingCard {
        .init(
            nodeID: nodeID,
            title: title,
            evidenceHash: "hash-\(nodeID)",
            canonicalPhrases: [title],
            semanticAliases: [alias],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            hardNegatives: [],
            confusableConcepts: [],
            activeTriggers: [.init(pattern: .phrase(alias), origin: .semanticAlias, score: 0.9)]
        )
    }
}
