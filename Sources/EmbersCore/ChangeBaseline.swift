import Foundation

/// The exact source and context whose history a baseline describes.
///
/// Context IDs are only meaningful inside their source. Keeping both parts in
/// the persisted key prevents one provider, account, or vault from inheriting
/// another source's change history.
public struct ContextChangeScope: Codable, Hashable, Sendable {
    public var sourceID: String
    public var contextID: String

    public init(sourceID: String, contextID: String) {
        self.sourceID = sourceID
        self.contextID = contextID
    }
}

/// The evidence state observed when a context was last peeked.
///
/// Providers already normalize their revision semantics into `contentHash`.
/// Local sources hash file contents; remote providers hash normalized entity
/// content and state. Core deliberately does not reinterpret provider data or
/// compare wall clocks.
public struct ContextChangeBaseline: Codable, Equatable, Sendable {
    public var scope: ContextChangeScope
    public var memberArtifactIDs: Set<String>
    public var artifactRevisions: [String: String]

    public init(
        scope: ContextChangeScope,
        memberArtifactIDs: Set<String>,
        artifactRevisions: [String: String]
    ) {
        self.scope = scope
        self.memberArtifactIDs = memberArtifactIDs
        self.artifactRevisions = artifactRevisions
    }

    /// Captures a baseline only when the requested context exists. References
    /// to temporarily unavailable artifacts remain in the membership set, but
    /// receive no invented revision token.
    public static func capture(for contextID: String, in snapshot: ContextSnapshot) -> ContextChangeBaseline? {
        guard let context = snapshot.anchors.first(where: { $0.id == contextID }) else { return nil }
        let artifactsByID = Dictionary(uniqueKeysWithValues: snapshot.artifacts.map { ($0.id, $0) })
        let owningSourceIDs = Set(context.memberArtifactIDs.compactMap { artifactsByID[$0]?.provider?.sourceID })
        // A composed workspace has its own synthetic source ID, but each
        // context remains owned by exactly one provider source. Persist that
        // real owner when it is unambiguous so disconnect/forget can retire
        // the correct history without touching its peers.
        let sourceID = owningSourceIDs.count == 1 ? owningSourceIDs.first! : snapshot.sourceID
        let revisions = context.memberArtifactIDs.reduce(into: [String: String]()) { result, artifactID in
            if let artifact = artifactsByID[artifactID] {
                result[artifactID] = artifact.contentHash
            }
        }
        return ContextChangeBaseline(
            scope: .init(sourceID: sourceID, contextID: contextID),
            memberArtifactIDs: context.memberArtifactIDs,
            artifactRevisions: revisions
        )
    }
}

/// A deterministic, provider-neutral description of what changed in one
/// context between two peeks.
public struct ContextChangeSet: Equatable, Sendable {
    public var addedArtifactIDs: Set<String>
    public var updatedArtifactIDs: Set<String>
    public var removedArtifactIDs: Set<String>
    public var membershipChanged: Bool

    public init(
        addedArtifactIDs: Set<String> = [],
        updatedArtifactIDs: Set<String> = [],
        removedArtifactIDs: Set<String> = [],
        membershipChanged: Bool = false
    ) {
        self.addedArtifactIDs = addedArtifactIDs
        self.updatedArtifactIDs = updatedArtifactIDs
        self.removedArtifactIDs = removedArtifactIDs
        self.membershipChanged = membershipChanged
    }

    /// Artifacts that still exist and can therefore be presented as evidence.
    /// Removed IDs remain available separately for future summary UI.
    public var currentChangedArtifactIDs: Set<String> {
        addedArtifactIDs.union(updatedArtifactIDs)
    }

    public var isEmpty: Bool {
        addedArtifactIDs.isEmpty
            && updatedArtifactIDs.isEmpty
            && removedArtifactIDs.isEmpty
            && !membershipChanged
    }

    /// Honest summaries for changes that cannot be represented by a current
    /// artifact row. A removed artifact has no current evidence to open, and a
    /// provider may report structural membership movement without identifying
    /// a newly present artifact.
    public var nonArtifactSummaries: [ContextChangeSummary] {
        var summaries: [ContextChangeSummary] = []
        if !removedArtifactIDs.isEmpty {
            summaries.append(.init(kind: .removedArtifacts, count: removedArtifactIDs.count))
        }
        if membershipChanged && addedArtifactIDs.isEmpty && removedArtifactIDs.isEmpty {
            summaries.append(.init(kind: .membershipChanged, count: 1))
        }
        return summaries
    }
}

public struct ContextChangeSummary: Hashable, Identifiable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case removedArtifacts
        case membershipChanged
    }

    public var id: Kind { kind }
    public var kind: Kind
    public var count: Int

    public init(kind: Kind, count: Int) {
        self.kind = kind
        self.count = max(count, 1)
    }
}

public enum ContextChangeDetector {
    /// Compares a normalized snapshot with an exact prior baseline.
    ///
    /// No baseline, a missing context, or a source/context mismatch behaves as
    /// a first peek. This fail-closed rule prevents corrupt or stale state from
    /// presenting an entire source as newly changed.
    public static func changes(
        for contextID: String,
        in snapshot: ContextSnapshot,
        since baseline: ContextChangeBaseline?
    ) -> ContextChangeSet {
        guard let baseline,
              let current = ContextChangeBaseline.capture(for: contextID, in: snapshot),
              baseline.scope == current.scope,
              let context = snapshot.anchors.first(where: { $0.id == contextID }) else {
            return ContextChangeSet()
        }

        let currentMembers = context.memberArtifactIDs
        let previousMembers = baseline.memberArtifactIDs
        let artifactsByID = Dictionary(uniqueKeysWithValues: snapshot.artifacts.map { ($0.id, $0) })

        // Only present added artifacts that exist in the validated current
        // snapshot. A dangling membership reference is not evidence.
        let added = currentMembers
            .subtracting(previousMembers)
            .filter { artifactsByID[$0] != nil }
        let removed = previousMembers.subtracting(currentMembers)
        let shared = currentMembers.intersection(previousMembers)
        let updated = shared.reduce(into: Set<String>()) { result, artifactID in
            guard let previousRevision = baseline.artifactRevisions[artifactID],
                  let currentRevision = artifactsByID[artifactID]?.contentHash,
                  previousRevision != currentRevision else { return }
            result.insert(artifactID)
        }

        return ContextChangeSet(
            addedArtifactIDs: Set(added),
            updatedArtifactIDs: updated,
            removedArtifactIDs: removed,
            membershipChanged: currentMembers != previousMembers
        )
    }
}
