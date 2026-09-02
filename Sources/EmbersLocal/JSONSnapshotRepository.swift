import Foundation
import EmbersCore

public actor JSONSnapshotRepository: ContextRepository {
    public let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func applicationSupport() -> JSONSnapshotRepository {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Embers", isDirectory: true)
        return .init(fileURL: base.appendingPathComponent("context-snapshot.json"))
    }

    public func load() async -> ContextSnapshot? {
        guard let data = try? Data(contentsOf: fileURL), let snapshot = try? decoder.decode(ContextSnapshot.self, from: data), (try? snapshot.validated()) != nil else { return nil }
        return snapshot
    }

    public func replace(with snapshot: ContextSnapshot) async throws {
        _ = try snapshot.validated()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    public func delete() async throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
    }
}
