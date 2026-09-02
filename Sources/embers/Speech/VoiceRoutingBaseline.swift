import Foundation
import EmbersCore

/// The same title-derived evidence is used by live routing and Context Lens. Model output
/// cannot grant or revoke these names; it can only add vocabulary alongside them.
struct VoiceRoutingBaseline {
    struct Rule {
        var target: MatchTarget
        var trigger: VoiceRoutingTrigger
    }

    struct Decision: Codable, Equatable, Sendable {
        var nodeID: String
        var trigger: VoiceRoutingTrigger
        var ownerNodeIDs: [String]
        var isActive: Bool
    }

    var rules: [Rule]
    var sharedConcepts: [VoiceRoutingSharedConcept]
    var decisions: [Decision]

    init(targets: [MatchTarget]) {
        var proposed: [Rule] = []
        var seenNodes = Set<String>()
        for target in targets {
            guard case .node(let nodeID) = target.ref else { continue }
            let isCanonical = seenNodes.insert(nodeID).inserted
            proposed.append(.init(target: target, trigger: .init(
                pattern: .phrase(target.phrase),
                origin: isCanonical ? .canonicalName : .existingAlias,
                score: isCanonical ? 1 : 0.98
            )))
            guard isCanonical else { continue }
            for fragment in Self.fragments(of: target.title) {
                proposed.append(.init(
                    target: .init(phrase: fragment, ref: target.ref, title: target.title),
                    trigger: .init(pattern: .phrase(fragment), origin: .titleFragment, score: 0.96)
                ))
            }
        }

        let groups = Dictionary(grouping: proposed) { PhraseMatcher.normalize($0.trigger.pattern.displayPhrase) }
        var rules: [Rule] = []
        var concepts: [VoiceRoutingSharedConcept] = []
        var decisions: [Decision] = []
        for phrase in groups.keys.sorted() where !phrase.isEmpty {
            let proposals = groups[phrase] ?? []
            let authority = proposals.map { $0.trigger.origin.identityAuthority }.max() ?? 0
            var owners: [String: Rule] = [:]
            for rule in proposals where rule.trigger.origin.identityAuthority == authority {
                if case .node(let nodeID) = rule.target.ref { owners[nodeID] = rule }
            }
            let ownerIDs = owners.keys.sorted()
            rules.append(contentsOf: ownerIDs.compactMap { owners[$0] })
            for rule in proposals {
                guard case .node(let nodeID) = rule.target.ref else { continue }
                decisions.append(.init(nodeID: nodeID, trigger: rule.trigger, ownerNodeIDs: ownerIDs,
                    isActive: rule.trigger.origin.identityAuthority == authority))
            }
            if owners.count > 1 {
                let pattern = VoiceRoutingTriggerPattern.phrase(phrase)
                concepts.append(.init(id: VoiceRoutingSharedConcept.stableID(for: pattern), pattern: pattern,
                    candidates: ownerIDs.compactMap { nodeID -> VoiceRoutingConceptCandidateEdge? in
                        guard let rule = owners[nodeID] else { return nil }
                        return .init(nodeID: nodeID, compiledStrength: rule.trigger.score,
                            origin: rule.trigger.origin, evidenceHash: StableHash.hex(rule.target.title))
                    }))
            }
        }
        self.rules = rules
        sharedConcepts = concepts
        self.decisions = decisions
    }

    private static func fragments(of title: String) -> [String] {
        let words = PhraseMatcher.normalize(title).split(separator: " ").map(String.init)
        guard words.count > 1 else { return [] }
        var fragments = Set<String>()
        for start in words.indices {
            for end in (start + 1)...words.count where end - start < words.count {
                let fragment = words[start..<end]
                guard fragment.contains(where: { !voiceRoutingStopWords.contains($0) }) else { continue }
                fragments.insert(fragment.joined(separator: " "))
            }
        }
        return fragments.sorted()
    }
}

extension VoiceRoutingTriggerOrigin {
    var identityAuthority: Int {
        switch self {
        case .canonicalName: 4
        case .existingAlias: 3
        case .titleFragment: 2
        case .shortenedCanonical: 1
        default: 0
        }
    }

    var isDeterministicIdentity: Bool {
        switch self {
        case .canonicalName, .existingAlias, .titleFragment: true
        default: false
        }
    }
}

let voiceRoutingStopWords: Set<String> = [
    "a", "an", "the", "i", "me", "my", "we", "our", "you", "your", "it", "its",
    "this", "that", "to", "of", "in", "on", "for", "with", "and", "or", "is", "are",
    "was", "were", "be", "been", "do", "does", "did", "have", "has", "need", "want",
]
