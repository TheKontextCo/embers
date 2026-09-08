import Foundation

public struct DeterministicGraphBuilder: Sendable {
    public init() {}

    public func build(from scan: SourceScan, mentionCache: GraphMentionCache? = nil) throws -> ContextSnapshot {
        var state = GraphBuildState(scan: scan)
        state.addDeclarations()
        state.addFolderAnchors()
        state.addMetadataAnchors()
        state.addLinks()
        return try state.snapshot(mentionCache: mentionCache)
    }

    public static func ranksBefore(_ lhs: Anchor, _ rhs: Anchor) -> Bool {
        let l = lhs.evidence, r = rhs.evidence
        if l.manifest != r.manifest { return l.manifest }
        if l.frontmatter != r.frontmatter { return l.frontmatter }
        if l.folder != r.folder { return l.folder }
        if l.inboundLinkCount != r.inboundLinkCount { return l.inboundLinkCount > r.inboundLinkCount }
        if lhs.memberArtifactIDs.count != rhs.memberArtifactIDs.count { return lhs.memberArtifactIDs.count > rhs.memberArtifactIDs.count }
        if l.exactMentionCount != r.exactMentionCount { return l.exactMentionCount > r.exactMentionCount }
        if l.mostRecentModification != r.mostRecentModification { return l.mostRecentModification > r.mostRecentModification }
        return lhs.id < rhs.id
    }
}

private struct GraphBuildState {
    let scan: SourceScan
    let artifacts: [SourceArtifact]
    let artifactByPath: [String: SourceArtifact]
    let stemGroups: [String: [SourceArtifact]]
    var diagnostics: [ContextDiagnostic]
    var anchors: [String: Anchor] = [:]
    var relations: [ContextRelation] = []

    init(scan: SourceScan) {
        self.scan = scan
        artifacts = scan.artifacts.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        diagnostics = scan.diagnostics
        artifactByPath = Dictionary(uniqueKeysWithValues: artifacts.map { (normalizedPath($0.relativePath), $0) })
        stemGroups = Dictionary(grouping: artifacts, by: { URL(fileURLWithPath: $0.relativePath).deletingPathExtension().lastPathComponent.embersNormalized })
    }

    mutating func merge(_ candidate: Anchor) {
        if var existing = anchors[candidate.id] {
            existing.aliases = Array(Set(existing.aliases + candidate.aliases)).sorted(by: stableNameOrder)
            existing.provenance.formUnion(candidate.provenance)
            existing.memberArtifactIDs.formUnion(candidate.memberArtifactIDs)
            existing.kind = existing.kind ?? candidate.kind
            existing.scopePath = existing.scopePath ?? candidate.scopePath
            existing.evidence.manifest = existing.evidence.manifest || candidate.evidence.manifest
            existing.evidence.frontmatter = existing.evidence.frontmatter || candidate.evidence.frontmatter
            existing.evidence.folder = existing.evidence.folder || candidate.evidence.folder
            existing.evidence.mostRecentModification = max(existing.evidence.mostRecentModification, candidate.evidence.mostRecentModification)
            anchors[candidate.id] = existing
        } else {
            anchors[candidate.id] = candidate
        }
    }

    func implicitID(_ category: String, _ value: String) -> String {
        "\(category)-\(StableHash.hex(scan.sourceID + ":" + value.embersNormalized))"
    }

    // Provider declarations are authoritative, but malformed members and
    // relations remain non-fatal. Folder manifests have already been adapted
    // into this provider-neutral representation by their source.
    mutating func addDeclarations() {
        guard let declarations = scan.declarations else { return }
        if declarations.version != 1 {
            diagnostics.append(.init(id: "declarations-version", severity: .warning, message: "Unsupported context declaration version \(declarations.version); automatic discovery continued."))
        } else {
            var seen = Set<String>()
            let artifactIDs = Set(artifacts.map(\.id))
            for declaration in declarations.contexts {
                guard !declaration.id.trimmingCharacters(in: .whitespaces).isEmpty,
                      !declaration.name.trimmingCharacters(in: .whitespaces).isEmpty,
                      seen.insert(declaration.id).inserted else {
                    diagnostics.append(.init(id: "declaration-context-\(StableHash.hex(declaration.id + declaration.name))", severity: .warning, message: "Ignored an invalid or duplicate context declaration."))
                    continue
                }
                let members = Set(declaration.artifactIDs.filter(artifactIDs.contains))
                for missingID in Set(declaration.artifactIDs).subtracting(artifactIDs).sorted() {
                    diagnostics.append(.init(id: "declaration-missing-artifact-\(StableHash.hex(missingID))", severity: .warning, message: "Context declaration references an unavailable artifact.", path: missingID))
                }
                merge(.init(id: declaration.id, canonicalName: declaration.name, aliases: declaration.aliases, kind: declaration.kind, provenance: [.manifest], evidence: .init(manifest: true, mostRecentModification: mostRecent(members, in: artifacts)), memberArtifactIDs: members))
            }
            for relation in declarations.relations {
                guard anchors[relation.from] != nil, anchors[relation.to] != nil, !relation.kind.isEmpty else {
                    diagnostics.append(.init(id: "declaration-relation-\(StableHash.hex(relation.from + relation.to + relation.kind))", severity: .warning, message: "Ignored a context relation with a missing context."))
                    continue
                }
                relations.append(.init(source: relation.from, target: relation.to, kind: relation.kind, provenance: .init(detail: relation.detail ?? "declaration"), evidence: .authored, weight: 1.0))
            }
        }
    }

    // Every visible folder is a speakable anchor.
    mutating func addFolderAnchors() {
        var folderPaths = Set<String>()
        for artifact in artifacts {
            let components = artifact.graphRelativePath.split(separator: "/").dropLast()
            var accumulated: [Substring] = []
            for component in components where !component.hasPrefix(".") {
                accumulated.append(component)
                folderPaths.insert(accumulated.joined(separator: "/"))
            }
        }
        for folder in folderPaths.sorted() {
            let memberArtifacts = artifacts.filter { normalizedPath($0.graphRelativePath).hasPrefix(folder + "/") }
            let members = Set(memberArtifacts.map(\.id))
            let name = URL(fileURLWithPath: folder).lastPathComponent
            let kind = memberArtifacts.contains(where: { $0.metadata.importKind == "notion" }) ? "collection" : nil
            merge(.init(id: implicitID("folder", folder), canonicalName: name, kind: kind, provenance: [.folder], evidence: .init(folder: true, mostRecentModification: mostRecent(members, in: artifacts)), memberArtifactIDs: members, scopePath: folder))
        }
    }

    // Frontmatter titles make useful anchors, but only an explicit identity or
    // alias is strong enough to outrank structural folder evidence. A plain
    // `title` is common in generated documentation and example content.
    mutating func addMetadataAnchors() {
        for artifact in artifacts {
            if artifact.metadata.declaredTitle != nil || artifact.metadata.explicitID != nil || !artifact.metadata.aliases.isEmpty {
                let id = artifact.metadata.explicitID ?? implicitID("artifact", artifact.relativePath)
                let hasExplicitIdentity = artifact.metadata.explicitID != nil || !artifact.metadata.aliases.isEmpty
                merge(.init(id: id, canonicalName: artifact.title, aliases: artifact.metadata.aliases, kind: artifact.metadata.kind, provenance: [.frontmatter], evidence: .init(frontmatter: hasExplicitIdentity, mostRecentModification: artifact.rankingModifiedAt), memberArtifactIDs: [artifact.id]))
            }
            for tag in artifact.metadata.tags {
                let clean = tag.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                guard !clean.isEmpty else { continue }
                merge(.init(id: implicitID("tag", clean), canonicalName: clean, kind: "tag", provenance: [.tag], evidence: .init(mostRecentModification: artifact.rankingModifiedAt), memberArtifactIDs: [artifact.id]))
            }
        }
    }

    // Explicit links promote their destination, even when the target does not exist yet.
    mutating func addLinks() {
        for source in artifacts {
            for link in source.metadata.links {
                let resolution = resolve(link: link, from: source, artifactByPath: artifactByPath, stemGroups: stemGroups)
                if link.kind == .embed {
                    if let target = resolution.artifact {
                        relations.append(.init(source: "artifact:\(source.id)", target: "artifact:\(target.id)", kind: "embeds", provenance: .init(artifactID: source.id, detail: link.kind.rawValue), evidence: .extracted, weight: 0.8))
                    }
                    continue
                }
                let targetAnchorID: String
                if let target = resolution.artifact {
                    targetAnchorID = target.metadata.explicitID ?? implicitID("artifact", target.relativePath)
                    merge(.init(id: targetAnchorID, canonicalName: target.title, aliases: target.metadata.aliases, kind: target.metadata.kind, provenance: [.linkedDocument], evidence: .init(mostRecentModification: target.rankingModifiedAt), memberArtifactIDs: [target.id]))
                } else {
                    let name = resolution.virtualName
                    targetAnchorID = implicitID("virtual", name)
                    merge(.init(id: targetAnchorID, canonicalName: name, provenance: [.unresolvedLink], evidence: .init(mostRecentModification: source.rankingModifiedAt)))
                }
                let sourceAnchor = source.metadata.explicitID ?? implicitID("artifact", source.relativePath)
                relations.append(.init(source: anchors[sourceAnchor] == nil ? "artifact:\(source.id)" : sourceAnchor, target: targetAnchorID, kind: "links-to", provenance: .init(artifactID: source.id, detail: link.kind.rawValue), evidence: .extracted, weight: 0.95))
            }
        }
    }

    // Build one phrase automaton, then retain exact per-document matches as graph edges.
    // This keeps node retrieval explainable without doing anchor × document regex work.
    mutating func snapshot(mentionCache: GraphMentionCache?) throws -> ContextSnapshot {
        let mentionPostings = mentionCache?.postings(anchors: anchors, artifacts: artifacts)
            ?? exactMentionPostings(anchors: anchors, artifacts: artifacts)
        let inboundLinkCounts = Dictionary(grouping: relations.filter { $0.kind == "links-to" }, by: \.target).mapValues(\.count)
        var mentionCounts: [String: Int] = [:]
        for artifactID in mentionPostings.keys.sorted() {
            for anchorID in mentionPostings[artifactID]!.keys.sorted() {
                let count = mentionPostings[artifactID]![anchorID]!
                mentionCounts[anchorID, default: 0] += count
                guard let anchor = anchors[anchorID], shouldMaterializeMentionEdge(anchor, inboundLinks: inboundLinkCounts[anchorID, default: 0]) else { continue }
                relations.append(.init(
                    source: "artifact:\(artifactID)",
                    target: anchorID,
                    kind: "mentions",
                    provenance: .init(artifactID: artifactID, detail: "count:\(count)"),
                    evidence: .extracted,
                    weight: 0.75
                ))
            }
        }
        for id in anchors.keys.sorted() {
            guard var anchor = anchors[id] else { continue }
            anchor.evidence.inboundLinkCount = inboundLinkCounts[id, default: 0]
            anchor.evidence.exactMentionCount = mentionCounts[id, default: 0]
            anchors[id] = anchor
        }

        let ranked = anchors.values.sorted(by: DeterministicGraphBuilder.ranksBefore)
        let stableRelations = Array(Set(relations)).sorted {
            ($0.source, $0.target, $0.kind, $0.provenance.artifactID ?? "") < ($1.source, $1.target, $1.kind, $1.provenance.artifactID ?? "")
        }
        let revisionMaterial = artifacts.map { "\($0.id):\($0.contentHash):\($0.relativePath):\($0.graphRelativePath):\($0.metadata.importKind ?? ""):\($0.metadata.modificationDateReliable.map(String.init) ?? "")" }.joined(separator: "|")
            + ranked.map { anchor in
                "\(anchor.id):\(anchor.canonicalName):\(anchor.aliases.joined(separator: ",")):\(anchor.kind ?? ""):\(anchor.scopePath ?? ""):\(anchor.provenance.map(\.rawValue).sorted().joined(separator: ",")):\(anchor.memberArtifactIDs.sorted().joined(separator: ",")):\(anchor.evidence.manifest):\(anchor.evidence.frontmatter):\(anchor.evidence.folder):\(anchor.evidence.inboundLinkCount):\(anchor.evidence.exactMentionCount):\(anchor.evidence.mostRecentModification.timeIntervalSince1970)"
            }.joined(separator: "|")
            + stableRelations.map { "\($0.source):\($0.target):\($0.kind):\($0.evidence?.rawValue ?? ""):\($0.weight ?? 0):\($0.provenance.detail ?? "")" }.joined(separator: "|")
        return try ContextSnapshot(sourceID: scan.sourceID, revision: StableHash.hex(revisionMaterial), artifacts: artifacts, anchors: ranked, relations: stableRelations, diagnostics: diagnostics.sorted { $0.id < $1.id }, indexedAt: scan.indexedAt).validated()
    }
}

private struct LinkResolution { var artifact: SourceArtifact?; var virtualName: String }

private func resolve(link: ArtifactLink, from source: SourceArtifact, artifactByPath: [String: SourceArtifact], stemGroups: [String: [SourceArtifact]]) -> LinkResolution {
    let stripped = link.target.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines)
    let decoded = stripped.removingPercentEncoding ?? stripped
    let sourceDirectory = NSString(string: source.relativePath).deletingLastPathComponent
    var candidates = [decoded, decoded + ".md", decoded + ".markdown"]
    if !sourceDirectory.isEmpty && sourceDirectory != "." { candidates += candidates.map { sourceDirectory + "/" + $0 } }
    for candidate in candidates {
        if let artifact = artifactByPath[normalizedPath(candidate)] { return .init(artifact: artifact, virtualName: artifact.title) }
    }
    let stem = URL(fileURLWithPath: decoded).deletingPathExtension().lastPathComponent.embersNormalized
    if let matches = stemGroups[stem], matches.count == 1 { return .init(artifact: matches[0], virtualName: matches[0].title) }
    let virtual = link.label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? URL(fileURLWithPath: decoded).deletingPathExtension().lastPathComponent
    return .init(artifact: nil, virtualName: virtual)
}

private func normalizedPath(_ path: String) -> String {
    let standardized = NSString(string: path.replacingOccurrences(of: "\\", with: "/")).standardizingPath
    return standardized.hasPrefix("./") ? String(standardized.dropFirst(2)) : standardized
}

private func mostRecent(_ ids: Set<String>, in artifacts: [SourceArtifact]) -> Date {
    artifacts.filter { ids.contains($0.id) }.map(\.rankingModifiedAt).max() ?? .distantPast
}

private func stableNameOrder(_ lhs: String, _ rhs: String) -> Bool {
    lhs.embersNormalized == rhs.embersNormalized ? lhs < rhs : lhs.embersNormalized < rhs.embersNormalized
}

private func lexicalFold(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
}

private struct PhrasePattern {
    var characters: [Character]
    var anchorIDs: [String]
}

private struct PhraseOwner {
    var anchor: Anchor
    var canonical: Bool
}

private struct PhraseTrieNode {
    var transitions: [Character: Int] = [:]
    var failure = 0
    var outputs: [Int] = []
}

private struct PhraseAutomaton {
    var patterns: [PhrasePattern]
    var nodes: [PhraseTrieNode]
}

/// Optional, source-owned acceleration. The uncached builder remains the correctness oracle.
/// Entries are bounded to the current source and invalidated by text or phrase ownership.
public final class GraphMentionCache: @unchecked Sendable {
    fileprivate struct Entry {
        var rawText: String
        var foldedText: String
        var counts: [String: Int]
    }
    private let lock = NSLock()
    fileprivate var entries: [String: Entry] = [:]
    fileprivate var owners: [String: String] = [:]
    fileprivate var localeIdentifier = ""
    public init() {}

    fileprivate func postings(anchors: [String: Anchor], artifacts: [SourceArtifact]) -> [String: [String: Int]] {
        lock.withLock { exactMentionPostings(anchors: anchors, artifacts: artifacts, cache: self) }
    }
}

private func exactMentionPostings(anchors: [String: Anchor], artifacts: [SourceArtifact], cache: GraphMentionCache? = nil) -> [String: [String: Int]] {
    let owners = phraseOwners(from: anchors)
    let sameLocale = cache?.localeIdentifier == Locale.current.identifier
    let sameOwners = sameLocale && cache?.owners == owners
    var nextEntries: [String: GraphMentionCache.Entry] = [:]
    defer { update(cache: cache, entries: nextEntries, owners: owners) }
    guard let automaton = makePhraseAutomaton(owners: owners) else { return [:] }
    let result = scanMentionPostings(
        automaton: automaton, artifacts: artifacts, previousEntries: cache?.entries,
        canReuseEntries: sameOwners && sameLocale, canReuseFoldedText: sameLocale,
        retainEntries: cache != nil
    )
    nextEntries = result.entries
    return result.postings
}

private func phraseOwners(from anchors: [String: Anchor]) -> [String: String] {
    var candidates: [String: [PhraseOwner]] = [:]
    for anchor in anchors.values {
        for (rawPhrase, canonical) in [(anchor.canonicalName, true)] + anchor.aliases.map({ ($0, false) }) {
            let phrase = lexicalFold(rawPhrase)
            if !phrase.isEmpty { candidates[phrase, default: []].append(.init(anchor: anchor, canonical: canonical)) }
        }
    }
    return candidates.mapValues { values in
        values.sorted {
            if $0.canonical != $1.canonical { return $0.canonical }
            return DeterministicGraphBuilder.ranksBefore($0.anchor, $1.anchor)
        }.first!.anchor.id
    }
}

private func update(cache: GraphMentionCache?, entries: [String: GraphMentionCache.Entry], owners: [String: String]) {
    cache?.entries = entries
    cache?.owners = owners
    cache?.localeIdentifier = Locale.current.identifier
}

private func makePhraseAutomaton(owners: [String: String]) -> PhraseAutomaton? {
    let patterns = owners.keys.sorted().map { PhrasePattern(characters: Array($0), anchorIDs: [owners[$0]!]) }
    guard !patterns.isEmpty else { return nil }

    var nodes = [PhraseTrieNode()]
    for (patternIndex, pattern) in patterns.enumerated() {
        var state = 0
        for character in pattern.characters {
            if let next = nodes[state].transitions[character] {
                state = next
            } else {
                nodes.append(PhraseTrieNode())
                let next = nodes.count - 1
                nodes[state].transitions[character] = next
                state = next
            }
        }
        nodes[state].outputs.append(patternIndex)
    }

    var queue = Array(nodes[0].transitions.values).sorted()
    var queueIndex = 0
    while queueIndex < queue.count {
        let state = queue[queueIndex]
        queueIndex += 1
        for (character, next) in nodes[state].transitions.sorted(by: { $0.key < $1.key }) {
            queue.append(next)
            var failure = nodes[state].failure
            while failure != 0 && nodes[failure].transitions[character] == nil { failure = nodes[failure].failure }
            if let target = nodes[failure].transitions[character], target != next { nodes[next].failure = target }
            nodes[next].outputs.append(contentsOf: nodes[nodes[next].failure].outputs)
        }
    }

    return .init(patterns: patterns, nodes: nodes)
}

private func scanMentionPostings(
    automaton: PhraseAutomaton,
    artifacts: [SourceArtifact],
    previousEntries: [String: GraphMentionCache.Entry]?,
    canReuseEntries: Bool,
    canReuseFoldedText: Bool,
    retainEntries: Bool
) -> (postings: [String: [String: Int]], entries: [String: GraphMentionCache.Entry]) {
    var postings: [String: [String: Int]] = [:]
    var entries: [String: GraphMentionCache.Entry] = [:]
    for artifact in artifacts {
        let previous = previousEntries?[artifact.id]
        let sameText = canReuseFoldedText && previous?.rawText == artifact.extractedText
        if sameText, canReuseEntries, let previous {
            if retainEntries { entries[artifact.id] = previous }
            if !previous.counts.isEmpty { postings[artifact.id] = previous.counts }
            continue
        }
        let foldedText = sameText ? previous!.foldedText : lexicalFold(artifact.semanticText)
        let text = Array(foldedText)
        var counts: [String: Int] = [:]
        var state = 0
        for index in text.indices {
            let character = text[index]
            while state != 0 && automaton.nodes[state].transitions[character] == nil { state = automaton.nodes[state].failure }
            state = automaton.nodes[state].transitions[character] ?? 0
            for output in automaton.nodes[state].outputs {
                let pattern = automaton.patterns[output]
                let beforeIndex = index - pattern.characters.count
                let afterIndex = index + 1
                let before = beforeIndex >= 0 ? text[beforeIndex] : nil
                let after = afterIndex < text.count ? text[afterIndex] : nil
                guard isLexicalBoundary(before), isLexicalBoundary(after) else { continue }
                for anchorID in pattern.anchorIDs { counts[anchorID, default: 0] += 1 }
            }
        }
        if !counts.isEmpty { postings[artifact.id] = counts }
        if retainEntries {
            entries[artifact.id] = .init(rawText: artifact.extractedText, foldedText: foldedText, counts: counts)
        }
    }
    return (postings, entries)
}

private func shouldMaterializeMentionEdge(_ anchor: Anchor, inboundLinks: Int) -> Bool {
    anchor.provenance.contains(.manifest)
        || anchor.provenance.contains(.frontmatter)
        || anchor.provenance.contains(.linkedDocument)
        || (anchor.provenance.contains(.folder) && anchor.memberArtifactIDs.count >= 2)
        || (anchor.provenance.contains(.tag) && anchor.memberArtifactIDs.count >= 2)
        || (anchor.provenance.contains(.unresolvedLink) && inboundLinks >= 2)
}

private func isLexicalBoundary(_ character: Character?) -> Bool {
    guard let character else { return true }
    return !(character.isLetter || character.isNumber || character == "_")
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
