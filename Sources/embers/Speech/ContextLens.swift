import EmbersCore
import Foundation

struct ContextLensDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    struct Source: Codable, Equatable, Sendable {
        var id: String
        var name: String
    }

    var schemaVersion = Self.currentSchemaVersion
    var name = "Context Lens"
    var source: Source
    var graphRevision: String
    var compilerVersion: String
    var modelVersion: String
    var generatedAt: Date
    var entries: [ContextLensEntry]
}

struct ContextLensEntry: Codable, Equatable, Identifiable, Sendable {
    var id: String { nodeID }
    var nodeID: String
    var title: String
    var evidenceHash: String
    var input: VoiceRoutingSeed
    var modelProposal: ContextLensModelProposal
    var deterministicDecision: ContextLensDeterministicDecision
}

struct ContextLensModelProposal: Codable, Equatable, Sendable {
    var semanticAliases: [String]
    var topicTags: [String]
    var artifactTypes: [String]
    var representativeUtterances: [String]
    var hardNegatives: [String]
    var confusableConcepts: [String]
    var descriptiveVocabulary: [String]
    var provenance: VoiceRoutingProposalProvenance
}

struct ContextLensDeterministicDecision: Codable, Equatable, Sendable {
    var baselineMatches: [VoiceRoutingBaseline.Decision] = []
    var acceptedTriggers: [VoiceRoutingTrigger]
    var rejectedTriggers: [VoiceRoutingRejectedTrigger]
    var sharedConcepts: [VoiceRoutingSharedConcept]
}

/// Capturing a request only checks readiness. UI availability must never build
/// evidence or an export document as a side effect of rendering a control.
struct ContextLensRequest: Sendable {
    let sourceID: String
    let sourceName: String
    let sourceSnapshot: ContextSnapshot
    let graph: ContextGraph
    let snapshot: ContextSnapshot
    let pack: VoiceRoutingPack?

    init?(
        sourceID: String,
        sourceName: String,
        sourceSnapshot: ContextSnapshot?,
        graph: ContextGraph?,
        snapshot: ContextSnapshot?,
        pack: VoiceRoutingPack?
    ) {
        guard let sourceSnapshot, let graph, let snapshot,
              graph.revision == snapshot.revision,
              pack == nil || pack?.graphRevision == graph.revision else { return nil }
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.sourceSnapshot = sourceSnapshot
        self.graph = graph
        self.snapshot = snapshot
        self.pack = pack
    }

    func build() -> ContextLensDocument? {
        ContextLensDocumentBuilder().build(
            sourceID: sourceID, sourceName: sourceName,
            sourceSnapshot: sourceSnapshot, graph: graph, snapshot: snapshot, pack: pack
        )
    }
}

struct ContextLensDocumentBuilder: Sendable {
    func build(
        sourceID: String,
        sourceName: String,
        sourceSnapshot: ContextSnapshot?,
        graph: ContextGraph,
        snapshot: ContextSnapshot,
        pack: VoiceRoutingPack?
    ) -> ContextLensDocument? {
        guard graph.revision == snapshot.revision,
              pack == nil || pack?.graphRevision == graph.revision,
              let sourceSnapshot else { return nil }

        let ownedAnchorIDs = Set(sourceSnapshot.anchors.map(\.id))
        let ownedNodeIDs = Set(graph.nodes.compactMap { node in
            node.role == .context && ownedAnchorIDs.contains(node.referenceID) ? node.id : nil
        })
        let seeds = VoiceRoutingSeedBuilder().build(graph: graph, snapshot: snapshot)
        let seedByNodeID = Dictionary(uniqueKeysWithValues: seeds.map { ($0.nodeID, $0) })
        let cardByNodeID = Dictionary(uniqueKeysWithValues: (pack?.cards ?? []).map { ($0.nodeID, $0) })
        let baseline = VoiceRoutingBaseline(targets: VoiceRoutingBaseTargetBuilder().build(nodes: graph.voiceNodes))

        let entries = ownedNodeIDs.compactMap { nodeID -> ContextLensEntry? in
            guard let seed = seedByNodeID[nodeID] else { return nil }
            let card = cardByNodeID[nodeID]
            let sharedConcepts = (pack?.sharedConcepts ?? []).filter { concept in
                concept.candidates.contains { $0.nodeID == nodeID }
            }
            return ContextLensEntry(
                nodeID: nodeID,
                title: seed.canonicalName,
                evidenceHash: seed.evidenceHash,
                input: seed,
                modelProposal: .init(
                    semanticAliases: card?.semanticAliases ?? [],
                    topicTags: card?.topicTags ?? [],
                    artifactTypes: card?.artifactTypes ?? [],
                    representativeUtterances: card?.representativeUtterances ?? [],
                    hardNegatives: card?.hardNegatives ?? [],
                    confusableConcepts: card?.confusableConcepts ?? [],
                    descriptiveVocabulary: card?.descriptiveVocabulary ?? [],
                    provenance: card?.proposalProvenance ?? .init()
                ),
                deterministicDecision: .init(
                    baselineMatches: baseline.decisions.filter { $0.nodeID == nodeID },
                    acceptedTriggers: card?.activeTriggers ?? [],
                    rejectedTriggers: card?.rejectedTriggers ?? [],
                    sharedConcepts: sharedConcepts
                )
            )
        }.sorted {
            ($0.title.embersNormalized, $0.nodeID) < ($1.title.embersNormalized, $1.nodeID)
        }

        return ContextLensDocument(
            source: .init(id: sourceID, name: sourceName),
            graphRevision: graph.revision,
            compilerVersion: pack?.compilerVersion ?? VoiceRoutingCompiler.compilerVersion,
            modelVersion: pack?.modelVersion ?? "unavailable",
            generatedAt: pack?.generatedAt ?? snapshot.indexedAt,
            entries: entries
        )
    }
}

struct ContextLensFileExporter {
    enum ExportError: Error {
        case defaultApplicationRejectedFile
    }

    var directoryURL: URL
    var openURL: (URL) -> Bool

    func writeAndOpen(_ document: ContextLensDocument) throws -> URL {
        let fileURL = try write(document)
        guard openURL(fileURL) else { throw ExportError.defaultApplicationRejectedFile }
        return fileURL
    }

    /// Encoding and disk IO can run off-main; opening the file remains a UI action.
    func write(_ document: ContextLensDocument) throws -> URL {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = directoryURL.appendingPathComponent(filename(for: document.source))
        let encoder = JSONEncoder.contextLens
        try encoder.encode(document).write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func filename(for source: ContextLensDocument.Source) -> String {
        let slug = source.name.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let normalized = String(slug)
            .split(separator: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let safeName = normalized.isEmpty ? "source" : normalized
        return "context-lens-\(safeName)-\(StableHash.hex(source.id).prefix(10)).json"
    }
}

extension JSONEncoder {
    static var contextLens: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var contextLens: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
