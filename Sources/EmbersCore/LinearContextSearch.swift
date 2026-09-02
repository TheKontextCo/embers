import Foundation

public struct LinearContextSearch: Sendable {
    public init() {}

    public func summaries(in snapshot: ContextSnapshot, ignoring ignored: Set<String> = []) -> [AnchorSummary] {
        visibleAnchors(in: snapshot, ignoring: ignored).map { anchor in
            let linked = snapshot.relations.filter { $0.source == anchor.id || $0.target == anchor.id }
            let documentIDs = anchor.memberArtifactIDs.union(linked.compactMap(\.provenance.artifactID))
            return AnchorSummary(id: anchor.id, name: anchor.canonicalName, kind: anchor.kind, documentCount: documentIDs.count, linkCount: linked.count, modifiedAt: anchor.evidence.mostRecentModification)
        }
    }

    public func recent(in snapshot: ContextSnapshot, accessedAt: [String: Date], limit: Int = 50) -> [RecentArtifact] {
        let accessed: [RecentArtifact] = snapshot.artifacts.compactMap { artifact in
            guard let date = accessedAt[artifact.id] else { return nil }
            return RecentArtifact(artifact: artifact, accessedAt: date)
        }
        let ordered = accessed.sorted {
            $0.accessedAt == $1.accessedAt ? $0.id < $1.id : $0.accessedAt > $1.accessedAt
        }
        return Array(ordered.prefix(limit))
    }

    /// Artifacts with no authored containment belong at the workspace root. They remain
    /// documents/evidence nodes rather than being promoted into synthetic contexts.
    public func unassignedArtifacts(in snapshot: ContextSnapshot, ownedByPluginID pluginID: String? = nil) -> [SourceArtifact] {
        let assigned = snapshot.anchors.reduce(into: Set<String>()) { ids, anchor in
            ids.formUnion(anchor.memberArtifactIDs)
        }
        return snapshot.artifacts.filter { artifact in
            !assigned.contains(artifact.id)
                && (pluginID == nil || artifact.provider?.pluginID == pluginID)
        }.sorted {
            let lhs = ($0.title.embersNormalized, $0.id)
            let rhs = ($1.title.embersNormalized, $1.id)
            return lhs < rhs
        }
    }

    public func vocabulary(in snapshot: ContextSnapshot, ignoring ignored: Set<String> = [], limit: Int = 100) -> [String] {
        var seen = Set<String>()
        return visibleAnchors(in: snapshot, ignoring: ignored).flatMap { [$0.canonicalName] + $0.aliases }.filter {
            seen.insert($0.embersNormalized).inserted
        }.prefix(limit).map { $0 }
    }

    public func match(_ spokenText: String, in snapshot: ContextSnapshot, ignoring ignored: Set<String> = []) -> Anchor? {
        struct Candidate { var anchor: Anchor; var canonical: Bool; var phrase: String; var location: Int }
        let ranked = Dictionary(uniqueKeysWithValues: snapshot.anchors.enumerated().map { ($0.element.id, $0.offset) })
        var candidates: [Candidate] = []
        for anchor in snapshot.anchors where !ignored.contains(anchor.id) {
            for (phrase, canonical) in [(anchor.canonicalName, true)] + anchor.aliases.map({ ($0, false) }) {
                guard let range = wholePhraseRange(phrase, in: spokenText) else { continue }
                candidates.append(.init(anchor: anchor, canonical: canonical, phrase: phrase, location: range.location))
            }
        }
        return candidates.sorted {
            if $0.canonical != $1.canonical { return $0.canonical }
            if $0.location != $1.location { return $0.location < $1.location }
            if $0.phrase.count != $1.phrase.count { return $0.phrase.count > $1.phrase.count }
            return (ranked[$0.anchor.id] ?? .max) < (ranked[$1.anchor.id] ?? .max)
        }.first?.anchor
    }

    public func detail(anchorID: String, in snapshot: ContextSnapshot, lastSeen: Date? = nil) -> AnchorDetail? {
        guard let anchor = snapshot.anchors.first(where: { $0.id == anchorID }) else { return nil }
        let phrases = [anchor.canonicalName] + anchor.aliases
        let linkedArtifactIDs = Set(snapshot.relations.filter { $0.source == anchorID || $0.target == anchorID }.compactMap(\.provenance.artifactID))
        let rows: [(SourceArtifact, Int, String)] = snapshot.artifacts.compactMap { artifact in
            let membership = anchor.memberArtifactIDs.contains(artifact.id)
            let explicit = linkedArtifactIDs.contains(artifact.id) || artifact.metadata.links.contains { link in
                phrases.contains { $0.embersNormalized == link.target.embersNormalized || $0.embersNormalized == (link.label ?? "").embersNormalized }
            }
            let match = firstPhraseMatch(phrases, in: artifact.extractedText)
            guard membership || explicit || match != nil else { return nil }
            return (artifact, membership ? 3 : (explicit ? 2 : 1), snippet(around: match, in: artifact.extractedText))
        }
        let orderedRows = rows.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.modifiedAt != $1.0.modifiedAt { return $0.0.modifiedAt > $1.0.modifiedAt }
            return $0.0.id < $1.0.id
        }
        let hits = orderedRows.prefix(12).map { row in
            ContextHit(artifact: row.0, snippet: row.2, changedSinceLastPeek: row.0.metadata.modificationDateReliable != false && (lastSeen.map { row.0.modifiedAt > $0 } ?? false))
        }

        let related: [RelatedAnchor] = Array(snapshot.relations.compactMap { relation -> RelatedAnchor? in
            let otherID: String
            if relation.source == anchorID { otherID = relation.target }
            else if relation.target == anchorID { otherID = relation.source }
            else { return nil }
            guard let other = snapshot.anchors.first(where: { $0.id == otherID }) else { return nil }
            return .init(id: other.id, name: other.canonicalName, relationKind: relation.kind)
        }.uniqued(by: \.id).prefix(8))

        let tasks = orderedRows.flatMap { artifact, _, _ in
            artifact.metadata.tasks.filter { $0.state == .open }.map {
                AnchorTask(taskID: $0.id, artifactID: artifact.id, artifactTitle: artifact.title, text: $0.text, state: $0.state, line: $0.line, mutationToken: $0.mutationToken)
            }
        }.prefix(10)
        return .init(anchor: anchor, hits: hits, relatedAnchors: related, tasks: Array(tasks))
    }
}

private func visibleAnchors(in snapshot: ContextSnapshot, ignoring ignored: Set<String>) -> [Anchor] {
    var seenNames = Set<String>()
    return snapshot.anchors.filter { anchor in
        guard !ignored.contains(anchor.id) else { return false }
        let hasDurableEvidence = anchor.provenance.contains(.manifest)
            || anchor.provenance.contains(.frontmatter)
            || anchor.provenance.contains(.linkedDocument)
            || (anchor.provenance.contains(.folder) && anchor.memberArtifactIDs.count >= 2)
            || (anchor.provenance.contains(.tag) && anchor.memberArtifactIDs.count >= 2)
            || (anchor.provenance.contains(.unresolvedLink) && anchor.evidence.inboundLinkCount >= 2)
        guard hasDurableEvidence else { return false }
        return seenNames.insert(anchor.canonicalName.embersNormalized).inserted
    }
}

private func wholePhraseRange(_ phrase: String, in text: String) -> NSRange? {
    guard !phrase.isEmpty else { return nil }
    let escaped = NSRegularExpression.escapedPattern(for: phrase)
    return try? NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])").firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.range
}

private func firstPhraseMatch(_ phrases: [String], in text: String) -> NSRange? {
    phrases.compactMap { wholePhraseRange($0, in: text) }.min { $0.location < $1.location }
}

private func snippet(around range: NSRange?, in text: String) -> String {
    let compact = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    guard compact.count > 160 else { return compact }
    guard let range, let stringRange = Range(range, in: text) else { return String(compact.prefix(157)) + "…" }
    let offset = text.distance(from: text.startIndex, to: stringRange.lowerBound)
    let start = max(0, min(compact.count - 160, offset - 50))
    let index = compact.index(compact.startIndex, offsetBy: start)
    let value = String(compact[index...].prefix(160))
    return (start > 0 ? "…" : "") + value + (start + value.count < compact.count ? "…" : "")
}

private extension Sequence {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
