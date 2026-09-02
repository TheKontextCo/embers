import XCTest
import EmbersCore
import EmbersLocal
@testable import embers

/// App-boundary tests for persisting Core's provider-neutral change baselines.
final class ChangeBaselinePersistenceTests: XCTestCase {
    func testUserDefaultsStoreSurvivesAppReopen() throws {
        let suiteName = "embers.change-baseline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "test.changed-since-last-peek"
        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: snapshot()))

        UserDefaultsChangeBaselineStore(defaults, storageKey: storageKey).save(baseline)
        let reopened = UserDefaultsChangeBaselineStore(defaults, storageKey: storageKey)

        XCTAssertEqual(reopened.baseline(for: baseline.scope), baseline)
    }

    func testStoreIsolatesProvidersSourcesAndContexts() throws {
        let suiteName = "embers.change-baseline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsChangeBaselineStore(defaults, storageKey: "test.changed-since-last-peek")
        let personal = try XCTUnwrap(ContextChangeBaseline.capture(
            for: "apollo",
            in: snapshot(sourceID: "folder:source:personal", contextID: "apollo", revision: "personal")
        ))
        let work = try XCTUnwrap(ContextChangeBaseline.capture(
            for: "apollo",
            in: snapshot(sourceID: "kontext:source:work", contextID: "apollo", revision: "work")
        ))
        let northstar = try XCTUnwrap(ContextChangeBaseline.capture(
            for: "northstar",
            in: snapshot(sourceID: "folder:source:personal", contextID: "northstar", revision: "northstar")
        ))

        store.save(personal)
        store.save(work)
        store.save(northstar)

        XCTAssertEqual(store.baseline(for: personal.scope), personal)
        XCTAssertEqual(store.baseline(for: work.scope), work)
        XCTAssertEqual(store.baseline(for: northstar.scope), northstar)
    }

    func testCorruptStoreFailsClosedAndCanRecoverOnTheNextSuccessfulPeek() throws {
        let suiteName = "embers.change-baseline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storageKey = "test.changed-since-last-peek"
        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: snapshot()))

        defaults.set(Data("not-json".utf8), forKey: storageKey)
        let corrupt = UserDefaultsChangeBaselineStore(defaults, storageKey: storageKey)
        let recoveredBaseline = corrupt.baseline(for: baseline.scope)
        let changes = ContextChangeDetector.changes(for: "apollo", in: snapshot(revision: "new"), since: recoveredBaseline)

        XCTAssertNil(recoveredBaseline)
        XCTAssertTrue(changes.isEmpty, "Corrupt state must behave like a first peek, never mark every document changed.")

        corrupt.save(baseline)
        XCTAssertEqual(
            UserDefaultsChangeBaselineStore(defaults, storageKey: storageKey).baseline(for: baseline.scope),
            baseline,
            "A later valid save should atomically replace corrupt data."
        )
    }

    func testRemovingOneBaselineLeavesOtherScopesIntact() throws {
        let suiteName = "embers.change-baseline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsChangeBaselineStore(defaults, storageKey: "test.changed-since-last-peek")
        let apollo = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: snapshot()))
        let northstar = try XCTUnwrap(ContextChangeBaseline.capture(
            for: "northstar",
            in: snapshot(contextID: "northstar", revision: "northstar")
        ))
        store.save(apollo)
        store.save(northstar)

        store.removeBaseline(for: apollo.scope)

        XCTAssertNil(store.baseline(for: apollo.scope))
        XCTAssertEqual(store.baseline(for: northstar.scope), northstar)
    }

    func testRemovingAProviderSourceLeavesPeerHistoryIntact() throws {
        let suiteName = "embers.change-baseline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsChangeBaselineStore(defaults, storageKey: "test.changed-since-last-peek")
        let folder = try XCTUnwrap(ContextChangeBaseline.capture(
            for: "apollo",
            in: snapshot(sourceID: "folder:source:personal", revision: "folder")
        ))
        let remote = try XCTUnwrap(ContextChangeBaseline.capture(
            for: "apollo",
            in: snapshot(sourceID: "kontext:source:work", revision: "remote")
        ))
        store.save(folder)
        store.save(remote)

        store.removeBaselines(forSourceID: folder.scope.sourceID)

        XCTAssertNil(store.baseline(for: folder.scope))
        XCTAssertEqual(store.baseline(for: remote.scope), remote)
    }

    func testRealLocalMarkdownEditIsDetectedByContentWithPreservedFileDate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("embers-change-baseline-\(UUID().uuidString)", isDirectory: true)
        let projectFolder = root.appendingPathComponent("Projects/Apollo", isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let brief = projectFolder.appendingPathComponent("Brief.md")
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("# Brief\nOriginal evidence.\n".utf8).write(to: brief)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: brief.path)

        let firstScan = try await FolderContextSource(sourceID: "folder:source:vault", rootURL: root).scan()
        let first = try DeterministicGraphBuilder().build(from: firstScan)
        let apolloID = try XCTUnwrap(first.anchors.first(where: { $0.canonicalName == "Apollo" })?.id)
        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: apolloID, in: first))
        let originalArtifact = try XCTUnwrap(first.artifacts.first)

        try Data("# Brief\nUpdated evidence with the same filesystem date.\n".utf8).write(to: brief)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: brief.path)
        let secondScan = try await FolderContextSource(sourceID: "folder:source:vault", rootURL: root).scan()
        let second = try DeterministicGraphBuilder().build(from: secondScan)
        let currentArtifact = try XCTUnwrap(second.artifacts.first)

        XCTAssertEqual(currentArtifact.id, originalArtifact.id, "The path-derived local identity must remain stable.")
        XCTAssertNotEqual(currentArtifact.contentHash, originalArtifact.contentHash)
        XCTAssertEqual(currentArtifact.modifiedAt, originalArtifact.modifiedAt)
        XCTAssertEqual(
            ContextChangeDetector.changes(for: apolloID, in: second, since: baseline).updatedArtifactIDs,
            Set([originalArtifact.id])
        )
    }

    private func snapshot(
        sourceID: String = "folder:source:vault",
        contextID: String = "apollo",
        revision: String = "v1"
    ) -> ContextSnapshot {
        let artifact = SourceArtifact(
            id: "\(sourceID):document:brief",
            relativePath: "Brief.md",
            mediaKind: .markdown,
            title: "Brief",
            extractedText: "Evidence",
            modifiedAt: .distantPast,
            contentHash: revision,
            provider: .init(pluginID: sourceID.components(separatedBy: ":").first ?? "fixture", sourceID: sourceID)
        )
        return ContextSnapshot(
            sourceID: sourceID,
            revision: revision,
            artifacts: [artifact],
            anchors: [
                Anchor(
                    id: contextID,
                    canonicalName: contextID.capitalized,
                    provenance: [.folder],
                    memberArtifactIDs: [artifact.id]
                )
            ],
            relations: [],
            diagnostics: [],
            indexedAt: .now
        )
    }
}
