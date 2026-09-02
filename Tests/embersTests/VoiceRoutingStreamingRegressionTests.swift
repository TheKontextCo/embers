import XCTest
import EmbersLocal
@testable import embers

/// End-to-end regressions for the exact deterministic router owned by `AppState`.
/// These deliberately avoid `SemanticVoiceMatcher`: production and tests consume the same
/// streaming partial-transcript implementation, without requiring Apple's model.
final class VoiceRoutingStreamingRegressionTests: XCTestCase {
    func testStreamingPartialImmediatelySurfacesSecondBrainInsideASentence() {
        var router = makeStreamRouter()

        XCTAssertEqual(router.process(partial("Yeah and then I'll add that to my second")).map(\.target.title), ["Building a Second Brain"])
        XCTAssertEqual(
            router.process(partial("Yeah and then I'll add that to my second brain knowledge library")).map(\.target.title),
            ["Building a Second Brain"]
        )
    }

    func testCompiledPatternsHandleNonContiguousAndInflectedProgressiveSummarization() {
        var noncontiguous = makeStreamRouter()
        XCTAssertEqual(
            noncontiguous.process(partial("let's be progressive about the summarization")).map(\.target.title),
            ["Progressive Summarization"]
        )

        var inflected = makeStreamRouter()
        XCTAssertEqual(
            inflected.process(partial("add it to the progressive summarizing project")).map(\.target.title),
            ["Progressive Summarization"]
        )
    }

    func testCompiledDiaryAndKnowledgeSystemPhraseFamiliesRouteWithoutAModel() {
        var diary = makeStreamRouter()
        XCTAssertEqual(
            diary.process(partial("I need to write in my diary")).map(\.target.title),
            ["Journal"]
        )

        var knowledgeSystem = makeStreamRouter()
        XCTAssertEqual(
            knowledgeSystem.process(partial("I keep that in my knowledge system")).map(\.target.title),
            ["Building a Second Brain"]
        )
    }

    func testHardNegativesBlockOtherwiseMatchingPositiveTriggers() {
        let cases = [
            "skip the links",
            "I need to write in my planner",
        ]

        for utterance in cases {
            var router = makeStreamRouter()
            XCTAssertTrue(router.process(partial(utterance)).isEmpty, "Unexpected route for: \(utterance)")
        }
    }

    func testSuffixNegativeRetractsAPreviouslyPresentedPartialHit() {
        var router = makeStreamRouter()
        let utteranceID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

        let positive = router.process(transcript("show me the links", id: utteranceID))
        XCTAssertEqual(positive.map(\.target.title), ["wikilinks"])
        router.markPresented(positive)

        let corrected = router.process(transcript("show me the links actually skip the links", id: utteranceID))
        XCTAssertTrue(corrected.matches.isEmpty)
        XCTAssertEqual(corrected.retractedNodeIDs, ["wikilinks"])
    }

    func testDirectReplacementPartialsPreserveThreeVisibleProjects() {
        var harness = makeThreeProjectHarness()
        let utteranceID = UUID(uuidString: "00000000-0000-0000-0000-000000000035")!

        for (title, expectedVisible) in [
            ("Kontext", Set(["kontext"])),
            ("Skippy", Set(["kontext", "skippy"])),
            ("Apollo", Set(["kontext", "skippy", "apollo"])),
        ] {
            let update = harness.process(title, utteranceID: utteranceID)

            XCTAssertEqual(update.map(\.target.title), [title])
            XCTAssertTrue(update.retractedNodeIDs.isEmpty)
            XCTAssertEqual(harness.visibleNodeIDs, expectedVisible)
        }
    }

    func testNoMatchPartialsBetweenReplacementHitsDoNotRemoveVisibleProjects() {
        var harness = makeThreeProjectHarness()
        let utteranceID = UUID(uuidString: "00000000-0000-0000-0000-000000000036")!

        _ = harness.process("Kontext", utteranceID: utteranceID)
        let generic = harness.process("something unrelated", utteranceID: utteranceID)
        XCTAssertTrue(generic.isEmpty)
        XCTAssertEqual(harness.visibleNodeIDs, ["kontext"])

        _ = harness.process("Skippy", utteranceID: utteranceID)
        let empty = harness.process("", utteranceID: utteranceID)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(harness.visibleNodeIDs, ["kontext", "skippy"])

        let third = harness.process("Apollo", utteranceID: utteranceID)
        XCTAssertEqual(third.map(\.target.title), ["Apollo"])
        XCTAssertTrue(third.retractedNodeIDs.isEmpty)
        XCTAssertEqual(harness.visibleNodeIDs, ["kontext", "skippy", "apollo"])
    }

    func testSeparateUtterancesPreserveThreeVisibleProjects() {
        var harness = makeThreeProjectHarness()
        let events = [
            ("Kontext", UUID(uuidString: "00000000-0000-0000-0000-000000000037")!),
            ("Skippy", UUID(uuidString: "00000000-0000-0000-0000-000000000038")!),
            ("Apollo", UUID(uuidString: "00000000-0000-0000-0000-000000000039")!),
        ]

        for (title, utteranceID) in events {
            let update = harness.process(title, utteranceID: utteranceID)
            XCTAssertEqual(update.map(\.target.title), [title])
            XCTAssertTrue(update.retractedNodeIDs.isEmpty)
        }

        XCTAssertEqual(harness.visibleNodeIDs, ["kontext", "skippy", "apollo"])
    }

    func testCumulativeThenRevisedPartialsPreserveThreeVisibleProjects() {
        var harness = makeThreeProjectHarness()
        let utteranceID = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!

        let first = harness.process("Kontext", utteranceID: utteranceID)
        let cumulative = harness.process("Kontext Skippy", utteranceID: utteranceID)
        let revised = harness.process("Kontext Apollo", utteranceID: utteranceID)

        XCTAssertEqual(first.map(\.target.title), ["Kontext"])
        XCTAssertEqual(cumulative.map(\.target.title), ["Skippy"])
        XCTAssertEqual(revised.map(\.target.title), ["Apollo"])
        XCTAssertTrue([first, cumulative, revised].allSatisfy(\.retractedNodeIDs.isEmpty))
        XCTAssertEqual(harness.visibleNodeIDs, ["kontext", "skippy", "apollo"])
    }

    func testUnrelatedPartialDoesNotRetractAPreviouslyPresentedUniqueMatch() {
        var router = makeStreamRouter()
        let utteranceID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!

        let positive = router.process(transcript("show me the links", id: utteranceID))
        XCTAssertEqual(positive.map(\.target.title), ["wikilinks"])
        router.markPresented(positive)

        let corrected = router.process(transcript("show me something else", id: utteranceID))

        XCTAssertTrue(corrected.isEmpty)
        XCTAssertTrue(corrected.retractedNodeIDs.isEmpty)
    }

    func testPrefixNegativeNeverPresentsAndHasNothingToRetract() {
        var router = makeStreamRouter()

        let update = router.process(partial("skip the links"))

        XCTAssertTrue(update.matches.isEmpty)
        XCTAssertTrue(update.retractedNodeIDs.isEmpty)
    }

    func testSharedVocabularyAbstainsWhenWinningMarginIsTooSmall() {
        let base = [
            target("First Brain", nodeID: "first"),
            target("Second Brain", nodeID: "second"),
        ]
        let pack = makePack(cards: [
            card(
                id: "first",
                title: "First Brain",
                active: [trigger("knowledge app", score: 0.90)]
            ),
            card(
                id: "second",
                title: "Second Brain",
                active: [trigger("knowledge app", score: 0.86)]
            ),
        ])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)

        XCTAssertTrue(router.process(partial("open the knowledge app")).isEmpty)
    }

    func testCompilerDeclaredSharedConceptPresentsAtMostThreeAttributedCandidates() {
        let base = (1...4).map { target("Context \($0)", nodeID: "node-\($0)") }
        let concept = sharedConcept(
            "knowledge system",
            candidates: (1...4).map { ("node-\($0)", 0.96 - Double($0) * 0.01) }
        )
        let pack = makePack(
            cards: (1...4).map { card(id: "node-\($0)", title: "Context \($0)") },
            sharedConcepts: [concept]
        )
        let router = VoiceRoutingRuntimeRouter(baseTargets: base, pack: pack)

        let matches = router.sharedMatches(in: "put it in my knowledge system")
        XCTAssertEqual(matches.first?.candidates.map(\.target.title), ["Context 1", "Context 2", "Context 3"])
        XCTAssertTrue(matches.first?.candidates.allSatisfy { $0.target.conceptID == concept.id } ?? false)
        XCTAssertTrue(router.matches(in: "put it in my knowledge system").isEmpty)
    }

    func testEquivalentPhraseAndOrderedSharedConceptsDedupeToPhraseForOneOccurrence() {
        let base = [
            target("Building a Second Brain", nodeID: "brain"),
            target("Knowledge Management", nodeID: "management"),
        ]
        let candidates = [("brain", 0.95), ("management", 0.91)]
        let phrase = sharedConcept(
            pattern: .phrase("knowledge management system"),
            candidates: candidates
        )
        let ordered = sharedConcept(
            pattern: .orderedTerms(["knowledge", "management", "system"], maximumGap: 2),
            candidates: candidates
        )
        let pack = makePack(cards: [
            card(id: "brain", title: "Building a Second Brain"),
            card(id: "management", title: "Knowledge Management"),
        ], sharedConcepts: [ordered, phrase])
        let runtime = VoiceRoutingRuntimeRouter(baseTargets: base, pack: pack)

        let matches = runtime.sharedMatches(in: "knowledge management system")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.conceptID, phrase.id)
        XCTAssertEqual(matches.first?.pattern, .phrase("knowledge management system"))

        var stream = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)
        XCTAssertEqual(stream.process(partial("knowledge management system")).sharedConcepts.count, 1)
    }

    func testEquivalentPatternsStillPreserveASeparateGappedMention() {
        let base = [
            target("Building a Second Brain", nodeID: "brain"),
            target("Knowledge Management", nodeID: "management"),
        ]
        let candidates = [("brain", 0.95), ("management", 0.91)]
        let phrase = sharedConcept(
            pattern: .phrase("knowledge management system"),
            candidates: candidates
        )
        let ordered = sharedConcept(
            pattern: .orderedTerms(["knowledge", "management", "system"], maximumGap: 2),
            candidates: candidates
        )
        let pack = makePack(cards: [
            card(id: "brain", title: "Building a Second Brain"),
            card(id: "management", title: "Knowledge Management"),
        ], sharedConcepts: [ordered, phrase])
        let runtime = VoiceRoutingRuntimeRouter(baseTargets: base, pack: pack)

        let matches = runtime.sharedMatches(
            in: "knowledge management system and knowledge about management system"
        )
        XCTAssertEqual(matches.map(\.conceptID), [phrase.id, ordered.id])
    }

    func testDifferentTermSequencesOnTheSameSpanRemainDistinctConcepts() {
        let base = [
            target("Building a Second Brain", nodeID: "brain"),
            target("Knowledge Management", nodeID: "management"),
        ]
        let candidates = [("brain", 0.95), ("management", 0.91)]
        let exactSequence = sharedConcept(
            pattern: .phrase("knowledge management system"),
            candidates: candidates
        )
        let broaderSequence = sharedConcept(
            pattern: .orderedTerms(["knowledge", "system"], maximumGap: 2),
            candidates: candidates
        )
        let pack = makePack(cards: [
            card(id: "brain", title: "Building a Second Brain"),
            card(id: "management", title: "Knowledge Management"),
        ], sharedConcepts: [exactSequence, broaderSequence])
        let runtime = VoiceRoutingRuntimeRouter(baseTargets: base, pack: pack)

        XCTAssertEqual(runtime.sharedMatches(in: "knowledge management system").count, 2)
    }

    func testExactIdentityDominatesAnOverlappingSharedConcept() {
        let base = [
            target("Building a Second Brain", nodeID: "building"),
            target("Second Brain", nodeID: "second"),
            target("Brain", nodeID: "brain"),
        ]
        let concept = sharedConcept("second brain", candidates: [("building", 0.95), ("brain", 0.90)])
        let pack = makePack(cards: [
            card(id: "building", title: "Building a Second Brain"),
            card(id: "second", title: "Second Brain"),
            card(id: "brain", title: "Brain"),
        ], sharedConcepts: [concept])
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: base,
            pack: pack,
            preferenceBoosts: [
                .init(conceptID: concept.id, nodeID: "building"): VoiceRoutingPreferenceStore.maximumBoost,
            ]
        )

        XCTAssertEqual(router.matches(in: "second brain").map(\.target.title), ["Second Brain"])
        XCTAssertTrue(router.sharedMatches(in: "second brain").isEmpty)
    }

    func testContainedShortIdentityDoesNotHideAMoreSpecificSharedConcept() {
        let base = [
            target("Building a Second Brain", nodeID: "building"),
            target("Brain", nodeID: "brain"),
            target("Areas", nodeID: "areas"),
        ]
        let concept = sharedConcept("second brain", candidates: [("building", 0.95), ("areas", 0.90)])
        let pack = makePack(cards: [
            card(id: "building", title: "Building a Second Brain"),
            card(id: "brain", title: "Brain"),
            card(id: "areas", title: "Areas"),
        ], sharedConcepts: [concept])
        let router = VoiceRoutingRuntimeRouter(baseTargets: base, pack: pack)

        XCTAssertTrue(router.matches(in: "second brain").isEmpty)
        XCTAssertEqual(
            router.sharedMatches(in: "second brain").first?.candidates.map(\.target.title),
            ["Building a Second Brain", "Areas"]
        )
    }

    func testSuffixBlockerNarrowsSharedConceptWithoutTurningItIntoAUniqueMatch() {
        let base = [
            target("Building a Second Brain", nodeID: "brain"),
            target("Areas", nodeID: "areas"),
        ]
        let concept = sharedConcept("knowledge system", candidates: [("brain", 0.95), ("areas", 0.91)])
        let pack = makePack(cards: [
            card(id: "brain", title: "Building a Second Brain", hardNegatives: ["company knowledge"]),
            card(id: "areas", title: "Areas"),
        ], sharedConcepts: [concept])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)
        let utteranceID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!

        let initial = router.process(transcript("my knowledge system", id: utteranceID))
        XCTAssertEqual(initial.sharedConcepts.first?.candidates.map(\.target.title), ["Building a Second Brain", "Areas"])
        router.markPresented(initial)

        let narrowed = router.process(transcript("my knowledge system for company knowledge", id: utteranceID))
        XCTAssertTrue(narrowed.matches.isEmpty)
        XCTAssertEqual(narrowed.sharedConcepts.first?.candidates.map(\.target.title), ["Areas"])
        XCTAssertTrue(narrowed.retractedConceptIDs.isEmpty)
    }

    func testPrefixBlockerAppliesPerCandidateBeforeSharedConceptPresentation() {
        let base = [target("Brain", nodeID: "brain"), target("Areas", nodeID: "areas")]
        let concept = sharedConcept("knowledge system", candidates: [("brain", 0.95), ("areas", 0.91)])
        let pack = makePack(cards: [
            card(id: "brain", title: "Brain", hardNegatives: ["company knowledge"]),
            card(id: "areas", title: "Areas"),
        ], sharedConcepts: [concept])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)

        let update = router.process(partial("company knowledge in the knowledge system"))
        XCTAssertEqual(update.sharedConcepts.first?.candidates.map(\.target.title), ["Areas"])
    }

    func testSharedConceptIsSuppressedAcrossPartialsButDistinctConceptStillSurfaces() {
        let base = [
            target("Brain", nodeID: "brain"),
            target("Areas", nodeID: "areas"),
            target("Journal", nodeID: "journal"),
        ]
        let knowledge = sharedConcept("knowledge system", candidates: [("brain", 0.95), ("areas", 0.91)])
        let capture = sharedConcept("daily capture", candidates: [("areas", 0.93), ("journal", 0.90)])
        let pack = makePack(cards: [
            card(id: "brain", title: "Brain"),
            card(id: "areas", title: "Areas"),
            card(id: "journal", title: "Journal"),
        ], sharedConcepts: [knowledge, capture])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)

        let first = router.process(partial("knowledge system"))
        XCTAssertEqual(first.sharedConcepts.map(\.conceptID), [knowledge.id])
        router.markPresented(first)
        XCTAssertTrue(router.process(partial("knowledge system")).isEmpty)

        let later = router.process(partial("knowledge system and daily capture"))
        XCTAssertEqual(later.sharedConcepts.map(\.conceptID), [capture.id])
    }

    func testSharedConceptRearmsForALaterOccurrenceInTheSameRecognizerSession() {
        let base = [target("Brain", nodeID: "brain"), target("Areas", nodeID: "areas")]
        let concept = sharedConcept("knowledge management", candidates: [("brain", 0.95), ("areas", 0.91)])
        let pack = makePack(cards: [
            card(id: "brain", title: "Brain"),
            card(id: "areas", title: "Areas"),
        ], sharedConcepts: [concept])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)
        let utteranceID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!

        let first = router.process(transcript("knowledge management", id: utteranceID))
        XCTAssertEqual(first.sharedConcepts.map(\.conceptID), [concept.id])
        XCTAssertEqual(first.sharedConcepts.first?.occurrenceCount, 1)
        router.markPresented(first)

        // The original occurrence remains in Apple's cumulative transcript after the peeks
        // expire. Unrelated growth must not replay it.
        XCTAssertTrue(router.process(
            transcript("knowledge management is useful", id: utteranceID)
        ).isEmpty)

        // A genuinely later occurrence increments the occurrence count and re-arms the group.
        let repeated = router.process(transcript(
            "knowledge management is useful and knowledge management is practical",
            id: utteranceID
        ))
        XCTAssertEqual(repeated.sharedConcepts.map(\.conceptID), [concept.id])
        XCTAssertEqual(repeated.sharedConcepts.first?.occurrenceCount, 2)
    }

    func testSharedConceptRearmsAfterThePhraseDisappearsAndReturns() {
        let base = [target("Brain", nodeID: "brain"), target("Areas", nodeID: "areas")]
        let concept = sharedConcept("knowledge management", candidates: [("brain", 0.95), ("areas", 0.91)])
        let pack = makePack(cards: [
            card(id: "brain", title: "Brain"),
            card(id: "areas", title: "Areas"),
        ], sharedConcepts: [concept])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)
        let utteranceID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!

        let first = router.process(transcript("knowledge management", id: utteranceID))
        router.markPresented(first)
        let departed = router.process(transcript("a different subject", id: utteranceID))
        XCTAssertEqual(departed.retractedConceptIDs, [concept.id])

        let returned = router.process(transcript("knowledge management", id: utteranceID))
        XCTAssertEqual(returned.sharedConcepts.map(\.conceptID), [concept.id])
    }

    func testRepeatedSharedConceptWhileItsPeeksAreVisibleDoesNotBecomeAGhostHit() {
        let base = [target("Brain", nodeID: "brain"), target("Areas", nodeID: "areas")]
        let concept = sharedConcept("knowledge management", candidates: [("brain", 0.95), ("areas", 0.91)])
        let pack = makePack(cards: [
            card(id: "brain", title: "Brain"),
            card(id: "areas", title: "Areas"),
        ], sharedConcepts: [concept])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)
        let utteranceID = UUID(uuidString: "00000000-0000-0000-0000-000000000033")!
        let visible = [concept.id: Set(["brain", "areas"])]

        let first = router.process(transcript("knowledge management", id: utteranceID))
        router.markPresented(first)
        XCTAssertTrue(router.process(
            transcript("knowledge management then knowledge management", id: utteranceID),
            visibleConceptCandidates: visible
        ).isEmpty)

        // Expiring the peeks alone does not replay a mention that was already consumed while
        // they were visible.
        XCTAssertTrue(router.process(
            transcript("knowledge management then knowledge management afterward", id: utteranceID)
        ).isEmpty)
    }

    func testAllCandidatesBlockedRetractsOnlyTheSharedConcept() {
        let base = [target("Brain", nodeID: "brain"), target("Areas", nodeID: "areas")]
        let concept = sharedConcept("knowledge system", candidates: [("brain", 0.95), ("areas", 0.91)])
        let pack = makePack(cards: [
            card(id: "brain", title: "Brain", hardNegatives: ["ignore that"]),
            card(id: "areas", title: "Areas", hardNegatives: ["ignore that"]),
        ], sharedConcepts: [concept])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)
        let utteranceID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!

        let first = router.process(transcript("knowledge system", id: utteranceID))
        router.markPresented(first)
        let blocked = router.process(transcript("knowledge system ignore that", id: utteranceID))

        XCTAssertTrue(blocked.matches.isEmpty)
        XCTAssertTrue(blocked.sharedConcepts.isEmpty)
        XCTAssertEqual(blocked.retractedConceptIDs, [concept.id])
        XCTAssertTrue(blocked.retractedNodeIDs.isEmpty)
    }

    func testNewUtteranceResetsSharedConceptSuppression() {
        let base = [target("Brain", nodeID: "brain"), target("Areas", nodeID: "areas")]
        let concept = sharedConcept("knowledge system", candidates: [("brain", 0.95), ("areas", 0.91)])
        let pack = makePack(cards: [
            card(id: "brain", title: "Brain"),
            card(id: "areas", title: "Areas"),
        ], sharedConcepts: [concept])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!

        let first = router.process(transcript("knowledge system", id: firstID))
        router.markPresented(first)
        XCTAssertTrue(router.process(transcript("knowledge system", id: firstID)).isEmpty)
        XCTAssertEqual(router.process(transcript("knowledge system", id: secondID)).sharedConcepts.map(\.conceptID), [concept.id])
    }

    func testPreferencesReorderSharedCandidatesBeforeTheThreeCandidateCapOnly() {
        let base = [
            target("Alpha", nodeID: "alpha"),
            target("Beta", nodeID: "beta"),
            target("Gamma", nodeID: "gamma"),
            target("Delta", nodeID: "delta"),
        ]
        let concept = sharedConcept(
            "knowledge system",
            candidates: [("alpha", 0.95), ("beta", 0.90), ("gamma", 0.89), ("delta", 0.88)]
        )
        let pack = makePack(cards: [
            card(id: "alpha", title: "Alpha"),
            card(id: "beta", title: "Beta"),
            card(id: "gamma", title: "Gamma"),
            card(id: "delta", title: "Delta"),
        ], sharedConcepts: [concept])
        let router = VoiceRoutingRuntimeRouter(
            baseTargets: base,
            pack: pack,
            preferenceBoosts: [
                .init(conceptID: concept.id, nodeID: "delta"): VoiceRoutingPreferenceStore.maximumBoost,
            ]
        )

        let shared = router.sharedMatches(in: "knowledge system")
        XCTAssertEqual(shared.first?.candidates.map(\.target.title), ["Delta", "Alpha", "Beta"])
        XCTAssertEqual(shared.first?.candidates.map(\.score), [0.88, 0.95, 0.90])
        XCTAssertTrue(router.matches(in: "Alpha").map(\.target.title) == ["Alpha"])
    }

    func testReplacingPreferencesReordersAnAlreadyPresentedConceptWithoutResettingItsHistory() {
        let base = [target("Alpha", nodeID: "alpha"), target("Beta", nodeID: "beta")]
        let concept = sharedConcept("knowledge system", candidates: [("alpha", 0.95), ("beta", 0.90)])
        let pack = makePack(cards: [
            card(id: "alpha", title: "Alpha"),
            card(id: "beta", title: "Beta"),
        ], sharedConcepts: [concept])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)
        let event = transcript(
            "knowledge system",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000024")!
        )

        let first = router.process(event)
        XCTAssertEqual(first.sharedConcepts.first?.candidates.map(\.target.title), ["Alpha", "Beta"])
        router.markPresented(first)
        router.replacePreferences([
            .init(conceptID: concept.id, nodeID: "beta"): VoiceRoutingPreferenceStore.maximumBoost,
        ])

        let reordered = router.process(event)
        XCTAssertEqual(reordered.sharedConcepts.first?.candidates.map(\.target.title), ["Beta", "Alpha"])
        XCTAssertTrue(reordered.retractedConceptIDs.isEmpty)
        router.markPresented(reordered)
        XCTAssertTrue(router.process(event).isEmpty)
    }

    func testParentDescriptiveAndRejectedVocabularyCannotContaminateRuntimeRouting() {
        let base = [
            target("Areas", nodeID: "areas"),
            target("Building a Second Brain", nodeID: "brain"),
        ]
        let pack = makePack(cards: [
            card(
                id: "areas",
                title: "Areas",
                descriptive: ["knowledge system", "knowledge management system"],
                rejected: [
                    .init(phrase: "knowledge system", origin: .artifactType, reason: .wrongWinner),
                ]
            ),
            card(
                id: "brain",
                title: "Building a Second Brain",
                active: [trigger("knowledge system", score: 0.94)]
            ),
        ])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)

        let matches = router.process(partial("put it in my knowledge system"))
        XCTAssertEqual(matches.map(\.target.title), ["Building a Second Brain"])
    }

    func testRejectedTriggerIsInspectableButNeverExecutable() {
        let base = [target("Areas", nodeID: "areas")]
        let pack = makePack(cards: [
            card(
                id: "areas",
                title: "Areas",
                descriptive: ["regional knowledge system"],
                rejected: [
                    .init(phrase: "regional knowledge system", origin: .semanticAlias, reason: .ambiguous),
                ]
            ),
        ])
        XCTAssertEqual(pack.cards[0].rejectedTriggers.map(\.phrase), ["regional knowledge system"])
        var router = VoiceRoutingStreamRouter(baseTargets: base, pack: pack)

        XCTAssertTrue(router.process(partial("open the regional knowledge system")).isEmpty)
    }

    func testActivatedCachePreservesActiveVersusRejectedRuntimeSemantics() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("voice-routing.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let routingCard = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger("knowledge system", origin: .phraseFamily, score: 0.94)],
            descriptive: ["knowledge app"],
            rejected: [
                .init(phrase: "knowledge app", origin: .semanticAlias, reason: .ambiguous),
            ]
        )
        let pack = makePack(cards: [routingCard])
        let store = VoiceRoutingStore(fileURL: file)
        try await store.save(
            card: routingCard,
            graphRevision: pack.graphRevision,
            compilerVersion: pack.compilerVersion,
            modelVersion: pack.modelVersion
        )
        try await store.activate(pack, retaining: [routingCard.evidenceHash])

        let reopened = VoiceRoutingStore(fileURL: file)
        let restored = await reopened.activePack(
            graphRevision: pack.graphRevision,
            compilerVersion: pack.compilerVersion,
            modelVersion: pack.modelVersion
        )
        let loaded = try XCTUnwrap(restored)
        XCTAssertEqual(loaded.cards[0].activeTriggers, routingCard.activeTriggers)
        XCTAssertEqual(loaded.cards[0].rejectedTriggers, routingCard.rejectedTriggers)

        let base = [target("Building a Second Brain", nodeID: "brain")]
        var activeRouter = VoiceRoutingStreamRouter(baseTargets: base, pack: loaded)
        XCTAssertEqual(
            activeRouter.process(partial("open my knowledge system")).map(\.target.title),
            ["Building a Second Brain"]
        )
        var rejectedRouter = VoiceRoutingStreamRouter(baseTargets: base, pack: loaded)
        XCTAssertTrue(rejectedRouter.process(partial("open the knowledge app")).isEmpty)
    }

    func testValidJSONCacheWithDuplicateCardsIsRejectedWithoutConstructingATrappingRouter() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("voice-routing.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let routingCard = card(
            id: "brain",
            title: "Building a Second Brain",
            active: [trigger("second brain", origin: .shortenedCanonical, score: 0.94)]
        )
        let pack = makePack(cards: [routingCard])
        let store = VoiceRoutingStore(fileURL: file)
        try await store.activate(pack, retaining: [routingCard.evidenceHash])

        var archive = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        var activePack = try XCTUnwrap(archive["activePack"] as? [String: Any])
        var cards = try XCTUnwrap(activePack["cards"] as? [[String: Any]])
        cards.append(cards[0])
        activePack["cards"] = cards
        archive["activePack"] = activePack
        try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys])
            .write(to: file, options: .atomic)

        let reopened = VoiceRoutingStore(fileURL: file)
        let duplicate = await reopened.activePack(
            graphRevision: pack.graphRevision,
            compilerVersion: pack.compilerVersion,
            modelVersion: pack.modelVersion
        )
        XCTAssertNil(duplicate)
    }

    func testOnePresentedNodeDoesNotSuppressLaterDistinctHitsInTheSameTranscript() {
        var router = makeStreamRouter()

        let first = router.process(partial("second brain"))
        XCTAssertEqual(first.map(\.target.title), ["Building a Second Brain"])
        router.markPresented(first)
        let second = router.process(partial("second brain and progressive summarization"))
        XCTAssertEqual(second.map(\.target.title), ["Progressive Summarization"])
        router.markPresented(second)
        XCTAssertTrue(router.process(partial("second brain and progressive summarization")).isEmpty)
    }

    func testVisibleNodeSuppressionDoesNotBlockAnotherContext() {
        var router = makeStreamRouter()
        let matches = router.process(
            partial("second brain and progressive summarization"),
            visibleNodeIDs: ["brain"]
        )

        XCTAssertEqual(matches.map(\.target.title), ["Progressive Summarization"])
    }

    func testNewUtteranceIDResetsTemporalSuppression() {
        var router = makeStreamRouter()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!

        let first = router.process(transcript("second brain", id: firstID))
        router.markPresented(first)
        XCTAssertTrue(router.process(transcript("second brain", id: firstID)).isEmpty)

        XCTAssertEqual(
            router.process(transcript("second brain", id: secondID)).map(\.target.title),
            ["Building a Second Brain"]
        )
    }

    func testVisiblePeekStillSuppressesAfterUtteranceIDReset() {
        var router = makeStreamRouter()
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!

        let first = router.process(transcript("second brain", id: firstID))
        router.markPresented(first)
        let reset = router.process(
            transcript("second brain", id: secondID),
            visibleNodeIDs: ["brain"]
        )

        XCTAssertTrue(reset.matches.isEmpty)
        XCTAssertTrue(reset.retractedNodeIDs.isEmpty)
    }

    func testNestedCanonicalNamesPreferTheMostSpecificContainedPhrase() {
        let router = VoiceRoutingRuntimeRouter(baseTargets: [
            target("Building a Second Brain", nodeID: "building"),
            target("Second Brain", nodeID: "second"),
            target("Brain", nodeID: "brain"),
        ], pack: nil)

        XCTAssertEqual(router.matches(in: "Building a Second Brain").map(\.target.title), ["Building a Second Brain"])
        XCTAssertEqual(router.matches(in: "Second Brain").map(\.target.title), ["Second Brain"])
        XCTAssertEqual(router.matches(in: "Brain").map(\.target.title), ["Brain"])
    }

    func testExactContextNameRoutesOnTheFirstNonFinalPartial() {
        var router = makeStreamRouter()
        let event = SpeechTranscript(text: "Progressive Summarization", isFinal: false)

        XCTAssertEqual(router.process(event).map(\.target.title), ["Progressive Summarization"])
    }

    func testGenericConversationalSpeechAbstains() {
        let utterances = [
            "Come on man",
            "What should I talk about to trigger something",
            "What do I have to talk about to get something to show up",
            "That is interesting",
        ]

        for utterance in utterances {
            var router = makeStreamRouter()
            XCTAssertTrue(router.process(partial(utterance)).isEmpty, "Unexpected route for: \(utterance)")
        }
    }

    private func makeStreamRouter() -> VoiceRoutingStreamRouter {
        let base = [
            target("Building a Second Brain", nodeID: "brain"),
            target("Progressive Summarization", nodeID: "summary"),
            target("Journal", nodeID: "journal"),
            target("wikilinks", nodeID: "wikilinks"),
            target("_Templates", nodeID: "templates"),
            target("Projects", nodeID: "projects"),
        ]
        let pack = makePack(cards: [
            card(
                id: "brain",
                title: "Building a Second Brain",
                active: [
                    trigger("second brain", origin: .shortenedCanonical, score: 0.96),
                    trigger("knowledge system", origin: .phraseFamily, score: 0.94),
                    trigger("knowledge management system", origin: .phraseFamily, score: 0.94),
                ]
            ),
            card(
                id: "summary",
                title: "Progressive Summarization",
                active: [
                    .init(
                        pattern: .orderedTerms(["progressive", "summarization"], maximumGap: 3),
                        origin: .phraseFamily,
                        score: 0.94
                    ),
                    trigger("progressive summarizing", origin: .phraseFamily, score: 0.92),
                ]
            ),
            card(
                id: "journal",
                title: "Journal",
                hardNegatives: ["write in my planner"],
                active: [
                    trigger("diary", origin: .semanticAlias, score: 0.94),
                    trigger("planner", origin: .semanticAlias, score: 0.84),
                ]
            ),
            card(
                id: "wikilinks",
                title: "wikilinks",
                hardNegatives: ["skip the links"],
                active: [trigger("links", origin: .shortenedCanonical, score: 0.92)]
            ),
            card(
                id: "templates",
                title: "_Templates",
                hardNegatives: ["project templates"],
                active: [trigger("templates", origin: .shortenedCanonical, score: 0.92)]
            ),
            card(id: "projects", title: "Projects"),
        ])
        return .init(baseTargets: base, pack: pack)
    }

    private func makeThreeProjectHarness() -> VisibleVoiceRoutingHarness {
        .init(router: .init(baseTargets: [
            target("Kontext", nodeID: "kontext"),
            target("Skippy", nodeID: "skippy"),
            target("Apollo", nodeID: "apollo"),
        ], pack: nil))
    }

    private func makePack(
        cards: [VoiceRoutingCard],
        sharedConcepts: [VoiceRoutingSharedConcept] = []
    ) -> VoiceRoutingPack {
        .init(
            graphRevision: "streaming-regressions",
            compilerVersion: "test-compiler",
            modelVersion: "test-model",
            generatedAt: .distantPast,
            cards: cards,
            sharedConcepts: sharedConcepts
        )
    }

    private func sharedConcept(
        _ phrase: String,
        candidates: [(String, Double)]
    ) -> VoiceRoutingSharedConcept {
        sharedConcept(pattern: .phrase(phrase), candidates: candidates)
    }

    private func sharedConcept(
        pattern: VoiceRoutingTriggerPattern,
        candidates: [(String, Double)]
    ) -> VoiceRoutingSharedConcept {
        return .init(
            id: VoiceRoutingSharedConcept.stableID(for: pattern),
            pattern: pattern,
            candidates: candidates.map { nodeID, strength in
                .init(
                    nodeID: nodeID,
                    compiledStrength: strength,
                    origin: .semanticAlias,
                    evidenceHash: "evidence-\(nodeID)"
                )
            }
        )
    }

    private func card(
        id: String,
        title: String,
        hardNegatives: [String] = [],
        active: [VoiceRoutingTrigger] = [],
        descriptive: [String] = [],
        rejected: [VoiceRoutingRejectedTrigger] = []
    ) -> VoiceRoutingCard {
        .init(
            nodeID: id,
            title: title,
            evidenceHash: "evidence-\(id)",
            canonicalPhrases: [title],
            semanticAliases: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            hardNegatives: hardNegatives,
            confusableConcepts: [],
            activeTriggers: active,
            descriptiveVocabulary: descriptive,
            rejectedTriggers: rejected
        )
    }

    private func trigger(
        _ phrase: String,
        origin: VoiceRoutingTriggerOrigin = .semanticAlias,
        score: Double
    ) -> VoiceRoutingTrigger {
        .init(pattern: .phrase(phrase), origin: origin, score: score)
    }

    private func target(_ phrase: String, nodeID: String) -> MatchTarget {
        .init(phrase: phrase, ref: .node(nodeID), title: phrase)
    }

    private func partial(_ text: String) -> SpeechTranscript {
        transcript(text, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    }

    private func transcript(_ text: String, id: UUID) -> SpeechTranscript {
        .init(text: text, isFinal: false, utteranceID: id)
    }
}

private struct VisibleVoiceRoutingHarness {
    var router: VoiceRoutingStreamRouter
    private(set) var visibleNodeIDs = Set<String>()

    mutating func process(_ text: String, utteranceID: UUID) -> VoiceRoutingStreamUpdate {
        let update = router.process(
            .init(text: text, isFinal: false, utteranceID: utteranceID),
            visibleNodeIDs: visibleNodeIDs
        )
        visibleNodeIDs.subtract(update.retractedNodeIDs)
        visibleNodeIDs.formUnion(update.compactMap { match -> String? in
            guard case .node(let nodeID) = match.target.ref else { return nil }
            return nodeID
        })
        router.markPresented(update)
        return update
    }
}
