import Foundation

public struct VoiceRoutingPreferenceKey: Hashable, Sendable {
    public var conceptID: String
    public var nodeID: String

    public init(conceptID: String, nodeID: String) {
        self.conceptID = conceptID
        self.nodeID = nodeID
    }
}

public struct VoiceRoutingPreferenceAssociation: Codable, Equatable, Sendable {
    public var conceptID: String
    public var nodeID: String
    public var openCount: Int
    public var lastOpenedAt: Date
    /// Preference strength at `lastOpenedAt`. Reads return this value decayed to
    /// their requested date.
    public var weight: Double

    public init(
        conceptID: String,
        nodeID: String,
        openCount: Int,
        lastOpenedAt: Date,
        weight: Double
    ) {
        self.conceptID = conceptID
        self.nodeID = nodeID
        self.openCount = openCount
        self.lastOpenedAt = lastOpenedAt
        self.weight = weight
    }
}

public struct VoiceRoutingPreferenceSummary: Equatable, Sendable {
    public var sourceID: String
    public var associationCount: Int
    public var totalOpenCount: Int
    public var lastOpenedAt: Date?

    public init(
        sourceID: String,
        associationCount: Int,
        totalOpenCount: Int,
        lastOpenedAt: Date?
    ) {
        self.sourceID = sourceID
        self.associationCount = associationCount
        self.totalOpenCount = totalOpenCount
        self.lastOpenedAt = lastOpenedAt
    }

    public static func empty(sourceID: String) -> Self {
        .init(sourceID: sourceID, associationCount: 0, totalOpenCount: 0, lastOpenedAt: nil)
    }
}

/// A point-in-time, immutable view of all active source preferences. Runtime
/// routing can retain this value and perform synchronous lookups for every
/// partial transcript without crossing the store actor.
public struct VoiceRoutingPreferenceSnapshot: Equatable, Sendable {
    public let sourceIDs: Set<String>
    public let generatedAt: Date
    public let associations: [VoiceRoutingPreferenceKey: VoiceRoutingPreferenceAssociation]
    public let boosts: [VoiceRoutingPreferenceKey: Double]
    public let summaryBySourceID: [String: VoiceRoutingPreferenceSummary]

    public init(
        sourceIDs: Set<String>,
        generatedAt: Date,
        associations: [VoiceRoutingPreferenceKey: VoiceRoutingPreferenceAssociation],
        boosts: [VoiceRoutingPreferenceKey: Double],
        summaryBySourceID: [String: VoiceRoutingPreferenceSummary]
    ) {
        self.sourceIDs = sourceIDs
        self.generatedAt = generatedAt
        self.associations = associations
        self.boosts = boosts
        self.summaryBySourceID = summaryBySourceID
    }

    public static let empty = VoiceRoutingPreferenceSnapshot(
        sourceIDs: [],
        generatedAt: .distantPast,
        associations: [:],
        boosts: [:],
        summaryBySourceID: [:]
    )

    public func boost(conceptID: String, nodeID: String) -> Double {
        boosts[.init(conceptID: conceptID, nodeID: nodeID), default: 0]
    }
}

/// Injectable persistence keeps preference math deterministic in tests while the
/// production implementation remains a separate, atomic, inspectable JSON file.
public protocol VoiceRoutingPreferencePersistence: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

public struct FileVoiceRoutingPreferencePersistence: VoiceRoutingPreferencePersistence, Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

public actor VoiceRoutingPreferenceStore {
    public static let halfLife: TimeInterval = 30 * 24 * 60 * 60
    public static let maximumWeight = 3.0
    public static let maximumBoost = 0.12
    public static let boostPerWeight = 0.04
    public static let maximumAssociationsPerSource = 500

    private struct SourcePreferences: Codable, Equatable, Sendable {
        var sourceID: String
        var associations: [VoiceRoutingPreferenceAssociation]
    }

    private struct Archive: Codable, Equatable, Sendable {
        static let schemaVersion = 1
        var schemaVersion = Self.schemaVersion
        var sources: [SourcePreferences] = []
    }

    private let persistence: any VoiceRoutingPreferencePersistence
    private var archive = Archive()
    private var hasLoaded = false
    /// Process-local tombstones order pending app tasks around reset/delete.
    /// They need not persist: no task survives an app process restart.
    private var minimumSourceGeneration: [String: UInt64] = [:]

    public init(persistence: any VoiceRoutingPreferencePersistence) {
        self.persistence = persistence
    }

    public init(fileURL: URL) {
        self.persistence = FileVoiceRoutingPreferencePersistence(fileURL: fileURL)
    }

    public static func applicationSupport() -> VoiceRoutingPreferenceStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Embers", isDirectory: true)
        return VoiceRoutingPreferenceStore(
            fileURL: root.appendingPathComponent("voice-routing-preferences.json")
        )
    }

    @discardableResult
    public func recordOpen(
        sourceID: String,
        conceptID: String,
        nodeID: String,
        at date: Date = .now,
        sourceGeneration: UInt64? = nil
    ) throws -> VoiceRoutingPreferenceAssociation {
        // App lifecycle events cancel stale pending opens before reset/delete.
        // Checking inside the actor prevents a canceled call that had not yet
        // reached the store from recreating an erased source bucket afterward.
        try Task.checkCancellation()
        if let sourceGeneration,
           sourceGeneration < minimumSourceGeneration[sourceID, default: 0] {
            throw CancellationError()
        }
        try loadIfNeeded()
        var source = sourcePreferences(sourceID: sourceID)
        let index = source.associations.firstIndex {
            $0.conceptID == conceptID && $0.nodeID == nodeID
        }
        let next: VoiceRoutingPreferenceAssociation
        if let index {
            let current = source.associations[index]
            let effectiveDate = max(date, current.lastOpenedAt)
            next = .init(
                conceptID: conceptID,
                nodeID: nodeID,
                openCount: current.openCount + 1,
                lastOpenedAt: effectiveDate,
                weight: min(
                    Self.maximumWeight,
                    decayedWeight(current, at: effectiveDate) + 1
                )
            )
            source.associations[index] = next
        } else {
            next = .init(
                conceptID: conceptID,
                nodeID: nodeID,
                openCount: 1,
                lastOpenedAt: date,
                weight: 1
            )
            source.associations.append(next)
        }
        source.associations = pruned(source.associations, at: date)
        replace(source)
        try persist()
        return next
    }

    public func associations(
        sourceID: String,
        at date: Date = .now
    ) throws -> [VoiceRoutingPreferenceAssociation] {
        try loadIfNeeded()
        return decayedAssociations(sourceID: sourceID, at: date)
    }

    /// Decays every requested source at one timestamp and returns a value that
    /// is safe to use synchronously on the speech hot path.
    public func snapshot(
        sourceIDs: Set<String>,
        at date: Date = .now
    ) throws -> VoiceRoutingPreferenceSnapshot {
        try loadIfNeeded()
        var combined: [VoiceRoutingPreferenceKey: VoiceRoutingPreferenceAssociation] = [:]
        var boosts: [VoiceRoutingPreferenceKey: Double] = [:]
        var summaries: [String: VoiceRoutingPreferenceSummary] = [:]

        for sourceID in sourceIDs.sorted() {
            let associations = decayedAssociations(sourceID: sourceID, at: date)
            summaries[sourceID] = .init(
                sourceID: sourceID,
                associationCount: associations.count,
                totalOpenCount: associations.reduce(0) { $0 + $1.openCount },
                lastOpenedAt: associations.map(\.lastOpenedAt).max()
            )
            for association in associations {
                let key = VoiceRoutingPreferenceKey(
                    conceptID: association.conceptID,
                    nodeID: association.nodeID
                )
                // Node IDs are globally unique in a validated workspace. Still,
                // prefer the strongest association deterministically so malformed
                // or migrated source data can never trap bulk snapshot creation.
                if let current = combined[key], !prefers(association, over: current) {
                    continue
                }
                combined[key] = association
                boosts[key] = min(Self.maximumBoost, Self.boostPerWeight * association.weight)
            }
        }

        return .init(
            sourceIDs: sourceIDs,
            generatedAt: date,
            associations: combined,
            boosts: boosts,
            summaryBySourceID: summaries
        )
    }

    public func association(
        sourceID: String,
        conceptID: String,
        nodeID: String,
        at date: Date = .now
    ) throws -> VoiceRoutingPreferenceAssociation? {
        try associations(sourceID: sourceID, at: date).first {
            $0.conceptID == conceptID && $0.nodeID == nodeID
        }
    }

    public func boost(
        sourceID: String,
        conceptID: String,
        nodeID: String,
        at date: Date = .now
    ) throws -> Double {
        guard let association = try association(
            sourceID: sourceID,
            conceptID: conceptID,
            nodeID: nodeID,
            at: date
        ) else { return 0 }
        return min(Self.maximumBoost, Self.boostPerWeight * association.weight)
    }

    /// Clear learned preferences for one source while leaving the inspectable
    /// archive and every other source intact.
    public func reset(sourceID: String, sourceGeneration: UInt64? = nil) throws {
        advanceMinimumGeneration(sourceID: sourceID, to: sourceGeneration)
        try loadIfNeeded()
        archive.sources.removeAll { $0.sourceID == sourceID }
        try persist()
    }

    /// Forget one source. If it was the final source, remove the preference file.
    public func delete(sourceID: String, sourceGeneration: UInt64? = nil) throws {
        advanceMinimumGeneration(sourceID: sourceID, to: sourceGeneration)
        try loadIfNeeded()
        archive.sources.removeAll { $0.sourceID == sourceID }
        if archive.sources.isEmpty {
            try persistence.delete()
        } else {
            try persist()
        }
    }

    public func deleteAll() throws {
        archive = Archive()
        hasLoaded = true
        try persistence.delete()
    }

    private func loadIfNeeded() throws {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try persistence.load() else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(Archive.self, from: data),
              decoded.schemaVersion == Archive.schemaVersion,
              structurallyValid(decoded) else {
            archive = Archive()
            return
        }
        archive = normalized(decoded)
    }

    private func persist() throws {
        archive = normalized(archive)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try persistence.save(encoder.encode(archive))
    }

    private func sourcePreferences(sourceID: String) -> SourcePreferences {
        archive.sources.first { $0.sourceID == sourceID }
            ?? SourcePreferences(sourceID: sourceID, associations: [])
    }

    private func advanceMinimumGeneration(sourceID: String, to generation: UInt64?) {
        guard let generation else { return }
        minimumSourceGeneration[sourceID] = max(
            minimumSourceGeneration[sourceID, default: 0],
            generation
        )
    }

    private func decayedAssociations(
        sourceID: String,
        at date: Date
    ) -> [VoiceRoutingPreferenceAssociation] {
        sourcePreferences(sourceID: sourceID).associations.map { association in
            var result = association
            result.weight = decayedWeight(association, at: date)
            return result
        }.sorted(by: preferenceOrder)
    }

    private func prefers(
        _ lhs: VoiceRoutingPreferenceAssociation,
        over rhs: VoiceRoutingPreferenceAssociation
    ) -> Bool {
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        if lhs.lastOpenedAt != rhs.lastOpenedAt { return lhs.lastOpenedAt > rhs.lastOpenedAt }
        return lhs.openCount > rhs.openCount
    }

    private func replace(_ source: SourcePreferences) {
        archive.sources.removeAll { $0.sourceID == source.sourceID }
        archive.sources.append(source)
    }

    private func pruned(
        _ associations: [VoiceRoutingPreferenceAssociation],
        at date: Date
    ) -> [VoiceRoutingPreferenceAssociation] {
        guard associations.count > Self.maximumAssociationsPerSource else { return associations }
        return associations.sorted { lhs, rhs in
            let leftWeight = decayedWeight(lhs, at: date)
            let rightWeight = decayedWeight(rhs, at: date)
            if leftWeight != rightWeight { return leftWeight > rightWeight }
            if lhs.lastOpenedAt != rhs.lastOpenedAt { return lhs.lastOpenedAt > rhs.lastOpenedAt }
            if lhs.conceptID != rhs.conceptID { return lhs.conceptID < rhs.conceptID }
            return lhs.nodeID < rhs.nodeID
        }.prefix(Self.maximumAssociationsPerSource).map { $0 }
    }

    private func decayedWeight(
        _ association: VoiceRoutingPreferenceAssociation,
        at date: Date
    ) -> Double {
        let age = max(0, date.timeIntervalSince(association.lastOpenedAt))
        return association.weight * pow(0.5, age / Self.halfLife)
    }

    private func preferenceOrder(
        _ lhs: VoiceRoutingPreferenceAssociation,
        _ rhs: VoiceRoutingPreferenceAssociation
    ) -> Bool {
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        if lhs.lastOpenedAt != rhs.lastOpenedAt { return lhs.lastOpenedAt > rhs.lastOpenedAt }
        if lhs.conceptID != rhs.conceptID { return lhs.conceptID < rhs.conceptID }
        return lhs.nodeID < rhs.nodeID
    }

    private func structurallyValid(_ archive: Archive) -> Bool {
        let sourceIDs = archive.sources.map(\.sourceID)
        guard Set(sourceIDs).count == sourceIDs.count else { return false }
        return archive.sources.allSatisfy { source in
            let keys = source.associations.map { "\($0.conceptID)\u{1f}\($0.nodeID)" }
            return !source.sourceID.isEmpty
                && source.associations.count <= Self.maximumAssociationsPerSource
                && Set(keys).count == keys.count
                && source.associations.allSatisfy {
                    !$0.conceptID.isEmpty
                        && !$0.nodeID.isEmpty
                        && $0.openCount > 0
                        && $0.weight.isFinite
                        && $0.weight > 0
                        && $0.weight <= Self.maximumWeight
                }
        }
    }

    private func normalized(_ archive: Archive) -> Archive {
        var result = archive
        result.sources = archive.sources.map { source in
            var source = source
            source.associations.sort {
                if $0.conceptID != $1.conceptID { return $0.conceptID < $1.conceptID }
                return $0.nodeID < $1.nodeID
            }
            return source
        }.sorted { $0.sourceID < $1.sourceID }
        return result
    }
}
