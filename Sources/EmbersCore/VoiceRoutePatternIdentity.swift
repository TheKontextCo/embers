import Foundation

/// Stable, storage-safe identity for one executable voice-routing pattern.
/// Scores and proposal origins are provenance; they are deliberately not part
/// of the identity a user rejects.
public struct VoiceRoutePatternIdentity: Codable, Hashable, Sendable {
    public static let currentNormalizerVersion = 1

    public enum Kind: String, Codable, Sendable {
        case phrase
        case orderedTerms
    }

    public var normalizerVersion: Int
    public var kind: Kind
    public var normalizedTerms: [String]
    public var maximumGap: Int?

    public init(
        normalizerVersion: Int = Self.currentNormalizerVersion,
        kind: Kind,
        normalizedTerms: [String],
        maximumGap: Int? = nil
    ) {
        self.normalizerVersion = normalizerVersion
        self.kind = kind
        self.normalizedTerms = normalizedTerms
        self.maximumGap = maximumGap
    }

    public var isValid: Bool {
        guard normalizerVersion == Self.currentNormalizerVersion,
              !normalizedTerms.isEmpty,
              normalizedTerms.allSatisfy({ !$0.isEmpty }) else { return false }
        switch kind {
        case .phrase:
            return maximumGap == nil
        case .orderedTerms:
            return maximumGap.map { $0 >= 0 } == true
        }
    }
}

/// One narrow user-authored exclusion. The same pattern remains available for
/// other nodes, and other patterns remain available for this node.
public struct VoiceRouteExclusionKey: Codable, Hashable, Sendable {
    public var sourceID: String
    public var nodeID: String
    public var pattern: VoiceRoutePatternIdentity

    public init(sourceID: String, nodeID: String, pattern: VoiceRoutePatternIdentity) {
        self.sourceID = sourceID
        self.nodeID = nodeID
        self.pattern = pattern
    }

    public var isValid: Bool {
        !sourceID.isEmpty && !nodeID.isEmpty && pattern.isValid
    }
}
