import Foundation

public struct GraphContextSearch: Sendable {
    public let graph: ContextGraph
    private let nodeByID: [String: GraphNode]
    private let edgeByID: [String: GraphEdge]
    private let edgesByNode: [String: [GraphEdge]]
    private let anchorByID: [String: Anchor]
    private let artifactByID: [String: SourceArtifact]

    public init(graph: ContextGraph) {
        self.init(graph: graph, snapshot: nil)
    }

    public init(graph: ContextGraph, snapshot: ContextSnapshot) {
        self.init(graph: graph, snapshot: Optional(snapshot))
    }

    private init(graph: ContextGraph, snapshot: ContextSnapshot?) {
        self.graph = graph
        self.nodeByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        self.edgeByID = Dictionary(uniqueKeysWithValues: graph.edges.map { ($0.id, $0) })
        self.anchorByID = snapshot.map { Dictionary(uniqueKeysWithValues: $0.anchors.map { ($0.id, $0) }) } ?? [:]
        self.artifactByID = snapshot.map { Dictionary(uniqueKeysWithValues: $0.artifacts.map { ($0.id, $0) }) } ?? [:]
        var adjacency: [String: [GraphEdge]] = [:]
        for edge in graph.edges {
            adjacency[edge.source, default: []].append(edge)
            adjacency[edge.target, default: []].append(edge)
        }
        self.edgesByNode = adjacency.mapValues { edges in
            edges.sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }
        }
    }

    public var activationNodes: [GraphNode] { graph.activationNodes }
    public var voiceNodes: [GraphNode] { graph.voiceNodes }

    public func summaries(in snapshot: ContextSnapshot) -> [AnchorSummary] {
        let anchors = graph.revision == snapshot.revision && !anchorByID.isEmpty
            ? anchorByID
            : Dictionary(uniqueKeysWithValues: snapshot.anchors.map { ($0.id, $0) })
        return activationNodes.map { node in
            let incident = edgesByNode[node.id, default: []]
            let documents = Set(incident.compactMap { edge -> String? in
                let other = edge.source == node.id ? edge.target : edge.source
                guard nodeByID[other]?.role == .document else { return nil }
                return nodeByID[other]?.referenceID
            })
            let anchor = anchors[node.referenceID]
            let isFolder = anchor?.provenance.contains(.folder) == true
            let linkCount = incident.filter { $0.kind == "links-to" || (!isFolder && $0.kind == "mentions") }.count
            let documentCount = isFolder ? (anchor?.memberArtifactIDs.count ?? documents.count) : documents.count
            return AnchorSummary(id: node.id, name: node.name, kind: node.kind, documentCount: documentCount, linkCount: linkCount, modifiedAt: anchor?.evidence.mostRecentModification ?? .distantPast)
        }
    }

    /// The home screen is a set of useful destinations, not a flattened folder tree.
    /// Pure structural wrappers yield to their first meaningful descendants, while a
    /// meaningful destination owns the deeper contexts navigated from its detail view.
    /// Voice addressability remains unchanged because this is a display projection only.
    public func homeSummaries(in snapshot: ContextSnapshot) -> [AnchorSummary] {
        let all = summaries(in: snapshot)
        let summaryByID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let anchors = graph.revision == snapshot.revision && !anchorByID.isEmpty
            ? anchorByID
            : Dictionary(uniqueKeysWithValues: snapshot.anchors.map { ($0.id, $0) })
        let hierarchy = graph.edges.filter { $0.kind == "contains-context" }
        let parentByChild = hierarchy.sorted { ($0.target, $0.source) < ($1.target, $1.source) }.reduce(into: [String: String]()) { result, edge in
            result[edge.target] = result[edge.target] ?? edge.source
        }
        let childrenByParent = Dictionary(grouping: hierarchy, by: \.source)

        func directDocumentNodeIDs(_ nodeID: String) -> Set<String> {
            Set(edgesByNode[nodeID, default: []].compactMap { edge -> String? in
                let other = edge.source == nodeID ? edge.target : edge.source
                guard nodeByID[other]?.role == .document else { return nil }
                return other
            })
        }

        func directDocumentCount(_ nodeID: String) -> Int {
            directDocumentNodeIDs(nodeID).count
        }

        func isRedundantCollection(_ nodeID: String) -> Bool {
            guard let node = nodeByID[nodeID],
                  anchors[node.referenceID]?.provenance.contains(.folder) == true else { return false }
            let documents = directDocumentNodeIDs(nodeID)
            guard !documents.isEmpty else { return false }
            let membershipKinds = Set(["declares", "includes", "resolves-to"])
            return documents.allSatisfy { documentID in
                edgesByNode[documentID, default: []].contains { edge in
                    guard membershipKinds.contains(edge.kind) else { return false }
                    let other = edge.source == documentID ? edge.target : edge.source
                    return other != nodeID && nodeByID[other]?.role == .context
                        && nodeByID[other]?.activationEligible == true
                }
            }
        }

        func isStructuralWrapper(_ nodeID: String) -> Bool {
            (childrenByParent[nodeID]?.isEmpty == false && directDocumentCount(nodeID) == 0)
                || isRedundantCollection(nodeID)
        }

        func hasMeaningfulAncestor(_ nodeID: String) -> Bool {
            var visited = Set<String>()
            var parent = parentByChild[nodeID]
            while let current = parent, visited.insert(current).inserted {
                if !isStructuralWrapper(current), summaryByID[current] != nil { return true }
                parent = parentByChild[current]
            }
            return false
        }

        return all.filter { summary in
            !isStructuralWrapper(summary.id) && !hasMeaningfulAncestor(summary.id)
        }
    }

    public func vocabulary(limit: Int = 100) -> [String] {
        var seen = Set<String>()
        return voiceNodes.flatMap { [$0.name] + $0.aliases }.filter {
            seen.insert($0.embersNormalized).inserted
        }.prefix(limit).map { $0 }
    }

    /// Find artifacts by the words in a free-form factual question.
    ///
    /// This is deliberately literal and local. Readable body text provides
    /// evidence, while human-visible titles, logical paths, headings, and tags
    /// provide stronger file-finding hints. Generated link targets and raw
    /// frontmatter are excluded. The caller opens the winning artifact rather
    /// than asking a model to discover or answer from it.
    public func literalSearch(
        _ query: String,
        in snapshot: ContextSnapshot,
        limit: Int = 8,
        lastSeen: Date? = nil
    ) -> [ContextHit] {
        guard limit > 0 else { return [] }
        let terms = literalQueryTerms(query)
        guard !terms.isEmpty else { return [] }

        let rows: [(artifact: SourceArtifact, score: Int, snippet: String)] = snapshot.artifacts.compactMap { artifact in
            let text = artifact.semanticText
            let bodyTokens = literalTokenMatches(in: text)
            let titleTokens = literalTokenMatches(in: artifact.title)
            let pathTokens = literalTokenMatches(in: artifact.graphRelativePath)
            let metadataTokens = literalTokenMatches(in: (artifact.metadata.headings + artifact.metadata.tags).joined(separator: " "))
            let searchable = Set(bodyTokens + titleTokens + pathTokens + metadataTokens)
            let matched = terms.filter { searchable.contains($0) }
            guard !matched.isEmpty else { return nil }

            let coverage = matched.count * 100 / terms.count
            let frequency = matched.reduce(into: 0) { total, term in total += bodyTokens.filter { $0 == term }.count }
            let bodyPhraseBoost = literalContainsTermSequence(terms, in: bodyTokens) ? 40 : 0
            let titlePhraseBoost = literalContainsTermSequence(terms, in: titleTokens) ? 80 : 0
            let titleBoost = terms.filter { titleTokens.contains($0) }.count * 50
            let pathBoost = terms.filter { pathTokens.contains($0) }.count * 25
            let metadataBoost = terms.filter { metadataTokens.contains($0) }.count * 35
            let score = coverage * 10 + bodyPhraseBoost + titlePhraseBoost + titleBoost + pathBoost + metadataBoost + min(frequency, 8) * 2
            let firstMatch = terms.compactMap { term in wholePhraseRange(term, in: text) }.min { $0.location < $1.location }
            return (artifact, score, snippet(around: firstMatch, in: text))
        }

        return rows.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.artifact.rankingModifiedAt != $1.artifact.rankingModifiedAt {
                return $0.artifact.rankingModifiedAt > $1.artifact.rankingModifiedAt
            }
            return $0.artifact.id < $1.artifact.id
        }.prefix(limit).map { row in
            ContextHit(
                artifact: row.artifact,
                snippet: row.snippet,
                changedSinceLastPeek: row.artifact.metadata.modificationDateReliable != false
                    && (lastSeen.map { row.artifact.modifiedAt > $0 } ?? false)
            )
        }
    }

    public func resolve(_ spokenText: String) -> NodeActivation? {
        struct Candidate {
            var node: GraphNode
            var phrase: String
            var kind: NodeMatchKind
            var range: NSRange
        }
        var candidates: [Candidate] = []
        for node in voiceNodes {
            if let range = wholePhraseRange(node.name, in: spokenText) {
                candidates.append(.init(node: node, phrase: node.name, kind: .canonicalName, range: range))
            }
            for alias in node.aliases {
                if let range = wholePhraseRange(alias, in: spokenText) {
                    candidates.append(.init(node: node, phrase: alias, kind: .alias, range: range))
                }
            }
        }
        guard let winner = candidates.sorted(by: {
            if $0.kind != $1.kind { return $0.kind == .canonicalName }
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.phrase.count != $1.phrase.count { return $0.phrase.count > $1.phrase.count }
            if $0.node.importance != $1.node.importance { return $0.node.importance > $1.node.importance }
            return $0.node.id < $1.node.id
        }).first else { return nil }
        return NodeActivation(
            nodeID: winner.node.id,
            matchedPhrase: winner.phrase,
            matchKind: winner.kind,
            path: .init(nodeIDs: [winner.node.id], edgeIDs: [], cost: 0),
            score: winner.node.importance + (winner.kind == .canonicalName ? 2 : 1)
        )
    }

    public func nearestActivation(toEvidenceNode nodeID: String, maxDepth: Int = 2) -> NodeActivation? {
        nearestNodes(from: nodeID, maxDepth: maxDepth, limit: 1).first.map { result in
            NodeActivation(
                nodeID: result.node.id,
                matchedPhrase: nodeByID[nodeID]?.name ?? "",
                matchKind: .evidence,
                supportingArtifactID: nodeByID[nodeID]?.role == .document ? nodeByID[nodeID]?.referenceID : nil,
                path: result.path,
                score: result.node.importance + 1 / max(result.path.cost, 0.001)
            )
        }
    }

    public func detail(nodeID: String, in snapshot: ContextSnapshot, lastSeen: Date? = nil) -> AnchorDetail? {
        let anchors = graph.revision == snapshot.revision && !anchorByID.isEmpty
            ? anchorByID
            : Dictionary(uniqueKeysWithValues: snapshot.anchors.map { ($0.id, $0) })
        let artifacts = graph.revision == snapshot.revision && !artifactByID.isEmpty
            ? artifactByID
            : Dictionary(uniqueKeysWithValues: snapshot.artifacts.map { ($0.id, $0) })
        guard let node = nodeByID[nodeID], node.role == .context,
              let anchor = anchors[node.referenceID] else { return nil }
        let isFolder = anchor.provenance.contains(.folder)

        let subcontexts = edgesByNode[nodeID, default: []].compactMap { edge -> AnchorSummary? in
            guard edge.kind == "contains-context", edge.source == nodeID,
                  let child = nodeByID[edge.target], child.role == .context,
                  let childAnchor = anchors[child.referenceID] else { return nil }
            return AnchorSummary(
                id: child.id,
                name: child.name,
                kind: child.kind,
                documentCount: childAnchor.memberArtifactIDs.count,
                linkCount: childAnchor.evidence.inboundLinkCount,
                modifiedAt: childAnchor.evidence.mostRecentModification
            )
        }.sorted {
            if $0.documentCount != $1.documentCount { return $0.documentCount > $1.documentCount }
            return ($0.name.embersNormalized, $0.id) < ($1.name.embersNormalized, $1.id)
        }

        var documentScores: [String: (weight: Double, edgeKind: String)] = [:]
        for edge in edgesByNode[nodeID, default: []] {
            if isFolder && edge.kind != "contains-directly" { continue }
            let otherID = edge.source == nodeID ? edge.target : edge.source
            guard let other = nodeByID[otherID], other.role == .document else { continue }
            let current = documentScores[other.referenceID]
            if current == nil || edge.weight > current!.weight { documentScores[other.referenceID] = (edge.weight, edge.kind) }
        }

        let phrases = [node.name] + node.aliases
        // Ingestion already materializes exact mentions as graph edges. Query those
        // postings directly instead of reparsing and regex-scanning the entire corpus.
        let rows: [(SourceArtifact, Double, Int, String)] = documentScores.compactMap { artifactID, evidence in
            guard let artifact = artifacts[artifactID] else { return nil }
            let semanticText = artifact.semanticText
            let structural = evidence.edgeKind == "contains-directly"
            let match = structural ? nil : firstPhraseMatch(phrases, in: semanticText)
            return (artifact, evidence.weight, contentUtility(artifact), snippet(around: match, in: semanticText))
        }
        let orderedRows = rows.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            if $0.0.rankingModifiedAt != $1.0.rankingModifiedAt { return $0.0.rankingModifiedAt > $1.0.rankingModifiedAt }
            return $0.0.id < $1.0.id
        }
        let hits = orderedRows.prefix(12).map { row in
            ContextHit(artifact: row.0, snippet: row.3, changedSinceLastPeek: row.0.metadata.modificationDateReliable != false && (lastSeen.map { row.0.modifiedAt > $0 } ?? false))
        }

        let subcontextIDs = Set(subcontexts.map(\.id))
        let related = nearestNodes(from: nodeID, maxDepth: 2, limit: 16).filter { result in
            guard !subcontextIDs.contains(result.node.id) else { return false }
            return !result.path.edgeIDs.contains { edgeByID[$0]?.kind == "contains-context" }
        }.prefix(8).map { result in
            let kinds = result.path.edgeIDs.compactMap { edgeByID[$0]?.kind }
            return RelatedAnchor(id: result.node.id, name: result.node.name, relationKind: kinds.joined(separator: " · "))
        }
        let tasks = orderedRows.flatMap { artifact, _, _, _ in
            artifact.metadata.tasks.filter { $0.state == .open }.map {
                AnchorTask(taskID: $0.id, artifactID: artifact.id, artifactTitle: artifact.title, text: $0.text, state: $0.state, line: $0.line, mutationToken: $0.mutationToken)
            }
        }.prefix(10)
        return AnchorDetail(anchor: anchor, hits: hits, subcontexts: subcontexts, relatedAnchors: Array(related), tasks: Array(tasks))
    }

    private func nearestNodes(from startID: String, maxDepth: Int, limit: Int) -> [(node: GraphNode, path: GraphPath)] {
        struct State {
            var nodeID: String
            var depth: Int
            var cost: Double
            var nodeIDs: [String]
            var edgeIDs: [String]
        }
        guard nodeByID[startID] != nil else { return [] }
        var frontier = [State(nodeID: startID, depth: 0, cost: 0, nodeIDs: [startID], edgeIDs: [])]
        var best = [startID: 0.0]
        var found: [(GraphNode, GraphPath)] = []
        while !frontier.isEmpty {
            frontier.sort { $0.cost == $1.cost ? $0.nodeID < $1.nodeID : $0.cost < $1.cost }
            let state = frontier.removeFirst()
            guard state.cost <= best[state.nodeID, default: .greatestFiniteMagnitude], state.depth < maxDepth else { continue }
            for edge in edgesByNode[state.nodeID, default: []] {
                let nextID = edge.source == state.nodeID ? edge.target : edge.source
                guard !state.nodeIDs.contains(nextID) else { continue }
                let cost = state.cost + 1 / max(edge.weight, 0.05)
                guard cost < best[nextID, default: .greatestFiniteMagnitude] else { continue }
                best[nextID] = cost
                let next = State(nodeID: nextID, depth: state.depth + 1, cost: cost, nodeIDs: state.nodeIDs + [nextID], edgeIDs: state.edgeIDs + [edge.id])
                if let node = nodeByID[nextID], node.activationEligible, nextID != startID {
                    found.append((node, .init(nodeIDs: next.nodeIDs, edgeIDs: next.edgeIDs, cost: cost)))
                }
                frontier.append(next)
            }
        }
        var seen = Set<String>()
        return found.sorted {
            if $0.1.cost != $1.1.cost { return $0.1.cost < $1.1.cost }
            if $0.0.importance != $1.0.importance { return $0.0.importance > $1.0.importance }
            return $0.0.id < $1.0.id
        }.filter { seen.insert($0.0.id).inserted }.prefix(limit).map { $0 }
    }
}

private func wholePhraseRange(_ phrase: String, in text: String) -> NSRange? {
    guard !phrase.isEmpty else { return nil }
    let source = text as NSString
    var search = NSRange(location: 0, length: source.length)
    while search.length > 0 {
        let match = source.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive], range: search)
        guard match.location != NSNotFound else { return nil }
        let before = match.location == 0 || isPhraseBoundary(source, at: match.location - 1)
        let end = NSMaxRange(match)
        let after = end == source.length || isPhraseBoundary(source, at: end)
        if before && after { return match }
        let next = max(end, match.location + 1)
        search = NSRange(location: next, length: source.length - next)
    }
    return nil
}

private func isPhraseBoundary(_ source: NSString, at index: Int) -> Bool {
    guard index >= 0, index < source.length else { return true }
    let range = source.rangeOfComposedCharacterSequence(at: index)
    let character = source.substring(with: range)
    var wordCharacters = CharacterSet.alphanumerics
    wordCharacters.insert(charactersIn: "_")
    return character.rangeOfCharacter(from: wordCharacters) == nil
}

private func firstPhraseMatch(_ phrases: [String], in text: String) -> NSRange? {
    phrases.compactMap { wholePhraseRange($0, in: text) }.min { $0.location < $1.location }
}

private func snippet(around range: NSRange?, in text: String) -> String {
    let compact = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    guard compact.count > 160 else { return compact }
    guard let range, let stringRange = Range(range, in: text) else { return String(compact.prefix(157)) + "…" }
    let lower = text.index(stringRange.lowerBound, offsetBy: -min(50, text.distance(from: text.startIndex, to: stringRange.lowerBound)))
    let upper = text.index(stringRange.upperBound, offsetBy: min(110, text.distance(from: stringRange.upperBound, to: text.endIndex)))
    let excerpt = text[lower..<upper].replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    return (lower > text.startIndex ? "…" : "") + String(excerpt.prefix(157)) + (upper < text.endIndex ? "…" : "")
}

private func contentUtility(_ artifact: SourceArtifact) -> Int {
    let text = artifact.semanticText
    let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    let prose = text.contains(".") || text.contains("!") || text.contains("?")
    let meaningfulTitle = !["untitled", "new page"].contains(artifact.title.embersNormalized)
    return min(words, 500) + (prose ? 100 : 0) + (meaningfulTitle ? 25 : 0)
}

private let literalStopWords: Set<String> = [
    "a", "an", "and", "are", "be", "can", "could", "do", "does", "find", "for", "from",
    "have", "how", "i", "in", "is", "it", "locate", "look", "lookup", "me", "my", "of",
    "on", "or", "please", "remind", "s", "search", "show", "tell", "that", "the", "this",
    "to", "up", "was", "what", "when", "where", "which", "who", "why", "with", "would",
    "you", "your"
]

private func literalQueryTerms(_ query: String) -> [String] {
    var seen = Set<String>()
    return literalTokenMatches(in: query).filter {
        !literalStopWords.contains($0) && seen.insert($0).inserted
    }
}

private func literalTokenMatches(in text: String) -> [String] {
    let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
}

private func literalContainsTermSequence(_ terms: [String], in tokens: [String]) -> Bool {
    guard terms.count > 1, tokens.count >= terms.count else { return false }
    return tokens.indices.contains { index in
        let end = index + terms.count
        return end <= tokens.count && Array(tokens[index..<end]) == terms
    }
}
