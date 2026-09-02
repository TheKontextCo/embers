import EmbersCore
import XCTest
@testable import embers

final class VoiceRoutingTitleFragmentTests: XCTestCase {
    func testWholeWordFragmentsWorkWithoutAModel() {
        let router = router(["San Francisco Trip", "America Trip", "Building a Second Brain"])
        for (utterance, title) in [
            ("san francisco", "San Francisco Trip"),
            ("let's discuss SAN, FRANCISCO", "San Francisco Trip"),
            ("america", "America Trip"),
            ("second brain", "Building a Second Brain"),
        ] {
            XCTAssertEqual(router.matches(in: utterance).map(\.target.title), [title])
        }
        for utterance in ["the", "a", "sanfrancisco", "american", "franciscophile"] {
            XCTAssertTrue(router.evaluate(in: utterance).matches.isEmpty, utterance)
            XCTAssertTrue(router.sharedMatches(in: utterance).isEmpty, utterance)
        }
    }

    func testExactTitlesWinAndShortOrFillerTitlesRemainSpeakable() {
        let router = router(["America", "America Trip", "AI", "Go", "The"])
        for title in ["America", "America Trip", "AI", "Go", "The"] {
            XCTAssertEqual(router.matches(in: title).map(\.target.title), [title])
            XCTAssertTrue(router.sharedMatches(in: title).isEmpty)
        }
    }

    func testSharedFragmentsHaveEveryOwnerAndPreferLongestOccurrence() {
        let titles = ["San Francisco Trip", "San Francisco Notes", "San Francisco Photos"]
        for orderedTitles in [titles, titles.reversed()] {
            let router = router(Array(orderedTitles))
            XCTAssertTrue(router.matches(in: "san francisco").isEmpty)
            let groups = router.sharedMatches(in: "san francisco")
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(Set(groups.flatMap(\.candidates).map(\.target.title)), Set(titles))
            XCTAssertEqual(groups.first?.pattern.displayPhrase, "san francisco")
        }
    }

    func testSharedSingleWordAndDuplicateFullTitlesNeverChooseAnArbitraryWinner() {
        for titles in [["America Trip", "America Notes"], ["America", "America"]] {
            let router = router(titles)
            XCTAssertTrue(router.matches(in: "america").isEmpty)
            XCTAssertEqual(router.sharedMatches(in: "america").flatMap(\.candidates).count, 2)
        }
    }

    func testAuthoredAliasWinsOverAFragment() {
        let targets = [
            MatchTarget(phrase: "America Trip", ref: .node("trip"), title: "America Trip"),
            MatchTarget(phrase: "Research", ref: .node("research"), title: "Research"),
            MatchTarget(phrase: "america", ref: .node("research"), title: "Research"),
        ]
        let router = VoiceRoutingRuntimeRouter(baseTargets: targets, pack: nil)
        XCTAssertEqual(router.matches(in: "america").map(\.target.title), ["Research"])
    }

    func testLongerTitleFragmentExcludesOwnersOfOnlyItsShorterWord() {
        let router = router(["San Francisco Trip", "San Mateo Notes"])
        XCTAssertEqual(router.matches(in: "san francisco").map(\.target.title), ["San Francisco Trip"])
        XCTAssertTrue(router.sharedMatches(in: "san francisco").isEmpty)
    }

    func testLensDecisionsRecordExactTitlePriorityOverFragments() throws {
        let baseline = VoiceRoutingBaseline(targets: targets(["America", "America Trip"]))
        let fragment = try XCTUnwrap(baseline.decisions.first {
            $0.nodeID == "1" && $0.trigger.pattern == .phrase("america")
        })
        XCTAssertFalse(fragment.isActive)
        XCTAssertEqual(fragment.ownerNodeIDs, ["0"])
    }

    func testModelNegativeCannotVetoTitleButStillBlocksSemanticProposal() {
        let card = VoiceRoutingCard(
            nodeID: "0", title: "America Trip", evidenceHash: "synthetic",
            canonicalPhrases: ["America Trip"], semanticAliases: [], topicTags: [],
            artifactTypes: [], representativeUtterances: [], hardNegatives: ["america", "wrong"],
            confusableConcepts: [],
            activeTriggers: [.init(pattern: .phrase("holiday"), origin: .semanticAlias, score: 0.94)]
        )
        let pack = VoiceRoutingPack(graphRevision: "test", compilerVersion: "test", modelVersion: "test", generatedAt: .distantPast, cards: [card])
        let router = VoiceRoutingRuntimeRouter(baseTargets: targets(["America Trip"]), pack: pack)
        XCTAssertEqual(router.matches(in: "america").map(\.target.title), ["America Trip"])
        XCTAssertEqual(router.validate(utterance: "america trip", expectedNodeID: "0").outcome, .accepted)
        XCTAssertTrue(router.matches(in: "wrong holiday").isEmpty)
    }

    func testBaseTargetBuilderPreservesAllOwners() {
        let nodes = ["first", "second"].map {
            GraphNode(id: $0, name: "America", role: .context, activationEligible: true, importance: 1, referenceID: $0)
        }
        XCTAssertEqual(VoiceRoutingBaseTargetBuilder().build(nodes: nodes).count, 2)
    }

    func testReplacementAndCumulativeFragmentsAccumulateThreePeeksWithoutRetraction() {
        for texts in [["san francisco", "second brain", "local model"],
                      ["san francisco", "san francisco second brain", "san francisco second brain local model"]] {
            var router = VoiceRoutingStreamRouter(baseTargets: [], pack: nil)
            router.replace(baseTargets: targets(["San Francisco Trip", "Building a Second Brain", "No Local Model Required"]), pack: nil)
            var visible = Set<String>()
            let utteranceID = UUID()
            for (index, text) in texts.enumerated() {
                let update = router.process(.init(text: text, isFinal: false, utteranceID: utteranceID), visibleNodeIDs: visible)
                visible.formUnion(update.matches.compactMap { if case .node(let id) = $0.target.ref { id } else { nil } })
                XCTAssertEqual(visible.count, index + 1)
                XCTAssertTrue(update.retractedNodeIDs.isEmpty)
                XCTAssertTrue(update.retractedConceptIDs.isEmpty)
            }
        }
    }

    private func targets(_ titles: [String]) -> [MatchTarget] {
        titles.enumerated().map { .init(phrase: $0.element, ref: .node(String($0.offset)), title: $0.element) }
    }

    private func router(_ titles: [String]) -> VoiceRoutingRuntimeRouter {
        .init(baseTargets: targets(titles), pack: nil)
    }
}
