import Foundation
import FoundationModels
import EmbersCore

final class VoiceRoutingGenerationProgress: @unchecked Sendable {
    static let unitsPerNote = 8

    private let lock = NSLock()
    private let total: Int
    private let reportingStride: Int
    private let report: @Sendable (VoiceRoutingCompilationProgress) -> Void
    private var completed = 0
    private var lastReported = 0

    init(
        noteCount: Int,
        report: @escaping @Sendable (VoiceRoutingCompilationProgress) -> Void
    ) {
        total = max(noteCount * Self.unitsPerNote, 1)
        reportingStride = max((total + 199) / 200, 1)
        self.report = report
        report(.init(stage: .generatingNotes, completed: 0, total: total))
    }

    func advance(by units: Int = 1) {
        update(toAtLeast: nil, adding: units)
    }

    func completeThrough(noteCount: Int) {
        update(toAtLeast: noteCount * Self.unitsPerNote, adding: 0)
    }

    private func update(toAtLeast target: Int?, adding units: Int) {
        lock.lock()
        completed = min(total, max(completed + max(units, 0), target ?? 0))
        let shouldReport = completed - lastReported >= reportingStride || completed == total
        if shouldReport { lastReported = completed }
        let snapshot = completed
        if shouldReport {
            report(.init(stage: .generatingNotes, completed: snapshot, total: total))
        }
        lock.unlock()
    }
}

actor VoiceRoutingCompiler {
    static let compilerVersion = "voice-routing-30"

    struct Outcome: Sendable {
        var pack: VoiceRoutingPack?
        var generatedCount: Int
        var reusedCount: Int
        var failure: String?
        var warnings: [String] = []
    }

    @Generable
    struct PositiveProposal {
        @Guide(description: "The smallest subset of words copied exactly from the supplied canonical title-word candidates that preserves the context's identifying meaning. Remove words that merely describe its general type or activity. Keep selected words in their original title order. This array is one subset that becomes one phrase, not several independent names. Example: America Trip returns [america]; Building a Second Brain may return [second, brain]", .maximumCount(8))
        var canonicalIdentitySubset: [String]

        @Guide(description: "Up to eight short natural phrases, usually one to five words, that directly name this context or a conventional synonym", .maximumCount(8))
        var semanticAliases: [String]

        @Guide(description: "Up to twelve natural spoken variants belonging to the same phrase family, including ordinary synonyms and inflections; for example journal may yield diary, and knowledge management system may yield knowledge system", .maximumCount(12))
        var phraseFamilyVariants: [String]

        @Guide(description: "Up to six nouns for the kind of artifact or organizational container represented here", .maximumCount(6))
        var artifactTypes: [String]

        @Guide(description: "Up to eight realistic short utterances that clearly refer to this context without saying its exact canonical name", .maximumCount(8))
        var representativeUtterances: [String]
    }

    @Generable
    struct LexicalAlternativeProposal {
        @Guide(description: "Up to twelve concise, standalone conventional names for the same target. Prefer different-root thesaurus synonyms and established abbreviations; omit repetitions, mere inflections, and phrases formed by appending words such as session, time, app, tool, or project", .maximumCount(12))
        var alternatives: [String]
    }

    @Generable
    struct SemanticRelationVerification {
        @Guide(description: "Candidate phrases copied from the supplied list that a speaker can use as a conventional name for the same target; include synonyms, abbreviations, inflections, spelling variants, and identity-preserving shortened names, but omit associations and broader or narrower topics", .maximumCount(20))
        var acceptedCandidatePhrases: [String]
    }

    struct LexicalAlternativeEnsemble: Sendable {
        var passes: [[String]]

        var alternatives: [String] {
            uniqueNormalized(passes.flatMap { $0 })
        }
    }

    @Generable
    struct ContrastProposal {
        @Guide(description: "Up to eight plausible utterances that contain nearby vocabulary but must not select this context", .maximumCount(8))
        var hardNegatives: [String]

        @Guide(description: "Up to eight parent, child, sibling, or neighboring concepts that belong elsewhere and must count against selecting this context", .maximumCount(8))
        var confusableConcepts: [String]
    }

    @Generable
    struct TagProposal {
        @Guide(description: "Up to twelve concise topic labels that distinguish this context from its parents, children, and neighboring concepts", .maximumCount(12))
        var topicTags: [String]

        @Guide(description: "Up to six nouns for the kind of artifact or organizational container represented here", .maximumCount(6))
        var artifactTypes: [String]
    }

    @Generable
    struct ArtifactHeadProposal {
        @Guide(description: "Up to eight single-word nouns naming the artifact, container, organizational system, or methodology type directly supported by the target identity and evidence", .maximumCount(8))
        var heads: [String]
    }

    private let languageModel = SystemLanguageModel.default
    private let taggingModel = SystemLanguageModel(useCase: .contentTagging)
    private let store: VoiceRoutingStore

    init(store: VoiceRoutingStore) { self.store = store }

    nonisolated var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable && SystemLanguageModel(useCase: .contentTagging).isAvailable
    }

    nonisolated static var modelVersion: String {
        "default+content-tagging|\(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    func compile(
        seeds: [VoiceRoutingSeed],
        graphRevision: String,
        inputRevision: String? = nil,
        progress: @escaping @Sendable (VoiceRoutingCompilationProgress) -> Void = { _ in }
    ) async -> Outcome {
        guard languageModel.isAvailable, taggingModel.isAvailable else {
            return .init(pack: nil, generatedCount: 0, reusedCount: 0, failure: "Apple on-device language models unavailable")
        }
        guard !seeds.isEmpty else {
            return .init(pack: nil, generatedCount: 0, reusedCount: 0, failure: "No voice-addressable contexts")
        }

        var cards: [VoiceRoutingCard] = []
        var generated = 0
        var reused = 0
        let generationProgress = VoiceRoutingGenerationProgress(
            noteCount: seeds.count,
            report: progress
        )
        for (index, seed) in seeds.enumerated() {
            guard !Task.isCancelled else { return .init(pack: nil, generatedCount: generated, reusedCount: reused, failure: "Cancelled") }
            if let cached = await store.cachedCard(
                evidenceHash: seed.evidenceHash,
                graphRevision: graphRevision,
                compilerVersion: Self.compilerVersion,
                modelVersion: Self.modelVersion
            ), cached.nodeID == seed.nodeID {
                cards.append(cached)
                reused += 1
                generationProgress.completeThrough(noteCount: index + 1)
                continue
            }
            do {
                let card = try await generateCard(
                    for: seed,
                    didCompleteGenerationUnit: { generationProgress.advance() }
                )
                try await store.save(
                    card: card,
                    graphRevision: graphRevision,
                    compilerVersion: Self.compilerVersion,
                    modelVersion: Self.modelVersion
                )
                cards.append(card)
                generated += 1
            } catch is CancellationError {
                return .init(pack: nil, generatedCount: generated, reusedCount: reused, failure: "Cancelled")
            } catch {
                Log.speech.error("voice_compiler_context_skipped")
            }
            generationProgress.completeThrough(noteCount: index + 1)
        }

        var pack = VoiceRoutingPack(
            graphRevision: graphRevision,
            compilerVersion: Self.compilerVersion,
            modelVersion: Self.modelVersion,
            generatedAt: .now,
            cards: cards
        )
        pack.inputRevision = inputRevision ?? VoiceRoutingInputRevision.make(seeds)
        pack = VoiceRoutingCompilerValidator().validate(pack, seeds: seeds, progress: progress)
        guard !Task.isCancelled else {
            return .init(pack: nil, generatedCount: generated, reusedCount: reused, failure: "Cancelled")
        }
        let gate = VoiceRoutingQualityGate().evaluate(pack: pack, expectedNodeCount: seeds.count)
        guard gate.passed else {
            let failure = gate.failures.joined(separator: "; ")
            Log.speech.info("voice_routing_pack_rejected")
            return .init(pack: nil, generatedCount: generated, reusedCount: reused, failure: failure)
        }
        if !gate.warnings.isEmpty {
            Log.speech.info("voice_routing_pack_activated_with_warnings")
        }
        do {
            try await store.activate(pack, retaining: Set(seeds.map(\.evidenceHash)))
        } catch {
            return .init(pack: nil, generatedCount: generated, reusedCount: reused, failure: "Could not persist validated routing pack: \(error.localizedDescription)")
        }
        return .init(
            pack: pack,
            generatedCount: generated,
            reusedCount: reused,
            failure: nil,
            warnings: gate.warnings
        )
    }

    private func generateCard(
        for seed: VoiceRoutingSeed,
        didCompleteGenerationUnit: @escaping @Sendable () -> Void
    ) async throws -> VoiceRoutingCard {
        let positivePrompt = positiveRoutingPrompt(seed)
        async let proposedSpeech = generateSpeechProposal(
            prompt: positivePrompt,
            didComplete: didCompleteGenerationUnit
        )
        async let proposedTags = generateTagProposal(
            prompt: positivePrompt,
            didComplete: didCompleteGenerationUnit
        )
        async let proposedContrasts = generateContrastProposal(
            prompt: contrastRoutingPrompt(seed),
            didComplete: didCompleteGenerationUnit
        )
        async let proposedLexicalAlternatives = generateLexicalAlternativesOrEmpty(
            for: seed,
            didComplete: didCompleteGenerationUnit
        )
        async let proposedArtifactHeads = generateArtifactHeadsOrEmpty(
            for: seed,
            didComplete: didCompleteGenerationUnit
        )
        let (proposal, tagProposal, contrasts, lexicalProposal, artifactHeadProposal) = try await (
            proposedSpeech,
            proposedTags,
            proposedContrasts,
            proposedLexicalAlternatives,
            proposedArtifactHeads
        )
        let canonicalIdentityAliases = canonicalIdentityPhrase(
            from: proposal.canonicalIdentitySubset,
            seed: seed
        ).map { [$0] } ?? []
        let groundedCompounds = modelGroundedConsensusCompounds(
            seed: seed,
            lexicalAlternativePasses: lexicalProposal.passes,
            independentProposalChannels: [
                lexicalProposal.alternatives,
                canonicalIdentityAliases + proposal.semanticAliases
                    + proposal.phraseFamilyVariants + proposal.artifactTypes,
                tagProposal.topicTags + tagProposal.artifactTypes,
                artifactHeadProposal.heads,
            ]
        )
        let semanticCandidates = uniqueNormalized(
            proposal.semanticAliases + proposal.phraseFamilyVariants
                + lexicalProposal.alternatives + groundedCompounds
        )
        let verifiedSemanticRelations = await verifySemanticRelationsOrEmpty(
            candidates: semanticCandidates,
            for: seed,
            didComplete: didCompleteGenerationUnit
        )
        let canonical = sanitized([seed.canonicalName] + seed.existingAliases, maximumCount: 16, allowGenericSingleton: true)
        let canonicalSet = Set(canonical.map(PhraseMatcher.normalize))
        let proposedAliases = canonicalIdentityAliases + proposal.semanticAliases
            + lexicalProposal.alternatives + groundedCompounds
        let aliases = sanitized(proposedAliases, maximumCount: 12).filter { !canonicalSet.contains(PhraseMatcher.normalize($0)) }
        let phraseFamilies = sanitized(proposal.phraseFamilyVariants, maximumCount: 12)
        let tags = sanitized(tagProposal.topicTags, maximumCount: 12)
        let artifactTypes = sanitized(
            proposal.artifactTypes + tagProposal.artifactTypes + artifactHeadProposal.heads,
            maximumCount: 12
        )
        let utterances = sanitized(proposal.representativeUtterances, maximumCount: 8, minimumWords: 2, maximumWords: 14)
        let negativeCandidates = sanitizedGeneratedPhrases(
            contrasts.hardNegatives,
            origin: .hardNegative,
            maximumCount: 8,
            minimumWords: 2,
            maximumWords: 14
        )
        let confuserCandidates = sanitizedGeneratedPhrases(
            contrasts.confusableConcepts + seed.contextOnlyChildNames,
            origin: .confuser,
            maximumCount: 12,
            minimumWords: 1,
            maximumWords: 8
        )
        let hardNegatives = negativeCandidates.accepted
        let confusers = confuserCandidates.accepted
        let generated = generatedTriggerCandidates(
            seed: seed,
            shortenedCanonicalForms: canonicalIdentityAliases,
            semanticAliases: proposal.semanticAliases + lexicalProposal.alternatives,
            phraseFamilies: proposal.phraseFamilyVariants,
            topicTags: tagProposal.topicTags,
            artifactTypes: proposal.artifactTypes + tagProposal.artifactTypes + artifactHeadProposal.heads,
            representativeUtterances: proposal.representativeUtterances,
            verifiedSemanticRelations: verifiedSemanticRelations,
            consensusArtifactVocabulary: Set(groundedCompounds.map(PhraseMatcher.normalize)),
            lexicalAlternativePasses: lexicalProposal.passes
        )
        return VoiceRoutingCard(
            nodeID: seed.nodeID,
            title: seed.canonicalName,
            evidenceHash: seed.evidenceHash,
            canonicalPhrases: canonical,
            semanticAliases: aliases + phraseFamilies.filter { !canonicalSet.contains(PhraseMatcher.normalize($0)) },
            topicTags: tags,
            artifactTypes: artifactTypes,
            representativeUtterances: utterances,
            hardNegatives: hardNegatives,
            confusableConcepts: confusers,
            activeTriggers: generated.accepted,
            descriptiveVocabulary: uniqueNormalized(aliases + phraseFamilies + tags + artifactTypes + utterances + hardNegatives + confusers),
            rejectedTriggers: generated.rejected + negativeCandidates.rejected + confuserCandidates.rejected,
            proposalProvenance: .init(lexicalAlternativePasses: lexicalProposal.passes)
        )
    }

    /// Contrastive hierarchy is isolated in a negative-only prompt. Nothing
    /// generated by this session is eligible to become a positive trigger.
    private func contrastRoutingPrompt(_ seed: VoiceRoutingSeed) -> String {
        """
        Target context: \(seed.canonicalName)
        Existing aliases: \(joined(seed.existingAliases))
        Context-only ancestor names: \(joined(seed.contextOnlyAncestry))
        Context-only immediate child names: \(joined(seed.contextOnlyChildNames))

        Produce only confusable concepts and hard-negative utterances. Ancestor and child names belong to other routing scopes and must never be proposed as positive vocabulary for the target.
        """
    }

    private func generateSpeechProposal(
        prompt: String,
        didComplete: @escaping @Sendable () -> Void
    ) async throws -> PositiveProposal {
        defer { didComplete() }
        let session = LanguageModelSession(model: languageModel, instructions: """
        You compile positive spoken routing vocabulary for one grounded context in an on-device personal context engine. Use only the supplied node identity and direct evidence. Produce natural names, conventional synonyms, inflections, and paraphrases a person would actually say, including obvious shortened forms of the canonical name. Never emit paths, URLs, identifiers, frontmatter, boilerplate, or generic conversational words.
        """)
        return try await session.respond(
            to: prompt,
            generating: PositiveProposal.self,
            options: GenerationOptions(sampling: .greedy)
        ).content
    }

    private func generateContrastProposal(
        prompt: String,
        didComplete: @escaping @Sendable () -> Void
    ) async throws -> ContrastProposal {
        defer { didComplete() }
        let session = LanguageModelSession(model: languageModel, instructions: """
        You generate negative routing boundaries for one grounded personal context. Return only concepts and utterances that must abstain or route to an ancestor, child, sibling, or nearby meaning. Never propose positive aliases. Never emit paths, URLs, identifiers, frontmatter, or boilerplate.
        """)
        return try await session.respond(
            to: prompt,
            generating: ContrastProposal.self,
            options: GenerationOptions(sampling: .greedy)
        ).content
    }

    private func generateLexicalAlternatives(
        for seed: VoiceRoutingSeed,
        sampling: GenerationOptions.SamplingMode
    ) async throws -> LexicalAlternativeProposal {
        let session = LanguageModelSession(model: languageModel, instructions: """
        Act as a precise spoken thesaurus for one context name. Return concise nouns or noun phrases that can replace the target while preserving its referent. Actively seek common different-root synonyms and established compact names, not repetitions or grammatical inflections of the target. Do not make variants by merely appending words such as session, time, system, app, tool, workflow, knowledge, or project. Do not return associated subjects, examples, parents, children, contents, or broader categories. Return an empty list when no safe equivalent exists.
        """)
        return try await session.respond(
            to: """
            Target canonical identity: \(seed.canonicalName)
            Existing aliases: \(joined(seed.existingAliases))
            Direct artifact titles: \(joined(seed.directArtifactTitles))
            Direct headings and tags: \(joined(seed.directHeadingsAndTags))
            Bounded direct semantic context: \(joined(Array(seed.directExcerpts.prefix(3))))
            """,
            generating: LexicalAlternativeProposal.self,
            options: GenerationOptions(sampling: sampling)
        ).content
    }

    private func generateLexicalAlternativesOrEmpty(
        for seed: VoiceRoutingSeed,
        didComplete: @escaping @Sendable () -> Void
    ) async -> LexicalAlternativeEnsemble {
        async let greedy = lexicalAlternativesAttempt(
            for: seed,
            sampling: .greedy,
            didComplete: didComplete
        )
        async let seededA = lexicalAlternativesAttempt(
            for: seed,
            sampling: .random(probabilityThreshold: 0.90, seed: 0x5eed_0001),
            didComplete: didComplete
        )
        async let seededB = lexicalAlternativesAttempt(
            for: seed,
            sampling: .random(probabilityThreshold: 0.90, seed: 0x5eed_0002),
            didComplete: didComplete
        )
        let proposals = await [greedy, seededA, seededB]
        if proposals.allSatisfy({ $0 == nil }) {
            Log.speech.info("voice_compiler_lexical_proposal_unavailable")
        }
        return .init(passes: proposals.map { proposal in
            Array(uniqueNormalized(proposal?.alternatives ?? []).prefix(12))
        })
    }

    private func lexicalAlternativesAttempt(
        for seed: VoiceRoutingSeed,
        sampling: GenerationOptions.SamplingMode,
        didComplete: @escaping @Sendable () -> Void
    ) async -> LexicalAlternativeProposal? {
        defer { didComplete() }
        return try? await generateLexicalAlternatives(for: seed, sampling: sampling)
    }

    /// A second, focused model pass may propose a semantic relation, but it
    /// cannot activate arbitrary text: deterministic code only accepts exact
    /// members of the bounded candidate set, then applies context-only,
    /// collision, and production-router validation. Hierarchy is deliberately
    /// absent from this session.
    private func verifySemanticRelationsOrEmpty(
        candidates: [String],
        for seed: VoiceRoutingSeed,
        didComplete: @escaping @Sendable () -> Void
    ) async -> Set<String> {
        defer { didComplete() }
        let validCandidates = sanitized(candidates, maximumCount: 24, maximumWords: 8)
        guard !validCandidates.isEmpty else { return [] }
        let groundingPhrases = uniqueNormalized(
            [seed.canonicalName] + seed.existingAliases
                + seed.directArtifactTitles + seed.directHeadingsAndTags
        ).filter { !$0.isEmpty }.prefix(40).map { $0 }
        guard !groundingPhrases.isEmpty else { return [] }

        let session = LanguageModelSession(model: languageModel, instructions: """
        Verify lexical equivalence conservatively. Accept a pair only when the candidate and grounding phrase name the same concept through conventional synonymy, abbreviation, inflection, spelling, or a meaning-preserving shortened proper name. Association is not equivalence: reject related topics, examples, containers, contents, parents, children, and phrases sharing only one word. Copy both phrases exactly from their supplied lists. Return an empty list when uncertain.
        """)
        let response: SemanticRelationVerification
        do {
            response = try await session.respond(
                to: """
                Target canonical identity: \(seed.canonicalName)
                Candidate phrases: \(joined(validCandidates))
                Allowed identity or direct-evidence grounding phrases: \(joined(groundingPhrases))

                Select every candidate that is another conventional spoken name for the target itself. A candidate need not share words with the target. Do not select phrases that merely describe its subject matter, contents, location, parent, child, or use case.
                """,
                generating: SemanticRelationVerification.self,
                options: GenerationOptions(sampling: .greedy)
            ).content
        } catch {
            Log.speech.info("voice_compiler_semantic_verification_unavailable")
            return []
        }

        let candidateSet = Set(validCandidates.map(PhraseMatcher.normalize))
        return Set(response.acceptedCandidatePhrases.compactMap { phrase in
            let candidate = PhraseMatcher.normalize(phrase)
            return candidateSet.contains(candidate) ? candidate : nil
        })
    }

    private func generateTagProposal(
        prompt: String,
        didComplete: @escaping @Sendable () -> Void
    ) async throws -> TagProposal {
        defer { didComplete() }
        let session = LanguageModelSession(model: taggingModel, instructions: """
        Produce concise, evidence-grounded content tags for one personal context. Prefer discriminative labels over broad associations. Child context names are confusers, not evidence for the parent.
        """)
        return try await session.respond(
            to: prompt,
            generating: TagProposal.self,
            options: GenerationOptions(sampling: .greedy)
        ).content
    }

    private func generateArtifactHeadsOrEmpty(
        for seed: VoiceRoutingSeed,
        didComplete: @escaping @Sendable () -> Void
    ) async -> ArtifactHeadProposal {
        defer { didComplete() }
        let session = LanguageModelSession(model: taggingModel, instructions: """
        Extract concise artifact or container head nouns for one context. Return only one-word type nouns directly supported by the identity or evidence, such as the kind of system, method, collection, or record represented. Do not return subject topics, properties, actions, parents, or children. Return an empty list when no type is supported.
        """)
        do {
            return try await session.respond(
                to: """
                Canonical identity: \(seed.canonicalName)
                Existing aliases: \(joined(seed.existingAliases))
                Direct artifact titles: \(joined(seed.directArtifactTitles))
                Direct headings and tags: \(joined(seed.directHeadingsAndTags))
                Bounded direct semantic context: \(joined(Array(seed.directExcerpts.prefix(3))))
                """,
                generating: ArtifactHeadProposal.self,
                options: GenerationOptions(sampling: .greedy)
            ).content
        } catch {
            Log.speech.info("voice_compiler_artifact_proposal_unavailable")
            return .init(heads: [])
        }
    }

}

struct GeneratedTriggerCandidates {
    var accepted: [VoiceRoutingTrigger]
    var rejected: [VoiceRoutingRejectedTrigger]
}

private struct SanitizedGeneratedPhrases {
    var accepted: [String]
    var rejected: [VoiceRoutingRejectedTrigger]
}

/// Global, deterministic validation shared by fresh and cached model proposals.
/// Cache entries remain proposals; only the cards returned here may be activated.
struct VoiceRoutingCompilerValidator: Sendable {
    func validate(
        _ proposedPack: VoiceRoutingPack,
        seeds: [VoiceRoutingSeed],
        progress: @Sendable (VoiceRoutingCompilationProgress) -> Void = { _ in }
    ) -> VoiceRoutingPack {
        let seedByNodeID = Dictionary(uniqueKeysWithValues: seeds.map { ($0.nodeID, $0) })
        var pack = proposedPack
        let validationUnitsByNodeID = Dictionary(uniqueKeysWithValues: pack.cards.map { card in
            (card.nodeID, card.activeTriggers.count)
        })
        let totalValidationUnits = max(validationUnitsByNodeID.values.reduce(0, +) * 5, 1)
        var completedValidationUnits = 0
        var lastReportedValidationUnits = 0
        let validationReportingStride = max(totalValidationUnits / 200, 1)
        func didProcessCard(_ nodeID: String) {
            completedValidationUnits = min(
                completedValidationUnits + validationUnitsByNodeID[nodeID, default: 0],
                totalValidationUnits
            )
            if completedValidationUnits - lastReportedValidationUnits >= validationReportingStride
                || completedValidationUnits == totalValidationUnits {
                lastReportedValidationUnits = completedValidationUnits
                progress(.init(
                    stage: .validatingPhraseChecks,
                    completed: completedValidationUnits,
                    total: totalValidationUnits
                ))
            }
        }
        progress(.init(stage: .validatingPhraseChecks, completed: 0, total: totalValidationUnits))
        pack.cards = removeSelfBlockingNegatives(pack.cards, seedByNodeID: seedByNodeID)
        let collisionResolution = resolveTriggerCollisions(
            pack.cards,
            seedByNodeID: seedByNodeID,
            in: pack
        )
        pack.cards = collisionResolution.cards
        pack.sharedConcepts = collisionResolution.sharedConcepts
        pack = enrichSharedConceptsWithRuntimeEvidence(pack)
        pack = promoteRuntimeAmbiguities(pack, didProcessCard: didProcessCard)
        pack.cards = retainProductionRoutableTriggers(pack.cards, in: pack, didProcessCard: didProcessCard)
        pack.cards = retainAbstainingNegatives(pack.cards, in: pack)
        pack.cards = applyRegressionBlockers(pack.cards, in: pack)
        // Removing a negative can expose an overlapping candidate that was
        // blocked during the first routing pass. Re-run production validation
        // against the final negative set so that one newly ambiguous trigger is
        // quarantined instead of rejecting the otherwise safe immutable pack.
        pack = promoteRuntimeAmbiguities(pack, didProcessCard: didProcessCard)
        pack.cards = retainProductionRoutableTriggers(pack.cards, in: pack, didProcessCard: didProcessCard)
        pack = finalizeSharedConcepts(pack)
        pack.cards = retainProductionRoutableTriggers(pack.cards, in: pack, didProcessCard: didProcessCard)
        progress(.init(
            stage: .validatingPhraseChecks,
            completed: totalValidationUnits,
            total: totalValidationUnits
        ))
        return pack
    }

    private struct CollisionEntry {
        var nodeID: String
        var trigger: VoiceRoutingTrigger
    }

    private struct CollisionResolution {
        var cards: [VoiceRoutingCard]
        var sharedConcepts: [VoiceRoutingSharedConcept]
    }

    private enum CollisionDecision {
        case uniqueWinner(
            nodeID: String,
            trigger: VoiceRoutingTrigger,
            rejectionReasons: [String: VoiceRoutingRejectionReason]
        )
        case shared(VoiceRoutingSharedConcept, validNodeIDs: Set<String>, invalidReasons: [String: VoiceRoutingRejectionReason])
        case rejected([String: VoiceRoutingRejectionReason])
    }

    private func applyRegressionBlockers(
        _ cards: [VoiceRoutingCard],
        in proposedPack: VoiceRoutingPack
    ) -> [VoiceRoutingCard] {
        var working = cards
        let expectedNodeIDByTitle = Dictionary(grouping: cards) {
            PhraseMatcher.normalize($0.title)
        }.compactMapValues { groupedCards -> String? in
            let nodeIDs = Set(groupedCards.map(\.nodeID))
            return nodeIDs.count == 1 ? nodeIDs.first : nil
        }

        // Blocking a wrong winner can reveal another one. Iterate monotonically
        // until every fixed negative abstains and positive probes either reach
        // their intended owner or safely abstain.
        for _ in 0...cards.count {
            var candidatePack = proposedPack
            candidatePack.cards = working
            let baseTargets = working.flatMap { card in
                card.canonicalPhrases.map {
                    MatchTarget(phrase: $0, ref: .node(card.nodeID), title: card.title)
                }
            }
            let router = VoiceRoutingRuntimeRouter(baseTargets: baseTargets, pack: candidatePack)
            let proposalRouter = VoiceRoutingRuntimeRouter(baseTargets: [], pack: candidatePack)
            var blockersByNodeID: [String: Set<String>] = [:]

            for utterance in VoiceRoutingRegressionCorpus.negative {
                for match in proposalRouter.matches(in: utterance) {
                    guard case .node(let nodeID) = match.target.ref else { continue }
                    blockersByNodeID[nodeID, default: []].insert(PhraseMatcher.normalize(utterance))
                }
                for concept in proposalRouter.sharedMatches(in: utterance) {
                    for nodeID in concept.candidateNodeIDs {
                        blockersByNodeID[nodeID, default: []].insert(PhraseMatcher.normalize(utterance))
                    }
                }
            }
            for regression in VoiceRoutingRegressionCorpus.positive {
                guard let expectedNodeID = expectedNodeIDByTitle[regression.canonicalTitle] else { continue }
                for match in router.matches(in: regression.utterance) {
                    guard !match.trigger.origin.isDeterministicIdentity,
                          case .node(let nodeID) = match.target.ref, nodeID != expectedNodeID else { continue }
                    blockersByNodeID[nodeID, default: []].insert(validationUtterance(for: match.trigger.pattern))
                }
                for concept in router.sharedMatches(in: regression.utterance)
                    where !concept.candidateNodeIDs.contains(expectedNodeID) {
                    for match in concept.candidates where !match.trigger.origin.isDeterministicIdentity {
                        guard case .node(let nodeID) = match.target.ref else { continue }
                        blockersByNodeID[nodeID, default: []].insert(PhraseMatcher.normalize(regression.utterance))
                    }
                }
            }

            guard !blockersByNodeID.isEmpty else { break }
            var changed = false
            working = working.map { card in
                guard let additions = blockersByNodeID[card.nodeID], !additions.isEmpty else { return card }
                var next = card
                var existing = Set(next.hardNegatives.map(PhraseMatcher.normalize))
                for phrase in additions.sorted() where existing.insert(phrase).inserted {
                    next.hardNegatives.append(phrase)
                    changed = true
                }
                return next
            }
            if !changed { break }
        }
        return working
    }

    private func removeSelfBlockingNegatives(
        _ cards: [VoiceRoutingCard],
        seedByNodeID: [String: VoiceRoutingSeed]
    ) -> [VoiceRoutingCard] {
        cards.map { card in
            var next = card
            let positivePhrases = Set(
                (card.canonicalPhrases + card.activeTriggers.map { validationUtterance(for: $0.pattern) })
                    .map(PhraseMatcher.normalize)
            )
            let contextOnly = Set(
                (seedByNodeID[card.nodeID]?.contextOnlyAncestry ?? []
                    + (seedByNodeID[card.nodeID]?.contextOnlyChildNames ?? []))
                    .map(PhraseMatcher.normalize)
            )

            func retain(_ phrase: String, origin: VoiceRoutingTriggerOrigin) -> Bool {
                let normalized = PhraseMatcher.normalize(phrase)
                // A shorter confuser such as "brain" must not disable the
                // owner's positive "second brain" phrase. A longer negative
                // such as "weather diary" remains a useful scoped blocker.
                if positivePhrases.contains(where: { phraseContains($0, normalized) }) {
                    next.rejectedTriggers.append(.init(phrase: phrase, origin: origin, reason: .negativeDidNotAbstain))
                    return false
                }
                // Hierarchy-provided confusers are valid by construction. The
                // explicit check documents why they are not positive evidence.
                if origin == .confuser, contextOnly.contains(normalized) { return true }
                return true
            }

            next.hardNegatives = card.hardNegatives.filter { retain($0, origin: .hardNegative) }
            next.confusableConcepts = card.confusableConcepts.filter { retain($0, origin: .confuser) }
            return next
        }
    }

    private func resolveTriggerCollisions(
        _ cards: [VoiceRoutingCard],
        seedByNodeID: [String: VoiceRoutingSeed],
        in proposedPack: VoiceRoutingPack
    ) -> CollisionResolution {
        let entriesByKey = Dictionary(grouping: cards.flatMap { card in
            card.activeTriggers.map { CollisionEntry(nodeID: card.nodeID, trigger: $0) }
        }, by: { triggerKey($0.trigger) })
        let canonicalByNode = Dictionary(uniqueKeysWithValues: cards.map {
            ($0.nodeID, Set($0.canonicalPhrases.flatMap(routingTerms)))
        })
        var decisions: [String: CollisionDecision] = [:]

        for (key, entries) in entriesByKey where Set(entries.map(\.nodeID)).count > 1 {
            let entriesByOwner = Dictionary(grouping: entries, by: \.nodeID)
            let owners = Set(entriesByOwner.keys)
            let representative = bestCollisionEntry(in: entries)
            let terms = Set(patternTerms(representative.trigger.pattern))
            let canonicalOwners = owners.filter { owner in
                terms.count >= 2 && terms.isSubset(of: canonicalByNode[owner, default: []])
            }
            if canonicalOwners.count == 1, let owner = canonicalOwners.first,
               let winner = entriesByOwner[owner].flatMap(bestCollisionEntry(in:)) {
                decisions[key] = .uniqueWinner(nodeID: owner, trigger: winner.trigger, rejectionReasons: [:])
                continue
            }

            let priorityByOwner = Dictionary(uniqueKeysWithValues: owners.map {
                ($0, routingSpecificity(seedByNodeID[$0]?.kind))
            })
            let highestPriority = priorityByOwner.values.max() ?? 0
            let mostSpecificOwners = owners.filter { priorityByOwner[$0] == highestPriority }
            if mostSpecificOwners.count == 1, let owner = mostSpecificOwners.first,
               entriesByOwner[owner, default: []].contains(where: { $0.trigger.origin == .consensusArtifactVocabulary }),
               let winner = entriesByOwner[owner].flatMap(bestCollisionEntry(in:)) {
                decisions[key] = .uniqueWinner(nodeID: owner, trigger: winner.trigger, rejectionReasons: [:])
                continue
            }

            var validEntries: [CollisionEntry] = []
            var invalidReasons: [String: VoiceRoutingRejectionReason] = [:]
            var outcomesByOwner: [String: VoiceRoutingTriggerValidationOutcome] = [:]
            for owner in owners.sorted() {
                guard let candidate = entriesByOwner[owner].flatMap(bestCollisionEntry(in:)) else { continue }
                let result = validateCollisionCandidate(
                    candidate,
                    triggerKey: key,
                    cards: cards,
                    proposedPack: proposedPack
                )
                outcomesByOwner[owner] = result.outcome
                if result.outcome == .accepted || result.outcome == .ambiguous {
                    validEntries.append(candidate)
                } else {
                    invalidReasons[owner] = rejectionReason(for: result.outcome)
                }
            }

            logFixedPositiveCollisionDiagnostic(
                pattern: representative.trigger.pattern,
                entries: entries,
                outcomesByOwner: outcomesByOwner,
                cards: cards,
                proposedPack: proposedPack
            )

            if validEntries.count >= 2 {
                let pattern = representative.trigger.pattern
                let concept = VoiceRoutingSharedConcept(
                    id: VoiceRoutingSharedConcept.stableID(for: pattern),
                    pattern: pattern,
                    candidates: validEntries.sorted { $0.nodeID < $1.nodeID }.compactMap { entry in
                        guard let card = cards.first(where: { $0.nodeID == entry.nodeID }) else { return nil }
                        return VoiceRoutingConceptCandidateEdge(
                            nodeID: entry.nodeID,
                            compiledStrength: entry.trigger.score,
                            origin: entry.trigger.origin,
                            evidenceHash: card.evidenceHash
                        )
                    }
                )
                decisions[key] = .shared(
                    concept,
                    validNodeIDs: Set(validEntries.map(\.nodeID)),
                    invalidReasons: invalidReasons
                )
            } else if let survivor = validEntries.first {
                decisions[key] = .uniqueWinner(
                    nodeID: survivor.nodeID,
                    trigger: survivor.trigger,
                    rejectionReasons: invalidReasons
                )
            } else {
                decisions[key] = .rejected(invalidReasons)
            }
        }

        let resolvedCards = cards.map { card in
            var next = card
            var rejected = card.rejectedTriggers
            var emittedWinnerKeys = Set<String>()
            next.activeTriggers = card.activeTriggers.compactMap { trigger in
                let key = triggerKey(trigger)
                guard let decision = decisions[key] else { return trigger }
                switch decision {
                case .uniqueWinner(let nodeID, let winningTrigger, let rejectionReasons):
                    guard nodeID == card.nodeID, emittedWinnerKeys.insert(key).inserted else {
                        rejected.append(.init(
                            phrase: trigger.pattern.displayPhrase,
                            origin: trigger.origin,
                            reason: rejectionReasons[card.nodeID] ?? .collision
                        ))
                        return nil
                    }
                    return winningTrigger
                case .shared(_, let validNodeIDs, let invalidReasons):
                    if !validNodeIDs.contains(card.nodeID) {
                        rejected.append(.init(
                            phrase: trigger.pattern.displayPhrase,
                            origin: trigger.origin,
                            reason: invalidReasons[card.nodeID] ?? .collision
                        ))
                    }
                    return nil
                case .rejected(let invalidReasons):
                    rejected.append(.init(
                        phrase: trigger.pattern.displayPhrase,
                        origin: trigger.origin,
                        reason: invalidReasons[card.nodeID] ?? .collision
                    ))
                    return nil
                }
            }
            next.rejectedTriggers = rejected
            return next
        }
        let concepts = decisions.values.compactMap { decision -> VoiceRoutingSharedConcept? in
            guard case .shared(let concept, _, _) = decision else { return nil }
            return concept
        }.sorted { $0.id < $1.id }
        return .init(cards: resolvedCards, sharedConcepts: concepts)
    }

    private func finalizeSharedConcepts(_ proposedPack: VoiceRoutingPack) -> VoiceRoutingPack {
        var pack = proposedPack
        var retained: [VoiceRoutingSharedConcept] = []
        for concept in proposedPack.sharedConcepts {
            // A title fragment may coincide with a generic utterance, but must not
            // promote that whole utterance into model-generated routing vocabulary.
            guard !matchesFixedNegative(concept.pattern) else { continue }
            let validation = concept.candidates.map { edge in
                (edge, VoiceRoutingSharedConceptValidator().validate(
                    candidate: edge,
                    concept: concept,
                    pack: pack
                ).outcome)
            }
            let validCandidates = validation.compactMap { edge, outcome in
                outcome == .accepted ? edge : nil
            }
            if validCandidates.count >= 2 {
                var next = concept
                next.candidates = validCandidates
                retained.append(next)
                logFixedPositiveConceptStage(
                    "finalized-retained",
                    concept: next,
                    validation: validation,
                    cards: pack.cards
                )
            } else if let survivor = validCandidates.first,
                      let index = pack.cards.firstIndex(where: { $0.nodeID == survivor.nodeID }) {
                let trigger = VoiceRoutingTrigger(
                    pattern: concept.pattern,
                    origin: survivor.origin,
                    score: survivor.compiledStrength
                )
                if !pack.cards[index].activeTriggers.contains(where: { triggerKey($0) == triggerKey(trigger) }) {
                    pack.cards[index].activeTriggers.append(trigger)
                }
                logFixedPositiveConceptStage(
                    "finalized-singleton-restored",
                    concept: concept,
                    validation: validation,
                    cards: pack.cards
                )
            } else {
                logFixedPositiveConceptStage(
                    "finalized-removed",
                    concept: concept,
                    validation: validation,
                    cards: pack.cards
                )
            }
        }
        pack.sharedConcepts = retained.sorted { $0.id < $1.id }
        return pack
    }

    private func enrichSharedConceptsWithRuntimeEvidence(
        _ proposedPack: VoiceRoutingPack
    ) -> VoiceRoutingPack {
        guard !proposedPack.sharedConcepts.isEmpty else { return proposedPack }
        var pack = proposedPack
        let baseTargets = pack.cards.flatMap { card in
            card.canonicalPhrases.map {
                MatchTarget(phrase: $0, ref: .node(card.nodeID), title: card.title)
            }
        }
        let router = VoiceRoutingRuntimeRouter(baseTargets: baseTargets, pack: pack)
        let cardByNodeID = Dictionary(uniqueKeysWithValues: pack.cards.map { ($0.nodeID, $0) })
        pack.sharedConcepts = pack.sharedConcepts.map { concept in
            let fullPatternStrength = concept.candidates.map(\.compiledStrength).max()
                ?? VoiceRoutingScorer.minimumScore
            let contextualCeiling = max(
                VoiceRoutingScorer.minimumScore,
                fullPatternStrength - 0.02
            )
            let evidence = router.evidencedCandidates(
                in: validationUtterance(for: concept.pattern),
                overlapping: concept.pattern
            )
            let contextualEdges = evidence.compactMap { evidence -> VoiceRoutingConceptCandidateEdge? in
                let match = evidence.match
                guard case .node(let nodeID) = match.target.ref,
                      !concept.candidates.contains(where: { $0.nodeID == nodeID }),
                      let card = cardByNodeID[nodeID] else { return nil }
                let edge = VoiceRoutingConceptCandidateEdge(
                    nodeID: nodeID,
                    compiledStrength: evidence.hasExactOriginSpan
                        ? match.score
                        : min(match.score, contextualCeiling),
                    origin: match.trigger.origin,
                    evidenceHash: card.evidenceHash
                )
                return edge.hasPositiveOrigin ? edge : nil
            }
            var enriched = concept
            enriched.candidates = bestConceptEdgesByNodeID(concept.candidates + contextualEdges)
            logFixedPositiveConceptStage(
                contextualEdges.isEmpty ? "collision-enrichment-no-new-edges" : "collision-enriched",
                concept: enriched,
                validation: [],
                cards: pack.cards,
                evidence: evidence
            )
            return enriched
        }.sorted { $0.id < $1.id }
        return pack
    }

    private func promoteRuntimeAmbiguities(
        _ proposedPack: VoiceRoutingPack,
        didProcessCard: (String) -> Void
    ) -> VoiceRoutingPack {
        var pack = proposedPack
        let baseTargets = pack.cards.flatMap { card in
            card.canonicalPhrases.map {
                MatchTarget(phrase: $0, ref: .node(card.nodeID), title: card.title)
            }
        }
        let router = VoiceRoutingRuntimeRouter(baseTargets: baseTargets, pack: pack)
        let cardByNodeID = Dictionary(uniqueKeysWithValues: pack.cards.map { ($0.nodeID, $0) })
        var conceptsByID = Dictionary(uniqueKeysWithValues: pack.sharedConcepts.map { ($0.id, $0) })
        var removedTriggerKeysByNodeID: [String: Set<String>] = [:]

        for card in pack.cards.sorted(by: { $0.nodeID < $1.nodeID }) {
            for trigger in card.activeTriggers.sorted(by: deterministicTriggerOrder) {
                let utterance = validationUtterance(for: trigger.pattern)
                let outcome = router.validate(utterance: utterance, expectedNodeID: card.nodeID).outcome
                guard outcome == .ambiguous else { continue }
                if matchesFixedNegative(trigger.pattern) {
                    logFixedPositiveRuntimePromotion(
                        stage: "runtime-promotion-blocked-fixed-negative",
                        owner: card,
                        trigger: trigger,
                        evidence: [],
                        cards: pack.cards
                    )
                    continue
                }
                let runtimeEvidence = router.evidencedCandidates(
                    in: utterance,
                    overlapping: trigger.pattern
                )
                let candidates = runtimeEvidence.compactMap { evidence -> VoiceRoutingConceptCandidateEdge? in
                    let match = evidence.match
                    guard case .node(let nodeID) = match.target.ref,
                          let candidateCard = cardByNodeID[nodeID] else { return nil }
                    let isOriginatingOwner = nodeID == card.nodeID
                    let contextualCeiling = max(
                        VoiceRoutingScorer.minimumScore,
                        trigger.score - 0.02
                    )
                    let edge = VoiceRoutingConceptCandidateEdge(
                        nodeID: nodeID,
                        compiledStrength: isOriginatingOwner
                            ? trigger.score
                            : (evidence.hasExactOriginSpan ? match.score : min(match.score, contextualCeiling)),
                        origin: isOriginatingOwner ? trigger.origin : match.trigger.origin,
                        evidenceHash: candidateCard.evidenceHash
                    )
                    return edge.hasPositiveOrigin ? edge : nil
                }
                let uniqueCandidates = bestConceptEdgesByNodeID(candidates)
                guard uniqueCandidates.count >= 2,
                      uniqueCandidates.contains(where: { $0.nodeID == card.nodeID }) else {
                    logFixedPositiveRuntimePromotion(
                        stage: "runtime-promotion-insufficient-edges",
                        owner: card,
                        trigger: trigger,
                        evidence: runtimeEvidence,
                        cards: pack.cards
                    )
                    continue
                }

                let conceptID = VoiceRoutingSharedConcept.stableID(for: trigger.pattern)
                let existing = conceptsByID[conceptID]
                let mergedCandidates = bestConceptEdgesByNodeID(
                    (existing?.candidates ?? []) + uniqueCandidates
                )
                conceptsByID[conceptID] = VoiceRoutingSharedConcept(
                    id: conceptID,
                    pattern: existing?.pattern ?? trigger.pattern,
                    candidates: mergedCandidates
                )
                removedTriggerKeysByNodeID[card.nodeID, default: []].insert(triggerKey(trigger))
                logFixedPositiveRuntimePromotion(
                    stage: "runtime-promoted",
                    owner: card,
                    trigger: trigger,
                    evidence: runtimeEvidence,
                    cards: pack.cards
                )
            }
            didProcessCard(card.nodeID)
        }

        pack.cards = pack.cards.map { card in
            var next = card
            let removed = removedTriggerKeysByNodeID[card.nodeID, default: []]
            next.activeTriggers.removeAll { removed.contains(triggerKey($0)) }
            return next
        }
        pack.sharedConcepts = conceptsByID.values.sorted { $0.id < $1.id }
        return pack
    }

    private func bestConceptEdgesByNodeID(
        _ edges: [VoiceRoutingConceptCandidateEdge]
    ) -> [VoiceRoutingConceptCandidateEdge] {
        var bestByNodeID: [String: VoiceRoutingConceptCandidateEdge] = [:]
        for edge in edges {
            if let current = bestByNodeID[edge.nodeID] {
                if current.compiledStrength > edge.compiledStrength { continue }
                if current.compiledStrength == edge.compiledStrength,
                   current.origin.rawValue <= edge.origin.rawValue { continue }
            }
            bestByNodeID[edge.nodeID] = edge
        }
        return bestByNodeID.values.sorted {
            if $0.compiledStrength != $1.compiledStrength {
                return $0.compiledStrength > $1.compiledStrength
            }
            return $0.nodeID < $1.nodeID
        }
    }

    private func deterministicTriggerOrder(
        _ lhs: VoiceRoutingTrigger,
        _ rhs: VoiceRoutingTrigger
    ) -> Bool {
        let lhsKey = triggerKey(lhs)
        let rhsKey = triggerKey(rhs)
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.origin.rawValue < rhs.origin.rawValue
    }

    private func matchesFixedNegative(_ pattern: VoiceRoutingTriggerPattern) -> Bool {
        let card = VoiceRoutingCard(
            nodeID: "fixed-negative-probe",
            title: "Fixed Negative Probe",
            evidenceHash: "fixed-negative-probe",
            canonicalPhrases: [],
            semanticAliases: [],
            topicTags: [],
            artifactTypes: [],
            representativeUtterances: [],
            hardNegatives: [],
            confusableConcepts: [],
            activeTriggers: [.init(pattern: pattern, origin: .phraseFamily, score: 1)]
        )
        let pack = VoiceRoutingPack(
            graphRevision: "fixed-negative-probe",
            compilerVersion: "fixed-negative-probe",
            modelVersion: "fixed-negative-probe",
            generatedAt: .distantPast,
            cards: [card]
        )
        let router = VoiceRoutingRuntimeRouter(baseTargets: [], pack: pack)
        return VoiceRoutingRegressionCorpus.negative.contains {
            !router.evidencedCandidates(in: $0, overlapping: pattern).isEmpty
        }
    }

    private func isFixedPositiveDiagnosticPattern(_ pattern: VoiceRoutingTriggerPattern) -> Bool {
        let terms = Set(patternTerms(pattern))
        guard terms.count >= 2 else { return false }
        return VoiceRoutingRegressionCorpus.positive.contains { regression in
            let fixedTerms = Set(routingTerms(regression.utterance))
            return fixedTerms.count >= 2
                && (fixedTerms.isSubset(of: terms) || terms.isSubset(of: fixedTerms))
        }
    }

    private func logFixedPositiveCollisionDiagnostic(
        pattern: VoiceRoutingTriggerPattern,
        entries: [CollisionEntry],
        outcomesByOwner: [String: VoiceRoutingTriggerValidationOutcome],
        cards: [VoiceRoutingCard],
        proposedPack: VoiceRoutingPack
    ) {
        guard isFixedPositiveDiagnosticPattern(pattern) else { return }
        Log.speech.debug("voice_routing_fixed_positive_diagnostic")
    }

    private func logFixedPositiveRuntimePromotion(
        stage: String,
        owner: VoiceRoutingCard,
        trigger: VoiceRoutingTrigger,
        evidence: [VoiceRoutingRuntimeEvidenceCandidate],
        cards: [VoiceRoutingCard]
    ) {
        guard isFixedPositiveDiagnosticPattern(trigger.pattern) else { return }
        Log.speech.debug("voice_routing_fixed_positive_diagnostic")
    }

    private func logFixedPositiveConceptStage(
        _ stage: String,
        concept: VoiceRoutingSharedConcept,
        validation: [(VoiceRoutingConceptCandidateEdge, VoiceRoutingTriggerValidationOutcome)],
        cards: [VoiceRoutingCard],
        evidence: [VoiceRoutingRuntimeEvidenceCandidate] = []
    ) {
        guard isFixedPositiveDiagnosticPattern(concept.pattern) else { return }
        Log.speech.debug("voice_routing_fixed_positive_diagnostic")
    }

    private func validateCollisionCandidate(
        _ candidate: CollisionEntry,
        triggerKey key: String,
        cards: [VoiceRoutingCard],
        proposedPack: VoiceRoutingPack
    ) -> VoiceRoutingTriggerValidation {
        let isolatedCards = cards.map { card in
            var next = card
            next.activeTriggers.removeAll { triggerKey($0) == key }
            if card.nodeID == candidate.nodeID { next.activeTriggers.append(candidate.trigger) }
            return next
        }
        // A missing owner is never a valid compiled edge.
        guard isolatedCards.contains(where: { $0.nodeID == candidate.nodeID }) else {
            return .init(outcome: .abstained, match: nil)
        }
        var isolatedPack = proposedPack
        isolatedPack.cards = isolatedCards
        isolatedPack.sharedConcepts.removeAll {
            triggerKey(.init(pattern: $0.pattern, origin: candidate.trigger.origin, score: candidate.trigger.score)) == key
        }
        let baseTargets = isolatedCards.flatMap { card in
            card.canonicalPhrases.map {
                MatchTarget(phrase: $0, ref: .node(card.nodeID), title: card.title)
            }
        }
        return VoiceRoutingRuntimeRouter(baseTargets: baseTargets, pack: isolatedPack).validate(
            utterance: validationUtterance(for: candidate.trigger.pattern),
            expectedNodeID: candidate.nodeID
        )
    }

    private func bestCollisionEntry(in entries: [CollisionEntry]) -> CollisionEntry {
        entries.sorted {
            if $0.trigger.score != $1.trigger.score { return $0.trigger.score > $1.trigger.score }
            if $0.trigger.origin.rawValue != $1.trigger.origin.rawValue {
                return $0.trigger.origin.rawValue < $1.trigger.origin.rawValue
            }
            return $0.nodeID < $1.nodeID
        }[0]
    }

    private func rejectionReason(for outcome: VoiceRoutingTriggerValidationOutcome) -> VoiceRoutingRejectionReason {
        switch outcome {
        case .accepted: .duplicate
        case .abstained, .ambiguous: .ambiguous
        case .wrongWinner: .wrongWinner
        case .blockedByNegative: .negativeDidNotAbstain
        }
    }

    private func retainProductionRoutableTriggers(
        _ cards: [VoiceRoutingCard],
        in proposedPack: VoiceRoutingPack,
        didProcessCard: (String) -> Void
    ) -> [VoiceRoutingCard] {
        var candidatePack = proposedPack
        candidatePack.cards = cards
        let baseTargets = cards.flatMap { card in
            card.canonicalPhrases.map {
                MatchTarget(phrase: $0, ref: .node(card.nodeID), title: card.title)
            }
        }
        let router = VoiceRoutingRuntimeRouter(baseTargets: baseTargets, pack: candidatePack)
        return cards.map { card in
            defer { didProcessCard(card.nodeID) }
            var next = card
            var rejected = card.rejectedTriggers
            next.activeTriggers = card.activeTriggers.filter { trigger in
                guard !matchesFixedNegative(trigger.pattern) else {
                    rejected.append(.init(phrase: trigger.pattern.displayPhrase, origin: trigger.origin, reason: .generic))
                    return false
                }
                let result = router.validate(
                    utterance: validationUtterance(for: trigger.pattern),
                    expectedNodeID: card.nodeID
                )
                guard result.outcome == .accepted else {
                    let reason: VoiceRoutingRejectionReason = switch result.outcome {
                    case .accepted: .duplicate
                    case .abstained, .ambiguous: .ambiguous
                    case .wrongWinner: .wrongWinner
                    case .blockedByNegative: .negativeDidNotAbstain
                    }
                    rejected.append(.init(phrase: trigger.pattern.displayPhrase, origin: trigger.origin, reason: reason))
                    return false
                }
                return true
            }
            next.rejectedTriggers = rejected
            return next
        }
    }

    private func retainAbstainingNegatives(
        _ cards: [VoiceRoutingCard],
        in proposedPack: VoiceRoutingPack
    ) -> [VoiceRoutingCard] {
        var activePack = proposedPack
        activePack.cards = cards
        // Negatives constrain optional proposals, not deterministic title evidence.
        let router = VoiceRoutingRuntimeRouter(baseTargets: [], pack: activePack)
        return cards.map { card in
            var next = card
            func retainHardNegative(_ phrase: String) -> Bool {
                guard router.matches(in: phrase).isEmpty, router.sharedMatches(in: phrase).isEmpty else {
                    next.rejectedTriggers.append(.init(phrase: phrase, origin: .hardNegative, reason: .negativeDidNotAbstain))
                    return false
                }
                return true
            }
            func retainConfuser(_ phrase: String) -> Bool {
                let ownerWon = router.matches(in: phrase).contains { match in
                    guard case .node(let nodeID) = match.target.ref else { return false }
                    return nodeID == card.nodeID
                }
                let sharedWithOwner = router.sharedMatches(in: phrase).contains {
                    $0.candidateNodeIDs.contains(card.nodeID)
                }
                guard !ownerWon, !sharedWithOwner else {
                    next.rejectedTriggers.append(.init(phrase: phrase, origin: .confuser, reason: .negativeDidNotAbstain))
                    return false
                }
                return true
            }
            next.hardNegatives = card.hardNegatives.filter(retainHardNegative)
            next.confusableConcepts = card.confusableConcepts.filter(retainConfuser)
            return next
        }
    }
}

/// This prompt intentionally cannot see ancestry or child names. The model
/// therefore cannot turn hierarchy-only context into positive vocabulary.
func positiveRoutingPrompt(_ seed: VoiceRoutingSeed) -> String {
    let titleWords = canonicalTitleWordCandidates(seed.canonicalName)
    return """
    Canonical context: \(seed.canonicalName)
    Exact canonical title-word candidates: \(titleWords.isEmpty ? "none" : titleWords.joined(separator: " | "))
    Existing aliases: \(joined(seed.existingAliases))
    Kind: \(seed.kind ?? "unspecified")
    Direct artifact titles: \(joined(seed.directArtifactTitles))
    Direct headings and tags: \(joined(seed.directHeadingsAndTags))
    Bounded direct excerpts: \(joined(seed.directExcerpts))

    Generate compact positive routing vocabulary grounded in the identity or direct evidence above. Every positive phrase must clearly identify this context.

    Select the smallest subset of these title words that preserves the context's identifying meaning. Remove words that merely describe its general type, container, artifact, or activity. Do not require the subset to be globally unique or fully descriptive by itself; deterministic collision handling runs afterward. Keep selected words in their original order. The selected subset becomes one phrase, not separate triggers. Copy the subset exactly into canonicalIdentitySubset. For America Trip, return [america]. For Building a Second Brain, [second, brain] is a valid subset. Return an empty subset only when no title-word subset carries identifying meaning.

    """
}

/// Exact normalized content words are the complete one-word choice set shown
/// to the model. The model decides meaning; deterministic validation later
/// proves that any selected word belongs to the canonical identity.
func canonicalTitleWordCandidates(_ title: String) -> [String] {
    var seen = Set<String>()
    return PhraseMatcher.normalize(title)
        .split(separator: " ")
        .map(String.init)
        .filter { !voiceRoutingStopWords.contains($0) && seen.insert($0).inserted }
}

func canonicalIdentityPhrase(
    from selections: [String],
    seed: VoiceRoutingSeed
) -> String? {
    let allowedTitleWords = canonicalTitleWordCandidates(seed.canonicalName)
    let allowedTitleWordSet = Set(allowedTitleWords)
    let normalizedSelections = selections.map(PhraseMatcher.normalize)
    guard !normalizedSelections.isEmpty,
          normalizedSelections.allSatisfy({ selection in
              !selection.contains(" ") && allowedTitleWordSet.contains(selection)
          }),
          Set(normalizedSelections).count == normalizedSelections.count else { return nil }
    let selectedSet = Set(normalizedSelections)
    return allowedTitleWords.filter(selectedSet.contains).joined(separator: " ")
}

private func routingSpecificity(_ kind: String?) -> Int {
    switch PhraseMatcher.normalize(kind ?? "") {
    case "manifest", "frontmatter": 6
    case "linked document", "linkeddocument": 5
    case "local model", "localmodel": 4
    case "folder": 3
    case "tag": 2
    case "unresolved link", "unresolvedlink": 1
    default: 4
    }
}

func generatedTriggerCandidates(
    seed: VoiceRoutingSeed,
    shortenedCanonicalForms: [String],
    semanticAliases: [String],
    phraseFamilies: [String],
    topicTags: [String],
    artifactTypes: [String],
    representativeUtterances: [String],
    verifiedSemanticRelations: Set<String> = [],
    consensusArtifactVocabulary: Set<String> = [],
    lexicalAlternativePasses: [[String]] = []
) -> GeneratedTriggerCandidates {
    struct RawCandidate {
        var phrase: String
        var origin: VoiceRoutingTriggerOrigin
        var score: Double
        var maximumWords: Int
        var addOrderedPattern: Bool
    }

    var raw: [RawCandidate] = []
    raw += shortenedCanonicalForms.map { .init(phrase: $0, origin: .shortenedCanonical, score: 0.94, maximumWords: 6, addOrderedPattern: true) }
    // Consensus evidence is stronger provenance than a model placing the same
    // phrase in a generic alias/family field. Admit it first so collision
    // ownership can distinguish grounded artifact vocabulary from taxonomy.
    raw += consensusArtifactVocabulary.sorted().map {
        .init(phrase: $0, origin: .consensusArtifactVocabulary, score: 0.86, maximumWords: 6, addOrderedPattern: false)
    }
    raw += semanticAliases.map { .init(phrase: $0, origin: .semanticAlias, score: 0.92, maximumWords: 6, addOrderedPattern: true) }
    raw += phraseFamilies.map { .init(phrase: $0, origin: .phraseFamily, score: 0.90, maximumWords: 6, addOrderedPattern: true) }
    raw += topicTags.map { .init(phrase: $0, origin: .topicTag, score: 0.86, maximumWords: 6, addOrderedPattern: false) }
    raw += artifactTypes.map { .init(phrase: $0, origin: .artifactType, score: 0.84, maximumWords: 6, addOrderedPattern: false) }
    raw += representativeUtterances.map { .init(phrase: $0, origin: .representativeUtterance, score: 0.82, maximumWords: 14, addOrderedPattern: false) }
    raw += deterministicCanonicalShortenings(of: seed.canonicalName).map {
        .init(phrase: $0, origin: .shortenedCanonical, score: 0.94, maximumWords: 6, addOrderedPattern: true)
    }
    raw += morphologicalVariants(of: seed.canonicalName).map {
        .init(phrase: $0, origin: .phraseFamily, score: 0.90, maximumWords: 8, addOrderedPattern: true)
    }
    // A canonical multiword name owns an ordered spoken family even when the
    // model returns no useful shortening. This handles ASR insertions such as
    // "progressive about the summarization" without a live model.
    raw.append(.init(phrase: seed.canonicalName, origin: .phraseFamily, score: 0.92, maximumWords: 8, addOrderedPattern: true))

    let canonical = Set(([seed.canonicalName] + seed.existingAliases).map(PhraseMatcher.normalize))
    let lexicalPasses = lexicalAlternativePasses.map { Set($0.map(PhraseMatcher.normalize)) }
    let unanimousLexicalSingletons: Set<String>
    if lexicalPasses.count >= 3 {
        unanimousLexicalSingletons = lexicalPasses.dropFirst().reduce(lexicalPasses[0]) { partial, pass in
            partial.intersection(pass)
        }.filter { routingTerms($0).count == 1 }
    } else {
        unanimousLexicalSingletons = []
    }
    var accepted: [VoiceRoutingTrigger] = []
    var rejected: [VoiceRoutingRejectedTrigger] = []
    var seen = Set<String>()
    for candidate in raw {
        guard let normalized = validGeneratedPhrase(candidate.phrase, maximumWords: candidate.maximumWords) else {
            rejected.append(.init(
                phrase: candidate.phrase,
                origin: candidate.origin,
                reason: rejectionReason(forInvalidPhrase: candidate.phrase)
            ))
            continue
        }
        if [.topicTag, .artifactType].contains(candidate.origin), routingTerms(normalized).count < 2 {
            rejected.append(.init(phrase: normalized, origin: candidate.origin, reason: .generic))
            continue
        }
        if [.semanticAlias, .phraseFamily].contains(candidate.origin),
           routingTerms(normalized).count == 1,
           !canonical.contains(normalized),
           !(verifiedSemanticRelations.contains(normalized) && unanimousLexicalSingletons.contains(normalized)) {
            rejected.append(.init(phrase: normalized, origin: candidate.origin, reason: .generic))
            continue
        }
        let grounding = groundingDisposition(
            normalized,
            seed: seed,
            origin: candidate.origin,
            verifiedSemanticRelations: verifiedSemanticRelations,
            consensusArtifactVocabulary: consensusArtifactVocabulary
        )
        guard grounding == nil else {
            rejected.append(.init(phrase: normalized, origin: candidate.origin, reason: grounding!))
            continue
        }

        if !canonical.contains(normalized) {
            let exact = VoiceRoutingTrigger(pattern: .phrase(normalized), origin: candidate.origin, score: candidate.score)
            if seen.insert(triggerKey(exact)).inserted { accepted.append(exact) }
            else { rejected.append(.init(phrase: normalized, origin: candidate.origin, reason: .duplicate)) }
        } else if candidate.origin != .phraseFamily {
            rejected.append(.init(phrase: normalized, origin: candidate.origin, reason: .duplicate))
        }

        guard candidate.addOrderedPattern else { continue }
        let terms = routingTerms(normalized)
        guard (2...4).contains(terms.count) else { continue }
        let ordered = VoiceRoutingTrigger(
            pattern: .orderedTerms(terms, maximumGap: 2),
            origin: .phraseFamily,
            score: max(candidate.score - 0.02, VoiceRoutingScorer.minimumScore)
        )
        if seen.insert(triggerKey(ordered)).inserted { accepted.append(ordered) }
        else { rejected.append(.init(phrase: ordered.pattern.displayPhrase, origin: .phraseFamily, reason: .duplicate)) }
    }
    return .init(accepted: accepted, rejected: rejected)
}

private func sanitizedGeneratedPhrases(
    _ values: [String],
    origin: VoiceRoutingTriggerOrigin,
    maximumCount: Int,
    minimumWords: Int,
    maximumWords: Int
) -> SanitizedGeneratedPhrases {
    var accepted: [String] = []
    var rejected: [VoiceRoutingRejectedTrigger] = []
    var seen = Set<String>()
    for raw in values {
        guard let normalized = validGeneratedPhrase(raw, minimumWords: minimumWords, maximumWords: maximumWords) else {
            rejected.append(.init(phrase: raw, origin: origin, reason: rejectionReason(forInvalidPhrase: raw)))
            continue
        }
        guard seen.insert(normalized).inserted else {
            rejected.append(.init(phrase: normalized, origin: origin, reason: .duplicate))
            continue
        }
        if accepted.count < maximumCount { accepted.append(normalized) }
        else { rejected.append(.init(phrase: normalized, origin: origin, reason: .duplicate)) }
    }
    return .init(accepted: accepted, rejected: rejected)
}

private func groundingDisposition(
    _ phrase: String,
    seed: VoiceRoutingSeed,
    origin: VoiceRoutingTriggerOrigin,
    verifiedSemanticRelations: Set<String>,
    consensusArtifactVocabulary: Set<String>
) -> VoiceRoutingRejectionReason? {
    if origin == .shortenedCanonical {
        let identityWords = Set(canonicalTitleWordCandidates(seed.canonicalName))
        let candidateWords = PhraseMatcher.normalize(phrase).split(separator: " ").map(String.init)
        guard !candidateWords.isEmpty,
              Set(candidateWords).isSubset(of: identityWords) else { return .unsupportedEvidence }
        return nil
    }

    let positiveMaterial = [seed.canonicalName] + seed.existingAliases
        + seed.directArtifactTitles + seed.directHeadingsAndTags + seed.directExcerpts
    let positiveTerms = Set(positiveMaterial.flatMap(groundingTerms))
    let candidateTerms = groundingTerms(phrase)
    guard !candidateTerms.isEmpty else { return .generic }

    let contextOnlyTerms = Set(
        (seed.contextOnlyAncestry + seed.contextOnlyChildNames).flatMap(groundingTerms)
    )
    var supportedIndexes = Set(candidateTerms.indices.filter { positiveTerms.contains(candidateTerms[$0]) })
    if candidateTerms.count >= 2 {
        for index in 0..<(candidateTerms.count - 1) where positiveTerms.contains(candidateTerms[index] + candidateTerms[index + 1]) {
            supportedIndexes.insert(index)
            supportedIndexes.insert(index + 1)
        }
    }
    let unsupported = Set(candidateTerms.indices.filter { !supportedIndexes.contains($0) }.map { candidateTerms[$0] })
    if !unsupported.isEmpty, unsupported.isSubset(of: contextOnlyTerms) { return .contextOnlyEvidence }
    if origin == .consensusArtifactVocabulary,
       consensusArtifactVocabulary.contains(PhraseMatcher.normalize(phrase)),
       unsupported.count <= 1 {
        return nil
    }
    if verifiedSemanticRelations.contains(PhraseMatcher.normalize(phrase)),
       supportedIndexes.isEmpty || unsupported.count == 1 {
        return nil
    }
    guard unsupported.isEmpty else { return .unsupportedEvidence }
    return nil
}

/// Identity-derived shortening only: drop a leading action word from a
/// canonical name when at least two distinctive content terms remain. Global
/// collision and production-router validation still decide whether it is safe.
private func deterministicCanonicalShortenings(of phrase: String) -> [String] {
    let terms = routingTerms(phrase)
    guard terms.count >= 3, let first = terms.first, first.count > 5, first.hasSuffix("ing") else { return [] }
    let tail = Array(terms.dropFirst())
    guard tail.count >= 2 else { return [] }
    return [tail.joined(separator: " ")]
}

/// Combines a distinctive authored tag modifier with an artifact/container
/// head that independently recurs across proposal passes or channels. This is
/// grounded artifact vocabulary, not an assertion of exact synonymy. Global
/// collision, runtime score/margin, and negative gates still own activation.
func modelGroundedConsensusCompounds(
    seed: VoiceRoutingSeed,
    lexicalAlternativePasses: [[String]],
    independentProposalChannels: [[String]] = []
) -> [String] {
    let canonicalTerms = Set(routingTerms(seed.canonicalName))
    guard canonicalTerms.count >= 2 else { return [] }
    let contextOnlyTermSets = (seed.contextOnlyAncestry + seed.contextOnlyChildNames).map {
        Set(routingTerms($0))
    }
    let topicTerms = seed.directTags.compactMap { phrase -> [String]? in
        let terms = routingTerms(phrase)
        guard (2...4).contains(terms.count),
              !contextOnlyTermSets.contains(Set(terms)) else { return nil }
        return terms
    }
    func heads(in phrases: [String]) -> Set<String> {
        Set(phrases.compactMap { routingTerms($0).last })
    }
    var lexicalPassCount: [String: Int] = [:]
    for pass in lexicalAlternativePasses {
        for head in heads(in: pass) { lexicalPassCount[head, default: 0] += 1 }
    }
    var channelCount: [String: Int] = [:]
    for channel in independentProposalChannels {
        for head in heads(in: channel) { channelCount[head, default: 0] += 1 }
    }
    let consensusHeads = Set(lexicalPassCount.compactMap { $0.value >= 2 ? $0.key : nil })
        .union(channelCount.compactMap { $0.value >= 2 ? $0.key : nil })
    let proposedHeads = Set(lexicalPassCount.keys).union(channelCount.keys)
    let directEvidenceStems = Set(
        (seed.directHeadingsAndTags + seed.directExcerpts).flatMap(groundingTerms)
    )
    let directlyCorroboratedHeads = proposedHeads.filter {
        directEvidenceStems.contains(groundingStem($0))
    }
    let eligibleHeads = consensusHeads.union(directlyCorroboratedHeads)
    var seen = Set<String>()
    var result: [String] = []
    for topic in topicTerms {
        guard let modifier = topic.first else { continue }
        for head in eligibleHeads.sorted()
        where !canonicalTerms.contains(head) && !topic.contains(head) && modifier != head {
            let candidate = "\(modifier) \(head)"
            if seen.insert(candidate).inserted { result.append(candidate) }
            if result.count == 16 { return result }
        }
    }
    return result
}

private func phraseContains(_ phrase: String, _ possibleSubphrase: String) -> Bool {
    let phraseWords = PhraseMatcher.normalize(phrase).split(separator: " ").map(String.init)
    let subphraseWords = PhraseMatcher.normalize(possibleSubphrase).split(separator: " ").map(String.init)
    guard !subphraseWords.isEmpty, subphraseWords.count <= phraseWords.count else { return false }
    for start in 0...(phraseWords.count - subphraseWords.count) {
        if Array(phraseWords[start..<(start + subphraseWords.count)]) == subphraseWords { return true }
    }
    return false
}

private func morphologicalVariants(of phrase: String) -> [String] {
    let words = PhraseMatcher.normalize(phrase).split(separator: " ").map(String.init)
    var variants: [String] = []
    for index in words.indices where words[index].count > 7 && words[index].hasSuffix("ation") {
        var variant = words
        variant[index] = String(words[index].dropLast(5)) + "ing"
        variants.append(variant.joined(separator: " "))
    }
    return variants
}

private func validGeneratedPhrase(
    _ value: String,
    minimumWords: Int = 1,
    maximumWords: Int
) -> String? {
    guard !containsGeneratedMetadataSyntax(value) else { return nil }
    let normalized = PhraseMatcher.normalize(value)
    let words = normalized.split(separator: " ")
    guard !normalized.isEmpty, words.count >= minimumWords, words.count <= maximumWords, normalized.count <= 120 else { return nil }
    guard normalized.range(of: #"\b[0-9a-f]{24,}\b"#, options: .regularExpression) == nil else { return nil }
    let generic: Set<String> = [
        "thing", "things", "something", "anything", "stuff", "item", "items", "note", "notes",
        "document", "documents", "file", "files", "work", "topic", "topics", "idea", "ideas",
        "project", "projects", "person", "people", "today", "later", "interesting", "none"
    ]
    let boilerplatePhrases: Set<String> = [
        "see also", "related topics", "related notes", "table of contents"
    ]
    guard !boilerplatePhrases.contains(normalized) else { return nil }
    guard words.count > 1 || !generic.contains(normalized) else { return nil }
    return normalized
}

private func rejectionReason(forInvalidPhrase value: String) -> VoiceRoutingRejectionReason {
    let normalized = PhraseMatcher.normalize(value)
    if containsGeneratedMetadataSyntax(value)
        || normalized.range(of: #"\b[0-9a-f]{24,}\b"#, options: .regularExpression) != nil {
        return .invalidMetadata
    }
    return .generic
}

private func containsGeneratedMetadataSyntax(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    if lowercased.contains("://") || value.contains("/") || value.contains("\\") || value.contains("#") { return true }
    if value.contains("\n") || value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("---") { return true }
    return value.range(of: #"^\s*[A-Za-z][A-Za-z0-9_-]*:\s"#, options: .regularExpression) != nil
}

private func validationUtterance(for pattern: VoiceRoutingTriggerPattern) -> String {
    switch pattern {
    case .phrase(let phrase): phrase
    case .orderedTerms(let terms, _): terms.joined(separator: " about ")
    }
}

private func triggerKey(_ trigger: VoiceRoutingTrigger) -> String {
    switch trigger.pattern {
    case .phrase(let phrase): "phrase:\(PhraseMatcher.normalize(phrase))"
    case .orderedTerms(let terms, let maximumGap):
        "ordered:\(terms.map(PhraseMatcher.normalize).joined(separator: "|")):\(maximumGap)"
    }
}

private func patternTerms(_ pattern: VoiceRoutingTriggerPattern) -> [String] {
    switch pattern {
    case .phrase(let phrase): routingTerms(phrase)
    case .orderedTerms(let terms, _): terms.flatMap(routingTerms)
    }
}

private func routingTerms(_ text: String) -> [String] {
    return PhraseMatcher.normalize(text).split(separator: " ").map(String.init).filter {
        $0.count > 2 && !voiceRoutingStopWords.contains($0)
    }
}

private func groundingTerms(_ text: String) -> [String] {
    routingTerms(text).map(groundingStem)
}

private func groundingStem(_ word: String) -> String {
    if word.count > 7, word.hasSuffix("ation") { return String(word.dropLast(5)) }
    if word.count > 5, word.hasSuffix("ing") { return String(word.dropLast(3)) }
    if word.count > 5, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
    if word.count > 4, word.hasSuffix("s") { return String(word.dropLast()) }
    return word
}

private func uniqueNormalized(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
        let normalized = PhraseMatcher.normalize(value)
        return !normalized.isEmpty && seen.insert(normalized).inserted ? normalized : nil
    }
}

private func joined(_ values: [String]) -> String { values.isEmpty ? "none" : values.joined(separator: " | ") }

private func sanitized(
    _ values: [String],
    maximumCount: Int,
    minimumWords: Int = 1,
    maximumWords: Int = 5,
    allowGenericSingleton: Bool = false
) -> [String] {
    let generic: Set<String> = [
        "thing", "things", "something", "anything", "stuff", "item", "items", "note", "notes",
        "document", "documents", "file", "files", "work", "topic", "topics", "idea", "ideas",
        "project", "projects", "person", "people", "today", "later", "interesting", "none"
    ]
    var seen = Set<String>()
    return values.compactMap { value -> String? in
        guard !containsGeneratedMetadataSyntax(value) else { return nil }
        let normalized = PhraseMatcher.normalize(value)
        let words = normalized.split(separator: " ")
        guard !normalized.isEmpty, words.count >= minimumWords, words.count <= maximumWords, normalized.count <= 120 else { return nil }
        guard normalized.range(of: #"\b[0-9a-f]{24,}\b"#, options: .regularExpression) == nil else { return nil }
        guard allowGenericSingleton || words.count > 1 || !generic.contains(normalized) else { return nil }
        return seen.insert(normalized).inserted ? normalized : nil
    }.prefix(maximumCount).map { $0 }
}
