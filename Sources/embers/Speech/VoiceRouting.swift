import Foundation
import Combine
import EmbersCore
import EmbersLocal

struct VoiceRoutingFeatures: Equatable, Sendable {
    var utterance: String
    var subject: String
    var categoryLabels: [String]
    var artifactType: String
    var isSpecific: Bool
    var hasConcreteSubject: Bool
}

enum VoiceRoutingTriggerOrigin: String, Codable, Equatable, Sendable {
    case canonicalName
    case existingAlias
    case titleFragment
    case shortenedCanonical
    case semanticAlias
    case topicTag
    case artifactType
    case consensusArtifactVocabulary
    case representativeUtterance
    case phraseFamily
    case hardNegative
    case confuser
}

enum VoiceRoutingTriggerPattern: Codable, Equatable, Sendable {
    case phrase(String)
    case orderedTerms([String], maximumGap: Int)

    private enum CodingKeys: String, CodingKey { case kind, phrase, terms, maximumGap }
    private enum Kind: String, Codable { case phrase, orderedTerms }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .phrase:
            self = .phrase(try container.decode(String.self, forKey: .phrase))
        case .orderedTerms:
            self = .orderedTerms(
                try container.decode([String].self, forKey: .terms),
                maximumGap: try container.decode(Int.self, forKey: .maximumGap)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .phrase(let phrase):
            try container.encode(Kind.phrase, forKey: .kind)
            try container.encode(phrase, forKey: .phrase)
        case .orderedTerms(let terms, let maximumGap):
            try container.encode(Kind.orderedTerms, forKey: .kind)
            try container.encode(terms, forKey: .terms)
            try container.encode(maximumGap, forKey: .maximumGap)
        }
    }

    var displayPhrase: String {
        switch self {
        case .phrase(let phrase): phrase
        case .orderedTerms(let terms, _): terms.joined(separator: " … ")
        }
    }
}

struct VoiceRoutingTrigger: Codable, Equatable, Sendable {
    var pattern: VoiceRoutingTriggerPattern
    var origin: VoiceRoutingTriggerOrigin
    /// A deterministic, compiler-validated strength in the normalized 0...1 score space.
    var score: Double
}

enum VoiceRoutingRejectionReason: String, Codable, Equatable, Sendable {
    case generic
    case invalidMetadata
    case collision
    case ambiguous
    case wrongWinner
    case negativeDidNotAbstain
    case contextOnlyEvidence
    case unsupportedEvidence
    case duplicate
}

struct VoiceRoutingRejectedTrigger: Codable, Equatable, Sendable {
    var phrase: String
    var origin: VoiceRoutingTriggerOrigin
    var reason: VoiceRoutingRejectionReason
}

struct VoiceRoutingProposalProvenance: Codable, Equatable, Sendable {
    /// Exactly one entry per deterministic lexical proposal pass. Failed
    /// passes remain as empty arrays so consensus remains auditable.
    var lexicalAlternativePasses: [[String]] = []
}

struct VoiceRoutingConceptCandidateEdge: Codable, Equatable, Sendable {
    var nodeID: String
    /// The compiler-validated strength of this node's evidence for the concept.
    var compiledStrength: Double
    var origin: VoiceRoutingTriggerOrigin
    /// Identifies the direct evidence used to compile this edge without persisting source text.
    var evidenceHash: String

    var hasPositiveOrigin: Bool {
        switch origin {
        case .hardNegative, .confuser: false
        default: true
        }
    }
}

struct VoiceRoutingSharedConcept: Codable, Equatable, Sendable {
    var id: String
    var pattern: VoiceRoutingTriggerPattern
    var candidates: [VoiceRoutingConceptCandidateEdge]

    static func stableID(for pattern: VoiceRoutingTriggerPattern) -> String {
        let material: String = switch pattern {
        case .phrase(let phrase):
            "phrase\u{1f}\(PhraseMatcher.normalize(phrase))"
        case .orderedTerms(let terms, let maximumGap):
            "ordered\u{1f}\(terms.map(PhraseMatcher.normalize).joined(separator: "\u{1e}"))\u{1f}\(maximumGap)"
        }
        return "concept-\(StableHash.hex(material))"
    }

    var hasValidPattern: Bool {
        switch pattern {
        case .phrase(let phrase):
            !PhraseMatcher.normalize(phrase).isEmpty
        case .orderedTerms(let terms, let maximumGap):
            maximumGap >= 0
                && !terms.isEmpty
                && terms.allSatisfy { !PhraseMatcher.normalize($0).isEmpty }
        }
    }
}

struct VoiceMatchSuppression: Sendable {
    private(set) var matchedNodeIDs: Set<String> = []

    /// Suppress a node only while its trigger is still present in the running transcript. This
    /// lets one partial surface several different contexts and naturally unlocks a node when
    /// Apple's recognizer resets or rewrites the transcript between spoken thoughts.
    mutating func newMatches(
        from matches: [MatchTarget],
        alsoSuppressing visibleNodeIDs: Set<String> = []
    ) -> [MatchTarget] {
        let currentNodeIDs = Set(matches.compactMap(nodeID))
        matchedNodeIDs.formIntersection(currentNodeIDs)
        var unique = Set<String>()
        return matches.filter { target in
            guard let id = nodeID(target), unique.insert(id).inserted else { return false }
            return !matchedNodeIDs.contains(id) && !visibleNodeIDs.contains(id)
        }
    }

    mutating func markPresented(_ targets: [MatchTarget]) {
        matchedNodeIDs.formUnion(targets.compactMap(nodeID))
    }

    mutating func reset() { matchedNodeIDs.removeAll() }

    private func nodeID(_ target: MatchTarget) -> String? {
        guard case .node(let id) = target.ref else { return nil }
        return id
    }
}

struct VoiceRoutingExactTargetBuilder: Sendable {
    func augment(_ baseTargets: [MatchTarget], with pack: VoiceRoutingPack?) -> [MatchTarget] {
        guard let pack else { return baseTargets }
        var result = baseTargets
        var claimed = Set(baseTargets.map { PhraseMatcher.normalize($0.phrase) })
        var targetsByNode: [String: MatchTarget] = [:]
        for target in baseTargets {
            guard case .node(let id) = target.ref, targetsByNode[id] == nil else { continue }
            targetsByNode[id] = target
        }
        let tagOwners = Dictionary(grouping: pack.cards.flatMap { card in
            card.topicTags.map { (PhraseMatcher.normalize($0), card.nodeID) }
        }, by: \.0).mapValues { Set($0.map(\.1)) }
        let scorer = VoiceRoutingScorer()
        for card in pack.cards {
            guard let base = targetsByNode[card.nodeID] else { continue }
            let uniqueTags = card.topicTags.filter { tag in
                let normalized = PhraseMatcher.normalize(tag)
                guard normalized.split(separator: " ").count >= 2,
                      tagOwners[normalized]?.count == 1 else { return false }
                let features = VoiceRoutingFeatures(
                    utterance: tag,
                    subject: tag,
                    categoryLabels: [tag],
                    artifactType: "none",
                    isSpecific: true,
                    hasConcreteSubject: true
                )
                return scorer.decide(features: features, pack: pack)?.nodeID == card.nodeID
            }
            for alias in card.semanticAliases + uniqueTags {
                let normalized = PhraseMatcher.normalize(alias)
                guard !normalized.isEmpty, claimed.insert(normalized).inserted else { continue }
                result.append(.init(phrase: alias, ref: base.ref, title: base.title))
            }
        }
        return result
    }
}

struct VoiceRoutingBaseTargetBuilder: Sendable {
    func build(nodes: [GraphNode]) -> [MatchTarget] {
        var claimed: [String: Set<String>] = [:]
        var targets: [MatchTarget] = []
        for node in nodes where claimed[node.id, default: []].insert(PhraseMatcher.normalize(node.name)).inserted {
            targets.append(.init(phrase: node.name, ref: .node(node.id), title: node.name))
        }
        for node in nodes {
            for alias in node.aliases where claimed[node.id, default: []].insert(PhraseMatcher.normalize(alias)).inserted {
                targets.append(.init(phrase: alias, ref: .node(node.id), title: node.name))
            }
        }
        return targets
    }
}

struct VoiceRoutingCompilationProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case generatingNotes
        case validatingPhraseChecks
    }

    let stage: Stage
    let completed: Int
    let total: Int

    var overallFraction: Double {
        let generationWeight = 0.9
        switch stage {
        case .generatingNotes:
            return stageFraction * generationWeight
        case .validatingPhraseChecks:
            return generationWeight + stageFraction * (1 - generationWeight)
        }
    }

    var percentageLabel: String {
        "\(Int((overallFraction * 100).rounded()))%"
    }

    private var stageFraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

enum ContextProgressCompletionTiming {
    static let sweepDuration: TimeInterval = 0.22
    static let statusHoldDuration: TimeInterval = 0.28

    static func sweepDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : sweepDuration
    }
}

@MainActor
final class VoiceRoutingStatus: ObservableObject {
    enum State: Equatable {
        case waitingForContext
        case checking
        case building(progress: VoiceRoutingCompilationProgress)
        case ready(contextCount: Int, phraseCount: Int, recallWarningCount: Int)
        case namesOnly(reason: String)

        var label: String {
            switch self {
            case .waitingForContext: "WAITING"
            case .checking: "CHECKING"
            case .building: "BUILDING"
            case .ready: "READY"
            case .namesOnly: "EXACT NAMES READY"
            }
        }

        var detail: String {
            switch self {
            case .waitingForContext: "Choose a context source first"
            case .checking: "Checking the local compiled vocabulary"
            case .building(let progress):
                switch progress.stage {
                case .generatingNotes: "Learning grounded phrases for your notes on this Mac"
                case .validatingPhraseChecks: "Checking generated phrases on this Mac"
                }
            case .ready(let contextCount, let phraseCount, let recallWarningCount):
                if recallWarningCount == 0 {
                    "\(phraseCount) phrases across \(contextCount) contexts"
                } else {
                    "\(phraseCount) phrases across \(contextCount) contexts · \(recallWarningCount) recall check\(recallWarningCount == 1 ? "" : "s") missed"
                }
            case .namesOnly(let reason): reason
            }
        }

        var contextLensActivityLabel: String? {
            switch self {
            case .checking, .building: "Preparing your notes:"
            default: nil
            }
        }

        var compilationProgress: VoiceRoutingCompilationProgress? {
            guard case .building(let progress) = self else { return nil }
            return progress
        }

        var isWorking: Bool {
            switch self {
            case .checking, .building: true
            default: false
            }
        }

        var shouldPresentInSettings: Bool {
            isWorking || isFallback
        }

        var isFallback: Bool {
            if case .namesOnly = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .waitingForContext

    func set(_ state: State) { self.state = state }

    func update(_ progress: VoiceRoutingCompilationProgress) {
        guard state.isWorking else { return }
        if case .building(let current) = state {
            switch (current.stage, progress.stage) {
            case (.validatingPhraseChecks, .generatingNotes):
                return
            case let (currentStage, nextStage) where currentStage == nextStage:
                guard progress.completed >= current.completed else { return }
            default:
                break
            }
        }
        state = .building(progress: progress)
    }

    func completeBuildingProgress() {
        guard state.isWorking else { return }
        state = .building(progress: .init(
            stage: .validatingPhraseChecks,
            completed: 1,
            total: 1
        ))
    }
}

struct VoiceRoutingCard: Codable, Equatable, Sendable {
    var nodeID: String
    var title: String
    var evidenceHash: String
    var canonicalPhrases: [String]
    var semanticAliases: [String]
    var topicTags: [String]
    var artifactTypes: [String]
    var representativeUtterances: [String]
    var hardNegatives: [String]
    var confusableConcepts: [String]
    /// The only compiler-generated material executable by the production hot path.
    var activeTriggers: [VoiceRoutingTrigger] = []
    /// Grounded card material retained for inspection, but never interpreted as a trigger.
    var descriptiveVocabulary: [String] = []
    var rejectedTriggers: [VoiceRoutingRejectedTrigger] = []
    var proposalProvenance: VoiceRoutingProposalProvenance = .init()
}

struct VoiceRoutingPack: Codable, Equatable, Sendable {
    static let schemaVersion = 5

    var schemaVersion: Int = Self.schemaVersion
    var graphRevision: String
    var inputRevision: String = ""
    var compilerVersion: String
    var modelVersion: String
    var generatedAt: Date
    var cards: [VoiceRoutingCard]
    var sharedConcepts: [VoiceRoutingSharedConcept] = []

    func card(nodeID: String) -> VoiceRoutingCard? { cards.first { $0.nodeID == nodeID } }

    var isStructurallyValid: Bool {
        let nodeIDs = Set(cards.map(\.nodeID))
        guard nodeIDs.count == cards.count else { return false }
        let evidenceHashByNodeID = Dictionary(uniqueKeysWithValues: cards.map { ($0.nodeID, $0.evidenceHash) })
        return cards.allSatisfy { card in
                !card.nodeID.isEmpty
                    && !card.title.isEmpty
                    && card.activeTriggers.allSatisfy { $0.score.isFinite && (0...1).contains($0.score) }
            }
            && Set(sharedConcepts.map(\.id)).count == sharedConcepts.count
            && sharedConcepts.allSatisfy { concept in
                concept.hasValidPattern
                    && concept.id == VoiceRoutingSharedConcept.stableID(for: concept.pattern)
                    && Set(concept.candidates.map(\.nodeID)).count == concept.candidates.count
                    && concept.candidates.count >= 2
                    && concept.candidates.allSatisfy { edge in
                        nodeIDs.contains(edge.nodeID)
                            && !edge.evidenceHash.isEmpty
                            && evidenceHashByNodeID[edge.nodeID] == edge.evidenceHash
                            && edge.hasPositiveOrigin
                            && edge.compiledStrength.isFinite
                            && (VoiceRoutingScorer.minimumScore...1).contains(edge.compiledStrength)
                    }
            }
    }
}

struct VoiceRoutingDecision: Equatable, Sendable {
    var nodeID: String
    var title: String
    var score: Double
    var runnerUpScore: Double
}

struct VoiceRoutingSharedConceptValidator: Sendable {
    func validate(
        candidate edge: VoiceRoutingConceptCandidateEdge,
        concept: VoiceRoutingSharedConcept,
        pack: VoiceRoutingPack
    ) -> VoiceRoutingTriggerValidation {
        let candidateNodeIDs = Set(concept.candidates.map(\.nodeID))
        guard candidateNodeIDs.contains(edge.nodeID),
              edge.hasPositiveOrigin,
              edge.compiledStrength >= VoiceRoutingScorer.minimumScore,
              let ownerIndex = pack.cards.firstIndex(where: {
                  $0.nodeID == edge.nodeID && $0.evidenceHash == edge.evidenceHash
              }) else {
            return .init(outcome: .abstained, match: nil)
        }

        var isolated = pack
        isolated.sharedConcepts.removeAll { $0.id == concept.id }
        for index in isolated.cards.indices where candidateNodeIDs.contains(isolated.cards[index].nodeID) {
            isolated.cards[index].activeTriggers.removeAll()
        }
        isolated.cards[ownerIndex].activeTriggers.append(.init(
            pattern: concept.pattern,
            origin: edge.origin,
            score: edge.compiledStrength
        ))
        let baseTargets = isolated.cards.flatMap { card -> [MatchTarget] in
            guard card.nodeID == edge.nodeID || !candidateNodeIDs.contains(card.nodeID) else { return [] }
            return card.canonicalPhrases.map {
                MatchTarget(phrase: $0, ref: .node(card.nodeID), title: card.title)
            }
        }
        let utterance: String = switch concept.pattern {
        case .phrase(let phrase): phrase
        case .orderedTerms(let terms, _): terms.joined(separator: " about ")
        }
        return VoiceRoutingRuntimeRouter(baseTargets: baseTargets, pack: isolated).validate(
            utterance: utterance,
            expectedNodeID: edge.nodeID
        )
    }
}

struct VoiceRoutingRuntimeMatch: Equatable {
    var target: MatchTarget
    var trigger: VoiceRoutingTrigger
    var score: Double
    var runnerUpScore: Double
}

struct VoiceRoutingRuntimeEvidenceCandidate: Equatable {
    var match: VoiceRoutingRuntimeMatch
    var matchedSpan: Range<Int>
    var originatingSpan: Range<Int>

    var hasExactOriginSpan: Bool { matchedSpan == originatingSpan }
}

/// A compiler-declared semantic concept with several honest destinations. This is deliberately
/// not a winner: even one surviving candidate remains a shared-concept presentation so suffix
/// blockers can narrow choices without silently turning semantics into navigation.
struct VoiceRoutingSharedConceptMatch: Equatable {
    var conceptID: String
    var pattern: VoiceRoutingTriggerPattern
    var candidates: [VoiceRoutingRuntimeMatch]
    /// Number of distinct occurrences of this concept in the normalized running transcript.
    /// The streaming shell uses this to distinguish a repeated mention from another partial
    /// that still contains the original words.
    var occurrenceCount: Int = 1

    var candidateNodeIDs: Set<String> {
        Set(candidates.compactMap { match in
            guard case .node(let nodeID) = match.target.ref else { return nil }
            return nodeID
        })
    }

    var orderedCandidateNodeIDs: [String] {
        candidates.compactMap { match in
            guard case .node(let nodeID) = match.target.ref else { return nil }
            return nodeID
        }
    }
}

enum VoiceRoutingTriggerValidationOutcome: Equatable, Sendable {
    case accepted
    case abstained
    case ambiguous
    case wrongWinner
    case blockedByNegative
}

struct VoiceRoutingTriggerValidation: Equatable {
    var outcome: VoiceRoutingTriggerValidationOutcome
    var match: VoiceRoutingRuntimeMatch?
}

/// Pure deterministic execution of an immutable routing pack. The compiler may propose rich
/// material, but only `activeTriggers` and validated `sharedConcepts` reach this hot path.
struct VoiceRoutingRuntimeRouter {
    private struct Rule {
        var target: MatchTarget
        var trigger: VoiceRoutingTrigger
    }

    private struct Candidate {
        var rule: Rule
        var span: Range<Int>
        var score: Double
    }

    private struct SharedOccurrenceKey: Hashable {
        var lowerBound: Int
        var upperBound: Int
        var normalizedTerms: [String]
    }

    private struct SharedOccurrence {
        var span: Range<Int>
        var match: VoiceRoutingSharedConceptMatch
    }

    /// Node IDs are globally unique in the composed graph. Source identity is
    /// retained in storage for scoped deletion, then omitted from this hot-path
    /// lookup so every transcript check remains constant-time.
    private struct ExcludedRouteIdentity: Hashable {
        var nodeID: String
        var normalizedTerms: [String]
    }

    struct Evaluation {
        var matches: [VoiceRoutingRuntimeMatch]
        var sharedConcepts: [VoiceRoutingSharedConceptMatch]
        var blockedMatchedNodeIDs: Set<String>
        var positivelyMatchedNodeIDs: Set<String>
    }

    private let rules: [Rule]
    private let blockingPhrasesByNodeID: [String: [String]]
    private let sharedConcepts: [VoiceRoutingSharedConcept]
    private let targetsByNodeID: [String: MatchTarget]
    private let preferenceBoosts: [VoiceRoutingPreferenceKey: Double]
    private let excludedRoutes: Set<ExcludedRouteIdentity>

    init(
        baseTargets: [MatchTarget],
        pack: VoiceRoutingPack?,
        preferenceBoosts: [VoiceRoutingPreferenceKey: Double] = [:],
        excludedRouteKeys: Set<VoiceRouteExclusionKey> = []
    ) {
        let baseline = VoiceRoutingBaseline(targets: baseTargets)
        var rules = baseline.rules.map { Rule(target: $0.target, trigger: $0.trigger) }
        var targetByNodeID: [String: MatchTarget] = [:]
        for target in baseTargets {
            guard case .node(let nodeID) = target.ref else { continue }
            targetByNodeID[nodeID, default: target] = target
        }

        if let pack {
            for card in pack.cards {
                let base = targetByNodeID[card.nodeID] ?? MatchTarget(
                    phrase: card.title,
                    ref: .node(card.nodeID),
                    title: card.title
                )
                targetByNodeID[card.nodeID] = base
                for trigger in card.activeTriggers {
                    rules.append(.init(
                        target: .init(phrase: trigger.pattern.displayPhrase, ref: base.ref, title: base.title),
                        trigger: trigger
                    ))
                }
            }
            blockingPhrasesByNodeID = pack.cards.reduce(into: [:]) { result, card in
                result[card.nodeID, default: []].append(contentsOf: card.hardNegatives + card.confusableConcepts)
            }
            let baselineIDs = Set(baseline.sharedConcepts.map(\.id))
            sharedConcepts = baseline.sharedConcepts + pack.sharedConcepts.filter { !baselineIDs.contains($0.id) }
        } else {
            blockingPhrasesByNodeID = [:]
            sharedConcepts = baseline.sharedConcepts
        }
        self.rules = rules
        targetsByNodeID = targetByNodeID
        self.preferenceBoosts = preferenceBoosts
        excludedRoutes = Set(excludedRouteKeys.map {
            ExcludedRouteIdentity(nodeID: $0.nodeID, normalizedTerms: $0.pattern.normalizedTerms)
        })
    }

    var vocabulary: [String] {
        var seen = Set<String>()
        let patterns = rules.map(\.trigger.pattern) + sharedConcepts.map(\.pattern)
        return patterns.compactMap { pattern in
            guard case .phrase(let phrase) = pattern else { return nil }
            let normalized = PhraseMatcher.normalize(phrase)
            return !normalized.isEmpty && seen.insert(normalized).inserted ? phrase : nil
        }
    }

    var triggerCount: Int { rules.count + sharedConcepts.count }

    func matches(in transcript: String) -> [VoiceRoutingRuntimeMatch] {
        evaluate(in: transcript).matches
    }

    func evaluate(in transcript: String) -> Evaluation {
        let evaluated = evaluatedCandidates(in: transcript)
        let shared = sharedConceptMatches(
            in: transcript,
            uniqueMatches: evaluated.qualified,
            blockedNodeIDs: evaluated.blockedNodeIDs
        )
        return .init(
            matches: evaluated.qualified.filter {
                !isMatchContainedBySharedConcept($0, concepts: shared, transcript: transcript)
            },
            sharedConcepts: shared,
            blockedMatchedNodeIDs: evaluated.blockedMatchedNodeIDs,
            positivelyMatchedNodeIDs: evaluated.positivelyMatchedNodeIDs
        )
    }

    func sharedMatches(in transcript: String) -> [VoiceRoutingSharedConceptMatch] {
        evaluate(in: transcript).sharedConcepts
    }

    /// Candidates that independently clear the production score threshold and overlap the
    /// originating trigger before the winning-margin gate. The compiler uses this to preserve
    /// honest ambiguity instead of trusting an ungrounded relationship proposed by a model.
    func evidencedCandidates(
        in transcript: String,
        overlapping originatingPattern: VoiceRoutingTriggerPattern
    ) -> [VoiceRoutingRuntimeEvidenceCandidate] {
        let evaluated = evaluatedCandidates(in: transcript)
        let words = PhraseMatcher.normalize(transcript).split(separator: " ").map(String.init)
        let originatingSpans = matchSpans(for: originatingPattern, in: words)
        guard !originatingSpans.isEmpty else { return [] }
        return evaluated.evidenced.compactMap { match in
            guard case .node(let nodeID) = match.target.ref,
                  let matchedSpan = evaluated.candidateSpansByNodeID[nodeID] else { return nil }
            let overlapping = originatingSpans.filter { $0.overlaps(matchedSpan) }
            guard let originatingSpan = overlapping.sorted(by: { lhs, rhs in
                if (lhs == matchedSpan) != (rhs == matchedSpan) { return lhs == matchedSpan }
                let lhsOverlap = min(lhs.upperBound, matchedSpan.upperBound) - max(lhs.lowerBound, matchedSpan.lowerBound)
                let rhsOverlap = min(rhs.upperBound, matchedSpan.upperBound) - max(rhs.lowerBound, matchedSpan.lowerBound)
                if lhsOverlap != rhsOverlap { return lhsOverlap > rhsOverlap }
                if lhs.count != rhs.count { return lhs.count < rhs.count }
                return lhs.lowerBound < rhs.lowerBound
            }).first else { return nil }
            return .init(match: match, matchedSpan: matchedSpan, originatingSpan: originatingSpan)
        }
    }

    func validate(utterance: String, expectedNodeID: String) -> VoiceRoutingTriggerValidation {
        let evaluation = evaluatedCandidates(in: utterance)
        if evaluation.blockedNodeIDs.contains(expectedNodeID) {
            return .init(outcome: .blockedByNegative, match: nil)
        }
        let matches = evaluation.qualified
        if matches.count == 1, let match = matches.first {
            guard case .node(let nodeID) = match.target.ref else {
                return .init(outcome: .abstained, match: nil)
            }
            return .init(outcome: nodeID == expectedNodeID ? .accepted : .wrongWinner, match: match)
        }
        if matches.count > 1 {
            let expected = matches.first { match in
                guard case .node(let nodeID) = match.target.ref else { return false }
                return nodeID == expectedNodeID
            }
            return .init(outcome: .ambiguous, match: expected ?? matches.first)
        }
        if evaluation.unqualifiedNodeIDs.count > 1 {
            return .init(outcome: .ambiguous, match: nil)
        }
        return .init(outcome: .abstained, match: nil)
    }

    private func evaluatedCandidates(in transcript: String) -> (
        qualified: [VoiceRoutingRuntimeMatch],
        evidenced: [VoiceRoutingRuntimeMatch],
        blockedNodeIDs: Set<String>,
        blockedMatchedNodeIDs: Set<String>,
        positivelyMatchedNodeIDs: Set<String>,
        unqualifiedNodeIDs: Set<String>,
        candidateSpansByNodeID: [String: Range<Int>]
    ) {
        let words = PhraseMatcher.normalize(transcript).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ([], [], [], [], [], [], [:]) }
        var blockedNodeIDs = Set<String>()
        for (nodeID, negatives) in blockingPhrasesByNodeID where negatives.contains(where: {
            matchSpan(for: .phrase($0), in: words) != nil
        }) {
            blockedNodeIDs.insert(nodeID)
        }

        var rawCandidates: [Candidate] = []
        for rule in rules {
            guard case .node(let nodeID) = rule.target.ref else { continue }
            let patternIdentity = rule.trigger.pattern.routePatternIdentity
            guard !excludedRoutes.contains(.init(
                nodeID: nodeID,
                normalizedTerms: patternIdentity.normalizedTerms
            )) else {
                continue
            }
            let score = min(max(rule.trigger.score, 0), 1)
            rawCandidates.append(contentsOf: matchSpans(for: rule.trigger.pattern, in: words).map {
                Candidate(rule: rule, span: $0, score: score)
            })
        }
        let positivelyMatchedNodeIDs = Set(rawCandidates.compactMap { candidate -> String? in
            guard case .node(let nodeID) = candidate.rule.target.ref else { return nil }
            return nodeID
        })
        // A model negative can veto its semantic proposal, never source-authored identity.
        let identityNodeIDs = Set(rawCandidates.compactMap { candidate -> String? in
            guard candidate.rule.trigger.origin.isDeterministicIdentity,
                  case .node(let nodeID) = candidate.rule.target.ref else { return nil }
            return nodeID
        })
        let effectiveBlockedNodeIDs = blockedNodeIDs.subtracting(identityNodeIDs)
        let blockedMatchedNodeIDs = positivelyMatchedNodeIDs.intersection(effectiveBlockedNodeIDs)
        let unblockedOccurrences = rawCandidates.filter { candidate in
            guard case .node(let nodeID) = candidate.rule.target.ref,
                  candidate.rule.trigger.origin.isDeterministicIdentity || !blockedNodeIDs.contains(nodeID) else { return false }
            return true
        }
        let eligibleOccurrences = unblockedOccurrences.filter { candidate in
            !isIdentityDominated(candidate, among: unblockedOccurrences)
        }
        var bestByNodeID: [String: Candidate] = [:]
        for candidate in eligibleOccurrences {
            guard case .node(let nodeID) = candidate.rule.target.ref else { continue }
            if let current = bestByNodeID[nodeID], !isBetter(candidate, than: current) { continue }
            bestByNodeID[nodeID] = candidate
        }

        let candidates = Array(bestByNodeID.values)
        var matches: [VoiceRoutingRuntimeMatch] = []
        var evidenced: [VoiceRoutingRuntimeMatch] = []
        for candidate in candidates {
            let runnerUp = candidates
                .filter { other in
                    guard case .node(let candidateID) = candidate.rule.target.ref,
                          case .node(let otherID) = other.rule.target.ref else { return false }
                    return candidateID != otherID && candidate.span.overlaps(other.span)
                }
                .map(\.score)
                .max() ?? 0
            guard candidate.score >= VoiceRoutingScorer.minimumScore else { continue }
            let match = VoiceRoutingRuntimeMatch(
                target: candidate.rule.target,
                trigger: candidate.rule.trigger,
                score: candidate.score,
                runnerUpScore: runnerUp
            )
            evidenced.append(match)
            if candidate.score - runnerUp >= VoiceRoutingScorer.minimumMargin {
                matches.append(match)
            }
        }
        func ordered(_ lhs: VoiceRoutingRuntimeMatch, _ rhs: VoiceRoutingRuntimeMatch) -> Bool {
            guard let lhsCandidate = candidate(for: lhs, among: candidates),
                  let rhsCandidate = candidate(for: rhs, among: candidates) else {
                return lhs.target.title < rhs.target.title
            }
            if lhsCandidate.span.lowerBound != rhsCandidate.span.lowerBound {
                return lhsCandidate.span.lowerBound < rhsCandidate.span.lowerBound
            }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.target.title < rhs.target.title
        }
        matches.sort(by: ordered)
        evidenced.sort(by: ordered)
        let candidateSpansByNodeID = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate -> (String, Range<Int>)? in
            guard case .node(let nodeID) = candidate.rule.target.ref else { return nil }
            return (nodeID, candidate.span)
        })
        return (matches, evidenced, effectiveBlockedNodeIDs, blockedMatchedNodeIDs, positivelyMatchedNodeIDs, Set(candidates.compactMap { candidate in
            guard case .node(let nodeID) = candidate.rule.target.ref else { return nil }
            return nodeID
        }), candidateSpansByNodeID)
    }

    private func sharedConceptMatches(
        in transcript: String,
        uniqueMatches: [VoiceRoutingRuntimeMatch],
        blockedNodeIDs: Set<String>
    ) -> [VoiceRoutingSharedConceptMatch] {
        let words = PhraseMatcher.normalize(transcript).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var matched: [SharedOccurrence] = []
        for concept in sharedConcepts {
            let candidates = concept.candidates.compactMap { edge -> (
                edge: VoiceRoutingConceptCandidateEdge,
                base: MatchTarget,
                boost: Double
            )? in
                let patternIdentity = concept.pattern.routePatternIdentity
                guard !excludedRoutes.contains(.init(
                    nodeID: edge.nodeID,
                    normalizedTerms: patternIdentity.normalizedTerms
                )),
                      edge.origin.isDeterministicIdentity || !blockedNodeIDs.contains(edge.nodeID),
                      edge.compiledStrength >= VoiceRoutingScorer.minimumScore,
                      let base = targetsByNodeID[edge.nodeID] else { return nil }
                let rawBoost = preferenceBoosts[
                    .init(conceptID: concept.id, nodeID: edge.nodeID),
                    default: 0
                ]
                let boost = rawBoost.isFinite
                    ? min(max(rawBoost, 0), VoiceRoutingPreferenceStore.maximumBoost)
                    : 0
                return (edge, base, boost)
            }
                .sorted {
                    let leftScore = $0.edge.compiledStrength + $0.boost
                    let rightScore = $1.edge.compiledStrength + $1.boost
                    if leftScore != rightScore { return leftScore > rightScore }
                    if $0.edge.compiledStrength != $1.edge.compiledStrength {
                        return $0.edge.compiledStrength > $1.edge.compiledStrength
                    }
                    if $0.base.title != $1.base.title { return $0.base.title < $1.base.title }
                    return $0.edge.nodeID < $1.edge.nodeID
                }
                .prefix(maxPeeks)
                .map { candidate -> VoiceRoutingRuntimeMatch in
                    let edge = candidate.edge
                    let trigger = VoiceRoutingTrigger(
                        pattern: concept.pattern,
                        origin: edge.origin,
                        score: edge.compiledStrength
                    )
                    return .init(
                        target: .init(
                            phrase: concept.pattern.displayPhrase,
                            ref: candidate.base.ref,
                            title: candidate.base.title,
                            conceptID: concept.id
                        ),
                        trigger: trigger,
                        score: edge.compiledStrength,
                        runnerUpScore: 0
                    )
                }
            guard !candidates.isEmpty else { continue }
            for conceptSpan in matchSpans(for: concept.pattern, in: words) where !uniqueIdentityDominates(
                conceptSpan: conceptSpan,
                uniqueMatches: uniqueMatches,
                words: words
            ) {
                matched.append(.init(
                    span: conceptSpan,
                    match: .init(conceptID: concept.id, pattern: concept.pattern, candidates: candidates)
                ))
            }
        }
        var preferredByOccurrence: [SharedOccurrenceKey: SharedOccurrence] = [:]
        for occurrence in matched where !matched.contains(where: { other in
            let authority = occurrence.match.candidates.map { $0.trigger.origin.identityAuthority }.max() ?? 0
            let otherAuthority = other.match.candidates.map { $0.trigger.origin.identityAuthority }.max() ?? 0
            return otherAuthority > 0 && otherAuthority >= authority
                && other.span.count > occurrence.span.count
                && other.span.lowerBound <= occurrence.span.lowerBound
                && other.span.upperBound >= occurrence.span.upperBound
        }) {
            let key = SharedOccurrenceKey(
                lowerBound: occurrence.span.lowerBound,
                upperBound: occurrence.span.upperBound,
                normalizedTerms: normalizedTerms(for: occurrence.match.pattern)
            )
            if let current = preferredByOccurrence[key],
               !isPreferredSharedOccurrence(occurrence, over: current) {
                continue
            }
            preferredByOccurrence[key] = occurrence
        }
        let ordered = preferredByOccurrence.values.sorted {
            if $0.span.lowerBound != $1.span.lowerBound { return $0.span.lowerBound < $1.span.lowerBound }
            if $0.span.upperBound != $1.span.upperBound { return $0.span.upperBound < $1.span.upperBound }
            return $0.match.conceptID < $1.match.conceptID
        }
        var grouped: [String: (firstIndex: Int, match: VoiceRoutingSharedConceptMatch)] = [:]
        for (index, occurrence) in ordered.enumerated() {
            if var existing = grouped[occurrence.match.conceptID] {
                existing.match.occurrenceCount += 1
                grouped[occurrence.match.conceptID] = existing
            } else {
                grouped[occurrence.match.conceptID] = (index, occurrence.match)
            }
        }
        return grouped.values.sorted { $0.firstIndex < $1.firstIndex }.map(\.match)
    }

    private func normalizedTerms(for pattern: VoiceRoutingTriggerPattern) -> [String] {
        switch pattern {
        case .phrase(let phrase):
            PhraseMatcher.normalize(phrase).split(separator: " ").map(String.init)
        case .orderedTerms(let terms, _):
            terms.flatMap { PhraseMatcher.normalize($0).split(separator: " ").map(String.init) }
        }
    }

    private func isPreferredSharedOccurrence(
        _ lhs: SharedOccurrence,
        over rhs: SharedOccurrence
    ) -> Bool {
        switch (lhs.match.pattern, rhs.match.pattern) {
        case (.phrase, .orderedTerms): return true
        case (.orderedTerms, .phrase): return false
        case (.orderedTerms(_, let leftGap), .orderedTerms(_, let rightGap)) where leftGap != rightGap:
            return leftGap < rightGap
        default:
            return lhs.match.conceptID < rhs.match.conceptID
        }
    }

    private func uniqueIdentityDominates(
        conceptSpan: Range<Int>,
        uniqueMatches: [VoiceRoutingRuntimeMatch],
        words: [String]
    ) -> Bool {
        uniqueMatches.contains { match in
            guard identityAuthority(match.trigger.origin) > 0 else { return false }
            return matchSpans(for: match.trigger.pattern, in: words).contains { identitySpan in
                identitySpan.lowerBound <= conceptSpan.lowerBound
                    && identitySpan.upperBound >= conceptSpan.upperBound
            }
        }
    }

    private func isMatchContainedBySharedConcept(
        _ match: VoiceRoutingRuntimeMatch,
        concepts: [VoiceRoutingSharedConceptMatch],
        transcript: String
    ) -> Bool {
        guard case .node(let nodeID) = match.target.ref else { return false }
        let words = PhraseMatcher.normalize(transcript).split(separator: " ").map(String.init)
        let identitySpans = matchSpans(for: match.trigger.pattern, in: words)
        guard !identitySpans.isEmpty else { return false }
        return identitySpans.allSatisfy { matchSpan in
            concepts.contains { concept in
                let isIdentity = identityAuthority(match.trigger.origin) > 0
                guard isIdentity || concept.candidateNodeIDs.contains(nodeID) else { return false }
                return matchSpans(for: concept.pattern, in: words).contains { conceptSpan in
                    conceptSpan.count >= matchSpan.count
                        && conceptSpan.lowerBound <= matchSpan.lowerBound
                        && conceptSpan.upperBound >= matchSpan.upperBound
                }
            }
        }
    }

    private func candidate(for match: VoiceRoutingRuntimeMatch, among candidates: [Candidate]) -> Candidate? {
        guard case .node(let nodeID) = match.target.ref else { return nil }
        return candidates.first {
            guard case .node(let candidateID) = $0.rule.target.ref else { return false }
            return candidateID == nodeID
        }
    }

    private func isBetter(_ lhs: Candidate, than rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.span.count != rhs.span.count { return lhs.span.count > rhs.span.count }
        return lhs.rule.trigger.pattern.displayPhrase.count > rhs.rule.trigger.pattern.displayPhrase.count
    }

    private func isIdentityDominated(_ candidate: Candidate, among candidates: [Candidate]) -> Bool {
        guard case .node(let nodeID) = candidate.rule.target.ref else { return false }
        let candidateAuthority = identityAuthority(candidate.rule.trigger.origin)
        return candidates.contains { other in
            let otherAuthority = identityAuthority(other.rule.trigger.origin)
            guard otherAuthority > 0,
                  case .node(let otherNodeID) = other.rule.target.ref,
                  otherNodeID != nodeID else { return false }
            let strongerIdentityOwnsEqualSpan = other.span.count == candidate.span.count
                && otherAuthority > candidateAuthority
            let equalOrStrongerIdentityOwnsLargerSpan = other.span.count > candidate.span.count
                && otherAuthority >= candidateAuthority
            guard strongerIdentityOwnsEqualSpan || equalOrStrongerIdentityOwnsLargerSpan else {
                return false
            }
            return other.span.lowerBound <= candidate.span.lowerBound
                && other.span.upperBound >= candidate.span.upperBound
        }
    }

    private func identityAuthority(_ origin: VoiceRoutingTriggerOrigin) -> Int {
        origin.identityAuthority
    }
}

/// Stateful streaming shell used by AppState. It runs synchronously for every changed partial
/// transcript, suppressing presented unique nodes and stable shared-concept IDs independently.
struct VoiceRoutingStreamUpdate: RandomAccessCollection, Equatable {
    typealias Index = Int
    var matches: [VoiceRoutingRuntimeMatch]
    /// New or candidate-changed shared groups. Repeated unchanged concept IDs are suppressed.
    var sharedConcepts: [VoiceRoutingSharedConceptMatch]
    var retractedNodeIDs: Set<String>
    /// Remove only peeks attributed to these concepts; unique peeks and other groups survive.
    var retractedConceptIDs: Set<String>

    var startIndex: Int { matches.startIndex }
    var endIndex: Int { matches.endIndex }
    subscript(position: Int) -> VoiceRoutingRuntimeMatch { matches[position] }
    var isEmpty: Bool {
        matches.isEmpty
            && sharedConcepts.isEmpty
            && retractedNodeIDs.isEmpty
            && retractedConceptIDs.isEmpty
    }
}

struct VoiceRoutingStreamRouter {
    private var runtime: VoiceRoutingRuntimeRouter
    private var baseTargets: [MatchTarget]
    private var pack: VoiceRoutingPack?
    private var preferenceBoosts: [VoiceRoutingPreferenceKey: Double]
    private var learning: VoiceLearningSnapshot
    private var suppression = VoiceMatchSuppression()
    private var lastUtteranceID: UUID?
    private var presentedNodeIDs = Set<String>()
    private var presentedConceptCandidatesByID: [String: [String]] = [:]
    /// How many occurrences from the current recognizer transcript have already been consumed
    /// for each concept. Counts, rather than a session-wide seen bit, let a later repetition
    /// surface without replaying the original occurrence when an old cumulative transcript grows.
    private var acknowledgedConceptOccurrenceCountsByID: [String: Int] = [:]

    init(
        baseTargets: [MatchTarget],
        pack: VoiceRoutingPack?,
        preferences: VoiceRoutingPreferenceSnapshot = .empty,
        learning: VoiceLearningSnapshot = .empty
    ) {
        self.baseTargets = baseTargets
        self.pack = pack
        preferenceBoosts = preferences.boosts
        self.learning = learning
        runtime = .init(
            baseTargets: baseTargets,
            pack: pack,
            preferenceBoosts: preferences.boosts,
            excludedRouteKeys: Set(learning.exclusions.keys)
        )
    }

    var vocabulary: [String] { runtime.vocabulary }
    var triggerCount: Int { runtime.triggerCount }

    mutating func replace(baseTargets: [MatchTarget], pack: VoiceRoutingPack?) {
        self.baseTargets = baseTargets
        self.pack = pack
        runtime = .init(
            baseTargets: baseTargets,
            pack: pack,
            preferenceBoosts: preferenceBoosts,
            excludedRouteKeys: Set(learning.exclusions.keys)
        )
        suppression.reset()
        lastUtteranceID = nil
        presentedNodeIDs.removeAll()
        presentedConceptCandidatesByID.removeAll()
        acknowledgedConceptOccurrenceCountsByID.removeAll()
    }

    /// Swap the immutable preference view without resetting any utterance suppression. If a
    /// boost changes candidate order, the next partial emits a replacement for that concept.
    mutating func replacePreferences(_ preferences: VoiceRoutingPreferenceSnapshot) {
        replacePreferences(preferences.boosts)
    }

    mutating func replacePreferences(_ boosts: [VoiceRoutingPreferenceKey: Double]) {
        preferenceBoosts = boosts
        runtime = .init(
            baseTargets: baseTargets,
            pack: pack,
            preferenceBoosts: boosts,
            excludedRouteKeys: Set(learning.exclusions.keys)
        )
    }

    /// Explicit user exclusions are safe to install immediately: they remove
    /// one route and cannot manufacture a new match. Preserve streaming
    /// suppression and presentation history for the current utterance.
    mutating func replaceLearning(_ learning: VoiceLearningSnapshot) {
        self.learning = learning
        runtime = .init(
            baseTargets: baseTargets,
            pack: pack,
            preferenceBoosts: preferenceBoosts,
            excludedRouteKeys: Set(learning.exclusions.keys)
        )
    }

    mutating func process(
        _ event: SpeechTranscript,
        visibleNodeIDs: Set<String> = [],
        visibleConceptCandidates: [String: Set<String>] = [:]
    ) -> VoiceRoutingStreamUpdate {
        if lastUtteranceID != event.utteranceID {
            suppression.reset()
            presentedNodeIDs.removeAll()
            presentedConceptCandidatesByID.removeAll()
            acknowledgedConceptOccurrenceCountsByID.removeAll()
            lastUtteranceID = event.utteranceID
        }
        let evaluation = runtime.evaluate(in: event.text)
        presentedNodeIDs.formIntersection(evaluation.positivelyMatchedNodeIDs)
        let retractedNodeIDs = presentedNodeIDs.intersection(evaluation.blockedMatchedNodeIDs)
        presentedNodeIDs.subtract(retractedNodeIDs)
        let allMatches = evaluation.matches
        let freshTargets = suppression.newMatches(
            from: allMatches.map(\.target),
            alsoSuppressing: visibleNodeIDs
        )
        let freshNodeIDs = Set(freshTargets.compactMap { target -> String? in
            guard case .node(let nodeID) = target.ref else { return nil }
            return nodeID
        })
        let freshMatches = allMatches.filter { match in
            guard case .node(let nodeID) = match.target.ref else { return false }
            return freshNodeIDs.contains(nodeID)
        }

        var availableConcepts: [VoiceRoutingSharedConceptMatch] = []
        for concept in evaluation.sharedConcepts {
            let ownVisibleNodeIDs = visibleConceptCandidates[concept.conceptID, default: []]
            let candidates = concept.candidates.filter { match in
                guard case .node(let nodeID) = match.target.ref else { return false }
                return !visibleNodeIDs.contains(nodeID) || ownVisibleNodeIDs.contains(nodeID)
            }
            guard !candidates.isEmpty else { continue }
            availableConcepts.append(.init(
                conceptID: concept.conceptID,
                pattern: concept.pattern,
                candidates: candidates,
                occurrenceCount: concept.occurrenceCount
            ))
        }
        let currentConceptsByID = availableConcepts.reduce(into: [String: [String]]()) {
            $0[$1.conceptID] = $1.orderedCandidateNodeIDs
        }
        let currentOccurrenceCountsByID = availableConcepts.reduce(into: [String: Int]()) {
            $0[$1.conceptID] = $1.occurrenceCount
        }
        let visibleConceptIDs = Set(visibleConceptCandidates.compactMap { conceptID, nodeIDs in
            nodeIDs.isEmpty ? nil : conceptID
        })

        // A concept becomes eligible again only after its candidate peeks are gone. Lower the
        // acknowledged count when Apple removes/corrects an occurrence; a later return then
        // counts as new. While candidates remain visible, consume any additional occurrence so
        // it cannot become a delayed ghost hit after the peeks expire.
        let trackedConceptIDs = Set(acknowledgedConceptOccurrenceCountsByID.keys)
            .union(currentOccurrenceCountsByID.keys)
        for conceptID in trackedConceptIDs {
            let currentCount = currentOccurrenceCountsByID[conceptID, default: 0]
            let acknowledgedCount = acknowledgedConceptOccurrenceCountsByID[conceptID, default: 0]
            if visibleConceptIDs.contains(conceptID) {
                acknowledgedConceptOccurrenceCountsByID[conceptID] = currentCount
            } else if currentCount < acknowledgedCount {
                acknowledgedConceptOccurrenceCountsByID[conceptID] = currentCount
            }
        }
        let retractedConceptIDs = Set(presentedConceptCandidatesByID.keys)
            .subtracting(currentConceptsByID.keys)
        retractedConceptIDs.forEach { presentedConceptCandidatesByID[$0] = nil }
        let freshConcepts = availableConcepts.filter { concept in
            if let presented = presentedConceptCandidatesByID[concept.conceptID] {
                if presented != concept.orderedCandidateNodeIDs { return true }
            }
            guard !visibleConceptIDs.contains(concept.conceptID) else { return false }
            return concept.occurrenceCount
                > acknowledgedConceptOccurrenceCountsByID[concept.conceptID, default: 0]
        }
        return .init(
            matches: freshMatches,
            sharedConcepts: freshConcepts,
            retractedNodeIDs: retractedNodeIDs,
            retractedConceptIDs: retractedConceptIDs
        )
    }

    mutating func markPresented(_ matches: [VoiceRoutingRuntimeMatch]) {
        suppression.markPresented(matches.map(\.target))
        presentedNodeIDs.formUnion(matches.compactMap { match -> String? in
            guard case .node(let nodeID) = match.target.ref else { return nil }
            return nodeID
        })
    }

    mutating func markPresented(_ update: VoiceRoutingStreamUpdate) {
        markPresented(update.matches)
        markPresented(update.sharedConcepts)
    }

    mutating func markPresented(_ concepts: [VoiceRoutingSharedConceptMatch]) {
        for concept in concepts {
            acknowledgedConceptOccurrenceCountsByID[concept.conceptID] = concept.occurrenceCount
            presentedConceptCandidatesByID[concept.conceptID] = concept.orderedCandidateNodeIDs
        }
    }
}

struct VoiceRoutingScorer: Sendable {
    static let minimumScore = 0.80
    static let minimumMargin = 0.15

    func decide(features: VoiceRoutingFeatures, pack: VoiceRoutingPack) -> VoiceRoutingDecision? {
        guard features.isSpecific, features.hasConcreteSubject, !pack.cards.isEmpty else { return nil }
        let ranked = rank(features: features, pack: pack)
        guard let winner = ranked.first else { return nil }
        let runnerUp = ranked.dropFirst().first?.score ?? 0
        guard winner.score >= Self.minimumScore,
              winner.score - runnerUp >= Self.minimumMargin else { return nil }
        return .init(nodeID: winner.card.nodeID, title: winner.card.title, score: winner.score, runnerUpScore: runnerUp)
    }

    func rank(features: VoiceRoutingFeatures, pack: VoiceRoutingPack) -> [(card: VoiceRoutingCard, score: Double)] {
        let utterance = PhraseMatcher.normalize(features.utterance)
        let labels = ([features.subject] + features.categoryLabels).map(PhraseMatcher.normalize).filter { !$0.isEmpty && $0 != "none" }
        let labelTerms = Set(labels.flatMap(contentTerms))
        let artifactType = PhraseMatcher.normalize(features.artifactType)
        let documentFrequency = topicDocumentFrequency(pack.cards)
        let cardCount = max(pack.cards.count, 1)

        return pack.cards.map { card in
            var score = 0.0
            for phrase in card.canonicalPhrases {
                let normalized = PhraseMatcher.normalize(phrase)
                if labels.contains(normalized) || containsWholePhrase(normalized, in: utterance) { score = max(score, 0.96) }
                else if isSpecificFragment(labels: labels, of: normalized) { score = max(score, 0.90) }
            }
            for phrase in card.semanticAliases {
                let normalized = PhraseMatcher.normalize(phrase)
                if labels.contains(normalized) || containsWholePhrase(normalized, in: utterance) { score = max(score, 0.90) }
            }

            let exactTags = Set(card.topicTags.map(PhraseMatcher.normalize)).intersection(labels)
            if !exactTags.isEmpty {
                let weight = exactTags.reduce(0.0) { partial, tag in
                    partial + inverseDocumentFrequency(documentFrequency[tag, default: 0], total: cardCount)
                }
                let denominator = labels.reduce(0.0) { partial, label in
                    partial + inverseDocumentFrequency(documentFrequency[label, default: 0], total: cardCount)
                }
                let coverage = denominator > 0 ? min(weight / denominator, 1) : 0
                score = max(score, 0.82 + 0.08 * coverage)
            } else {
                let cardTerms = Set(card.topicTags.flatMap(contentTerms))
                let overlap = weightedTermCoverage(labelTerms, cardTerms, documentFrequency: documentFrequency, total: cardCount)
                if overlap >= 0.66 { score = max(score, 0.72 + 0.16 * overlap) }
            }

            if artifactType != "none", card.artifactTypes.map(PhraseMatcher.normalize).contains(artifactType) {
                score = max(score, 0.74)
            }
            for example in card.representativeUtterances {
                let similarity = jaccard(contentTerms(utterance), contentTerms(example))
                if similarity >= 0.60 { score = max(score, 0.80 + 0.15 * similarity) }
            }

            let negativePhrases = card.hardNegatives + card.confusableConcepts
            if negativePhrases.contains(where: {
                containsWholePhrase(PhraseMatcher.normalize($0), in: utterance)
                    || jaccard(contentTerms(utterance), contentTerms($0)) >= 0.65
            }) {
                score -= 0.35
            }
            return (card, min(max(score, 0), 1))
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.nodeID < $1.0.nodeID
        }
    }
}

struct VoiceRoutingQualityGate: Sendable {
    struct Result: Equatable, Sendable {
        var passed: Bool
        var coverage: Double
        var failures: [String]
        var warnings: [String]
    }

    func evaluate(pack: VoiceRoutingPack, expectedNodeCount: Int) -> Result {
        var failures: [String] = []
        var warnings: [String] = []
        if Set(pack.cards.map(\.nodeID)).count != pack.cards.count { failures.append("duplicate node cards") }
        if !pack.isStructurallyValid { failures.append("routing pack is structurally invalid") }

        let baseTargets = pack.cards.flatMap { card in
            card.canonicalPhrases.map {
                MatchTarget(phrase: $0, ref: .node(card.nodeID), title: card.title)
            }
        }
        let router = VoiceRoutingRuntimeRouter(baseTargets: baseTargets, pack: pack)
        let proposalRouter = VoiceRoutingRuntimeRouter(baseTargets: [], pack: pack)
        for concept in pack.sharedConcepts {
            if pack.cards.contains(where: { card in
                card.activeTriggers.contains {
                    VoiceRoutingSharedConcept.stableID(for: $0.pattern) == concept.id
                }
            }) {
                failures.append("shared concept also exists as an active trigger: \(concept.id)")
            }
            let utterance: String = switch concept.pattern {
            case .phrase(let phrase): phrase
            case .orderedTerms(let terms, _): terms.joined(separator: " about ")
            }
            let runtimeConcept = router.sharedMatches(in: utterance).first { $0.conceptID == concept.id }
            let compiledNodeIDs = Set(concept.candidates.map(\.nodeID))
            let presentedNodeIDs = runtimeConcept?.candidateNodeIDs ?? []
            if runtimeConcept == nil
                || !presentedNodeIDs.isSubset(of: compiledNodeIDs)
                || presentedNodeIDs.count != min(3, compiledNodeIDs.count) {
                failures.append("shared concept did not preserve its compiled candidates: \(concept.id)")
            }
            for edge in concept.candidates {
                if VoiceRoutingSharedConceptValidator().validate(
                    candidate: edge,
                    concept: concept,
                    pack: pack
                ).outcome != .accepted {
                    failures.append("shared concept candidate did not independently route: \(concept.id):\(edge.nodeID)")
                }
            }
        }
        let canonicallyValidatedNodeIDs = Set(pack.cards.compactMap { card -> String? in
            guard let canonical = card.canonicalPhrases.first,
                  router.validate(utterance: canonical, expectedNodeID: card.nodeID).outcome == .accepted else {
                return nil
            }
            return card.nodeID
        })
        let coverage = expectedNodeCount > 0
            ? Double(canonicallyValidatedNodeIDs.count) / Double(expectedNodeCount)
            : 0
        if coverage < 0.80 { failures.append("validated card coverage below 80%") }
        for card in pack.cards {
            if let canonical = card.canonicalPhrases.first,
               router.validate(utterance: canonical, expectedNodeID: card.nodeID).outcome != .accepted {
                failures.append("canonical phrase did not uniquely route for \(card.nodeID)")
            }
            for trigger in card.activeTriggers {
                let utterance: String = switch trigger.pattern {
                case .phrase(let phrase): phrase
                case .orderedTerms(let terms, _): terms.joined(separator: " about ")
                }
                if router.validate(utterance: utterance, expectedNodeID: card.nodeID).outcome != .accepted {
                    failures.append("active trigger did not uniquely route for \(card.nodeID)")
                    break
                }
            }
        }
        for card in pack.cards {
            for phrase in card.hardNegatives {
                if !proposalRouter.matches(in: phrase).isEmpty || !proposalRouter.sharedMatches(in: phrase).isEmpty {
                    failures.append("hard negative did not globally abstain for \(card.nodeID)")
                    break
                }
            }
            for phrase in card.confusableConcepts {
                let uniquelyRoutedToOwner = proposalRouter.matches(in: phrase).contains(where: { match in
                    guard case .node(let nodeID) = match.target.ref else { return false }
                    return nodeID == card.nodeID
                })
                let sharedWithOwner = proposalRouter.sharedMatches(in: phrase).contains {
                    $0.candidateNodeIDs.contains(card.nodeID)
                }
                if uniquelyRoutedToOwner || sharedWithOwner {
                    failures.append("confuser routed to its owner \(card.nodeID)")
                    break
                }
            }
        }
        for _ in 0..<3 {
            for regression in VoiceRoutingRegressionCorpus.positive {
                guard let card = pack.cards.first(where: {
                    PhraseMatcher.normalize($0.title) == regression.canonicalTitle
                }) else { continue }
                let evaluation = router.evaluate(in: regression.utterance)
                if evaluation.sharedConcepts.contains(where: {
                    $0.candidateNodeIDs.contains(card.nodeID)
                }) {
                    continue
                }
                if !evaluation.sharedConcepts.isEmpty {
                    failures.append("fixed recall regression routed unsafely for \(card.nodeID): \(regression.utterance)")
                    continue
                }
                let result = router.validate(utterance: regression.utterance, expectedNodeID: card.nodeID)
                switch result.outcome {
                case .accepted:
                    break
                case .abstained, .blockedByNegative:
                    warnings.append("fixed recall regression missed for \(card.nodeID): \(regression.utterance)")
                case .ambiguous, .wrongWinner:
                    failures.append("fixed recall regression routed unsafely for \(card.nodeID): \(regression.utterance)")
                }
            }
            for utterance in VoiceRoutingRegressionCorpus.negative {
                if !proposalRouter.matches(in: utterance).isEmpty || !proposalRouter.sharedMatches(in: utterance).isEmpty {
                    failures.append("generic regression did not abstain: \(utterance)")
                }
            }
        }
        return .init(
            passed: failures.isEmpty,
            coverage: coverage,
            failures: Array(Set(failures)).sorted(),
            warnings: Array(Set(warnings)).sorted()
        )
    }
}

enum VoiceRoutingRegressionCorpus {
    static let positive: [(canonicalTitle: String, utterance: String)] = [
        ("journal", "I need to write in my diary"),
        ("building a second brain", "second brain"),
        ("building a second brain", "knowledge system"),
        ("progressive summarization", "progressive about the summarization"),
        ("progressive summarization", "progressive summarizing"),
    ]

    static let negative = [
        "Come on man",
        "What should I talk about to trigger something?",
        "What do I have to talk about to get something to show up?",
        "skip the links",
        "show me the project templates",
        "I need to write in my planner",
        "I should write something",
        "Show me my notes",
    ]
}

struct VoiceRoutingCardValidator: Sendable {
    func removingGlobalAliasCollisions(_ cards: [VoiceRoutingCard]) -> [VoiceRoutingCard] {
        var canonicalOwners: [String: Set<String>] = [:]
        var semanticOwners: [String: Set<String>] = [:]
        for card in cards {
            for phrase in card.canonicalPhrases { canonicalOwners[PhraseMatcher.normalize(phrase), default: []].insert(card.nodeID) }
            for phrase in card.semanticAliases { semanticOwners[PhraseMatcher.normalize(phrase), default: []].insert(card.nodeID) }
        }
        var canonicalFragmentOwners: [String: Set<String>] = [:]
        for phrase in semanticOwners.keys {
            for card in cards where card.canonicalPhrases.contains(where: {
                isSpecificFragment(labels: [phrase], of: PhraseMatcher.normalize($0))
            }) {
                canonicalFragmentOwners[phrase, default: []].insert(card.nodeID)
            }
        }
        return cards.map { card in
            var next = card
            next.semanticAliases = card.semanticAliases.filter { phrase in
                let normalized = PhraseMatcher.normalize(phrase)
                let canonical = canonicalOwners[normalized, default: []]
                let semantic = semanticOwners[normalized, default: []]
                let fragment = canonicalFragmentOwners[normalized, default: []]
                if fragment.count == 1 { return fragment.contains(card.nodeID) }
                return (canonical.isEmpty || canonical == Set([card.nodeID])) && semantic == Set([card.nodeID])
            }
            return next
        }
    }
}

actor VoiceRoutingStore {
    enum StoreError: Error { case invalidPack }
    private struct Archive: Codable {
        static let schemaVersion = 6
        var schemaVersion = Self.schemaVersion
        var compilerVersion: String
        var modelVersion: String
        var proposalsByCacheKey: [String: VoiceRoutingCard]
        var activePack: VoiceRoutingPack?
    }

    let fileURL: URL
    private var archive: Archive?

    init(fileURL: URL) { self.fileURL = fileURL }

    static func applicationSupport() -> VoiceRoutingStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Embers", isDirectory: true)
        return VoiceRoutingStore(fileURL: root.appendingPathComponent("voice-routing.json"))
    }

    func activePack(graphRevision: String, compilerVersion: String, modelVersion: String) -> VoiceRoutingPack? {
        let archive = load(compilerVersion: compilerVersion, modelVersion: modelVersion)
        guard let pack = archive.activePack,
              pack.schemaVersion == VoiceRoutingPack.schemaVersion,
              pack.isStructurallyValid,
              pack.graphRevision == graphRevision,
              pack.compilerVersion == compilerVersion,
              pack.modelVersion == modelVersion else { return nil }
        return pack
    }

    func activePack(inputRevision: String, compilerVersion: String, modelVersion: String) -> VoiceRoutingPack? {
        let archive = load(compilerVersion: compilerVersion, modelVersion: modelVersion)
        guard let pack = archive.activePack,
              pack.schemaVersion == VoiceRoutingPack.schemaVersion,
              pack.isStructurallyValid,
              pack.inputRevision == inputRevision,
              pack.compilerVersion == compilerVersion,
              pack.modelVersion == modelVersion else { return nil }
        return pack
    }

    func cachedCard(
        evidenceHash: String,
        graphRevision _: String,
        compilerVersion: String,
        modelVersion: String
    ) -> VoiceRoutingCard? {
        load(compilerVersion: compilerVersion, modelVersion: modelVersion)
            .proposalsByCacheKey[proposalCacheKey(evidenceHash: evidenceHash)]
    }

    func save(
        card: VoiceRoutingCard,
        graphRevision _: String,
        compilerVersion: String,
        modelVersion: String
    ) throws {
        var next = load(compilerVersion: compilerVersion, modelVersion: modelVersion)
        next.proposalsByCacheKey[proposalCacheKey(evidenceHash: card.evidenceHash)] = card
        archive = next
        try persist(next)
    }

    func activate(_ pack: VoiceRoutingPack, retaining evidenceHashes: Set<String>) throws {
        guard pack.isStructurallyValid else { throw StoreError.invalidPack }
        var next = load(compilerVersion: pack.compilerVersion, modelVersion: pack.modelVersion)
        let retainedKeys = Set(evidenceHashes.map {
            proposalCacheKey(evidenceHash: $0)
        })
        next.proposalsByCacheKey = next.proposalsByCacheKey.filter { retainedKeys.contains($0.key) }
        next.activePack = pack
        archive = next
        try persist(next)
    }

    func delete() throws {
        archive = nil
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
    }

    private func load(compilerVersion: String, modelVersion: String) -> Archive {
        if let archive,
           archive.compilerVersion == compilerVersion,
           archive.modelVersion == modelVersion { return archive }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode(Archive.self, from: data),
              decoded.schemaVersion == Archive.schemaVersion,
              decoded.compilerVersion == compilerVersion,
              decoded.modelVersion == modelVersion else {
            let empty = Archive(compilerVersion: compilerVersion, modelVersion: modelVersion, proposalsByCacheKey: [:])
            archive = empty
            return empty
        }
        archive = decoded
        return decoded
    }

    private func persist(_ archive: Archive) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: fileURL, options: .atomic)
    }

    private func proposalCacheKey(evidenceHash: String) -> String {
        evidenceHash
    }
}

private func containsWholePhrase(_ phrase: String, in text: String) -> Bool {
    guard !phrase.isEmpty else { return false }
    return (" " + text + " ").contains(" " + phrase + " ")
}

private func matchSpan(for pattern: VoiceRoutingTriggerPattern, in words: [String]) -> Range<Int>? {
    matchSpans(for: pattern, in: words).first
}

private func matchSpans(for pattern: VoiceRoutingTriggerPattern, in words: [String]) -> [Range<Int>] {
    switch pattern {
    case .phrase(let phrase):
        return contiguousSpans(
            of: PhraseMatcher.normalize(phrase).split(separator: " ").map(String.init),
            in: words
        )
    case .orderedTerms(let terms, let maximumGap):
        let groups = terms.map { PhraseMatcher.normalize($0).split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty }
        guard !groups.isEmpty else { return [] }
        var results: [Range<Int>] = []
        for start in words.indices {
            guard let first = firstContiguousSpan(of: groups[0], in: words, startingAt: start),
                  first.lowerBound == start else { continue }
            var end = first.upperBound
            var matched = true
            for group in groups.dropFirst() {
                let latestStart = min(end + max(maximumGap, 0), words.count - 1)
                var next: Range<Int>?
                if end < words.count {
                    for candidateStart in end...latestStart {
                        if let span = firstContiguousSpan(of: group, in: words, startingAt: candidateStart),
                           span.lowerBound == candidateStart {
                            next = span
                            break
                        }
                    }
                }
                guard let next else { matched = false; break }
                end = next.upperBound
            }
            if matched { results.append(start..<end) }
        }
        return results
    }
}

private func contiguousSpans(of needle: [String], in haystack: [String]) -> [Range<Int>] {
    guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
    return (0...(haystack.count - needle.count)).compactMap { index in
        Array(haystack[index..<(index + needle.count)]) == needle
            ? index..<(index + needle.count)
            : nil
    }
}

private func firstContiguousSpan(
    of needle: [String],
    in haystack: [String],
    startingAt: Int
) -> Range<Int>? {
    guard !needle.isEmpty, needle.count <= haystack.count, startingAt < haystack.count else { return nil }
    let lastStart = haystack.count - needle.count
    guard startingAt <= lastStart else { return nil }
    for index in startingAt...lastStart where Array(haystack[index..<(index + needle.count)]) == needle {
        return index..<(index + needle.count)
    }
    return nil
}

private func isSpecificFragment(labels: [String], of phrase: String) -> Bool {
    let target = Set(contentTerms(phrase))
    guard target.count >= 2 else { return false }
    return labels.contains { label in
        let terms = Set(contentTerms(label))
        return terms.count >= 2 && terms.isSubset(of: target)
    }
}

private func contentTerms(_ text: String) -> [String] {
    let stopWords: Set<String> = [
        "a", "an", "the", "i", "me", "my", "we", "our", "you", "your", "it", "its",
        "this", "that", "what", "which", "who", "to", "of", "in", "on", "for", "with",
        "and", "or", "is", "are", "was", "were", "be", "been", "do", "does", "did",
        "have", "has", "need", "want", "should", "would", "could", "something", "anything"
    ]
    return PhraseMatcher.normalize(text).split(separator: " ").map(String.init).filter {
        $0.count > 2 && !stopWords.contains($0)
    }.map { word in
        word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }
}

private func jaccard(_ lhs: [String], _ rhs: [String]) -> Double {
    let left = Set(lhs), right = Set(rhs)
    guard !left.isEmpty, !right.isEmpty else { return 0 }
    return Double(left.intersection(right).count) / Double(left.union(right).count)
}

private func topicDocumentFrequency(_ cards: [VoiceRoutingCard]) -> [String: Int] {
    cards.reduce(into: [:]) { result, card in
        for tag in Set(card.topicTags.map(PhraseMatcher.normalize)) { result[tag, default: 0] += 1 }
    }
}

private func inverseDocumentFrequency(_ frequency: Int, total: Int) -> Double {
    log((Double(total) + 1) / (Double(frequency) + 1)) + 1
}

private func weightedTermCoverage(
    _ query: Set<String>,
    _ card: Set<String>,
    documentFrequency: [String: Int],
    total: Int
) -> Double {
    guard !query.isEmpty else { return 0 }
    let denominator = query.reduce(0.0) { $0 + inverseDocumentFrequency(documentFrequency[$1, default: 0], total: total) }
    let numerator = query.intersection(card).reduce(0.0) { $0 + inverseDocumentFrequency(documentFrequency[$1, default: 0], total: total) }
    return denominator > 0 ? numerator / denominator : 0
}
