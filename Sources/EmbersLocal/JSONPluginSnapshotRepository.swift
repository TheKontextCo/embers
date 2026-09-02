import Foundation
import EmbersCore
import EmbersPluginKit

/// File-backed storage for independently recoverable plugin snapshots.
/// Filenames are hashes so provider/account identifiers are not exposed in the
/// application-support directory listing.
public actor JSONPluginSnapshotRepository: PluginSnapshotRepository {
    public let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func applicationSupport() -> JSONPluginSnapshotRepository {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Embers", isDirectory: true)
            .appendingPathComponent("plugin-snapshots", isDirectory: true)
        return .init(directoryURL: base)
    }

    public func load(for source: PluginSourceIdentifier) async -> ContextSnapshot? {
        let fileURL = url(for: source)
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? decoder.decode(ContextSnapshot.self, from: data),
              (try? snapshot.validated()) != nil,
              snapshot.sourceID == source.rawValue else { return nil }
        return snapshot
    }

    /// Loads the valid source-scoped caches without refreshing or contacting a
    /// provider. This is intended for offline diagnostics such as the live
    /// voice-routing evaluation, which must compose the same cache format that
    /// production uses instead of relying on the retired workspace cache.
    public func loadAllValid() -> [(PluginSourceIdentifier, ContextSnapshot)] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return fileURLs.compactMap { fileURL in
            guard fileURL.pathExtension == "json",
                  let data = try? Data(contentsOf: fileURL),
                  let snapshot = try? decoder.decode(ContextSnapshot.self, from: data),
                  (try? snapshot.validated()) != nil,
                  let source = PluginSourceIdentifier(rawValue: snapshot.sourceID),
                  fileURL.lastPathComponent == "\(StableHash.hex(source.rawValue)).json"
            else { return nil }
            return (source, snapshot)
        }.sorted { $0.0 < $1.0 }
    }

    public func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws {
        _ = try snapshot.validated()
        guard snapshot.sourceID == source.rawValue else {
            throw JSONPluginSnapshotRepositoryError.sourceMismatch(expected: source.rawValue, actual: snapshot.sourceID)
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: url(for: source), options: .atomic)
    }

    public func remove(source: PluginSourceIdentifier) async throws {
        let fileURL = url(for: source)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func url(for source: PluginSourceIdentifier) -> URL {
        directoryURL.appendingPathComponent("\(StableHash.hex(source.rawValue)).json")
    }
}

public enum JSONPluginSnapshotRepositoryError: LocalizedError {
    case sourceMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .sourceMismatch(let expected, let actual):
            return "Snapshot source \(actual) cannot be stored for \(expected)."
        }
    }
}
