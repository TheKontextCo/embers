import EmbersCore
import Foundation
import XCTest

@testable import EmbersLocal

final class VoiceLearningStoreTests: XCTestCase {
    private let rejectedAt = Date(timeIntervalSince1970: 1_700_000_123)

    func testRoundTripPreservesExactPatternAndFiltersRequestedSources() async throws {
        let persistence = MemoryVoiceLearningPersistence()
        let first = VoiceLearningStore(persistence: persistence)
        let phrase = key(sourceID: "folder:a", nodeID: "apollo", terms: ["apollo"])
        let ordered = key(
            sourceID: "folder:b",
            nodeID: "second-brain",
            kind: .orderedTerms,
            terms: ["second", "brain"],
            maximumGap: 2
        )

        try await first.recordExclusion(phrase, at: rejectedAt, sourceGeneration: 0)
        try await first.recordExclusion(ordered, at: rejectedAt.addingTimeInterval(1), sourceGeneration: 0)

        let reopened = VoiceLearningStore(persistence: persistence)
        let sourceA = try await reopened.snapshot(sourceIDs: ["folder:a"])
        XCTAssertEqual(sourceA.sourceIDs, ["folder:a"])
        XCTAssertEqual(sourceA.exclusions[phrase]?.rejectedAt, rejectedAt)
        XCTAssertNil(sourceA.exclusions[ordered])
        XCTAssertTrue(try XCTUnwrap(persistence.data).utf8String.contains("\n"))
    }

    func testRecordIsIdempotentAndUndoRemovesOnlyTheExactRoute() async throws {
        let store = VoiceLearningStore(persistence: MemoryVoiceLearningPersistence())
        let apollo = key(sourceID: "folder:a", nodeID: "apollo", terms: ["apollo"])
        let mission = key(sourceID: "folder:a", nodeID: "apollo", terms: ["moon", "mission"])

        try await store.recordExclusion(apollo, at: rejectedAt, sourceGeneration: 0)
        try await store.recordExclusion(apollo, at: rejectedAt.addingTimeInterval(10), sourceGeneration: 0)
        try await store.recordExclusion(mission, at: rejectedAt, sourceGeneration: 0)
        var snapshot = try await store.snapshot(sourceIDs: ["folder:a"])
        XCTAssertEqual(snapshot.exclusions.count, 2)
        XCTAssertEqual(snapshot.exclusions[apollo]?.rejectedAt, rejectedAt)

        try await store.removeExclusion(apollo, sourceGeneration: 0)
        snapshot = try await store.snapshot(sourceIDs: ["folder:a"])
        XCTAssertNil(snapshot.exclusions[apollo])
        XCTAssertNotNil(snapshot.exclusions[mission])
    }

    func testDeleteIsSourceScopedAndRejectsDelayedWrites() async throws {
        let persistence = MemoryVoiceLearningPersistence()
        let store = VoiceLearningStore(persistence: persistence)
        let sourceA = key(sourceID: "folder:a", nodeID: "apollo", terms: ["apollo"])
        let sourceB = key(sourceID: "folder:b", nodeID: "journal", terms: ["journal"])
        try await store.recordExclusion(sourceA, sourceGeneration: 0)
        try await store.recordExclusion(sourceB, sourceGeneration: 0)

        try await store.delete(sourceID: "folder:a", sourceGeneration: 1)
        do {
            try await store.recordExclusion(sourceA, sourceGeneration: 0)
            XCTFail("A delayed pre-delete write must not recreate removed learning data.")
        } catch is CancellationError {
            // Expected stale-generation rejection.
        }

        let snapshot = try await store.snapshot(sourceIDs: ["folder:a", "folder:b"])
        XCTAssertNil(snapshot.exclusions[sourceA])
        XCTAssertNotNil(snapshot.exclusions[sourceB])
    }

    func testFailedSaveRollsBackInMemoryMutation() async throws {
        let persistence = MemoryVoiceLearningPersistence()
        persistence.failNextSave = true
        let store = VoiceLearningStore(persistence: persistence)
        let exclusion = key(sourceID: "folder:a", nodeID: "apollo", terms: ["apollo"])

        do {
            try await store.recordExclusion(exclusion, sourceGeneration: 0)
            XCTFail("Expected the injected persistence failure.")
        } catch MemoryVoiceLearningPersistence.Failure.save {
            // Expected.
        }

        let snapshot = try await store.snapshot(sourceIDs: ["folder:a"])
        XCTAssertTrue(snapshot.exclusions.isEmpty)
    }

    private func key(
        sourceID: String,
        nodeID: String,
        kind: VoiceRoutePatternIdentity.Kind = .phrase,
        terms: [String],
        maximumGap: Int? = nil
    ) -> VoiceRouteExclusionKey {
        .init(
            sourceID: sourceID,
            nodeID: nodeID,
            pattern: .init(kind: kind, normalizedTerms: terms, maximumGap: maximumGap)
        )
    }
}

private final class MemoryVoiceLearningPersistence: VoiceLearningPersistence, @unchecked Sendable {
    enum Failure: Error { case save }

    private let lock = NSLock()
    private var storedData: Data?
    var failNextSave = false

    var data: Data? { lock.withLock { storedData } }

    func load() throws -> Data? {
        lock.withLock { storedData }
    }

    func save(_ data: Data) throws {
        try lock.withLock {
            if failNextSave {
                failNextSave = false
                throw Failure.save
            }
            storedData = data
        }
    }

    func delete() throws {
        lock.withLock { storedData = nil }
    }
}

private extension Data {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
