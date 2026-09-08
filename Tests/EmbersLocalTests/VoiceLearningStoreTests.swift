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

    func testLoadFailureDoesNotAuthorizeAnEmptyArchiveAndCanBeRetried() async throws {
        let persistence = MemoryVoiceLearningPersistence()
        persistence.failNextLoad = true
        let store = VoiceLearningStore(persistence: persistence)
        let exclusion = key(sourceID: "folder:a", nodeID: "apollo", terms: ["apollo"])

        do {
            _ = try await store.snapshot(sourceIDs: ["folder:a"])
            XCTFail("Expected the injected load failure.")
        } catch MemoryVoiceLearningPersistence.Failure.load {
            // Expected. The store must remain unloaded.
        }

        try await store.recordExclusion(exclusion, at: rejectedAt, sourceGeneration: 0)
        let snapshot = try await store.snapshot(sourceIDs: ["folder:a"])
        XCTAssertNotNil(snapshot.exclusions[exclusion])
    }

    func testCorruptArchiveRemainsVisibleUntilSourceRetirementErasesIt() async throws {
        let persistence = MemoryVoiceLearningPersistence()
        persistence.replaceData(Data("not json".utf8))
        let store = VoiceLearningStore(persistence: persistence)

        for _ in 0 ..< 2 {
            do {
                _ = try await store.snapshot(sourceIDs: ["folder:a"])
                XCTFail("A corrupt archive must not be treated as empty state.")
            } catch {
                XCTAssertNotNil(persistence.data)
            }
        }

        try await store.delete(sourceID: "folder:a", sourceGeneration: 1)
        XCTAssertNil(persistence.data)
        let reopened = VoiceLearningStore(persistence: persistence)
        let snapshot = try await reopened.snapshot(sourceIDs: ["folder:a"])
        XCTAssertTrue(snapshot.exclusions.isEmpty)
    }

    func testUnsupportedArchiveRemainsVisibleUntilSourceRetirementErasesIt() async throws {
        let persistence = MemoryVoiceLearningPersistence()
        persistence.replaceData(Data(#"{"schemaVersion":999,"exclusions":[]}"#.utf8))
        let store = VoiceLearningStore(persistence: persistence)

        do {
            _ = try await store.snapshot(sourceIDs: ["folder:a"])
            XCTFail("Expected an unsupported archive error.")
        } catch VoiceLearningStoreError.unsupportedArchive {
            XCTAssertNotNil(persistence.data)
        }

        try await store.delete(sourceID: "folder:a", sourceGeneration: 1)
        XCTAssertNil(persistence.data)
    }

    func testFailedUnreadableArchiveDeletionRemainsRetryable() async throws {
        let persistence = MemoryVoiceLearningPersistence()
        persistence.replaceData(Data("not json".utf8))
        persistence.failNextDelete = true
        let store = VoiceLearningStore(persistence: persistence)

        do {
            try await store.delete(sourceID: "folder:a", sourceGeneration: 1)
            XCTFail("Expected the injected deletion failure.")
        } catch MemoryVoiceLearningPersistence.Failure.delete {
            XCTAssertNotNil(persistence.data)
        }

        try await store.delete(sourceID: "folder:a", sourceGeneration: 2)
        XCTAssertNil(persistence.data)
    }

    func testFailedUndoCanBeRetriedWithoutLosingThePersistedExclusion() async throws {
        let persistence = MemoryVoiceLearningPersistence()
        let store = VoiceLearningStore(persistence: persistence)
        let exclusion = key(sourceID: "folder:a", nodeID: "apollo", terms: ["apollo"])
        try await store.recordExclusion(exclusion, at: rejectedAt, sourceGeneration: 0)
        persistence.failNextSave = true

        do {
            _ = try await store.removeExclusion(exclusion, sourceGeneration: 0)
            XCTFail("Expected the injected save failure.")
        } catch MemoryVoiceLearningPersistence.Failure.save {
            let snapshot = try await store.snapshot(sourceIDs: ["folder:a"])
            XCTAssertNotNil(snapshot.exclusions[exclusion])
        }

        try await store.removeExclusion(exclusion, sourceGeneration: 0)
        let reopened = VoiceLearningStore(persistence: persistence)
        let snapshot = try await reopened.snapshot(sourceIDs: ["folder:a"])
        XCTAssertNil(snapshot.exclusions[exclusion])
    }

    func testFailedResetCanBeRetriedAndIsDurableAfterReopening() async throws {
        let persistence = MemoryVoiceLearningPersistence()
        let store = VoiceLearningStore(persistence: persistence)
        let sourceA = key(sourceID: "folder:a", nodeID: "apollo", terms: ["apollo"])
        let sourceB = key(sourceID: "folder:b", nodeID: "journal", terms: ["journal"])
        try await store.recordExclusion(sourceA, at: rejectedAt, sourceGeneration: 0)
        try await store.recordExclusion(sourceB, at: rejectedAt, sourceGeneration: 0)
        persistence.failNextSave = true

        do {
            try await store.delete(sourceID: "folder:a", sourceGeneration: 1)
            XCTFail("Expected the injected save failure.")
        } catch MemoryVoiceLearningPersistence.Failure.save {
            let snapshot = try await store.snapshot(sourceIDs: ["folder:a"])
            XCTAssertNotNil(snapshot.exclusions[sourceA])
        }

        try await store.delete(sourceID: "folder:a", sourceGeneration: 2)
        let reopened = VoiceLearningStore(persistence: persistence)
        let snapshot = try await reopened.snapshot(sourceIDs: ["folder:a", "folder:b"])
        XCTAssertNil(snapshot.exclusions[sourceA])
        XCTAssertNotNil(snapshot.exclusions[sourceB])
    }

    func testCancelledMutationsDoNotPersistOrEraseLearning() async throws {
        let persistence = MemoryVoiceLearningPersistence()
        let store = VoiceLearningStore(persistence: persistence)
        let exclusion = key(sourceID: "folder:a", nodeID: "apollo", terms: ["apollo"])
        let date = rejectedAt
        let recordGate = CancellationGate()
        let recordTask = Task { () throws -> VoiceLearningSnapshot in
            await recordGate.wait()
            return try await store.recordExclusion(exclusion, at: date, sourceGeneration: 0)
        }
        recordTask.cancel()
        await recordGate.open()

        do {
            _ = try await recordTask.value
            XCTFail("Expected cancellation before recording.")
        } catch is CancellationError {
            let snapshot = try await store.snapshot(sourceIDs: ["folder:a"])
            XCTAssertTrue(snapshot.exclusions.isEmpty)
        }

        try await store.recordExclusion(exclusion, at: rejectedAt, sourceGeneration: 0)
        let deletionGate = CancellationGate()
        let deletionTask = Task { () throws -> Void in
            await deletionGate.wait()
            try await store.delete(sourceID: "folder:a", sourceGeneration: 1)
        }
        deletionTask.cancel()
        await deletionGate.open()

        do {
            try await deletionTask.value
            XCTFail("Expected cancellation before reset.")
        } catch is CancellationError {
            let snapshot = try await store.snapshot(sourceIDs: ["folder:a"])
            XCTAssertNotNil(snapshot.exclusions[exclusion])
        }
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
    enum Failure: Error { case load, save, delete }

    private let lock = NSLock()
    private var storedData: Data?
    var failNextLoad = false
    var failNextSave = false
    var failNextDelete = false

    var data: Data? { lock.withLock { storedData } }

    func replaceData(_ data: Data?) { lock.withLock { storedData = data } }

    func load() throws -> Data? {
        try lock.withLock {
            if failNextLoad {
                failNextLoad = false
                throw Failure.load
            }
            return storedData
        }
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
        try lock.withLock {
            if failNextDelete {
                failNextDelete = false
                throw Failure.delete
            }
            storedData = nil
        }
    }
}

private actor CancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private extension Data {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
