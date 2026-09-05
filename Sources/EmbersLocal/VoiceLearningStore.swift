import EmbersCore
import Foundation

public struct VoiceRouteExclusion: Codable, Equatable, Sendable {
    public var key: VoiceRouteExclusionKey
    public var rejectedAt: Date

    public init(key: VoiceRouteExclusionKey, rejectedAt: Date) {
        self.key = key
        self.rejectedAt = rejectedAt
    }
}

/// Immutable point-in-time state used by routing and Context Lens without
/// crossing the persistence actor on the transcript hot path.
public struct VoiceLearningSnapshot: Equatable, Sendable {
    public var sourceIDs: Set<String>
    public var exclusions: [VoiceRouteExclusionKey: VoiceRouteExclusion]

    public init(
        sourceIDs: Set<String>,
        exclusions: [VoiceRouteExclusionKey: VoiceRouteExclusion]
    ) {
        self.sourceIDs = sourceIDs
        self.exclusions = exclusions
    }

    public static let empty = VoiceLearningSnapshot(sourceIDs: [], exclusions: [:])
}

public protocol VoiceLearningPersistence: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

public protocol VoiceLearningStoring: Sendable {
    func snapshot(sourceIDs: Set<String>) async throws -> VoiceLearningSnapshot
    func recordExclusion(
        _ key: VoiceRouteExclusionKey,
        at date: Date,
        sourceGeneration: UInt64
    ) async throws -> VoiceLearningSnapshot
    func removeExclusion(
        _ key: VoiceRouteExclusionKey,
        sourceGeneration: UInt64
    ) async throws -> VoiceLearningSnapshot
    func delete(sourceID: String, sourceGeneration: UInt64) async throws
}

public struct FileVoiceLearningPersistence: VoiceLearningPersistence, Sendable {
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

public actor VoiceLearningStore {
    public static let maximumExclusions = 1_000

    private struct Archive: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1
        var schemaVersion = Self.currentSchemaVersion
        var exclusions: [VoiceRouteExclusion] = []
    }

    private let persistence: any VoiceLearningPersistence
    private var archive = Archive()
    private var hasLoaded = false
    private var minimumSourceGeneration: [String: UInt64] = [:]

    public init(persistence: any VoiceLearningPersistence) {
        self.persistence = persistence
    }

    public init(fileURL: URL) {
        persistence = FileVoiceLearningPersistence(fileURL: fileURL)
    }

    public static func applicationSupport() -> VoiceLearningStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Embers", isDirectory: true)
        return VoiceLearningStore(fileURL: root.appendingPathComponent("voice-learning.json"))
    }

    public func snapshot(sourceIDs: Set<String>) throws -> VoiceLearningSnapshot {
        try loadIfNeeded()
        let records = archive.exclusions.filter { sourceIDs.contains($0.key.sourceID) }
        return VoiceLearningSnapshot(
            sourceIDs: sourceIDs,
            exclusions: Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        )
    }

    @discardableResult
    public func recordExclusion(
        _ key: VoiceRouteExclusionKey,
        at date: Date = .now,
        sourceGeneration: UInt64
    ) throws -> VoiceLearningSnapshot {
        try Task.checkCancellation()
        guard key.isValid else { throw VoiceLearningStoreError.invalidExclusion }
        guard sourceGeneration >= minimumSourceGeneration[key.sourceID, default: 0] else {
            throw CancellationError()
        }
        try loadIfNeeded()
        if archive.exclusions.contains(where: { $0.key == key }) {
            return try snapshot(sourceIDs: Set(archive.exclusions.map { $0.key.sourceID }))
        }

        let previous = archive
        archive.exclusions.append(.init(key: key, rejectedAt: date))
        archive.exclusions.sort { lhs, rhs in
            if lhs.rejectedAt != rhs.rejectedAt { return lhs.rejectedAt > rhs.rejectedAt }
            return exclusionSortKey(lhs.key) < exclusionSortKey(rhs.key)
        }
        archive.exclusions = Array(archive.exclusions.prefix(Self.maximumExclusions))
        do {
            try persist()
        } catch {
            archive = previous
            throw error
        }
        return try snapshot(sourceIDs: Set(archive.exclusions.map { $0.key.sourceID }))
    }

    @discardableResult
    public func removeExclusion(
        _ key: VoiceRouteExclusionKey,
        sourceGeneration: UInt64
    ) throws -> VoiceLearningSnapshot {
        try Task.checkCancellation()
        guard sourceGeneration >= minimumSourceGeneration[key.sourceID, default: 0] else {
            throw CancellationError()
        }
        try loadIfNeeded()
        let previous = archive
        archive.exclusions.removeAll { $0.key == key }
        guard archive != previous else {
            return try snapshot(sourceIDs: Set(archive.exclusions.map { $0.key.sourceID }))
        }
        do {
            try persist()
        } catch {
            archive = previous
            throw error
        }
        return try snapshot(sourceIDs: Set(archive.exclusions.map { $0.key.sourceID }))
    }

    public func delete(sourceID: String, sourceGeneration: UInt64) throws {
        minimumSourceGeneration[sourceID] = max(
            sourceGeneration,
            minimumSourceGeneration[sourceID, default: 0]
        )
        try loadIfNeeded()
        let previous = archive
        archive.exclusions.removeAll { $0.key.sourceID == sourceID }
        guard archive != previous else { return }
        do {
            try persist()
        } catch {
            archive = previous
            throw error
        }
    }

    private func loadIfNeeded() throws {
        guard !hasLoaded else { return }
        defer { hasLoaded = true }
        guard let data = try persistence.load() else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Archive.self, from: data)
        guard decoded.schemaVersion == Archive.currentSchemaVersion,
              decoded.exclusions.allSatisfy({ $0.key.isValid }) else {
            throw VoiceLearningStoreError.unsupportedArchive
        }
        archive = decoded
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try persistence.save(encoder.encode(archive))
    }

    private func exclusionSortKey(_ key: VoiceRouteExclusionKey) -> String {
        [
            key.sourceID,
            key.nodeID,
            key.pattern.kind.rawValue,
            key.pattern.normalizedTerms.joined(separator: "\u{1f}"),
            key.pattern.maximumGap.map(String.init) ?? "",
        ].joined(separator: "\u{1e}")
    }
}

extension VoiceLearningStore: VoiceLearningStoring {}

public enum VoiceLearningStoreError: Error {
    case invalidExclusion
    case unsupportedArchive
}
