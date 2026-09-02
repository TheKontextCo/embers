import Foundation
import XCTest
@testable import EmbersLocal

final class VoiceRoutingPreferenceStoreTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func testWeightDecaysWithThirtyDayHalfLife() async throws {
        let store = VoiceRoutingPreferenceStore(persistence: MemoryPreferencePersistence())
        try await store.recordOpen(
            sourceID: "folder:a",
            conceptID: "journal",
            nodeID: "node-journal",
            at: epoch
        )

        let half = try await store.association(
            sourceID: "folder:a",
            conceptID: "journal",
            nodeID: "node-journal",
            at: epoch.addingTimeInterval(VoiceRoutingPreferenceStore.halfLife)
        )
        let quarter = try await store.association(
            sourceID: "folder:a",
            conceptID: "journal",
            nodeID: "node-journal",
            at: epoch.addingTimeInterval(VoiceRoutingPreferenceStore.halfLife * 2)
        )

        XCTAssertEqual(half?.weight ?? -1, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(quarter?.weight ?? -1, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(half?.openCount, 1)
    }

    func testRepeatedOpensAddOneCapAtThreeAndBoostCapsAtTwelvePercent() async throws {
        let store = VoiceRoutingPreferenceStore(persistence: MemoryPreferencePersistence())

        for _ in 0..<5 {
            try await store.recordOpen(
                sourceID: "folder:a",
                conceptID: "second-brain",
                nodeID: "node-brain",
                at: epoch
            )
        }

        let association = try await store.association(
            sourceID: "folder:a",
            conceptID: "second-brain",
            nodeID: "node-brain",
            at: epoch
        )
        let boost = try await store.boost(
            sourceID: "folder:a",
            conceptID: "second-brain",
            nodeID: "node-brain",
            at: epoch
        )
        XCTAssertEqual(association?.openCount, 5)
        XCTAssertEqual(association?.weight, 3)
        XCTAssertEqual(boost, 0.12, accuracy: 0.000_001)
    }

    func testEqualPreferencesUseStableConceptAndNodeTies() async throws {
        let store = VoiceRoutingPreferenceStore(persistence: MemoryPreferencePersistence())
        for (conceptID, nodeID) in [
            ("zeta", "node-b"),
            ("alpha", "node-z"),
            ("alpha", "node-a"),
        ] {
            try await store.recordOpen(
                sourceID: "folder:a",
                conceptID: conceptID,
                nodeID: nodeID,
                at: epoch
            )
        }

        let associations = try await store.associations(sourceID: "folder:a", at: epoch)
        XCTAssertEqual(
            associations.map { "\($0.conceptID):\($0.nodeID)" },
            ["alpha:node-a", "alpha:node-z", "zeta:node-b"]
        )
        for association in associations {
            let boost = try await store.boost(
                sourceID: "folder:a",
                conceptID: association.conceptID,
                nodeID: association.nodeID,
                at: epoch
            )
            XCTAssertEqual(boost, 0.04, accuracy: 0.000_001)
        }
    }

    func testSourcesAreIsolatedAndResetPreservesOtherSources() async throws {
        let persistence = MemoryPreferencePersistence()
        let store = VoiceRoutingPreferenceStore(persistence: persistence)
        try await store.recordOpen(
            sourceID: "folder:a",
            conceptID: "journal",
            nodeID: "node-a",
            at: epoch
        )
        try await store.recordOpen(
            sourceID: "folder:b",
            conceptID: "journal",
            nodeID: "node-b",
            at: epoch
        )

        let sourceABeforeReset = try await store.associations(sourceID: "folder:a", at: epoch)
        let sourceBBeforeReset = try await store.associations(sourceID: "folder:b", at: epoch)
        XCTAssertEqual(sourceABeforeReset.map(\.nodeID), ["node-a"])
        XCTAssertEqual(sourceBBeforeReset.map(\.nodeID), ["node-b"])

        try await store.reset(sourceID: "folder:a")

        let sourceAAfterReset = try await store.associations(sourceID: "folder:a", at: epoch)
        let sourceBAfterReset = try await store.associations(sourceID: "folder:b", at: epoch)
        XCTAssertTrue(sourceAAfterReset.isEmpty)
        XCTAssertEqual(sourceBAfterReset.map(\.nodeID), ["node-b"])
        let json = try XCTUnwrap(persistence.data).utf8String
        XCTAssertFalse(json.contains("folder:a"))
        XCTAssertTrue(json.contains("folder:b"))
    }

    func testBulkSnapshotCombinesRequestedSourcesWithSynchronousBoosts() async throws {
        let store = VoiceRoutingPreferenceStore(persistence: MemoryPreferencePersistence())
        try await store.recordOpen(
            sourceID: "folder:a",
            conceptID: "knowledge-system",
            nodeID: "node-brain",
            at: epoch
        )
        for _ in 0..<3 {
            try await store.recordOpen(
                sourceID: "kontext:account",
                conceptID: "project-planning",
                nodeID: "node-project",
                at: epoch
            )
        }
        try await store.recordOpen(
            sourceID: "unused",
            conceptID: "journal",
            nodeID: "node-journal",
            at: epoch
        )

        let snapshot = try await store.snapshot(
            sourceIDs: ["folder:a", "kontext:account"],
            at: epoch.addingTimeInterval(VoiceRoutingPreferenceStore.halfLife)
        )

        XCTAssertEqual(snapshot.sourceIDs, ["folder:a", "kontext:account"])
        XCTAssertEqual(snapshot.generatedAt, epoch.addingTimeInterval(VoiceRoutingPreferenceStore.halfLife))
        XCTAssertEqual(snapshot.associations.count, 2)
        XCTAssertEqual(
            snapshot.boost(conceptID: "knowledge-system", nodeID: "node-brain"),
            0.02,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            snapshot.boost(conceptID: "project-planning", nodeID: "node-project"),
            0.06,
            accuracy: 0.000_001
        )
        XCTAssertEqual(snapshot.boost(conceptID: "journal", nodeID: "node-journal"), 0)
        XCTAssertEqual(snapshot.boost(conceptID: "missing", nodeID: "missing"), 0)
    }

    func testBulkSnapshotReportsPerSourceSummaryIncludingEmptyRequestedSource() async throws {
        let store = VoiceRoutingPreferenceStore(persistence: MemoryPreferencePersistence())
        try await store.recordOpen(
            sourceID: "folder:a",
            conceptID: "journal",
            nodeID: "node-journal",
            at: epoch
        )
        try await store.recordOpen(
            sourceID: "folder:a",
            conceptID: "journal",
            nodeID: "node-journal",
            at: epoch.addingTimeInterval(60)
        )
        try await store.recordOpen(
            sourceID: "folder:a",
            conceptID: "knowledge-system",
            nodeID: "node-brain",
            at: epoch.addingTimeInterval(120)
        )

        let snapshot = try await store.snapshot(
            sourceIDs: ["folder:a", "folder:empty"],
            at: epoch.addingTimeInterval(180)
        )

        XCTAssertEqual(
            snapshot.summaryBySourceID["folder:a"],
            .init(
                sourceID: "folder:a",
                associationCount: 2,
                totalOpenCount: 3,
                lastOpenedAt: epoch.addingTimeInterval(120)
            )
        )
        XCTAssertEqual(
            snapshot.summaryBySourceID["folder:empty"],
            .empty(sourceID: "folder:empty")
        )
        XCTAssertEqual(VoiceRoutingPreferenceSnapshot.empty.boost(conceptID: "x", nodeID: "y"), 0)
    }

    func testDeleteSourceRemovesFileOnlyAfterFinalSourceAndDeleteAllClearsMemory() async throws {
        let persistence = MemoryPreferencePersistence()
        let store = VoiceRoutingPreferenceStore(persistence: persistence)
        for sourceID in ["folder:a", "folder:b"] {
            try await store.recordOpen(
                sourceID: sourceID,
                conceptID: "journal",
                nodeID: "node-journal",
                at: epoch
            )
        }

        try await store.delete(sourceID: "folder:a")
        XCTAssertNotNil(persistence.data)
        let sourceB = try await store.associations(sourceID: "folder:b", at: epoch)
        XCTAssertEqual(sourceB.count, 1)

        try await store.delete(sourceID: "folder:b")
        XCTAssertNil(persistence.data)

        try await store.recordOpen(
            sourceID: "folder:c",
            conceptID: "journal",
            nodeID: "node-journal",
            at: epoch
        )
        try await store.deleteAll()
        XCTAssertNil(persistence.data)
        let sourceC = try await store.associations(sourceID: "folder:c", at: epoch)
        XCTAssertTrue(sourceC.isEmpty)
    }

    func testResetAndDeleteTombstonesRejectDelayedOlderGenerationWrites() async throws {
        let store = VoiceRoutingPreferenceStore(persistence: MemoryPreferencePersistence())
        try await store.recordOpen(
            sourceID: "folder:a",
            conceptID: "knowledge-system",
            nodeID: "node-brain",
            at: epoch,
            sourceGeneration: 0
        )

        try await store.reset(sourceID: "folder:a", sourceGeneration: 1)
        do {
            try await store.recordOpen(
                sourceID: "folder:a",
                conceptID: "knowledge-system",
                nodeID: "node-brain",
                at: epoch,
                sourceGeneration: 0
            )
            XCTFail("A delayed pre-reset open must not recreate the source bucket")
        } catch is CancellationError {
            // Expected stale generation rejection.
        }
        let afterReset = try await store.associations(sourceID: "folder:a", at: epoch)
        XCTAssertTrue(afterReset.isEmpty)

        try await store.recordOpen(
            sourceID: "folder:a",
            conceptID: "knowledge-system",
            nodeID: "node-brain",
            at: epoch,
            sourceGeneration: 1
        )
        try await store.delete(sourceID: "folder:a", sourceGeneration: 2)
        do {
            try await store.recordOpen(
                sourceID: "folder:a",
                conceptID: "knowledge-system",
                nodeID: "node-brain",
                at: epoch,
                sourceGeneration: 1
            )
            XCTFail("A delayed pre-delete open must not recreate the source bucket")
        } catch is CancellationError {
            // Expected stale generation rejection.
        }
        let afterDelete = try await store.associations(sourceID: "folder:a", at: epoch)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testCorruptArchiveRecoversAsEmptyAndNextWriteIsInspectableJSON() async throws {
        let persistence = MemoryPreferencePersistence(data: Data("not-json".utf8))
        let store = VoiceRoutingPreferenceStore(persistence: persistence)

        let recovered = try await store.associations(sourceID: "folder:a", at: epoch)
        XCTAssertTrue(recovered.isEmpty)
        try await store.recordOpen(
            sourceID: "folder:a",
            conceptID: "journal",
            nodeID: "node-journal",
            at: epoch
        )

        let data = try XCTUnwrap(persistence.data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        let sources = try XCTUnwrap(object["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.first?["sourceID"] as? String, "folder:a")
        XCTAssertTrue(data.utf8String.contains("\n"), "JSON should remain human-inspectable")
    }

    func testPrunesLowestEffectiveWeightToFiveHundredPerSource() async throws {
        let store = VoiceRoutingPreferenceStore(persistence: MemoryPreferencePersistence())
        for index in 0...VoiceRoutingPreferenceStore.maximumAssociationsPerSource {
            try await store.recordOpen(
                sourceID: "folder:a",
                conceptID: String(format: "concept-%03d", index),
                nodeID: String(format: "node-%03d", index),
                at: epoch.addingTimeInterval(TimeInterval(index))
            )
        }

        let now = epoch.addingTimeInterval(
            TimeInterval(VoiceRoutingPreferenceStore.maximumAssociationsPerSource)
        )
        let associations = try await store.associations(sourceID: "folder:a", at: now)
        XCTAssertEqual(associations.count, VoiceRoutingPreferenceStore.maximumAssociationsPerSource)
        XCTAssertFalse(associations.contains { $0.conceptID == "concept-000" })
        XCTAssertTrue(associations.contains { $0.conceptID == "concept-500" })
    }
}

private final class MemoryPreferencePersistence: VoiceRoutingPreferencePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var storedData: Data?

    init(data: Data? = nil) {
        storedData = data
    }

    var data: Data? {
        lock.withLock { storedData }
    }

    func load() throws -> Data? {
        lock.withLock { storedData }
    }

    func save(_ data: Data) throws {
        lock.withLock { storedData = data }
    }

    func delete() throws {
        lock.withLock { storedData = nil }
    }
}

private extension Data {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
