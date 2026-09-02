import Foundation

public enum GraphNodeRole: String, Hashable, Sendable {
    case context
    case document
}

public struct GraphNode: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var kind: String?
    public var role: GraphNodeRole
    public var activationEligible: Bool
    public var voiceEligible: Bool
    public var importance: Double
    public var referenceID: String

    public init(id: String, name: String, aliases: [String] = [], kind: String? = nil, role: GraphNodeRole, activationEligible: Bool, voiceEligible: Bool? = nil, importance: Double, referenceID: String) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.kind = kind
        self.role = role
        self.activationEligible = activationEligible
        self.voiceEligible = voiceEligible ?? activationEligible
        self.importance = importance
        self.referenceID = referenceID
    }
}

public struct GraphEdge: Identifiable, Hashable, Sendable {
    public var id: String
    public var source: String
    public var target: String
    public var kind: String
    public var evidence: RelationEvidence
    public var weight: Double
    public var provenance: RelationProvenance

    public init(id: String, source: String, target: String, kind: String, evidence: RelationEvidence, weight: Double, provenance: RelationProvenance = .init()) {
        self.id = id
        self.source = source
        self.target = target
        self.kind = kind
        self.evidence = evidence
        self.weight = weight
        self.provenance = provenance
    }
}

public struct ContextGraph: Sendable {
    public var revision: String
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]

    public init(revision: String, nodes: [GraphNode], edges: [GraphEdge]) {
        self.revision = revision
        self.nodes = nodes
        self.edges = edges
    }

    public var activationNodes: [GraphNode] { nodes.filter(\.activationEligible) }
    public var voiceNodes: [GraphNode] { nodes.filter(\.voiceEligible) }
}

public struct GraphPath: Hashable, Sendable {
    public var nodeIDs: [String]
    public var edgeIDs: [String]
    public var cost: Double

    public init(nodeIDs: [String], edgeIDs: [String], cost: Double) {
        self.nodeIDs = nodeIDs
        self.edgeIDs = edgeIDs
        self.cost = cost
    }
}

public enum NodeMatchKind: String, Hashable, Sendable {
    case canonicalName
    case alias
    case evidence
}

public struct NodeActivation: Hashable, Sendable {
    public var nodeID: String
    public var matchedPhrase: String
    public var matchKind: NodeMatchKind
    public var supportingArtifactID: String?
    public var path: GraphPath
    public var score: Double

    public init(nodeID: String, matchedPhrase: String, matchKind: NodeMatchKind, supportingArtifactID: String? = nil, path: GraphPath, score: Double) {
        self.nodeID = nodeID
        self.matchedPhrase = matchedPhrase
        self.matchKind = matchKind
        self.supportingArtifactID = supportingArtifactID
        self.path = path
        self.score = score
    }
}

public struct DeterministicContextGraphProjector: Sendable {
    public init() {}

    public func project(_ snapshot: ContextSnapshot, ignoring ignored: Set<String> = []) -> ContextGraph {
        var claimedNames = Set<String>()
        let anchorCount = max(snapshot.anchors.count, 1)
        var nodes = snapshot.anchors.enumerated().map { index, anchor in
            let durable = anchor.provenance.contains(.manifest)
                || anchor.provenance.contains(.frontmatter)
                || anchor.provenance.contains(.linkedDocument)
                || (anchor.provenance.contains(.folder) && anchor.memberArtifactIDs.count >= 2)
                || (anchor.provenance.contains(.tag) && anchor.memberArtifactIDs.count >= 2)
                || (anchor.provenance.contains(.unresolvedLink) && anchor.evidence.inboundLinkCount >= 2)
            let generatedName = isGeneratedImportName(anchor.canonicalName) && !anchor.provenance.contains(.manifest)
            let uniqueName = claimedNames.insert(anchor.canonicalName.embersNormalized).inserted
            let available = uniqueName && !generatedName && !ignored.contains(anchor.id)
            return GraphNode(
                id: anchor.id,
                name: anchor.canonicalName,
                aliases: anchor.aliases,
                kind: anchor.kind,
                role: .context,
                activationEligible: durable && available,
                voiceEligible: available && (durable || anchor.provenance.contains(.folder)),
                importance: Double(anchorCount - index) / Double(anchorCount),
                referenceID: anchor.id
            )
        }
        nodes += snapshot.artifacts.map {
            GraphNode(id: artifactNodeID($0.id), name: $0.title, kind: $0.mediaKind.rawValue, role: .document, activationEligible: false, voiceEligible: false, importance: 0, referenceID: $0.id)
        }

        let nodeIDs = Set(nodes.map(\.id))
        let artifactByID = Dictionary(uniqueKeysWithValues: snapshot.artifacts.map { ($0.id, $0) })
        let folderScopes = resolvedFolderScopes(anchors: snapshot.anchors, artifacts: snapshot.artifacts)
        var folderIDByScope: [String: String] = [:]
        for (id, scope) in folderScopes.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            // Imported snapshots can contain two anchors that resolve to one structural
            // scope after model/name merging. The stable first ID owns hierarchy edges.
            folderIDByScope[scope] = folderIDByScope[scope] ?? id
        }
        var edges: [GraphEdge] = []
        for anchor in snapshot.anchors {
            let membership = membershipSemantics(for: anchor)
            let artifactIDs: [String]
            if anchor.provenance.contains(.folder), let scope = folderScopes[anchor.id] {
                artifactIDs = anchor.memberArtifactIDs.filter { artifactID in
                    artifactByID[artifactID].map { parentGraphPath($0.graphRelativePath) == scope } ?? false
                }.sorted()
            } else {
                artifactIDs = anchor.memberArtifactIDs.sorted()
            }
            for artifactID in artifactIDs {
                let documentID = artifactNodeID(artifactID)
                guard nodeIDs.contains(documentID) else { continue }
                let endpoints = membership.documentFirst ? (documentID, anchor.id) : (anchor.id, documentID)
                edges.append(makeEdge(source: endpoints.0, target: endpoints.1, kind: membership.kind, evidence: membership.evidence, weight: membership.weight, provenance: .init(artifactID: artifactID)))
            }
        }
        for (childID, childScope) in folderScopes.sorted(by: { $0.value < $1.value }) {
            let parentScope = parentGraphPath(childScope)
            guard let parentID = folderIDByScope[parentScope], parentID != childID else { continue }
            edges.append(makeEdge(source: parentID, target: childID, kind: "contains-context", evidence: .extracted, weight: 0.9, provenance: .init(detail: childScope)))
        }
        for relation in snapshot.relations {
            let source = relation.source.hasPrefix("artifact:") ? relation.source : relation.source
            guard nodeIDs.contains(source), nodeIDs.contains(relation.target) else { continue }
            edges.append(makeEdge(
                source: source,
                target: relation.target,
                kind: relation.kind,
                evidence: relation.evidence ?? .extracted,
                weight: relation.weight ?? defaultWeight(for: relation.kind),
                provenance: relation.provenance
            ))
        }
        let stableEdges = Array(Set(edges)).sorted { ($0.source, $0.target, $0.kind, $0.id) < ($1.source, $1.target, $1.kind, $1.id) }
        return ContextGraph(revision: snapshot.revision, nodes: nodes, edges: stableEdges)
    }
}

private func isGeneratedImportName(_ name: String) -> Bool {
    let normalized = name.embersNormalized
    if normalized == "untitled" || normalized == "new page" { return true }
    guard normalized.hasPrefix("untitled ") else { return false }
    let suffix = normalized.dropFirst("untitled ".count)
    if suffix.allSatisfy(\.isNumber) { return true }
    let hexChunks = suffix.split(separator: "-")
    return hexChunks.count >= 2 && hexChunks.allSatisfy { chunk in
        chunk.count >= 4 && chunk.allSatisfy(\.isHexDigit)
    }
}

private func artifactNodeID(_ artifactID: String) -> String { "artifact:\(artifactID)" }

private func makeEdge(source: String, target: String, kind: String, evidence: RelationEvidence, weight: Double, provenance: RelationProvenance) -> GraphEdge {
    let material = "\(source)|\(target)|\(kind)|\(evidence.rawValue)|\(provenance.artifactID ?? "")|\(provenance.detail ?? "")"
    return GraphEdge(id: "edge-\(StableHash.hex(material))", source: source, target: target, kind: kind, evidence: evidence, weight: weight, provenance: provenance)
}

private func membershipSemantics(for anchor: Anchor) -> (kind: String, evidence: RelationEvidence, weight: Double, documentFirst: Bool) {
    if anchor.provenance.contains(.manifest) { return ("includes", .authored, 1.0, false) }
    if anchor.provenance.contains(.frontmatter) { return ("declares", .extracted, 0.9, true) }
    if anchor.provenance.contains(.linkedDocument) { return ("resolves-to", .extracted, 0.9, false) }
    if anchor.provenance.contains(.tag) { return ("tagged-with", .extracted, 0.4, true) }
    if anchor.provenance.contains(.folder) { return ("contains-directly", .extracted, 0.8, false) }
    return ("contains", .extracted, 0.25, false)
}

private func resolvedFolderScopes(anchors: [Anchor], artifacts: [SourceArtifact]) -> [String: String] {
    var allScopes = Set<String>()
    for artifact in artifacts {
        var scope = parentGraphPath(artifact.graphRelativePath)
        while !scope.isEmpty {
            allScopes.insert(scope)
            scope = parentGraphPath(scope)
        }
    }
    let membersByScope = Dictionary(uniqueKeysWithValues: allScopes.map { scope in
        (scope, Set(artifacts.filter { normalizedGraphPath($0.graphRelativePath).hasPrefix(scope + "/") }.map(\.id)))
    })
    var result: [String: String] = [:]
    for anchor in anchors where anchor.provenance.contains(.folder) {
        if let declared = anchor.scopePath { result[anchor.id] = normalizedGraphPath(declared); continue }
        let candidates = allScopes.filter { URL(fileURLWithPath: $0).lastPathComponent.embersNormalized == anchor.canonicalName.embersNormalized }
        if let exact = candidates.filter({ membersByScope[$0] == anchor.memberArtifactIDs }).sorted().first {
            result[anchor.id] = exact
        }
    }
    return result
}

private func normalizedGraphPath(_ path: String) -> String {
    NSString(string: path.replacingOccurrences(of: "\\", with: "/")).standardizingPath
}

private func parentGraphPath(_ path: String) -> String {
    let parent = NSString(string: normalizedGraphPath(path)).deletingLastPathComponent
    return parent == "." ? "" : parent
}

private func defaultWeight(for kind: String) -> Double {
    switch kind {
    case "links-to": return 0.95
    case "mentions": return 0.75
    default: return 0.7
    }
}
