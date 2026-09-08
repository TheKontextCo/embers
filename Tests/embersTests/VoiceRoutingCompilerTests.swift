import XCTest
import EmbersCore
import EmbersLocal
@testable import embers

final class VoiceRoutingCompilerTests: XCTestCase {
    func testGenerationProgressAdvancesBeforeTheFirstWholeNoteCompletes() {
        let recorder = VoiceRoutingProgressRecorder()
        let progress = VoiceRoutingGenerationProgress(
            noteCount: 2,
            report: { recorder.append($0) }
        )

        progress.advance()

        XCTAssertEqual(
            recorder.snapshots,
            [
                .init(stage: .generatingNotes, completed: 0, total: 16),
                .init(stage: .generatingNotes, completed: 1, total: 16),
            ]
        )
        XCTAssertGreaterThan(recorder.snapshots.last?.overallFraction ?? 0, 0)
    }

    func testCachedNoteCompletesAllGenerationUnitsAtOnce() {
        let recorder = VoiceRoutingProgressRecorder()
        let progress = VoiceRoutingGenerationProgress(
            noteCount: 2,
            report: { recorder.append($0) }
        )

        progress.completeThrough(noteCount: 1)

        XCTAssertEqual(
            recorder.snapshots.last,
            .init(stage: .generatingNotes, completed: 8, total: 16)
        )
    }

    func testGenerationProgressNeverRegressesWhenCachedAndLiveCallbacksArriveLate() {
        let recorder = VoiceRoutingProgressRecorder()
        let progress = VoiceRoutingGenerationProgress(
            noteCount: 3,
            report: { recorder.append($0) }
        )

        progress.completeThrough(noteCount: 2)
        progress.completeThrough(noteCount: 1)
        progress.advance()

        let snapshots = recorder.snapshots
        XCTAssertEqual(snapshots.last?.completed, 17)
        XCTAssertTrue(zip(snapshots, snapshots.dropFirst()).allSatisfy {
            $0.completed <= $1.completed
        })
    }

    func testGenerationProgressIsThreadSafeBoundedMonotonicAndTerminal() {
        let recorder = VoiceRoutingProgressRecorder()
        let progress = VoiceRoutingGenerationProgress(
            noteCount: 4,
            report: { recorder.append($0) }
        )

        DispatchQueue.concurrentPerform(iterations: 96) { _ in
            progress.advance()
        }

        let snapshots = recorder.snapshots
        XCTAssertEqual(snapshots.first?.completed, 0)
        XCTAssertEqual(snapshots.last?.completed, 32)
        XCTAssertTrue(snapshots.allSatisfy { (0...32).contains($0.completed) })
        XCTAssertTrue(zip(snapshots, snapshots.dropFirst()).allSatisfy {
            $0.completed <= $1.completed
        })
    }

    func testLargeVaultProgressIsThrottledButAlwaysReportsCompletion() {
        let recorder = VoiceRoutingProgressRecorder()
        let progress = VoiceRoutingGenerationProgress(
            noteCount: 841,
            report: { recorder.append($0) }
        )

        for _ in 0..<6_728 { progress.advance() }

        XCTAssertEqual(
            recorder.snapshots.last,
            .init(stage: .generatingNotes, completed: 6_728, total: 6_728)
        )
        XCTAssertLessThanOrEqual(recorder.snapshots.count, 202)
    }

    func testValidatorReportsMonotonicPhraseCheckProgress() {
        let recorder = VoiceRoutingProgressRecorder()
        let first = card(
            id: "first",
            title: "First",
            active: [trigger("first phrase", origin: .semanticAlias, score: 0.9)]
        )
        let second = card(
            id: "second",
            title: "Second",
            active: [trigger("second phrase", origin: .semanticAlias, score: 0.9)]
        )

        _ = VoiceRoutingCompilerValidator().validate(
            pack([first, second]),
            seeds: [seed(id: "first", name: "First"), seed(id: "second", name: "Second")]
        ) { recorder.append($0) }

        let snapshots = recorder.snapshots
        XCTAssertEqual(snapshots.first, .init(stage: .validatingPhraseChecks, completed: 0, total: 10))
        XCTAssertEqual(snapshots.last, .init(stage: .validatingPhraseChecks, completed: 10, total: 10))
        XCTAssertTrue(zip(snapshots, snapshots.dropFirst()).allSatisfy { $0.completed <= $1.completed })
    }

    func testValidatorReportsOneBoundedCheckWhenThereAreNoGeneratedTriggers() {
        let recorder = VoiceRoutingProgressRecorder()
        let empty = card(id: "empty", title: "Empty", active: [])

        _ = VoiceRoutingCompilerValidator().validate(
            pack([empty]),
            seeds: [seed(id: "empty", name: "Empty")]
        ) { recorder.append($0) }

        XCTAssertEqual(
            recorder.snapshots,
            [
                .init(stage: .validatingPhraseChecks, completed: 0, total: 1),
                .init(stage: .validatingPhraseChecks, completed: 1, total: 1),
            ]
        )
    }

    func testCanonicalTitleWordCandidatesAreBoundedExactWords() {
        XCTAssertEqual(
            canonicalTitleWordCandidates("America Trip"),
            ["america", "trip"]
        )
        XCTAssertEqual(
            canonicalTitleWordCandidates("Building a Second Brain"),
            ["building", "second", "brain"]
        )
        XCTAssertEqual(
            canonicalTitleWordCandidates("  America—Trip / 2026  "),
            ["america", "trip", "2026"]
        )
        XCTAssertEqual(
            canonicalTitleWordCandidates("AI Strategy in US"),
            ["ai", "strategy", "us"],
            "Short authored identity words must not inherit speech stop-word filtering"
        )
    }

    func testPositivePromptOffersExactTitleWordsForModelSelection() {
        let prompt = positiveRoutingPrompt(seed(id: "america", name: "America Trip"))

        XCTAssertTrue(prompt.contains("Exact canonical title-word candidates: america | trip"))
        XCTAssertTrue(prompt.contains("Select the smallest subset of these title words that preserves the context's identifying meaning"))
        XCTAssertTrue(prompt.contains("Keep selected words in their original order"))
        XCTAssertTrue(prompt.contains("The selected subset becomes one phrase, not separate triggers"))
        XCTAssertTrue(prompt.contains("Copy the subset exactly into canonicalIdentitySubset"))
    }

    func testCanonicalIdentitySubsetCompilesToOneExactPhrase() {
        let america = seed(id: "america", name: "America Trip")

        XCTAssertEqual(
            canonicalIdentityPhrase(from: ["America"], seed: america),
            "america"
        )
        XCTAssertEqual(
            canonicalIdentityPhrase(from: ["America", "Trip"], seed: america),
            "america trip",
            "One selected subset must compile to one phrase, never two single-word triggers"
        )
        XCTAssertNil(
            canonicalIdentityPhrase(from: ["America", "AT"], seed: america),
            "A subset containing a word outside the supplied title candidates must fail closed"
        )
        XCTAssertEqual(
            canonicalIdentityPhrase(
                from: ["brain", "second"],
                seed: seed(id: "brain", name: "Building a Second Brain")
            ),
            "second brain",
            "Deterministic code restores canonical order before joining the subset"
        )
        XCTAssertNil(canonicalIdentityPhrase(from: [], seed: america))
    }

    func testShortAuthoredIdentitySubsetCanBecomeATrigger() throws {
        let strategy = seed(id: "strategy", name: "AI Strategy")
        let phrase = try XCTUnwrap(canonicalIdentityPhrase(from: ["AI"], seed: strategy))
        let generated = generatedTriggerCandidates(
            seed: strategy,
            shortenedCanonicalForms: [phrase],
            semanticAliases: [],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: []
        )

        XCTAssertTrue(generated.accepted.contains {
            $0.pattern == .phrase("ai") && $0.origin == .shortenedCanonical
        })
    }

    func testTitleWordsRouteIndependentlyOfModelSelection() {
        let america = seed(id: "america", name: "America Trip")
        let generated = generatedTriggerCandidates(
            seed: america,
            shortenedCanonicalForms: ["america"],
            semanticAliases: [],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: []
        )

        XCTAssertTrue(generated.accepted.contains {
            $0.pattern == .phrase("america") && $0.origin == .shortenedCanonical
        })
        XCTAssertFalse(generated.accepted.contains { $0.pattern == .phrase("trip") })

        let routingCard = card(id: "america", title: "America Trip", active: generated.accepted)
        let routingPack = VoiceRoutingCompilerValidator().validate(
            pack([routingCard]),
            seeds: [america]
        )
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: [MatchTarget(phrase: "America Trip", ref: .node("america"), title: "America Trip")],
            pack: routingPack
        )

        XCTAssertEqual(router.matches(in: "america").first?.target.title, "America Trip")
        XCTAssertEqual(router.matches(in: "trip").first?.target.title, "America Trip")
    }

    func testModelSelectedSharedTitleWordProducesBothPeeks() throws {
        let pattern = VoiceRoutingTriggerPattern.phrase("america")
        let trip = card(
            id: "trip",
            title: "America Trip",
            active: [.init(pattern: pattern, origin: .shortenedCanonical, score: 0.94)]
        )
        let research = card(
            id: "research",
            title: "America Research",
            active: [.init(pattern: pattern, origin: .shortenedCanonical, score: 0.94)]
        )
        let validated = VoiceRoutingCompilerValidator().validate(
            pack([trip, research]),
            seeds: [
                seed(id: "trip", name: "America Trip"),
                seed(id: "research", name: "America Research"),
            ]
        )
        let router = VoiceRoutingRuntimeRouter(baseTargets: [], pack: validated)

        XCTAssertTrue(router.matches(in: "america").isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(router.sharedMatches(in: "america").first).candidates.map(\.target.title),
            ["America Research", "America Trip"]
        )
    }

    func testNoModelSelectionPreservesCanonicalAndAuthoredAliasRouting() {
        let america = VoiceRoutingSeed(
            nodeID: "america",
            canonicalName: "America Trip",
            existingAliases: ["US Holiday"],
            kind: nil,
            contextOnlyAncestry: [],
            contextOnlyChildNames: [],
            directArtifactTitles: [],
            directHeadingsAndTags: [],
            directTags: [],
            directExcerpts: [],
            evidenceHash: "hash-america"
        )
        let generated = generatedTriggerCandidates(
            seed: america,
            shortenedCanonicalForms: [],
            semanticAliases: [],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: []
        )
        let routingCard = VoiceRoutingCard(
            nodeID: america.nodeID,
            title: america.canonicalName,
            evidenceHash: america.evidenceHash,
            canonicalPhrases: [america.canonicalName] + america.existingAliases,
            semanticAliases: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            hardNegatives: [],
            confusableConcepts: [],
            activeTriggers: generated.accepted
        )
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: routingCard.canonicalPhrases.map {
                MatchTarget(phrase: $0, ref: .node(america.nodeID), title: america.canonicalName)
            },
            pack: pack([routingCard])
        )

        XCTAssertEqual(router.matches(in: "america trip").first?.target.title, "America Trip")
        XCTAssertEqual(router.matches(in: "US holiday").first?.target.title, "America Trip")
        XCTAssertEqual(router.matches(in: "america").first?.target.title, "America Trip")
    }

    func testGeneratedFamiliesRequireDirectGroundingAndCannotBorrowChildVocabulary() {
        let journal = seed(
            id: "journal",
            name: "Journal",
            directTerms: ["diary", "reflection"]
        )
        let journalCandidates = generatedTriggerCandidates(
            seed: journal,
            shortenedCanonicalForms: [],
            semanticAliases: ["diary", "https://example.com/private"],
            phraseFamilies: ["journaling"],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            verifiedSemanticRelations: ["diary", "journaling"],
            lexicalAlternativePasses: [
                ["diary", "journaling"],
                ["diary", "journaling"],
                ["diary", "journaling"],
            ]
        )
        XCTAssertTrue(journalCandidates.accepted.contains { $0.pattern == .phrase("diary") })
        XCTAssertTrue(journalCandidates.accepted.contains { $0.pattern == .phrase("journaling") })
        XCTAssertTrue(journalCandidates.rejected.contains {
            $0.phrase == "https://example.com/private" && $0.reason == .invalidMetadata
        })

        let projects = seed(
            id: "projects",
            name: "Projects",
            children: ["Building a Second Brain"]
        )
        let contaminated = generatedTriggerCandidates(
            seed: projects,
            shortenedCanonicalForms: [],
            semanticAliases: ["brain project"],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: []
        )
        XCTAssertFalse(contaminated.accepted.contains { $0.pattern == .phrase("brain project") })
        XCTAssertTrue(contaminated.rejected.contains {
            $0.phrase == "brain project" && $0.reason == .contextOnlyEvidence
        })

        let oneOverlap = generatedTriggerCandidates(
            seed: projects,
            shortenedCanonicalForms: [],
            semanticAliases: ["brain project roadmap"],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: []
        )
        XCTAssertFalse(oneOverlap.accepted.contains { $0.pattern == .phrase("brain project roadmap") })
        XCTAssertTrue(oneOverlap.rejected.contains {
            $0.phrase == "brain project roadmap" && $0.reason == .unsupportedEvidence
        })
    }

    func testDirectEvidenceBuildsKnowledgeSystemAndCanonicalOrderedFamily() {
        let brain = seed(
            id: "brain",
            name: "Building a Second Brain",
            directTerms: ["knowledge management system", "knowledge system"]
        )
        let brainCandidates = generatedTriggerCandidates(
            seed: brain,
            shortenedCanonicalForms: ["second brain"],
            semanticAliases: [],
            phraseFamilies: ["knowledge system", "knowledge management system"],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: []
        )

        XCTAssertTrue(brainCandidates.accepted.contains { $0.pattern == .phrase("second brain") })
        XCTAssertTrue(brainCandidates.accepted.contains { $0.pattern == .phrase("knowledge system") })
        XCTAssertTrue(brainCandidates.accepted.contains { $0.pattern == .phrase("knowledge management system") })

        let deterministicShortening = generatedTriggerCandidates(
            seed: brain,
            shortenedCanonicalForms: [],
            semanticAliases: [],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: []
        )
        XCTAssertTrue(deterministicShortening.accepted.contains {
            $0.pattern == .phrase("second brain") && $0.origin == .shortenedCanonical
        })

        let summary = seed(id: "summary", name: "Progressive Summarization")
        let summaryCandidates = generatedTriggerCandidates(
            seed: summary,
            shortenedCanonicalForms: [],
            semanticAliases: [],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: []
        )
        XCTAssertTrue(summaryCandidates.accepted.contains {
            $0.pattern == .orderedTerms(["progressive", "summarization"], maximumGap: 2)
        })
        XCTAssertTrue(summaryCandidates.accepted.contains {
            $0.pattern == .phrase("progressive summarizing")
        })

        let wiki = seed(id: "wiki", name: "wikilinks")
        let wikiCandidates = generatedTriggerCandidates(
            seed: wiki,
            shortenedCanonicalForms: [],
            semanticAliases: [],
            phraseFamilies: ["wiki links"],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: []
        )
        XCTAssertTrue(wikiCandidates.accepted.contains { $0.pattern == .phrase("wiki links") })
    }

    func testVerifiedSemanticRelationsCrossLexicalGapsWithoutOverridingHierarchyOrContamination() {
        let journal = seed(id: "journal", name: "Journal")
        let diary = generatedTriggerCandidates(
            seed: journal,
            shortenedCanonicalForms: [],
            semanticAliases: ["diary"],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            verifiedSemanticRelations: ["diary"],
            lexicalAlternativePasses: [["diary"], ["diary"], ["diary"]]
        )
        XCTAssertTrue(diary.accepted.contains { $0.pattern == .phrase("diary") })

        let brain = seed(id: "brain", name: "Building a Second Brain")
        let knowledgeSystem = generatedTriggerCandidates(
            seed: brain,
            shortenedCanonicalForms: [],
            semanticAliases: ["knowledge system"],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            verifiedSemanticRelations: ["knowledge system"]
        )
        XCTAssertTrue(knowledgeSystem.accepted.contains { $0.pattern == .phrase("knowledge system") })

        let projects = seed(id: "projects", name: "Projects", children: ["Building a Second Brain"])
        let contextLeak = generatedTriggerCandidates(
            seed: projects,
            shortenedCanonicalForms: [],
            semanticAliases: ["second brain"],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            verifiedSemanticRelations: ["second brain"]
        )
        XCTAssertTrue(contextLeak.accepted.isEmpty)
        XCTAssertTrue(contextLeak.rejected.contains { $0.reason == .contextOnlyEvidence })

        let contamination = generatedTriggerCandidates(
            seed: projects,
            shortenedCanonicalForms: [],
            semanticAliases: ["brain project roadmap"],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            verifiedSemanticRelations: ["brain project roadmap"]
        )
        XCTAssertTrue(contamination.accepted.isEmpty)
        XCTAssertTrue(contamination.rejected.contains { $0.reason == .unsupportedEvidence })
    }

    func testConsensusArtifactCompoundRequiresRepeatedHeadAndRejectsParentContamination() {
        let brain = seed(
            id: "brain",
            name: "Building a Second Brain",
            directTerms: ["Knowledge-Management", "Key Concepts"]
        )
        let compounds = modelGroundedConsensusCompounds(
            seed: brain,
            lexicalAlternativePasses: [
                ["intelligent information system", "thought organizer", "external brain"],
                ["memory enhancement system", "personal brain"],
                ["personal knowledge repository", "project responsibility"],
            ]
        )

        XCTAssertTrue(compounds.contains("knowledge system"))
        XCTAssertFalse(compounds.contains("knowledge responsibility"))
        XCTAssertFalse(compounds.contains("second brain"))
        XCTAssertFalse(compounds.contains("knowledge brain"))

        let routed = generatedTriggerCandidates(
            seed: brain,
            shortenedCanonicalForms: [],
            semanticAliases: [],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            consensusArtifactVocabulary: Set(compounds)
        )
        XCTAssertTrue(routed.accepted.contains {
            $0.pattern == .phrase("knowledge system")
                && $0.origin == .consensusArtifactVocabulary
                && $0.score == 0.86
        })

        let contaminatedParent = seed(
            id: "parent",
            name: "Project Areas",
            directTerms: ["Second-Brain"],
            children: ["Second Brain"]
        )
        XCTAssertTrue(modelGroundedConsensusCompounds(
            seed: contaminatedParent,
            lexicalAlternativePasses: [
                ["information system"],
                ["memory system"],
                [],
            ]
        ).isEmpty)
    }

    func testConsensusArtifactHeadCanAgreeAcrossIndependentChannels() {
        let brain = seed(
            id: "brain",
            name: "Building a Second Brain",
            directTerms: ["Knowledge-Management"]
        )
        let compounds = modelGroundedConsensusCompounds(
            seed: brain,
            lexicalAlternativePasses: [["information platform"], [], []],
            independentProposalChannels: [
                ["knowledge platform"],
                ["organization platform"],
            ]
        )
        XCTAssertEqual(compounds, ["knowledge platform"])
    }

    func testConsensusArtifactHeadNeedsBothDirectEvidenceAndAModelProposal() {
        let grounded = seed(
            id: "brain",
            name: "Building a Second Brain",
            directTerms: ["Knowledge-Management"],
            directExcerpts: ["A trusted external system captures and organizes useful knowledge."]
        )
        XCTAssertEqual(modelGroundedConsensusCompounds(
            seed: grounded,
            lexicalAlternativePasses: [["intelligent information system"], [], []]
        ), ["knowledge system"])

        XCTAssertTrue(modelGroundedConsensusCompounds(
            seed: grounded,
            lexicalAlternativePasses: [[], [], []]
        ).isEmpty, "Direct evidence alone cannot nominate a head")

        let modelOnly = seed(
            id: "brain-model-only",
            name: "Building a Second Brain",
            directTerms: ["Knowledge-Management"]
        )
        XCTAssertTrue(modelGroundedConsensusCompounds(
            seed: modelOnly,
            lexicalAlternativePasses: [["intelligent information system"], [], []]
        ).isEmpty, "A one-off model proposal needs direct corroboration")

        let contextOnly = seed(
            id: "parent",
            name: "Project Areas",
            directTerms: ["Second-Brain"],
            children: ["Second Brain"],
            directExcerpts: ["This external system is described here."]
        )
        XCTAssertTrue(modelGroundedConsensusCompounds(
            seed: contextOnly,
            lexicalAlternativePasses: [["information system"], [], []]
        ).isEmpty)
    }

    func testSingleWordTagsAndArtifactTypesRemainDescriptiveOnly() {
        let journal = seed(id: "journal", name: "Journal")
        let candidates = generatedTriggerCandidates(
            seed: journal,
            shortenedCanonicalForms: [],
            semanticAliases: ["diary"],
            phraseFamilies: [],
            topicTags: ["overview"],
            artifactTypes: ["record"],
            representativeUtterances: [],
            verifiedSemanticRelations: ["diary", "overview", "record"],
            lexicalAlternativePasses: [["diary"], ["diary"], ["diary"]]
        )

        XCTAssertTrue(candidates.accepted.contains {
            $0.pattern == .phrase("diary") && $0.origin == .semanticAlias
        })
        XCTAssertFalse(candidates.accepted.contains {
            $0.pattern == .phrase("overview") || $0.pattern == .phrase("record")
        })
        XCTAssertTrue(candidates.rejected.contains {
            $0.phrase == "overview" && $0.origin == .topicTag && $0.reason == .generic
        })
        XCTAssertTrue(candidates.rejected.contains {
            $0.phrase == "record" && $0.origin == .artifactType && $0.reason == .generic
        })
    }

    func testUnverifiedSingleWordAliasesAndBoilerplateRemainDescriptiveOnly() {
        let journal = seed(id: "journal", name: "Journal", directTerms: ["Reflection"])
        let generated = generatedTriggerCandidates(
            seed: journal,
            shortenedCanonicalForms: [],
            semanticAliases: ["diary", "organize", "see also"],
            phraseFamilies: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            verifiedSemanticRelations: ["diary"],
            lexicalAlternativePasses: [["diary"], ["diary"], ["diary"]]
        )

        XCTAssertTrue(generated.accepted.contains { $0.pattern == .phrase("diary") })
        XCTAssertFalse(generated.accepted.contains { $0.pattern == .phrase("organize") })
        XCTAssertFalse(generated.accepted.contains { $0.pattern == .phrase("see also") })
    }

    func testCompilerValidatorUsesProductionRouterAndRecordsWhyMaterialWasRejected() throws {
        let journal = card(
            id: "journal",
            title: "Journal",
            negatives: ["weather diary"],
            confusers: ["diary"],
            active: [trigger("diary", origin: .semanticAlias, score: 0.92)]
        )
        let brain = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger("second brain", origin: .shortenedCanonical, score: 0.94)]
        )
        let areas = card(
            id: "areas",
            title: "Areas",
            active: [trigger("second brain", origin: .semanticAlias, score: 0.90)]
        )
        let proposed = pack([journal, brain, areas])

        let validated = VoiceRoutingCompilerValidator().validate(proposed, seeds: [
            seed(id: "journal", name: "Journal"),
            seed(id: "brain", name: "Building a Second Brain"),
            seed(id: "areas", name: "Areas"),
        ])

        let validatedJournal = try XCTUnwrap(validated.card(nodeID: "journal"))
        XCTAssertTrue(validatedJournal.activeTriggers.contains { $0.pattern == .phrase("diary") })
        XCTAssertEqual(validatedJournal.hardNegatives, ["weather diary"])
        XCTAssertTrue(validatedJournal.confusableConcepts.isEmpty)
        XCTAssertTrue(validatedJournal.rejectedTriggers.contains {
            $0.phrase == "diary" && $0.origin == .confuser && $0.reason == .negativeDidNotAbstain
        })

        let validatedBrain = try XCTUnwrap(validated.card(nodeID: "brain"))
        XCTAssertTrue(validatedBrain.activeTriggers.contains { $0.pattern == .phrase("second brain") })
        let validatedAreas = try XCTUnwrap(validated.card(nodeID: "areas"))
        XCTAssertTrue(validatedAreas.activeTriggers.isEmpty)
        XCTAssertTrue(validated.sharedConcepts.isEmpty)
        XCTAssertTrue(validatedAreas.rejectedTriggers.contains {
            $0.phrase == "second brain" && $0.reason == .collision
        })
    }

    func testConsensusArtifactCollisionPrefersUniqueConcreteContextOverTagTaxonomy() throws {
        let trigger = VoiceRoutingTrigger(
            pattern: .phrase("knowledge system"),
            origin: .consensusArtifactVocabulary,
            score: 0.86
        )
        let concrete = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger]
        )
        let taxonomy = card(
            id: "knowledge-tag",
            title: "Knowledge-Management",
            active: [trigger]
        )
        let validated = VoiceRoutingCompilerValidator().validate(
            pack([concrete, taxonomy]),
            seeds: [
                seed(id: "brain", name: "Building a Second Brain", kind: "Area"),
                seed(id: "knowledge-tag", name: "Knowledge-Management", kind: "tag"),
            ]
        )

        // The taxonomy's literal title word now supplies independent evidence. Keep both
        // candidates instead of letting semantic specificity silently suppress that owner.
        let router = VoiceRoutingRuntimeRouter(baseTargets: validated.cards.map {
            .init(phrase: $0.title, ref: .node($0.nodeID), title: $0.title)
        }, pack: validated)
        XCTAssertEqual(router.sharedMatches(in: "knowledge system").first?.candidateNodeIDs,
                       Set(["brain", "knowledge-tag"]))
        let rejectedTag = try XCTUnwrap(validated.card(nodeID: "knowledge-tag"))
        XCTAssertTrue(rejectedTag.activeTriggers.isEmpty)
        XCTAssertTrue(rejectedTag.rejectedTriggers.contains {
            $0.phrase == "knowledge system" && $0.reason == .collision
        })
    }

    func testConsensusArtifactConcreteOwnerBeatsTagWithDifferentTriggerOrigin() throws {
        let concrete = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger("knowledge system", origin: .consensusArtifactVocabulary, score: 0.86)]
        )
        let taxonomy = card(
            id: "technique",
            title: "Technique",
            active: [trigger("knowledge system", origin: .semanticAlias, score: 0.92)]
        )
        let validated = VoiceRoutingCompilerValidator().validate(
            pack([concrete, taxonomy]),
            seeds: [
                seed(id: "brain", name: "Building a Second Brain", kind: "linkedDocument"),
                seed(id: "technique", name: "Technique", kind: "tag"),
            ]
        )
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: validated.cards.map {
                MatchTarget(phrase: $0.title, ref: .node($0.nodeID), title: $0.title)
            },
            pack: validated
        )

        XCTAssertEqual(router.matches(in: "knowledge system").first?.target.title, "Building a Second Brain")
        XCTAssertTrue(try XCTUnwrap(validated.card(nodeID: "technique")).activeTriggers.isEmpty)
    }

    func testUnresolvedGeneratedCollisionCompilesEvidenceBackedSharedConcept() throws {
        let pattern = VoiceRoutingTriggerPattern.phrase("shared context")
        let alpha = card(
            id: "alpha",
            title: "Alpha Notes",
            active: [.init(pattern: pattern, origin: .semanticAlias, score: 0.91)]
        )
        let beta = card(
            id: "beta",
            title: "Beta Notes",
            active: [.init(pattern: pattern, origin: .topicTag, score: 0.86)]
        )

        let validated = VoiceRoutingCompilerValidator().validate(
            pack([alpha, beta]),
            seeds: [
                seed(id: "alpha", name: "Alpha Notes", kind: "Area"),
                seed(id: "beta", name: "Beta Notes", kind: "Area"),
            ]
        )

        XCTAssertTrue(try XCTUnwrap(validated.card(nodeID: "alpha")).activeTriggers.isEmpty)
        XCTAssertTrue(try XCTUnwrap(validated.card(nodeID: "beta")).activeTriggers.isEmpty)
        XCTAssertEqual(validated.sharedConcepts.count, 1)
        let concept = try XCTUnwrap(validated.sharedConcepts.first)
        XCTAssertEqual(concept.id, VoiceRoutingSharedConcept.stableID(for: pattern))
        XCTAssertEqual(concept.pattern, pattern)
        XCTAssertEqual(concept.candidates.map(\.nodeID), ["alpha", "beta"])
        XCTAssertEqual(concept.candidates.map(\.compiledStrength), [0.91, 0.86])
        XCTAssertEqual(concept.candidates.map(\.evidenceHash), ["hash-alpha", "hash-beta"])
        XCTAssertTrue(validated.isStructurallyValid)
    }

    func testCrossPatternRuntimeAmbiguityCompilesSharedConceptInsteadOfRejectingRecall() throws {
        let brain = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger("knowledge system", origin: .consensusArtifactVocabulary, score: 0.86)]
        )
        let techniques = card(
            id: "techniques",
            title: "Knowledge Techniques",
            active: [trigger("knowledge", origin: .semanticAlias, score: 0.90)]
        )

        let validated = VoiceRoutingCompilerValidator().validate(
            pack([brain, techniques]),
            seeds: [
                seed(id: "brain", name: "Building a Second Brain", kind: "Area"),
                seed(id: "techniques", name: "Knowledge Techniques", kind: "Area"),
            ]
        )

        let validatedBrain = try XCTUnwrap(validated.card(nodeID: "brain"))
        XCTAssertFalse(validatedBrain.rejectedTriggers.contains {
            $0.phrase == "knowledge system" && $0.reason == .ambiguous
        })
        XCTAssertFalse(validatedBrain.activeTriggers.contains {
            $0.pattern == .phrase("knowledge system")
        })
        let concept = try XCTUnwrap(validated.sharedConcepts.first {
            $0.pattern == .phrase("knowledge system")
        })
        XCTAssertEqual(concept.candidates.map(\.nodeID), ["brain", "techniques"])
        XCTAssertEqual(concept.candidates.map(\.evidenceHash), ["hash-brain", "hash-techniques"])
        XCTAssertEqual(concept.candidates.map(\.compiledStrength), [0.86, 0.84])

        let router = VoiceRoutingRuntimeRouter(
            baseTargets: validated.cards.map {
                MatchTarget(phrase: $0.title, ref: .node($0.nodeID), title: $0.title)
            },
            pack: validated
        )
        XCTAssertTrue(router.matches(in: "knowledge system").isEmpty)
        XCTAssertEqual(
            router.sharedMatches(in: "knowledge system").first?.candidates.map(\.target.title),
            ["Building a Second Brain", "Knowledge Techniques"]
        )
        let preferredRouter = VoiceRoutingRuntimeRouter(
            baseTargets: validated.cards.map {
                MatchTarget(phrase: $0.title, ref: .node($0.nodeID), title: $0.title)
            },
            pack: validated,
            preferenceBoosts: [
                .init(conceptID: concept.id, nodeID: "techniques"): VoiceRoutingPreferenceStore.boostPerWeight,
            ]
        )
        XCTAssertEqual(
            preferredRouter.sharedMatches(in: "knowledge system").first?.candidates.map(\.target.title),
            ["Knowledge Techniques", "Building a Second Brain"]
        )
        let gate = VoiceRoutingQualityGate().evaluate(pack: validated, expectedNodeCount: 2)
        XCTAssertTrue(gate.passed, gate.failures.joined(separator: ", "))
    }

    func testSameSpanCanonicalIdentityPreventsRuntimeAmbiguityPromotion() throws {
        let generated = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger("knowledge system", origin: .semanticAlias, score: 0.90)]
        )
        let identity = card(id: "canonical", title: "Knowledge System", active: [])

        let validated = VoiceRoutingCompilerValidator().validate(
            pack([generated, identity]),
            seeds: [
                seed(id: "brain", name: "Building a Second Brain", kind: "Area"),
                seed(id: "canonical", name: "Knowledge System", kind: "Area"),
            ]
        )

        XCTAssertTrue(validated.sharedConcepts.isEmpty)
        let rejected = try XCTUnwrap(validated.card(nodeID: "brain"))
        XCTAssertTrue(rejected.rejectedTriggers.contains {
            $0.phrase == "knowledge system" && $0.reason == .wrongWinner
        })
    }

    func testCrossPatternGenericAmbiguityCannotBecomeSharedConcept() throws {
        let validated = VoiceRoutingCompilerValidator().validate(
            pack([
                card(
                    id: "alpha",
                    title: "Alpha Notes",
                    active: [trigger("my notes", origin: .semanticAlias, score: 0.90)]
                ),
                card(
                    id: "beta",
                    title: "Beta Notes",
                    active: [trigger("notes", origin: .semanticAlias, score: 0.90)]
                ),
            ]),
            seeds: [
                seed(id: "alpha", name: "Alpha Notes", kind: "Area"),
                seed(id: "beta", name: "Beta Notes", kind: "Area"),
            ]
        )

        XCTAssertTrue(validated.sharedConcepts.isEmpty)
        let genericRouter = VoiceRoutingRuntimeRouter(baseTargets: [], pack: validated)
        XCTAssertTrue(genericRouter.matches(in: "show me my notes").isEmpty)
        XCTAssertTrue(genericRouter.sharedMatches(in: "show me my notes").isEmpty)

        let ordered = VoiceRoutingTrigger(
            pattern: .orderedTerms(["show", "notes"], maximumGap: 3),
            origin: .phraseFamily,
            score: 0.90
        )
        let orderedValidated = VoiceRoutingCompilerValidator().validate(
            pack([
                card(id: "ordered", title: "Ordered Notes", active: [ordered]),
                card(
                    id: "notes",
                    title: "Other Notes",
                    active: [trigger("notes", origin: .semanticAlias, score: 0.90)]
                ),
            ]),
            seeds: [
                seed(id: "ordered", name: "Ordered Notes", kind: "Area"),
                seed(id: "notes", name: "Other Notes", kind: "Area"),
            ]
        )
        XCTAssertTrue(orderedValidated.sharedConcepts.isEmpty)
    }

    func testRuntimeEvidenceCandidatesExcludeNonOverlappingMentions() {
        let alpha = card(
            id: "alpha",
            title: "First Context",
            active: [trigger("alpha signal", origin: .semanticAlias, score: 0.90)]
        )
        let beta = card(
            id: "beta",
            title: "Second Context",
            active: [trigger("beta signal", origin: .semanticAlias, score: 0.90)]
        )
        let routingPack = pack([alpha, beta])
        let router = VoiceRoutingRuntimeRouter(baseTargets: [], pack: routingPack)

        let evidence = router.evidencedCandidates(
            in: "alpha signal and later beta signal",
            overlapping: .phrase("alpha signal")
        )
        XCTAssertEqual(evidence.map(\.match.target.title), ["First Context"])
        XCTAssertTrue(evidence.allSatisfy(\.hasExactOriginSpan))
    }

    func testDuplicateCanonicalTitlesDoNotTrapRegressionLookup() {
        let validated = VoiceRoutingCompilerValidator().validate(
            pack([
                card(id: "journal-a", title: "Journal", active: []),
                card(id: "journal-b", title: "Journal", active: []),
            ]),
            seeds: [
                seed(id: "journal-a", name: "Journal"),
                seed(id: "journal-b", name: "Journal"),
            ]
        )

        XCTAssertEqual(validated.cards.count, 2)
    }

    func testSharedConceptIDDependsOnlyOnNormalizedPattern() {
        let first = VoiceRoutingSharedConcept.stableID(for: .phrase(" Shared   Context "))
        let second = VoiceRoutingSharedConcept.stableID(for: .phrase("shared context"))
        let ordered = VoiceRoutingSharedConcept.stableID(
            for: .orderedTerms(["Shared", "Context"], maximumGap: 2)
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, ordered)
    }

    func testCollisionWithOneProductionValidCandidateRestoresUniqueTrigger() throws {
        let collision = VoiceRoutingTrigger(
            pattern: .orderedTerms(["shared", "context"], maximumGap: 2),
            origin: .semanticAlias,
            score: 0.80
        )
        let alpha = card(
            id: "alpha",
            title: "Alpha Notes",
            active: [
                trigger("shared about context", origin: .semanticAlias, score: 1.0),
                collision,
            ]
        )
        let beta = card(
            id: "beta",
            title: "Beta Notes",
            active: [collision]
        )

        let validated = VoiceRoutingCompilerValidator().validate(
            pack([alpha, beta]),
            seeds: [
                seed(id: "alpha", name: "Alpha Notes", kind: "Area"),
                seed(id: "beta", name: "Beta Notes", kind: "Area"),
            ]
        )

        XCTAssertTrue(validated.sharedConcepts.isEmpty)
        XCTAssertTrue(try XCTUnwrap(validated.card(nodeID: "alpha")).activeTriggers.contains(collision))
        let rejectedBeta = try XCTUnwrap(validated.card(nodeID: "beta"))
        XCTAssertTrue(rejectedBeta.activeTriggers.isEmpty)
        XCTAssertTrue(rejectedBeta.rejectedTriggers.contains {
            $0.phrase == collision.pattern.displayPhrase && $0.reason == .wrongWinner
        })
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: validated.cards.map {
                MatchTarget(phrase: $0.title, ref: .node($0.nodeID), title: $0.title)
            },
            pack: validated
        )
        XCTAssertEqual(
            router.validate(utterance: "shared about context", expectedNodeID: "alpha").outcome,
            .accepted
        )
    }

    func testExactCollisionAmbiguitySurvivesLongEnoughToEnrichWithCrossPatternEvidence() throws {
        let brainTrigger = trigger("knowledge system", origin: .semanticAlias, score: 0.86)
        let techniqueTrigger = trigger("knowledge system", origin: .phraseFamily, score: 0.87)
        let brain = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [brainTrigger]
        )
        let technique = card(
            id: "technique",
            title: "Knowledge Technique",
            active: [techniqueTrigger]
        )
        let resource = card(
            id: "resource",
            title: "Knowledge Resource",
            active: [trigger("knowledge", origin: .semanticAlias, score: 0.90)]
        )

        let validated = VoiceRoutingCompilerValidator().validate(
            pack([brain, technique, resource]),
            seeds: [
                seed(id: "brain", name: "Building a Second Brain", kind: "Area"),
                seed(id: "technique", name: "Knowledge Technique", kind: "Area"),
                seed(id: "resource", name: "Knowledge Resource", kind: "Area"),
            ]
        )

        let concept = try XCTUnwrap(validated.sharedConcepts.first {
            $0.pattern == .phrase("knowledge system")
        })
        XCTAssertEqual(concept.candidates.map(\.nodeID), ["technique", "brain", "resource"])
        XCTAssertEqual(concept.candidates.map(\.compiledStrength), [0.87, 0.86, 0.85])
        XCTAssertFalse(validated.cards.flatMap(\.rejectedTriggers).contains {
            $0.phrase == "knowledge system" && $0.reason == .ambiguous
        })

        let router = VoiceRoutingRuntimeRouter(
            baseTargets: validated.cards.map {
                MatchTarget(phrase: $0.title, ref: .node($0.nodeID), title: $0.title)
            },
            pack: validated
        )
        XCTAssertTrue(router.matches(in: "knowledge system").isEmpty)
        XCTAssertEqual(
            router.sharedMatches(in: "knowledge system").first?.candidates.map(\.target.title),
            ["Knowledge Technique", "Building a Second Brain", "Knowledge Resource"]
        )
        let gate = VoiceRoutingQualityGate().evaluate(pack: validated, expectedNodeCount: 3)
        XCTAssertTrue(gate.passed, gate.failures.joined(separator: ", "))
    }

    func testGenericRegressionCollisionCannotBecomeASharedConcept() throws {
        let unsafe = trigger("show me my notes", origin: .semanticAlias, score: 0.91)
        let validated = VoiceRoutingCompilerValidator().validate(
            pack([
                card(id: "alpha", title: "Alpha Notes", active: [unsafe]),
                card(id: "beta", title: "Beta Notes", active: [unsafe]),
            ]),
            seeds: [
                seed(id: "alpha", name: "Alpha Notes", kind: "Area"),
                seed(id: "beta", name: "Beta Notes", kind: "Area"),
            ]
        )

        XCTAssertTrue(validated.sharedConcepts.isEmpty)
        XCTAssertTrue(try XCTUnwrap(validated.card(nodeID: "alpha")).activeTriggers.isEmpty)
        XCTAssertTrue(try XCTUnwrap(validated.card(nodeID: "beta")).activeTriggers.isEmpty)
        XCTAssertTrue(validated.cards.allSatisfy { $0.hardNegatives.contains("show me my notes") })
    }

    func testStoreJSONSeparatesCachedProposalsFromActivatedTriggers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("voice-routing.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var proposal = card(
            id: "journal",
            title: "Journal",
            active: [trigger("diary", origin: .semanticAlias, score: 0.92)]
        )
        proposal.proposalProvenance = .init(lexicalAlternativePasses: [
            ["diary", "logbook"],
            ["diary"],
            [],
        ])
        let store = VoiceRoutingStore(fileURL: file)
        try await store.save(card: proposal, graphRevision: "graph", compilerVersion: "compiler", modelVersion: "model")
        try await store.activate(pack([proposal]), retaining: [proposal.evidenceHash])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 6)
        let proposals = try XCTUnwrap(object["proposalsByCacheKey"] as? [String: Any])
        let encodedProposal = try XCTUnwrap(proposals.values.first as? [String: Any])
        let provenance = try XCTUnwrap(encodedProposal["proposalProvenance"] as? [String: Any])
        XCTAssertEqual((provenance["lexicalAlternativePasses"] as? [[String]])?.count, 3)
        XCTAssertNil(object["proposalsByEvidenceHash"])
        XCTAssertNil(object["cardsByEvidenceHash"])
        XCTAssertNotNil(object["activePack"])
    }

    func testStoreRoundTripsCompiledSharedConceptEdgesWithoutSourceEvidence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("voice-routing.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var compiled = pack([
            card(id: "alpha", title: "Alpha Notes", active: []),
            card(id: "beta", title: "Beta Notes", active: []),
        ])
        let pattern = VoiceRoutingTriggerPattern.phrase("shared context")
        compiled.sharedConcepts = [
            .init(
                id: VoiceRoutingSharedConcept.stableID(for: pattern),
                pattern: pattern,
                candidates: [
                    .init(nodeID: "alpha", compiledStrength: 0.91, origin: .semanticAlias, evidenceHash: "hash-alpha"),
                    .init(nodeID: "beta", compiledStrength: 0.86, origin: .topicTag, evidenceHash: "hash-beta"),
                ]
            ),
        ]
        let store = VoiceRoutingStore(fileURL: file)
        try await store.activate(compiled, retaining: ["hash-alpha", "hash-beta"])

        let restored = await store.activePack(
            graphRevision: "graph",
            compilerVersion: "compiler",
            modelVersion: "model"
        )
        XCTAssertEqual(restored?.sharedConcepts, compiled.sharedConcepts)
        let json = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        XCTAssertTrue(json.contains("sharedConcepts"))
        XCTAssertTrue(json.contains("evidenceHash"))
        XCTAssertFalse(json.contains("source excerpt"))

        var staleArchive = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        staleArchive["schemaVersion"] = 4
        try JSONSerialization.data(withJSONObject: staleArchive, options: [.sortedKeys])
            .write(to: file, options: .atomic)
        let reopened = VoiceRoutingStore(fileURL: file)
        let stalePack = await reopened.activePack(
            graphRevision: "graph",
            compilerVersion: "compiler",
            modelVersion: "model"
        )
        XCTAssertNil(stalePack)
    }

    func testQualityGateValidatesSharedConceptStructureCandidatesAndNegativeCorpus() {
        let alpha = card(id: "alpha", title: "Alpha Notes", active: [])
        let beta = card(id: "beta", title: "Beta Notes", active: [])
        let pattern = VoiceRoutingTriggerPattern.phrase("shared context")
        let concept = VoiceRoutingSharedConcept(
            id: VoiceRoutingSharedConcept.stableID(for: pattern),
            pattern: pattern,
            candidates: [
                .init(nodeID: "alpha", compiledStrength: 0.91, origin: .semanticAlias, evidenceHash: "hash-alpha"),
                .init(nodeID: "beta", compiledStrength: 0.86, origin: .topicTag, evidenceHash: "hash-beta"),
            ]
        )
        var valid = pack([alpha, beta])
        valid.sharedConcepts = [concept]
        let validResult = VoiceRoutingQualityGate().evaluate(pack: valid, expectedNodeCount: 2)
        XCTAssertTrue(validResult.passed, validResult.failures.joined(separator: ", "))

        var staleEvidence = valid
        staleEvidence.sharedConcepts[0].candidates[0].evidenceHash = "stale-hash"
        let staleResult = VoiceRoutingQualityGate().evaluate(pack: staleEvidence, expectedNodeCount: 2)
        XCTAssertFalse(staleResult.passed)
        XCTAssertTrue(staleResult.failures.contains("routing pack is structurally invalid"))

        var generic = valid
        let genericPattern = VoiceRoutingTriggerPattern.phrase("show me my notes")
        generic.sharedConcepts = [
            .init(
                id: VoiceRoutingSharedConcept.stableID(for: genericPattern),
                pattern: genericPattern,
                candidates: concept.candidates
            ),
        ]
        let genericResult = VoiceRoutingQualityGate().evaluate(pack: generic, expectedNodeCount: 2)
        XCTAssertFalse(genericResult.passed)
        XCTAssertTrue(genericResult.failures.contains { $0.contains("generic regression did not abstain") })
    }

    func testQualityGateAcceptsFixedRecallWhenExpectedNodeIsSharedCandidate() {
        let brain = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger("second brain", origin: .shortenedCanonical, score: 0.94)]
        )
        let knowledge = card(id: "knowledge", title: "Knowledge Management", active: [])
        let pattern = VoiceRoutingTriggerPattern.phrase("knowledge system")
        var candidatePack = pack([brain, knowledge])
        candidatePack.sharedConcepts = [
            .init(
                id: VoiceRoutingSharedConcept.stableID(for: pattern),
                pattern: pattern,
                candidates: [
                    .init(nodeID: "brain", compiledStrength: 0.91, origin: .semanticAlias, evidenceHash: "hash-brain"),
                    .init(nodeID: "knowledge", compiledStrength: 0.86, origin: .topicTag, evidenceHash: "hash-knowledge"),
                ]
            ),
        ]

        let result = VoiceRoutingQualityGate().evaluate(pack: candidatePack, expectedNodeCount: 2)

        XCTAssertTrue(result.passed, result.failures.joined(separator: ", "))
        XCTAssertFalse(result.warnings.contains { $0.contains("knowledge system") })
    }

    func testQualityGateExecutesOnlyActiveTriggersAndChecksNegativesGlobally() {
        var journal = card(
            id: "journal",
            title: "Journal",
            active: [trigger("diary", origin: .semanticAlias, score: 0.92)]
        )
        journal.semanticAliases = ["dormant unvalidated prose"]
        let clean = VoiceRoutingQualityGate().evaluate(pack: pack([journal]), expectedNodeCount: 1)
        XCTAssertTrue(clean.passed, clean.failures.joined(separator: ", "))
        XCTAssertTrue(clean.warnings.isEmpty)

        journal.hardNegatives = ["second brain"]
        let brain = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger("second brain", origin: .shortenedCanonical, score: 0.94)]
        )
        let unsafe = VoiceRoutingQualityGate().evaluate(pack: pack([journal, brain]), expectedNodeCount: 2)
        XCTAssertFalse(unsafe.passed)
        XCTAssertTrue(unsafe.failures.contains { $0.contains("hard negative did not globally abstain") })
    }

    func testConfuserMayRouteToNeighborWhileHardNegativeMustGloballyAbstain() throws {
        let brain = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger("second brain", origin: .shortenedCanonical, score: 0.94)]
        )
        let areasWithConfuser = card(
            id: "areas",
            title: "Areas",
            confusers: ["second brain"],
            active: [trigger("knowledge areas", origin: .semanticAlias, score: 0.92)]
        )
        let proposedConfuserPack = pack([brain, areasWithConfuser])
        let validatedConfusers = VoiceRoutingCompilerValidator().validate(proposedConfuserPack, seeds: [
            seed(id: "brain", name: "Building a Second Brain"),
            seed(id: "areas", name: "Areas"),
        ])
        XCTAssertEqual(try XCTUnwrap(validatedConfusers.card(nodeID: "areas")).confusableConcepts, ["second brain"])

        var areasWithHardNegative = areasWithConfuser
        areasWithHardNegative.confusableConcepts = []
        areasWithHardNegative.hardNegatives = ["second brain"]
        let validatedNegatives = VoiceRoutingCompilerValidator().validate(pack([brain, areasWithHardNegative]), seeds: [
            seed(id: "brain", name: "Building a Second Brain"),
            seed(id: "areas", name: "Areas"),
        ])
        let areas = try XCTUnwrap(validatedNegatives.card(nodeID: "areas"))
        XCTAssertTrue(areas.hardNegatives.isEmpty)
        XCTAssertTrue(areas.rejectedTriggers.contains {
            $0.phrase == "second brain" && $0.origin == .hardNegative && $0.reason == .negativeDidNotAbstain
        })
    }

    func testFinalValidationQuarantinesTriggerExposedByNegativePruning() throws {
        let specific = card(
            id: "specific",
            title: "PARA Method",
            active: [trigger("para method", origin: .semanticAlias, score: 0.92)]
        )
        let broad = card(
            id: "broad",
            title: "Methods",
            negatives: ["para method"],
            active: [trigger("method", origin: .semanticAlias, score: 0.92)]
        )

        let validated = VoiceRoutingCompilerValidator().validate(
            pack([specific, broad]),
            seeds: [
                seed(id: "specific", name: "PARA Method"),
                seed(id: "broad", name: "Methods"),
            ]
        )
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: validated.cards.map {
                MatchTarget(phrase: $0.title, ref: .node($0.nodeID), title: $0.title)
            },
            pack: validated
        )

        for card in validated.cards {
            for active in card.activeTriggers {
                let utterance: String = switch active.pattern {
                case .phrase(let phrase): phrase
                case .orderedTerms(let terms, _): terms.joined(separator: " about ")
                }
                XCTAssertEqual(
                    router.validate(
                        utterance: utterance,
                        expectedNodeID: card.nodeID
                    ).outcome,
                    .accepted
                )
            }
        }
        let gate = VoiceRoutingQualityGate().evaluate(pack: validated, expectedNodeCount: 2)
        XCTAssertTrue(gate.passed, gate.failures.joined(separator: ", "))
    }

    func testRegressionCorpusQuarantinesWrongWinnerAndScopesCanonicalNegative() {
        let brain = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger("second brain", origin: .shortenedCanonical, score: 0.94)]
        )
        let technique = card(
            id: "technique",
            title: "Technique",
            active: [trigger("knowledge system", origin: .consensusArtifactVocabulary, score: 0.86)]
        )
        let templates = card(id: "templates", title: "_Templates", active: [])
        let validated = VoiceRoutingCompilerValidator().validate(
            pack([brain, technique, templates]),
            seeds: [
                seed(id: "brain", name: "Building a Second Brain"),
                seed(id: "technique", name: "Technique"),
                seed(id: "templates", name: "_Templates"),
            ]
        )
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: validated.cards.map {
                MatchTarget(phrase: $0.title, ref: .node($0.nodeID), title: $0.title)
            },
            pack: validated
        )

        XCTAssertTrue(router.matches(in: "I keep that in my knowledge system").isEmpty)
        XCTAssertEqual(router.matches(in: "show me the project templates").first?.target.title, "_Templates")
        XCTAssertEqual(router.matches(in: "templates").first?.target.title, "_Templates")
        XCTAssertEqual(router.matches(in: "second brain").first?.target.title, "Building a Second Brain")
    }

    func testSubphraseConfuserCannotDisableOwnersCanonicalOrShortenedIdentity() throws {
        let brain = card(
            id: "brain",
            title: "Building a Second Brain",
            confusers: ["brain"],
            active: [trigger("second brain", origin: .shortenedCanonical, score: 0.94)]
        )
        let techniqueName = card(
            id: "technique-name",
            title: "Technique Name",
            confusers: ["technique"],
            active: []
        )
        let validated = VoiceRoutingCompilerValidator().validate(
            pack([brain, techniqueName]),
            seeds: [
                seed(id: "brain", name: "Building a Second Brain"),
                seed(id: "technique-name", name: "Technique Name"),
            ]
        )

        XCTAssertTrue(try XCTUnwrap(validated.card(nodeID: "brain")).confusableConcepts.isEmpty)
        XCTAssertTrue(try XCTUnwrap(validated.card(nodeID: "technique-name")).confusableConcepts.isEmpty)
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: validated.cards.map {
                MatchTarget(phrase: $0.title, ref: .node($0.nodeID), title: $0.title)
            },
            pack: validated
        )
        XCTAssertEqual(router.validate(utterance: "second brain", expectedNodeID: "brain").outcome, .accepted)
        XCTAssertEqual(router.validate(utterance: "technique name", expectedNodeID: "technique-name").outcome, .accepted)
    }

    func testCanonicalOnlyCardsCountAsValidatedCoverage() {
        let canonicalOnly = pack([
            card(id: "areas", title: "Areas", active: []),
            card(id: "articles", title: "Articles", active: []),
        ])
        let result = VoiceRoutingQualityGate().evaluate(pack: canonicalOnly, expectedNodeCount: 2)
        XCTAssertTrue(result.passed, result.failures.joined(separator: ", "))
        XCTAssertEqual(result.coverage, 1)
    }

    func testQualityGateReplaysFixedProductionCorpusThreeTimesWithoutLoweringCoverage() {
        let journal = card(
            id: "journal",
            title: "Journal",
            active: [trigger("diary", origin: .semanticAlias, score: 0.92)]
        )
        let brain = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [
                trigger("second brain", origin: .shortenedCanonical, score: 0.94),
                trigger("knowledge system", origin: .phraseFamily, score: 0.90),
            ]
        )
        let progressive = VoiceRoutingCard(
            nodeID: "progressive",
            title: "Progressive Summarization",
            evidenceHash: "hash-progressive",
            canonicalPhrases: ["Progressive Summarization"],
            semanticAliases: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            hardNegatives: [],
            confusableConcepts: [],
            activeTriggers: [
                .init(
                    pattern: .orderedTerms(["progressive", "summarization"], maximumGap: 2),
                    origin: .phraseFamily,
                    score: 0.90
                ),
                trigger("progressive summarizing", origin: .phraseFamily, score: 0.90),
            ]
        )
        let passingPack = pack([journal, brain, progressive])
        let passing = VoiceRoutingQualityGate().evaluate(pack: passingPack, expectedNodeCount: 3)
        XCTAssertTrue(passing.passed, passing.failures.joined(separator: ", "))
        XCTAssertEqual(passing.coverage, 1)

        var missingKnowledgeSystem = brain
        missingKnowledgeSystem.activeTriggers.removeAll { $0.pattern == .phrase("knowledge system") }
        let failing = VoiceRoutingQualityGate().evaluate(
            pack: pack([journal, missingKnowledgeSystem, progressive]),
            expectedNodeCount: 3
        )
        XCTAssertTrue(failing.passed, failing.failures.joined(separator: ", "))
        XCTAssertEqual(
            failing.warnings.filter { $0.contains("knowledge system") }.count,
            1,
            "A missed positive recall check must warn without discarding other safe triggers"
        )
    }

    func testQualityGateAcceptsExactlyEightyPercentCanonicalCoverage() {
        let cards = (1...4).map { card(id: "card-\($0)", title: "Card \($0)", active: []) }

        let passing = VoiceRoutingQualityGate().evaluate(pack: pack(cards), expectedNodeCount: 5)
        let failing = VoiceRoutingQualityGate().evaluate(pack: pack(cards), expectedNodeCount: 6)

        XCTAssertEqual(passing.coverage, 0.8)
        XCTAssertTrue(passing.passed, passing.failures.joined(separator: ", "))
        XCTAssertEqual(failing.coverage, 4.0 / 6.0)
        XCTAssertFalse(failing.passed)
        XCTAssertEqual(failing.failures, ["validated card coverage below 80%"])
    }

    func testQualityGatePreservesZeroAndMismatchedExpectedCountSemantics() {
        let empty = VoiceRoutingQualityGate().evaluate(pack: pack([]), expectedNodeCount: 0)
        let cards = [
            card(id: "alpha", title: "Alpha", active: []),
            card(id: "beta", title: "Beta", active: []),
        ]
        let mismatch = VoiceRoutingQualityGate().evaluate(pack: pack(cards), expectedNodeCount: 1)

        XCTAssertEqual(empty.coverage, 0)
        XCTAssertFalse(empty.passed)
        XCTAssertEqual(empty.failures, ["validated card coverage below 80%"])
        XCTAssertEqual(mismatch.coverage, 2)
        XCTAssertTrue(mismatch.passed, mismatch.failures.joined(separator: ", "))
    }

    func testQualityGateDeduplicatesSortsDiagnosticsAndKeepsWarningsWithFailures() {
        let brain = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger("second brain", origin: .shortenedCanonical, score: 0.94)]
        )
        let archive = card(
            id: "archive",
            title: "Archive",
            active: [
                trigger("show me my notes", origin: .semanticAlias, score: 0.92),
                trigger("I should write something", origin: .semanticAlias, score: 0.92),
            ]
        )
        let journal = card(id: "journal", title: "Journal", active: [])
        let candidatePack = pack([brain, archive, journal])

        let result = VoiceRoutingQualityGate().evaluate(pack: candidatePack, expectedNodeCount: 3)

        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.failures, [
            "generic regression did not abstain: I should write something",
            "generic regression did not abstain: Show me my notes",
        ])
        XCTAssertEqual(result.warnings, [
            "fixed recall regression missed for brain: knowledge system",
            "fixed recall regression missed for journal: I need to write in my diary",
        ])
    }

    private func seed(
        id: String,
        name: String,
        kind: String? = nil,
        directTerms: [String] = [],
        children: [String] = [],
        directExcerpts: [String] = []
    ) -> VoiceRoutingSeed {
        VoiceRoutingSeed(
            nodeID: id,
            canonicalName: name,
            existingAliases: [],
            kind: kind,
            contextOnlyAncestry: [],
            contextOnlyChildNames: children,
            directArtifactTitles: [],
            directHeadingsAndTags: directTerms,
            directTags: directTerms,
            directExcerpts: directExcerpts,
            evidenceHash: "hash-\(id)"
        )
    }

    private func trigger(
        _ phrase: String,
        origin: VoiceRoutingTriggerOrigin,
        score: Double
    ) -> VoiceRoutingTrigger {
        .init(pattern: .phrase(phrase), origin: origin, score: score)
    }

    private func card(
        id: String,
        title: String,
        negatives: [String] = [],
        confusers: [String] = [],
        active: [VoiceRoutingTrigger]
    ) -> VoiceRoutingCard {
        VoiceRoutingCard(
            nodeID: id,
            title: title,
            evidenceHash: "hash-\(id)",
            canonicalPhrases: [title],
            semanticAliases: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            hardNegatives: negatives,
            confusableConcepts: confusers,
            activeTriggers: active,
            descriptiveVocabulary: [],
            rejectedTriggers: []
        )
    }

    private func pack(_ cards: [VoiceRoutingCard]) -> VoiceRoutingPack {
        VoiceRoutingPack(
            graphRevision: "graph",
            compilerVersion: "compiler",
            modelVersion: "model",
            generatedAt: .distantPast,
            cards: cards
        )
    }
}

private final class VoiceRoutingProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [VoiceRoutingCompilationProgress] = []

    var snapshots: [VoiceRoutingCompilationProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ progress: VoiceRoutingCompilationProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}
