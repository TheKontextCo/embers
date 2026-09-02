import XCTest
import EmbersCore
import EmbersPluginKit
@testable import EmbersLocal

final class PluginSnapshotPersistenceCriticalFlowTests: XCTestCase {
    func testSnapshotsRemainSourceScopedWhenOneCacheIsCorruptOrRemoved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-source-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = JSONPluginSnapshotRepository(directoryURL: root)
        let first = source(plugin: "folder", source: "Private Client Alpha")
        let second = source(plugin: "kontext", source: "account@example.com")
        try await repository.replace(snapshot(for: first, revision: "first"), for: first)
        try await repository.replace(snapshot(for: second, revision: "second"), for: second)

        let cacheNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(cacheNames.count, 2)
        XCTAssertTrue(cacheNames.allSatisfy { $0.hasSuffix(".json") })
        XCTAssertTrue(cacheNames.allSatisfy { !$0.contains("Private") && !$0.contains("account") })

        let firstCache = root.appendingPathComponent("\(StableHash.hex(first.rawValue)).json")
        try Data("corrupt".utf8).write(to: firstCache, options: .atomic)

        let corruptedFirst = await repository.load(for: first)
        let intactSecond = await repository.load(for: second)
        XCTAssertNil(corruptedFirst)
        XCTAssertEqual(intactSecond?.revision, "second")

        try await repository.remove(source: first)
        let secondAfterRemoval = await repository.load(for: second)
        XCTAssertEqual(secondAfterRemoval?.revision, "second")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }

    func testRepositoryRejectsSnapshotFromAnotherSourceWithoutDisturbingExistingCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-source-mismatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = JSONPluginSnapshotRepository(directoryURL: root)
        let expected = source(plugin: "folder", source: "expected")
        let other = source(plugin: "folder", source: "other")
        try await repository.replace(snapshot(for: expected, revision: "last-good"), for: expected)

        do {
            try await repository.replace(snapshot(for: other, revision: "wrong"), for: expected)
            XCTFail("A source must never overwrite another source's cache.")
        } catch let error as JSONPluginSnapshotRepositoryError {
            guard case .sourceMismatch(let expectedID, let actualID) = error else {
                return XCTFail("Unexpected repository error: \(error)")
            }
            XCTAssertEqual(expectedID, expected.rawValue)
            XCTAssertEqual(actualID, other.rawValue)
        }

        let expectedAfterRejection = await repository.load(for: expected)
        let otherAfterRejection = await repository.load(for: other)
        XCTAssertEqual(expectedAfterRejection?.revision, "last-good")
        XCTAssertNil(otherAfterRejection)
    }

    func testRepositoryLoadsEveryValidSourceScopedSnapshotForOfflineComposition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-source-enumeration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = JSONPluginSnapshotRepository(directoryURL: root)
        let folder = source(plugin: "folder", source: "blue-book")
        let kontext = source(plugin: "kontext", source: "account")
        try await repository.replace(snapshot(for: folder, revision: "folder-revision"), for: folder)
        try await repository.replace(snapshot(for: kontext, revision: "kontext-revision"), for: kontext)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("corrupt.json"))

        let loaded = await repository.loadAllValid()

        XCTAssertEqual(loaded.map(\.0), [folder, kontext].sorted())
        XCTAssertEqual(Set(loaded.map { $0.1.revision }), ["folder-revision", "kontext-revision"])
    }

    private func source(plugin: String, source: String) -> PluginSourceIdentifier {
        PluginSourceIdentifier(pluginID: PluginIdentifier(rawValue: plugin)!, sourceID: source)
    }

    private func snapshot(for source: PluginSourceIdentifier, revision: String) -> ContextSnapshot {
        ContextSnapshot(
            sourceID: source.rawValue,
            revision: revision,
            artifacts: [],
            anchors: [],
            relations: [],
            diagnostics: [],
            indexedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
