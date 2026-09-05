import XCTest
import EmbersCore
@testable import embers

final class VoiceRoutingTests: XCTestCase {
    func testScorerRoutesStrongSemanticAliasAndRejectsWeakOrGenericSpeech() {
        let pack = makePack(cards: [
            makeCard(id: "journal", title: "Journal", aliases: ["diary"], tags: ["reflection", "diary"], artifactTypes: ["journal"]),
            makeCard(id: "templates", title: "_Templates", aliases: ["reusable skeleton"], tags: ["template", "starting point"], artifactTypes: ["template"]),
        ])
        let scorer = VoiceRoutingScorer()

        let diary = VoiceRoutingFeatures(
            utterance: "I need to write in my diary",
            subject: "diary",
            categoryLabels: ["journal"],
            artifactType: "journal",
            isSpecific: true,
            hasConcreteSubject: true
        )
        XCTAssertEqual(scorer.decide(features: diary, pack: pack)?.nodeID, "journal")

        let artifactOnly = VoiceRoutingFeatures(
            utterance: "I should write something",
            subject: "writing",
            categoryLabels: [],
            artifactType: "template",
            isSpecific: true,
            hasConcreteSubject: true
        )
        XCTAssertNil(scorer.decide(features: artifactOnly, pack: pack))

        let generic = VoiceRoutingFeatures(
            utterance: "Come on man",
            subject: "man",
            categoryLabels: ["person"],
            artifactType: "none",
            isSpecific: false,
            hasConcreteSubject: true
        )
        XCTAssertNil(scorer.decide(features: generic, pack: pack))
    }

    func testScorerAbstainsOnSmallMarginAndAppliesHardNegativePenalty() {
        let ambiguous = makePack(cards: [
            makeCard(id: "one", title: "First Brain", tags: ["knowledge system"]),
            makeCard(id: "two", title: "Second Brain", tags: ["knowledge system"]),
        ])
        let shared = VoiceRoutingFeatures(
            utterance: "show my knowledge system",
            subject: "knowledge system",
            categoryLabels: ["knowledge system"],
            artifactType: "none",
            isSpecific: true,
            hasConcreteSubject: true
        )
        XCTAssertNil(VoiceRoutingScorer().decide(features: shared, pack: ambiguous))

        let penalized = makePack(cards: [
            makeCard(id: "journal", title: "Journal", aliases: ["diary"], hardNegatives: ["weather diary"]),
        ])
        let negative = VoiceRoutingFeatures(
            utterance: "weather diary",
            subject: "diary",
            categoryLabels: ["diary"],
            artifactType: "none",
            isSpecific: true,
            hasConcreteSubject: true
        )
        XCTAssertNil(VoiceRoutingScorer().decide(features: negative, pack: penalized))
    }

    func testAliasCollisionRemovalAndQualityGate() {
        let cards = [
            makeCard(
                id: "journal",
                title: "Journal",
                aliases: ["daily notes", "diary"],
                activeTriggers: [.init(pattern: .phrase("diary"), origin: .semanticAlias, score: 0.92)]
            ),
            makeCard(
                id: "projects",
                title: "Projects",
                aliases: ["daily notes", "active work"],
                activeTriggers: [.init(pattern: .phrase("active work"), origin: .semanticAlias, score: 0.92)]
            ),
        ]
        let validated = VoiceRoutingCardValidator().removingGlobalAliasCollisions(cards)
        XCTAssertEqual(validated[0].semanticAliases, ["diary"])
        XCTAssertEqual(validated[1].semanticAliases, ["active work"])

        let pack = makePack(cards: validated)
        let result = VoiceRoutingQualityGate().evaluate(pack: pack, expectedNodeCount: 2)
        XCTAssertTrue(result.passed, result.failures.joined(separator: ", "))
        XCTAssertEqual(result.coverage, 1)
    }

    func testCanonicalFragmentOwnerWinsAGeneratedAliasCollision() {
        let cards = [
            makeCard(id: "brain", title: "Building a Second Brain", aliases: ["second brain"]),
            makeCard(id: "library", title: "Knowledge Library", aliases: ["second brain"]),
        ]

        let validated = VoiceRoutingCardValidator().removingGlobalAliasCollisions(cards)

        XCTAssertEqual(validated[0].semanticAliases, ["second brain"])
        XCTAssertTrue(validated[1].semanticAliases.isEmpty)
    }

    func testRoutingStoreRoundTripVersionInvalidationCorruptionAndDelete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("voice-routing.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let card = makeCard(id: "journal", title: "Journal", aliases: ["diary"])
        let pack = VoiceRoutingPack(
            graphRevision: "graph-1",
            compilerVersion: "compiler-1",
            modelVersion: "model-1",
            generatedAt: Date(timeIntervalSince1970: 1),
            cards: [card]
        )

        let store = VoiceRoutingStore(fileURL: file)
        try await store.save(card: card, graphRevision: "graph-1", compilerVersion: "compiler-1", modelVersion: "model-1")
        try await store.activate(pack, retaining: [card.evidenceHash])

        let reopened = VoiceRoutingStore(fileURL: file)
        let loaded = await reopened.activePack(graphRevision: "graph-1", compilerVersion: "compiler-1", modelVersion: "model-1")
        let stale = await reopened.activePack(graphRevision: "graph-2", compilerVersion: "compiler-1", modelVersion: "model-1")
        let sameRevision = await reopened.cachedCard(evidenceHash: card.evidenceHash, graphRevision: "graph-1", compilerVersion: "compiler-1", modelVersion: "model-1")
        let newerGraph = await reopened.cachedCard(evidenceHash: card.evidenceHash, graphRevision: "graph-2", compilerVersion: "compiler-1", modelVersion: "model-1")
        let invalidated = await reopened.cachedCard(evidenceHash: card.evidenceHash, graphRevision: "graph-1", compilerVersion: "compiler-2", modelVersion: "model-1")
        XCTAssertEqual(loaded, pack)
        XCTAssertNil(stale)
        XCTAssertEqual(sameRevision, card)
        XCTAssertEqual(newerGraph, card)
        XCTAssertNil(invalidated)

        var validJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var activePack = try XCTUnwrap(validJSON["activePack"] as? [String: Any])
        var cards = try XCTUnwrap(activePack["cards"] as? [[String: Any]])
        cards.append(try XCTUnwrap(cards.first))
        activePack["cards"] = cards
        validJSON["activePack"] = activePack
        try JSONSerialization.data(withJSONObject: validJSON).write(to: file, options: .atomic)
        let duplicateCards = VoiceRoutingStore(fileURL: file)
        let structurallyInvalid = await duplicateCards.activePack(
            graphRevision: "graph-1",
            compilerVersion: "compiler-1",
            modelVersion: "model-1"
        )
        XCTAssertNil(structurallyInvalid)

        try Data("corrupt".utf8).write(to: file, options: .atomic)
        let corrupt = VoiceRoutingStore(fileURL: file)
        let recovered = await corrupt.activePack(graphRevision: "graph-1", compilerVersion: "compiler-1", modelVersion: "model-1")
        XCTAssertNil(recovered)
        try await corrupt.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRoutingStoreReusesUnchangedEvidenceAcrossWorkspaceRevisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("voice-routing.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let card = makeCard(id: "projects", title: "Projects")
        var pack = VoiceRoutingPack(
            graphRevision: "before-task-check",
            compilerVersion: "compiler-1",
            modelVersion: "model-1",
            generatedAt: .distantPast,
            cards: [card]
        )
        pack.inputRevision = "unchanged-voice-input"
        let store = VoiceRoutingStore(fileURL: file)

        try await store.save(
            card: card,
            graphRevision: "before-task-check",
            compilerVersion: "compiler-1",
            modelVersion: "model-1"
        )
        try await store.activate(pack, retaining: [card.evidenceHash])

        let reused = await store.cachedCard(
            evidenceHash: card.evidenceHash,
            graphRevision: "after-task-check",
            compilerVersion: "compiler-1",
            modelVersion: "model-1"
        )
        let restoredPack = await store.activePack(
            inputRevision: "unchanged-voice-input",
            compilerVersion: "compiler-1",
            modelVersion: "model-1"
        )

        XCTAssertEqual(
            reused,
            card,
            "A workspace revision caused only by task state must not invalidate unchanged voice evidence."
        )
        XCTAssertEqual(restoredPack, pack)
    }

    func testVoiceInputFingerprintIgnoresMatchingRevisionChurnAndSkipsCrossedPublications() {
        let firstSnapshot = ContextSnapshot(
            sourceID: "fixture",
            revision: "before-task-check",
            artifacts: [],
            anchors: [],
            relations: [],
            diagnostics: [],
            indexedAt: .distantPast
        )
        let secondSnapshot = ContextSnapshot(
            sourceID: "fixture",
            revision: "after-task-check",
            artifacts: [],
            anchors: [],
            relations: [],
            diagnostics: [],
            indexedAt: .distantPast
        )
        let firstGraph = ContextGraph(revision: firstSnapshot.revision, nodes: [], edges: [])
        let secondGraph = ContextGraph(revision: secondSnapshot.revision, nodes: [], edges: [])

        XCTAssertEqual(
            VoiceRoutingCoordinator.voiceInputFingerprint(graph: firstGraph, snapshot: firstSnapshot),
            VoiceRoutingCoordinator.voiceInputFingerprint(graph: secondGraph, snapshot: secondSnapshot)
        )
        XCTAssertNil(
            VoiceRoutingCoordinator.voiceInputFingerprint(graph: secondGraph, snapshot: firstSnapshot)
        )
    }

    func testSuppressionHoldsOnlyPresentedNodesWhileOtherMatchesContinueSurfacing() {
        let brain = MatchTarget(phrase: "second brain", ref: .node("brain"), title: "Building a Second Brain")
        let summary = MatchTarget(phrase: "progressive summarization", ref: .node("summary"), title: "Progressive Summarization")
        var suppression = VoiceMatchSuppression()

        let first = suppression.newMatches(from: [brain])
        suppression.markPresented(first)
        let second = suppression.newMatches(from: [brain, summary])
        suppression.markPresented(second)

        XCTAssertEqual(first.map(\.title), ["Building a Second Brain"])
        XCTAssertEqual(second.map(\.title), ["Progressive Summarization"])
        XCTAssertTrue(suppression.newMatches(from: [brain, summary]).isEmpty)
    }

    func testSuppressionUnlocksAfterTriggerLeavesRunningTranscript() {
        let brain = MatchTarget(phrase: "second brain", ref: .node("brain"), title: "Building a Second Brain")
        var suppression = VoiceMatchSuppression()
        let first = suppression.newMatches(from: [brain])
        suppression.markPresented(first)

        XCTAssertTrue(suppression.newMatches(from: []).isEmpty)
        XCTAssertEqual(suppression.newMatches(from: [brain]).map(\.title), ["Building a Second Brain"])
    }

    func testOnlyUniqueValidatedMultiwordTagsEnterCompiledHotPath() {
        let base = [
            MatchTarget(phrase: "Progressive Summarization", ref: .node("summary"), title: "Progressive Summarization"),
            MatchTarget(phrase: "First Brain", ref: .node("one"), title: "First Brain"),
            MatchTarget(phrase: "Second Brain", ref: .node("two"), title: "Second Brain"),
        ]
        let pack = makePack(cards: [
            makeCard(id: "summary", title: "Progressive Summarization", tags: ["layered note distillation", "notes"]),
            makeCard(id: "one", title: "First Brain", tags: ["knowledge system"]),
            makeCard(id: "two", title: "Second Brain", tags: ["knowledge system"]),
        ])

        let phrases = VoiceRoutingExactTargetBuilder().augment(base, with: pack).map(\.phrase)

        XCTAssertTrue(phrases.contains("layered note distillation"))
        XCTAssertFalse(phrases.contains("notes"))
        XCTAssertFalse(phrases.contains("knowledge system"))
    }

    func testValidatedCompiledAliasMatchesInsideLongerSentenceOnExactHotPath() {
        let base = [MatchTarget(phrase: "Building a Second Brain", ref: .node("second-brain"), title: "Building a Second Brain")]
        let pack = makePack(cards: [
            makeCard(id: "second-brain", title: "Building a Second Brain", aliases: ["second brain"]),
        ])
        let targets = VoiceRoutingExactTargetBuilder().augment(base, with: pack)
        let result = PhraseMatcher(targets: targets).matches(
            in: "Yeah and then I'll add that to my second brain knowledge library"
        )

        XCTAssertEqual(result.map(\.title), ["Building a Second Brain"])
    }

    func testRuntimeExecutesOnlyExplicitActiveTriggersAndReportsTheirOrigin() {
        let pack = makePack(cards: [
            makeCard(
                id: "brain",
                title: "Building a Second Brain",
                tags: ["knowledge system"],
                activeTriggers: [
                    .init(pattern: .phrase("knowledge system"), origin: .phraseFamily, score: 0.92),
                ]
            ),
        ])
        let router = VoiceRoutingRuntimeRouter(baseTargets: [], pack: pack)

        let hit = router.matches(in: "I keep that in my knowledge system").first
        XCTAssertEqual(hit?.target.title, "Building a Second Brain")
        XCTAssertEqual(hit?.trigger.origin, .phraseFamily)
        XCTAssertEqual(hit?.score, 0.92)
        XCTAssertTrue(router.matches(in: "natural language processing").isEmpty)
    }

    func testRuntimeSupportsBoundedOrderedTermsWithoutRequiringContiguity() {
        let pack = makePack(cards: [
            makeCard(
                id: "summary",
                title: "Progressive Summarization",
                activeTriggers: [
                    .init(
                        pattern: .orderedTerms(["progressive", "summarization"], maximumGap: 2),
                        origin: .phraseFamily,
                        score: 0.92
                    ),
                ]
            ),
        ])
        let router = VoiceRoutingRuntimeRouter(baseTargets: [], pack: pack)

        XCTAssertEqual(router.matches(in: "progressive about the summarization").map(\.target.title), ["Progressive Summarization"])
        XCTAssertTrue(router.matches(in: "progressive notes about the whole summarization").isEmpty)
    }

    func testModelNegativesCannotOverrideAuthoredIdentity() {
        let base = [MatchTarget(phrase: "links", ref: .node("wiki"), title: "wikilinks")]
        let pack = makePack(cards: [
            makeCard(id: "wiki", title: "wikilinks", hardNegatives: ["skip the links"]),
        ])
        let router = VoiceRoutingRuntimeRouter(baseTargets: base, pack: pack)

        XCTAssertEqual(router.matches(in: "show me the links").map(\.target.title), ["wikilinks"])
        XCTAssertEqual(router.matches(in: "skip the links").map(\.target.title), ["wikilinks"])
        XCTAssertEqual(router.validate(utterance: "skip the links", expectedNodeID: "wiki").outcome, .accepted)
    }

    func testRuntimeAppliesMarginOnlyToOverlappingMentions() {
        let pack = makePack(cards: [
            makeCard(
                id: "brain",
                title: "Building a Second Brain",
                activeTriggers: [.init(pattern: .phrase("knowledge system"), origin: .phraseFamily, score: 0.92)]
            ),
            makeCard(
                id: "areas",
                title: "Areas",
                activeTriggers: [
                    .init(pattern: .phrase("knowledge system"), origin: .semanticAlias, score: 0.84),
                    .init(pattern: .phrase("areas"), origin: .semanticAlias, score: 0.90),
                ]
            ),
        ])
        let router = VoiceRoutingRuntimeRouter(baseTargets: [], pack: pack)

        XCTAssertTrue(router.matches(in: "knowledge system").isEmpty)
        XCTAssertEqual(
            Set(router.matches(in: "knowledge system and then areas").map(\.target.title)),
            Set(["Building a Second Brain", "Areas"])
        )
    }

    func testLongerCanonicalOwnsNestedExactSpanButSeparateMentionsStillRoute() {
        let base = [
            MatchTarget(phrase: "Building a Second Brain", ref: .node("building"), title: "Building a Second Brain"),
            MatchTarget(phrase: "Second Brain", ref: .node("second"), title: "Second Brain"),
            MatchTarget(phrase: "Brain", ref: .node("brain"), title: "Brain"),
        ]
        let router = VoiceRoutingRuntimeRouter(baseTargets: base, pack: nil)

        XCTAssertEqual(router.matches(in: "Building a Second Brain").map(\.target.title), ["Building a Second Brain"])
        XCTAssertEqual(router.matches(in: "Second Brain").map(\.target.title), ["Second Brain"])
        XCTAssertEqual(router.matches(in: "Brain").map(\.target.title), ["Brain"])
        XCTAssertEqual(
            router.matches(in: "Building a Second Brain and then Second Brain").map(\.target.title),
            ["Building a Second Brain", "Second Brain"]
        )
    }

    func testCanonicalIdentityOwnsEqualSpanAgainstGeneratedTrigger() {
        let base = [
            MatchTarget(phrase: "Kontext Editable Sharing", ref: .node("editable"), title: "Kontext Editable Sharing"),
            MatchTarget(phrase: "Kontext Sharing", ref: .node("sharing"), title: "Kontext Sharing"),
        ]
        let pack = makePack(cards: [
            makeCard(id: "editable", title: "Kontext Editable Sharing"),
            makeCard(
                id: "sharing",
                title: "Kontext Sharing",
                activeTriggers: [
                    .init(
                        pattern: .phrase("Kontext Editable Sharing"),
                        origin: .semanticAlias,
                        score: 0.92
                    ),
                ]
            ),
        ])
        let router = VoiceRoutingRuntimeRouter(baseTargets: base, pack: pack)

        XCTAssertEqual(
            router.matches(in: "Kontext Editable Sharing").map(\.target.title),
            ["Kontext Editable Sharing"]
        )
    }

    func testShortenedCanonicalOwnsContainedLowerAuthoritySemanticTrigger() {
        let base = [
            MatchTarget(phrase: "Building a Second Brain", ref: .node("building"), title: "Building a Second Brain"),
            MatchTarget(phrase: "Knowledge Management", ref: .node("knowledge"), title: "Knowledge Management"),
        ]
        let pack = makePack(cards: [
            makeCard(
                id: "building",
                title: "Building a Second Brain",
                activeTriggers: [
                    .init(pattern: .phrase("second brain"), origin: .shortenedCanonical, score: 0.94),
                ]
            ),
            makeCard(
                id: "knowledge",
                title: "Knowledge Management",
                activeTriggers: [
                    .init(pattern: .phrase("brain"), origin: .semanticAlias, score: 0.92),
                ]
            ),
        ])
        let router = VoiceRoutingRuntimeRouter(baseTargets: base, pack: pack)

        XCTAssertEqual(router.matches(in: "second brain").map(\.target.title), ["Building a Second Brain"])
    }

    func testShortenedCanonicalDoesNotOverrideARealContainedCanonicalName() {
        let base = [
            MatchTarget(phrase: "Building a Second Brain", ref: .node("building"), title: "Building a Second Brain"),
            MatchTarget(phrase: "Brain", ref: .node("brain"), title: "Brain"),
        ]
        let pack = makePack(cards: [
            makeCard(
                id: "building",
                title: "Building a Second Brain",
                activeTriggers: [
                    .init(pattern: .phrase("second brain"), origin: .shortenedCanonical, score: 0.94),
                ]
            ),
            makeCard(id: "brain", title: "Brain"),
        ])
        let router = VoiceRoutingRuntimeRouter(baseTargets: base, pack: pack)

        XCTAssertTrue(router.matches(in: "second brain").isEmpty)
    }

    func testExactRouteExclusionBlocksOnlyOnePatternForOneNode() {
        let base = [
            MatchTarget(phrase: "Apollo", ref: .node("mission"), title: "Mission"),
            MatchTarget(phrase: "Moon Mission", ref: .node("mission"), title: "Mission"),
            MatchTarget(phrase: "Journal", ref: .node("journal"), title: "Journal"),
        ]
        let exclusion = VoiceRouteExclusionKey(
            sourceID: "folder:a",
            nodeID: "mission",
            pattern: .init(kind: .phrase, normalizedTerms: ["apollo"])
        )
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: base,
            pack: nil,
            excludedRouteKeys: [exclusion]
        )

        XCTAssertTrue(router.matches(in: "Apollo").isEmpty)
        XCTAssertEqual(router.matches(in: "Moon Mission").map(\.target.title), ["Mission"])
        XCTAssertEqual(router.matches(in: "Journal").map(\.target.title), ["Journal"])
    }

    func testRouteExclusionBlocksEquivalentPhraseAndOrderedSiblingsOnlyForThatNode() {
        let pack = makePack(cards: [
            makeCard(
                id: "mission",
                title: "Mission",
                activeTriggers: [
                    .init(pattern: .phrase("moon mission"), origin: .phraseFamily, score: 0.94),
                    .init(
                        pattern: .orderedTerms(["moon", "mission"], maximumGap: 2),
                        origin: .phraseFamily,
                        score: 0.92
                    ),
                    .init(pattern: .phrase("lunar mission"), origin: .semanticAlias, score: 0.91),
                ]
            ),
            makeCard(
                id: "journal",
                title: "Journal",
                activeTriggers: [
                    .init(pattern: .phrase("journal"), origin: .canonicalName, score: 1),
                ]
            ),
        ])
        let exclusion = VoiceRouteExclusionKey(
            sourceID: "folder:a",
            nodeID: "mission",
            pattern: .init(kind: .phrase, normalizedTerms: ["moon", "mission"])
        )
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: [],
            pack: pack,
            excludedRouteKeys: [exclusion]
        )

        XCTAssertTrue(router.matches(in: "moon mission").isEmpty)
        XCTAssertTrue(router.matches(in: "moon about mission").isEmpty)
        XCTAssertEqual(router.matches(in: "lunar mission").map(\.target.title), ["Mission"])
        XCTAssertEqual(router.matches(in: "journal").map(\.target.title), ["Journal"])
    }

    func testSharedConceptExclusionRemovesOnlyTheRejectedCandidate() {
        let pattern = VoiceRoutingTriggerPattern.phrase("knowledge system")
        var pack = makePack(cards: [
            makeCard(id: "brain", title: "Second Brain"),
            makeCard(id: "notes", title: "Project Notes"),
        ])
        pack.sharedConcepts = [
            .init(
                id: VoiceRoutingSharedConcept.stableID(for: pattern),
                pattern: pattern,
                candidates: [
                    .init(nodeID: "brain", compiledStrength: 0.92, origin: .phraseFamily, evidenceHash: "hash-brain"),
                    .init(nodeID: "notes", compiledStrength: 0.91, origin: .phraseFamily, evidenceHash: "hash-notes"),
                ]
            ),
        ]
        let exclusion = VoiceRouteExclusionKey(
            sourceID: "folder:a",
            nodeID: "brain",
            pattern: pattern.routePatternIdentity
        )
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: [],
            pack: pack,
            excludedRouteKeys: [exclusion]
        )

        let match = router.sharedMatches(in: "open my knowledge system").first
        XCTAssertEqual(match?.orderedCandidateNodeIDs, ["notes"])
    }

    private func makePack(cards: [VoiceRoutingCard]) -> VoiceRoutingPack {
        VoiceRoutingPack(
            graphRevision: "graph",
            compilerVersion: "compiler",
            modelVersion: "model",
            generatedAt: .distantPast,
            cards: cards
        )
    }

    private func makeCard(
        id: String,
        title: String,
        aliases: [String] = [],
        tags: [String] = [],
        artifactTypes: [String] = [],
        hardNegatives: [String] = [],
        activeTriggers: [VoiceRoutingTrigger] = []
    ) -> VoiceRoutingCard {
        VoiceRoutingCard(
            nodeID: id,
            title: title,
            evidenceHash: "hash-\(id)",
            canonicalPhrases: [title],
            semanticAliases: aliases,
            topicTags: tags,
            artifactTypes: artifactTypes,
            representativeUtterances: [],
            hardNegatives: hardNegatives,
            confusableConcepts: [],
            activeTriggers: activeTriggers
        )
    }
}
