import XCTest
import EmbersCore
import EmbersLocal
import EmbersPluginHost
@testable import embers

final class SemanticVoiceMatcherEvalTests: XCTestCase {
    struct Case {
        let utterance: String
        let expected: String?
        let expectedSharedCandidate: String?

        init(utterance: String, expected: String?, expectedSharedCandidate: String? = nil) {
            self.utterance = utterance
            self.expected = expected
            self.expectedSharedCandidate = expectedSharedCandidate
        }
    }

    func testListConfiguredCandidates() async throws {
        guard ProcessInfo.processInfo.environment["EMBERS_RUN_VOICE_EVAL"] == "1" else {
            throw XCTSkip("Set EMBERS_RUN_VOICE_EVAL=1 to inspect the configured local snapshot.")
        }
        let snapshot = try await configuredWorkspaceSnapshot()
        let graph = DeterministicContextGraphProjector().project(snapshot)
        for node in graph.voiceNodes {
            print("VOICE_CANDIDATE name=\(node.name) aliases=\(node.aliases.joined(separator: " | ")) role=\(node.role.rawValue) importance=\(node.importance)")
        }
    }

    func testConfiguredNamesOnlyProductionRouter() async throws {
        guard ProcessInfo.processInfo.environment["EMBERS_RUN_VOICE_EVAL"] == "1" else {
            throw XCTSkip("Set EMBERS_RUN_VOICE_EVAL=1 to run against the configured local snapshot.")
        }

        let snapshot = try await configuredWorkspaceSnapshot()
        let graph = DeterministicContextGraphProjector().project(snapshot)
        let targets = productionTargets(graph: graph, snapshot: snapshot)

        let cases = [
            Case(utterance: "Open Building a Second Brain", expected: "Building a Second Brain"),
            Case(utterance: "Come on man", expected: nil),
            Case(utterance: "What do I have to talk about to get something to show up", expected: nil),
        ]

        var failures: [String] = []
        for item in cases {
            var router = VoiceRoutingStreamRouter(baseTargets: targets, pack: nil)
            let result = router.process(.init(text: item.utterance, isFinal: true)).first?.target.title
            let passed = result == item.expected
            print("VOICE_NAMES_ONLY_EVAL \(passed ? "PASS" : "FAIL") expected=\(item.expected ?? "nil") actual=\(result ?? "nil") utterance=\(item.utterance)")
            if !passed { failures.append("\(item.utterance): expected \(item.expected ?? "nil"), got \(result ?? "nil")") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testConfiguredCompiledVoiceRouter() async throws {
        guard ProcessInfo.processInfo.environment["EMBERS_RUN_VOICE_EVAL"] == "1" else {
            throw XCTSkip("Set EMBERS_RUN_VOICE_EVAL=1 to run the compiled router against the configured local snapshot.")
        }
        let snapshot = try await configuredWorkspaceSnapshot()
        let graph = DeterministicContextGraphProjector().project(snapshot)
        let targets = productionTargets(graph: graph, snapshot: snapshot)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceRoutingStore(fileURL: directory.appendingPathComponent("voice-routing.json"))
        let compiler = VoiceRoutingCompiler(store: store)
        guard compiler.isAvailable else { throw XCTSkip("Apple on-device content-tagging model is unavailable.") }
        let seeds = VoiceRoutingSeedBuilder().build(graph: graph, snapshot: snapshot)
        let outcome = await compiler.compile(seeds: seeds, graphRevision: graph.revision)
        let pack = try XCTUnwrap(outcome.pack, outcome.failure ?? "Compiled pack did not pass its quality gate")
        XCTAssertGreaterThanOrEqual(Double(pack.cards.count) / Double(max(seeds.count, 1)), 0.80)

        if let secondBrainCard = pack.cards.first(where: { $0.title == "Building a Second Brain" }) {
            let active = secondBrainCard.activeTriggers.map(\.pattern.displayPhrase).joined(separator: " | ")
            let rejected = secondBrainCard.rejectedTriggers.map { "\($0.phrase) [\($0.reason.rawValue)]" }.joined(separator: " | ")
            print("COMPILED_VOICE_CARD title=\(secondBrainCard.title) active=\(active) rejected=\(rejected)")
        }

        let cases = [
            Case(utterance: "I need to write in my diary", expected: "Journal"),
            Case(utterance: "Second brain", expected: "Building a Second Brain"),
            Case(utterance: "Yeah and then I'll add that to my second brain knowledge library", expected: "Building a Second Brain"),
            Case(
                utterance: "I keep that in my knowledge system",
                expected: nil,
                expectedSharedCandidate: "Building a Second Brain"
            ),
            Case(
                utterance: "Put that in my knowledge management system",
                expected: nil,
                expectedSharedCandidate: "Building a Second Brain"
            ),
            Case(utterance: "let's be progressive about the summarization", expected: "Progressive Summarization"),
            Case(utterance: "add it to the progressive summarizing project", expected: "Progressive Summarization"),
            Case(utterance: "skip the links", expected: nil),
            Case(utterance: "show me the project templates", expected: "_Templates"),
            Case(utterance: "I need to write in my planner", expected: nil),
            Case(utterance: "Come on man", expected: nil),
            Case(utterance: "What should I talk about to trigger something", expected: nil),
            Case(utterance: "I should write something", expected: nil),
            Case(utterance: "Show me my notes", expected: nil),
        ]
        let passes = Int(ProcessInfo.processInfo.environment["EMBERS_VOICE_EVAL_PASSES"] ?? "1") ?? 1
        var failures: [String] = []
        for pass in 1...passes {
            for item in cases {
                var router = VoiceRoutingStreamRouter(baseTargets: targets, pack: pack)
                let update = router.process(.init(text: item.utterance, isFinal: true))
                let result = update.first?.target.title
                let sharedCandidates = update.sharedConcepts.flatMap { $0.candidates.map(\.target.title) }
                let passed: Bool
                let expectedDescription: String
                if let expectedSharedCandidate = item.expectedSharedCandidate {
                    passed = result == nil && sharedCandidates.contains(expectedSharedCandidate)
                    expectedDescription = "shared candidate \(expectedSharedCandidate)"
                } else {
                    passed = result == item.expected && sharedCandidates.isEmpty
                    expectedDescription = item.expected ?? "nil"
                }
                let actualDescription = [result].compactMap { $0 }.joined(separator: ", ")
                    + (sharedCandidates.isEmpty ? "" : " shared=[\(sharedCandidates.joined(separator: ", "))]")
                print("COMPILED_VOICE_EVAL \(passed ? "PASS" : "FAIL") pass=\(pass) expected=\(expectedDescription) actual=\(actualDescription.isEmpty ? "nil" : actualDescription) utterance=\(item.utterance)")
                if !passed {
                    failures.append("pass \(pass), \(item.utterance): expected \(expectedDescription), got \(actualDescription.isEmpty ? "nil" : actualDescription)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func productionTargets(graph: ContextGraph, snapshot: ContextSnapshot) -> [MatchTarget] {
        let addressableNodes = VoiceRoutingAddressabilityPolicy().nodes(in: graph, snapshot: snapshot)
        return VoiceRoutingBaseTargetBuilder().build(nodes: addressableNodes)
    }

    private func configuredWorkspaceSnapshot() async throws -> ContextSnapshot {
        let entries = await JSONPluginSnapshotRepository.applicationSupport().loadAllValid()
        return try XCTUnwrap(
            try PluginHost.compose(entries.map { ($0.0, $0.1) }),
            "No valid configured source snapshots were found in Embers Application Support."
        )
    }
}
