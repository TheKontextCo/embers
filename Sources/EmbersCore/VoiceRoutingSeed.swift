import Foundation

/// Precision-first voice addressability derived from graph provenance. Unresolved
/// links can represent useful concepts, but template/schema placeholders are not
/// contexts a person can meaningfully address.
public struct VoiceRoutingAddressabilityPolicy: Sendable {
    public init() {}

    public func nodes(in graph: ContextGraph, snapshot: ContextSnapshot) -> [GraphNode] {
        guard graph.revision == snapshot.revision else { return [] }
        let anchorByID = Dictionary(uniqueKeysWithValues: snapshot.anchors.map { ($0.id, $0) })
        let artifactByID = Dictionary(uniqueKeysWithValues: snapshot.artifacts.map { ($0.id, $0) })
        let authoredLinkSources = Dictionary(grouping: snapshot.relations.filter {
            $0.kind == "links-to" && $0.provenance.artifactID != nil
        }, by: \.target).mapValues { relations in
            relations.compactMap(\.provenance.artifactID)
        }
        let linkTargetsByArtifactID = Dictionary(grouping: snapshot.relations.filter {
            $0.kind == "links-to" && $0.provenance.artifactID != nil
        }, by: { $0.provenance.artifactID! }).mapValues { relations in
            Set(relations.map(\.target))
        }
        let scaffoldArtifacts = snapshot.artifacts.filter {
            isScaffoldingPath($0.graphRelativePath)
        }
        let inheritedTemplateTargetsByArtifactID: [String: Set<String>] = Dictionary(uniqueKeysWithValues: snapshot.artifacts.compactMap { artifact in
            guard !isScaffoldingPath(artifact.graphRelativePath) else { return nil }
            let templates = scaffoldArtifacts.filter { followsTemplateSchema(artifact, template: $0) }
            guard !templates.isEmpty else { return nil }
            let inheritedTargets = templates.reduce(into: Set<String>()) { result, template in
                result.formUnion(linkTargetsByArtifactID[template.id, default: []])
            }
            return inheritedTargets.isEmpty ? nil : (artifact.id, inheritedTargets)
        })

        return graph.voiceNodes.filter { node in
            guard let anchor = anchorByID[node.referenceID] else { return false }
            guard anchor.provenance == [.unresolvedLink], anchor.memberArtifactIDs.isEmpty else { return true }

            // A scaffold link is schema, not a durable context. Documents copied
            // from that scaffold retain the same structural heading/tag signature;
            // links inherited from the matching template remain schema even after
            // the copy moves outside the scaffold folder. Any genuinely independent
            // source still makes the unresolved concept addressable.
            let sourceIDs = authoredLinkSources[anchor.id, default: []]
            guard !sourceIDs.isEmpty else { return false }
            return !sourceIDs.allSatisfy { artifactID in
                guard let artifact = artifactByID[artifactID] else { return false }
                if isScaffoldingPath(artifact.graphRelativePath) { return true }
                return inheritedTemplateTargetsByArtifactID[artifactID, default: []].contains(anchor.id)
            }
        }
    }
}

/// Deterministic, bounded evidence supplied to an optional local semantic compiler.
/// Only direct document membership contributes content; child context evidence is
/// deliberately not flattened into its parent.
public struct VoiceRoutingSeed: Codable, Hashable, Sendable {
    public var nodeID: String
    public var canonicalName: String
    public var existingAliases: [String]
    public var kind: String?
    /// Hierarchy is contrastive context only. It must never be promoted into
    /// positive vocabulary for this node.
    public var contextOnlyAncestry: [String]
    /// Child names identify concepts owned by the children, not the parent.
    /// They may only inform confusers and negatives for this node.
    public var contextOnlyChildNames: [String]
    public var directArtifactTitles: [String]
    public var directHeadingsAndTags: [String]
    /// Kept separately so the compiler can distinguish authored taxonomy from
    /// structural document headings when composing grounded spoken names.
    public var directTags: [String]
    public var directExcerpts: [String]
    public var evidenceHash: String

    public init(
        nodeID: String,
        canonicalName: String,
        existingAliases: [String],
        kind: String?,
        contextOnlyAncestry: [String],
        contextOnlyChildNames: [String],
        directArtifactTitles: [String],
        directHeadingsAndTags: [String],
        directTags: [String],
        directExcerpts: [String],
        evidenceHash: String
    ) {
        self.nodeID = nodeID
        self.canonicalName = canonicalName
        self.existingAliases = existingAliases
        self.kind = kind
        self.contextOnlyAncestry = contextOnlyAncestry
        self.contextOnlyChildNames = contextOnlyChildNames
        self.directArtifactTitles = directArtifactTitles
        self.directHeadingsAndTags = directHeadingsAndTags
        self.directTags = directTags
        self.directExcerpts = directExcerpts
        self.evidenceHash = evidenceHash
    }
}

/// Stable identity for the exact grounded inputs consumed by voice compilation.
/// Transport and task-state revisions are deliberately excluded because they do
/// not change how a context can be addressed.
public enum VoiceRoutingInputRevision {
    public static func make(_ seeds: [VoiceRoutingSeed]) -> String {
        StableHash.hex(seeds.sorted { $0.nodeID < $1.nodeID }.map {
            "\($0.nodeID)\u{1f}\($0.evidenceHash)"
        }.joined(separator: "\u{1e}"))
    }
}

public struct VoiceRoutingSeedBuilder: Sendable {
    public init() {}

    public func build(
        graph: ContextGraph,
        snapshot: ContextSnapshot,
        titleLimit: Int = 8,
        termLimit: Int = 12,
        excerptLimit: Int = 4,
        excerptLength: Int = 240
    ) -> [VoiceRoutingSeed] {
        guard graph.revision == snapshot.revision else { return [] }

        let nodeByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let anchorByID = Dictionary(uniqueKeysWithValues: snapshot.anchors.map { ($0.id, $0) })
        let artifactByID = Dictionary(uniqueKeysWithValues: snapshot.artifacts.map { ($0.id, $0) })
        let hierarchyEdges = graph.edges.filter { $0.kind == "contains-context" }
        let parentByChild = Dictionary(
            hierarchyEdges.map { ($0.target, $0.source) },
            uniquingKeysWith: { first, _ in first }
        )
        let childrenByParent = Dictionary(grouping: hierarchyEdges, by: \.source)
            .mapValues { edges in edges.map(\.target).sorted() }
        let membershipKinds: Set<String> = [
            "contains-directly", "includes", "declares", "resolves-to",
            "tagged-with", "evidenced-by", "contains"
        ]
        var artifactIDsByNode: [String: Set<String>] = [:]
        for edge in graph.edges where membershipKinds.contains(edge.kind) {
            let endpoints = [(edge.source, edge.target), (edge.target, edge.source)]
            for (contextID, documentID) in endpoints {
                guard nodeByID[contextID]?.role == .context,
                      let document = nodeByID[documentID], document.role == .document else { continue }
                artifactIDsByNode[contextID, default: []].insert(document.referenceID)
            }
        }

        func ancestors(of nodeID: String) -> [String] {
            var result: [String] = []
            var cursor = parentByChild[nodeID]
            var visited = Set<String>()
            while let id = cursor, visited.insert(id).inserted {
                if let name = nodeByID[id]?.name { result.append(name) }
                cursor = parentByChild[id]
            }
            return result.reversed()
        }

        let orderedNodes = VoiceRoutingAddressabilityPolicy().nodes(in: graph, snapshot: snapshot).sorted {
            let lhsDepth = ancestors(of: $0.id).count
            let rhsDepth = ancestors(of: $1.id).count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            if $0.importance != $1.importance { return $0.importance > $1.importance }
            return ($0.name.embersNormalized, $0.id) < ($1.name.embersNormalized, $1.id)
        }

        var seeds: [VoiceRoutingSeed] = []
        for node in orderedNodes {
            guard let anchor = anchorByID[node.referenceID] else { continue }
            let artifactIDs = artifactIDsByNode[node.id, default: []]
            let artifacts = artifactIDs.compactMap { artifactByID[$0] }.sorted {
                ($0.title.embersNormalized, $0.id) < ($1.title.embersNormalized, $1.id)
            }
            let titleCandidates = artifacts.map(\.title).filter(validEvidencePhrase)
            let titles = Array(unique(titleCandidates).prefix(max(titleLimit, 0)))
            let termCandidates = artifacts.flatMap { artifact -> [String] in
                let tags = artifact.metadata.tags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
                return artifact.metadata.headings + tags
            }.filter(validEvidencePhrase)
            let terms = Array(unique(termCandidates).prefix(max(termLimit, 0)))
            let tagCandidates = artifacts.flatMap { artifact in
                artifact.metadata.tags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            }.filter(validEvidencePhrase)
            let tags = Array(unique(tagCandidates).prefix(max(termLimit, 0)))
            let excerptCandidates = artifacts.compactMap { boundedExcerpt($0.semanticText, length: excerptLength) }
            let excerpts = Array(unique(excerptCandidates).prefix(max(excerptLimit, 0)))
            let ancestry = ancestors(of: node.id)
            let childIDs = childrenByParent[node.id, default: []]
            let children = childIDs.compactMap { nodeByID[$0]?.name }.sorted {
                $0.embersNormalized < $1.embersNormalized
            }
            let aliases = unique(node.aliases.filter(validEvidencePhrase))
            // Role markers make the seed hash sensitive to evidence provenance.
            // The same phrase moving from a child into a direct artifact must
            // invalidate the cache because it has changed from contrastive to
            // positive evidence.
            let material = [
                "identity", node.id, node.name, node.kind ?? "",
                "existing-aliases", aliases.joined(separator: "\u{1e}"),
                "context-only-ancestry", ancestry.joined(separator: "\u{1e}"),
                "context-only-children", children.joined(separator: "\u{1e}"),
                "direct-artifact-titles", titles.joined(separator: "\u{1e}"),
                "direct-headings-tags", terms.joined(separator: "\u{1e}"),
                "direct-tags", tags.joined(separator: "\u{1e}"),
                "direct-excerpts", excerpts.joined(separator: "\u{1e}"),
            ].joined(separator: "\u{1f}")
            seeds.append(VoiceRoutingSeed(
                nodeID: node.id,
                canonicalName: node.name,
                existingAliases: aliases,
                kind: node.kind ?? voiceRoutingKind(anchor),
                contextOnlyAncestry: ancestry,
                contextOnlyChildNames: children,
                directArtifactTitles: titles,
                directHeadingsAndTags: terms,
                directTags: tags,
                directExcerpts: excerpts,
                evidenceHash: StableHash.hex(material)
            ))
        }
        return seeds
    }
}

private func voiceRoutingKind(_ anchor: Anchor) -> String? {
    let precedence: [(AnchorProvenance, String)] = [
        (.manifest, "manifest"),
        (.frontmatter, "frontmatter"),
        (.linkedDocument, "linkedDocument"),
        (.folder, "folder"),
        (.tag, "tag"),
        (.unresolvedLink, "unresolvedLink"),
    ]
    return precedence.first(where: { anchor.provenance.contains($0.0) })?.1
}

private func isScaffoldingPath(_ path: String) -> Bool {
    path.split(separator: "/").dropLast().contains { component in
        component.hasPrefix("_") || component.hasPrefix(".")
    }
}

/// Detect copied template lineage from durable structure rather than placeholder
/// names. Tags identify the schema family and the template's heading sequence must
/// survive intact; copied notes may insert their own headings between schema slots.
private func followsTemplateSchema(_ artifact: SourceArtifact, template: SourceArtifact) -> Bool {
    let templateTags = Set(template.metadata.tags.map(\.embersNormalized).filter { !$0.isEmpty })
    let artifactTags = Set(artifact.metadata.tags.map(\.embersNormalized).filter { !$0.isEmpty })
    guard !templateTags.isEmpty, !templateTags.isDisjoint(with: artifactTags) else { return false }

    let templateHeadings = template.metadata.headings.map(\.embersNormalized).filter { !$0.isEmpty }
    let artifactHeadings = artifact.metadata.headings.map(\.embersNormalized).filter { !$0.isEmpty }
    guard templateHeadings.count >= 3, artifactHeadings.count >= templateHeadings.count else { return false }
    return isOrderedSubsequence(templateHeadings, of: artifactHeadings)
}

private func isOrderedSubsequence(_ needle: [String], of haystack: [String]) -> Bool {
    var index = needle.startIndex
    for value in haystack where index < needle.endIndex && value == needle[index] {
        index = needle.index(after: index)
    }
    return index == needle.endIndex
}

private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.compactMap { value in
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return seen.insert(trimmed.embersNormalized).inserted ? trimmed : nil
    }
}

private func validEvidencePhrase(_ value: String) -> Bool {
    let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = value.embersNormalized
    guard !normalized.isEmpty, normalized.count <= 100 else { return false }
    guard !containsMetadataSyntax(raw) else { return false }
    guard normalized.range(of: #"\b[0-9a-f]{24,}\b"#, options: .regularExpression) == nil else { return false }
    return true
}

private func boundedExcerpt(_ text: String, length: Int) -> String? {
    var insideFence = false
    let semanticLines = text.components(separatedBy: .newlines).compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            insideFence.toggle()
            return nil
        }
        guard !insideFence, !trimmed.isEmpty else { return nil }
        // Headings and callout/template instructions are structural context,
        // not note prose. Their authored labels remain available separately.
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(">") else { return nil }
        return trimmed.replacingOccurrences(of: #"^[-*+]\s+"#, with: "", options: .regularExpression)
    }
    let selected = semanticLines.first(where: { $0.split(whereSeparator: \.isWhitespace).count >= 6 })
        ?? semanticLines.first
        ?? ""
    let collapsed = selected.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty, length > 0, !containsMetadataSyntax(collapsed) else { return nil }
    if collapsed.count <= length { return collapsed }
    let end = collapsed.index(collapsed.startIndex, offsetBy: length)
    let prefix = collapsed[..<end]
    if let boundary = prefix.lastIndex(where: { $0 == " " }) {
        return String(prefix[..<boundary])
    }
    return String(prefix)
}

private func containsMetadataSyntax(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    if lowercased.contains("://") || value.contains("/") || value.contains("\\") { return true }
    if value.contains("\n") || value.hasPrefix("---") { return true }
    return value.range(of: #"^[A-Za-z][A-Za-z0-9_-]*:\s"#, options: .regularExpression) != nil
}
