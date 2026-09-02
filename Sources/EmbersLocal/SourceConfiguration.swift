import Foundation
import EmbersCore

public struct SourceConfiguration: Codable, Sendable {
    public var id: String
    public var bookmark: Data
    public var displayPath: String
    public var sourceType: String
    public init(id: String, bookmark: Data, displayPath: String, sourceType: String) { self.id = id; self.bookmark = bookmark; self.displayPath = displayPath; self.sourceType = sourceType }
}

public enum SourceConfigurationError: LocalizedError {
    case bookmarkCreationFailed(URL, Error)
    case bookmarkResolutionFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .bookmarkCreationFailed(let url, let error):
            return "Embers could not retain access to \(url.lastPathComponent): \(error.localizedDescription)"
        case .bookmarkResolutionFailed(let error):
            return "Embers no longer has permission for this folder. Choose the folder again to restore access. \(error.localizedDescription)"
        }
    }
}

public final class SourceConfigurationStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "localSourceConfiguration"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func save(url: URL, sourceType: String) throws -> SourceConfiguration {
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // A plain bookmark is not a substitute in an App Sandbox: it can
            // resolve a path without granting the app access to that path.
            throw SourceConfigurationError.bookmarkCreationFailed(url, error)
        }
        let existing = loadConfiguration()?.id
        let config = SourceConfiguration(id: existing ?? "source-\(StableHash.hex(UUID().uuidString))", bookmark: bookmark, displayPath: url.path, sourceType: sourceType)
        defaults.set(try JSONEncoder().encode(config), forKey: key)
        return config
    }

    public func loadConfiguration() -> SourceConfiguration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SourceConfiguration.self, from: data)
    }

    public func resolve(_ configuration: SourceConfiguration) throws -> URL {
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: configuration.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw SourceConfigurationError.bookmarkResolutionFailed(error)
        }
        if stale { _ = try save(url: url, sourceType: configuration.sourceType) }
        return url
    }

    public func clear() { defaults.removeObject(forKey: key) }
}
