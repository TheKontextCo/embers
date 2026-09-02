import Foundation
import FoundationModels
import NaturalLanguage

/// A grounded fallback for utterances which do not contain an exact context name.
/// The model extracts a subject without seeing the graph; deterministic code then
/// resolves that subject against the closed set of voice-addressable contexts.
actor SemanticVoiceMatcher {
    private static let minimumRelatedness = 80

    @Generable
    struct Resolution {
        @Guide(description: "A concise 1–4 word subject clearly identified by the utterance, or NONE when no specific subject is identified")
        var subject: String

        @Guide(description: "Up to five conventional category labels or direct synonyms for the subject; empty when there is no specific subject", .maximumCount(5))
        var categoryLabels: [String]

        @Guide(description: "The type of artifact, container, or organizational object requested by the utterance, or NONE when none is implied")
        var artifactType: String

        @Guide(description: "True only when the utterance clearly identifies that subject rather than merely mentioning a generic action")
        var isSpecific: Bool

        @Guide(description: "How clearly the utterance identifies the extracted subject, from 0 for no subject to 100 for explicit or unmistakable", .range(0...100))
        var relatedness: Int
    }

    private let model = SystemLanguageModel.default
    private var session: LanguageModelSession?
    private var isClassifying = false

    nonisolated var isAvailable: Bool { SystemLanguageModel.default.isAvailable }
    nonisolated var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(.deviceNotEligible): return "unavailable: device not eligible"
        case .unavailable(.appleIntelligenceNotEnabled): return "unavailable: Apple Intelligence disabled"
        case .unavailable(.modelNotReady): return "unavailable: model not ready"
        @unknown default: return "unavailable: unknown reason"
        }
    }

    func prewarm() {
        guard model.isAvailable else {
            Log.speech.info("semantic_prewarm_unavailable")
            return
        }
        guard session == nil, !isClassifying else { return }
        let session = makeSession()
        self.session = session
        session.prewarm()
        Log.speech.info("semantic_classifier_prewarming")
    }

    func match(utterance: String, candidates: [MatchTarget], routingPack: VoiceRoutingPack? = nil) async -> MatchTarget? {
        guard model.isAvailable else {
            Log.speech.info("semantic_request_unavailable")
            return nil
        }
        guard !candidates.isEmpty else {
            Log.speech.info("semantic_request_no_candidates")
            return nil
        }
        let normalized = PhraseMatcher.normalize(utterance)
        guard normalized.split(separator: " ").count >= 2 else {
            Log.speech.debug("semantic_request_too_short")
            return nil
        }
        // Consume one clean, prewarmed session, then prepare the next. This keeps the model
        // resident without accumulating prior utterances in a stateful conversation.
        let activeSession = session ?? makeSession()
        session = nil
        isClassifying = true
        defer {
            isClassifying = false
            let next = makeSession()
            session = next
            next.prewarm()
        }

        var uniqueTargets: [MatchTarget] = []
        var seenIDs = Set<String>()
        for target in candidates {
            let id: String
            switch target.ref { case .node(let value): id = value }
            if seenIDs.insert(id).inserted { uniqueTargets.append(target) }
        }

        // Resolve an explicit multiword fragment such as “second brain” without
        // allowing model sampling to turn a direct reference into an abstention.
        if hasConcreteNoun(in: utterance), let directTarget = resolve(labels: [normalized], in: uniqueTargets) {
            Log.speech.info("semantic_phrase_resolved_deterministically")
            return directTarget
        }

        let prompt = """
        Utterance: \(utterance)

        Extract the single concrete subject that the speaker is clearly referring to, without guessing what personal contexts may exist. Separately name any artifact or organizational object requested. Include up to five conventional category labels or direct synonyms. A functional description can identify an artifact type (for example, a reusable starting point is a template rather than the note created from it), but a generic action alone does not. Return NONE unless the utterance supplies enough meaning to name a specific subject.
        """

        Log.speech.info("semantic_subject_extraction_started")
        do {
            let response = try await activeSession.respond(
                to: prompt,
                generating: Resolution.self,
                options: GenerationOptions(sampling: .greedy)
            )
            guard !Task.isCancelled else {
                Log.speech.debug("semantic_classifier_cancelled")
                return nil
            }
            let subject = PhraseMatcher.normalize(response.content.subject)
            guard response.content.isSpecific, subject != "none" else {
                Log.speech.info("semantic_classifier_no_match")
                return nil
            }
            guard hasConcreteNoun(in: utterance) else {
                Log.speech.info("semantic_subject_rejected_no_concrete_noun")
                return nil
            }
            let artifactType = PhraseMatcher.normalize(response.content.artifactType)
            let labels = [subject, artifactType, normalized] + response.content.categoryLabels.map(PhraseMatcher.normalize)
            if let routingPack {
                let features = VoiceRoutingFeatures(
                    utterance: utterance,
                    subject: subject,
                    categoryLabels: response.content.categoryLabels,
                    artifactType: artifactType,
                    isSpecific: response.content.isSpecific,
                    hasConcreteSubject: true
                )
                guard let decision = VoiceRoutingScorer().decide(features: features, pack: routingPack),
                      let target = uniqueTargets.first(where: {
                          guard case .node(let id) = $0.ref else { return false }
                          return id == decision.nodeID
                      }) else {
                    Log.speech.info("compiled_voice_router_abstained")
                    return nil
                }
                Log.speech.info("compiled_voice_router_selected")
                return target
            }
            guard response.content.relatedness >= Self.minimumRelatedness else {
                Log.speech.info("semantic_classifier_rejected_low_relatedness")
                return nil
            }
            guard let target = resolve(labels: labels, in: uniqueTargets) else {
                Log.speech.info("semantic_subject_unresolved")
                return nil
            }
            Log.speech.info("semantic_subject_resolved")
            return target
        } catch is CancellationError {
            Log.speech.debug("semantic_classifier_cancelled")
            return nil
        } catch {
            Log.speech.error("semantic_classifier_failed")
            return nil
        }
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: model, instructions: """
        Extract the single concrete subject clearly identified by a spoken utterance, without seeing or guessing any available personal contexts. Separately identify the artifact, container, or organizational object being requested. For example, a reusable starting point is a template rather than the eventual note's topic. Return a concise subject plus up to five conventional category labels or direct synonyms. Functional descriptions may identify an artifact type, but generic actions alone do not. Return NONE, no labels, and mark it nonspecific for generic speech, meta-conversation, requests for suggestions, ordinary reactions, ambiguous statements, or actions lacking a concrete subject. Calibrate conservatively: 0 means no subject, 50 merely plausible, 80 clear, and 100 explicit.
        """)
    }

    private func resolve(labels: [String], in targets: [MatchTarget]) -> MatchTarget? {
        let labelSets = labels.map(contentStems).filter { !$0.isEmpty }
        let matches = targets.filter { target in
            let targetStems = contentStems(PhraseMatcher.normalize(target.title))
            guard !targetStems.isEmpty else { return false }
            return labelSets.contains { labelStems in
                targetStems == labelStems
                    || (targetStems.count == 1 && targetStems.isSubset(of: labelStems))
                    || (labelStems.count >= 2 && labelStems.isSubset(of: targetStems))
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func stem(_ word: String) -> String {
        word.count > 4 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    private func hasConcreteNoun(in text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var found = false
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, _ in
            if tag == .noun {
                found = true
                return false
            }
            return true
        }
        return found
    }

    private func contentStems(_ text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "the", "i", "me", "my", "mine", "we", "us", "our", "ours",
            "you", "your", "yours", "he", "she", "they", "them", "their", "it", "its",
            "this", "that", "these", "those", "what", "which", "who", "do", "does", "did",
            "have", "has", "had", "to", "of", "in", "on", "for", "with", "and", "or", "but",
            "is", "are", "was", "were", "be", "been", "being", "can", "could", "should", "would",
            "will", "just", "something", "anything", "get", "got", "need", "want"
        ]
        return Set(PhraseMatcher.normalize(text).split(separator: " ").map(String.init).filter {
            $0.count > 2 && !stopWords.contains($0)
        }.map(stem))
    }
}
