import XCTest
@testable import EmbersCore

/// Contract tests for provider-neutral Changed Since Last Peek.
///
/// These intentionally describe an API that does not exist yet. The implementation belongs in
/// EmbersCore because it compares normalized snapshots; providers supply stable IDs and content
/// revision tokens, while the app owns persistence and presentation.
final class ChangeBaselineTests: XCTestCase {
    func testFirstPeekCapturesABaselineWithoutReportingEverythingAsChanged() throws {
        let initial = snapshot(
            sourceID: "folder:source:vault",
            artifacts: [artifact("brief", revision: "v1")],
            members: ["brief"]
        )

        let changes = ContextChangeDetector.changes(
            for: "apollo",
            in: initial,
            since: nil
        )
        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: initial))

        XCTAssertTrue(changes.isEmpty, "A missing baseline means first peek, not that every artifact is new.")
        XCTAssertEqual(baseline.scope, ContextChangeScope(sourceID: "folder:source:vault", contextID: "apollo"))
        XCTAssertEqual(baseline.artifactRevisions, ["brief": "v1"])
    }

    func testContentRevisionRatherThanWallClockDeterminesWhetherAnArtifactChanged() throws {
        let baselineSnapshot = snapshot(
            artifacts: [artifact("brief", revision: "same", modifiedAt: Date(timeIntervalSince1970: 100))],
            members: ["brief"]
        )
        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: baselineSnapshot))

        let clockOnlyChange = snapshot(
            artifacts: [artifact("brief", revision: "same", modifiedAt: Date(timeIntervalSince1970: 9_999))],
            members: ["brief"]
        )
        XCTAssertTrue(
            ContextChangeDetector.changes(for: "apollo", in: clockOnlyChange, since: baseline).isEmpty,
            "A copied or cloud-synced timestamp must not create a false positive."
        )

        let realChangeWithSameClock = snapshot(
            artifacts: [artifact("brief", revision: "v2", modifiedAt: Date(timeIntervalSince1970: 100))],
            members: ["brief"]
        )
        XCTAssertEqual(
            ContextChangeDetector.changes(for: "apollo", in: realChangeWithSameClock, since: baseline).updatedArtifactIDs,
            Set(["brief"]),
            "A changed revision must survive preserved timestamps and clock skew."
        )
    }

    func testAddedUpdatedAndRemovedArtifactsAreReportedDeterministically() throws {
        let old = snapshot(
            artifacts: [
                artifact("alpha", revision: "v1"),
                artifact("beta", revision: "v1"),
                artifact("removed", revision: "v1"),
            ],
            members: ["alpha", "beta", "removed"]
        )
        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: old))
        let current = snapshot(
            artifacts: [
                artifact("alpha", revision: "v1"),
                artifact("beta", revision: "v2"),
                artifact("new", revision: "v1"),
            ],
            members: ["alpha", "beta", "new"]
        )

        let changes = ContextChangeDetector.changes(for: "apollo", in: current, since: baseline)

        XCTAssertEqual(changes.addedArtifactIDs, Set(["new"]))
        XCTAssertEqual(changes.updatedArtifactIDs, Set(["beta"]))
        XCTAssertEqual(changes.removedArtifactIDs, Set(["removed"]))
        XCTAssertEqual(changes.currentChangedArtifactIDs, Set(["beta", "new"]))
        XCTAssertTrue(changes.membershipChanged)
    }

    func testMembershipChangesAreVisibleEvenWhenArtifactContentIsUnchanged() throws {
        let allArtifacts = [artifact("brief", revision: "v1"), artifact("research", revision: "v1")]
        let old = snapshot(artifacts: allArtifacts, members: ["brief"])
        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: old))
        let current = snapshot(artifacts: allArtifacts, members: ["brief", "research"])

        let changes = ContextChangeDetector.changes(for: "apollo", in: current, since: baseline)

        XCTAssertTrue(changes.membershipChanged)
        XCTAssertEqual(changes.addedArtifactIDs, Set(["research"]))
        XCTAssertTrue(changes.updatedArtifactIDs.isEmpty)
    }

    func testUnchangedMembershipDoesNotDependOnSnapshotOrCollectionOrdering() throws {
        let first = snapshot(
            artifacts: [artifact("a", revision: "1"), artifact("b", revision: "1")],
            members: ["a", "b"]
        )
        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: first))
        let reordered = snapshot(
            artifacts: [artifact("b", revision: "1"), artifact("a", revision: "1")],
            members: ["b", "a"],
            revision: "different-workspace-revision"
        )

        XCTAssertTrue(ContextChangeDetector.changes(for: "apollo", in: reordered, since: baseline).isEmpty)
    }

    func testRecapturingAfterAPeekMakesThePresentedRevisionTheNewBaseline() throws {
        let first = snapshot(artifacts: [artifact("brief", revision: "v1")], members: ["brief"])
        let firstBaseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: first))
        let second = snapshot(artifacts: [artifact("brief", revision: "v2")], members: ["brief"])

        XCTAssertEqual(
            ContextChangeDetector.changes(for: "apollo", in: second, since: firstBaseline).updatedArtifactIDs,
            Set(["brief"])
        )

        let secondBaseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: second))
        XCTAssertTrue(ContextChangeDetector.changes(for: "apollo", in: second, since: secondBaseline).isEmpty)
    }

    func testAContextOrSourceMismatchFailsClosedInsteadOfLeakingAnotherSourcesHistory() throws {
        let sourceA = snapshot(
            sourceID: "folder:source:personal",
            artifacts: [artifact("brief", revision: "private-v1")],
            members: ["brief"]
        )
        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: sourceA))
        let sourceB = snapshot(
            sourceID: "kontext:source:work",
            artifacts: [artifact("brief", revision: "work-v9")],
            members: ["brief"]
        )

        XCTAssertTrue(
            ContextChangeDetector.changes(for: "apollo", in: sourceB, since: baseline).isEmpty,
            "A baseline is scoped by source and context; mismatches must behave like a first peek."
        )
        XCTAssertTrue(
            ContextChangeDetector.changes(for: "northstar", in: sourceA, since: baseline).isEmpty,
            "One context's baseline must never mark another context's artifacts as changed."
        )
    }

    func testMissingContextFailsClosed() throws {
        let old = snapshot(artifacts: [artifact("brief", revision: "v1")], members: ["brief"])
        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: old))
        let current = ContextSnapshot(
            sourceID: old.sourceID,
            revision: "without-apollo",
            artifacts: old.artifacts,
            anchors: [],
            relations: [],
            diagnostics: [],
            indexedAt: .now
        )

        XCTAssertNil(ContextChangeBaseline.capture(for: "apollo", in: current))
        XCTAssertTrue(ContextChangeDetector.changes(for: "apollo", in: current, since: baseline).isEmpty)
    }

    func testRemoteTaskStatusChangeIsAnUpdateEvenWhenItsTimestampIsUnreliable() throws {
        let openTask = remoteTask(state: .open, revision: "task:open")
        let old = snapshot(
            sourceID: "kontext:source:account-1",
            artifacts: [openTask],
            members: [openTask.id]
        )
        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: old))
        let completedTask = remoteTask(state: .completed, revision: "task:completed")
        let current = snapshot(
            sourceID: "kontext:source:account-1",
            artifacts: [completedTask],
            members: [completedTask.id]
        )

        let changes = ContextChangeDetector.changes(for: "apollo", in: current, since: baseline)

        XCTAssertEqual(changes.updatedArtifactIDs, Set([completedTask.id]))
        XCTAssertFalse(changes.membershipChanged)
    }

    func testRemovalOnlyChangeProducesASummaryWithoutInventingACurrentArtifact() {
        let changes = ContextChangeSet(
            removedArtifactIDs: ["removed-document"],
            membershipChanged: true
        )

        XCTAssertTrue(changes.currentChangedArtifactIDs.isEmpty)
        XCTAssertEqual(
            changes.nonArtifactSummaries,
            [ContextChangeSummary(kind: .removedArtifacts, count: 1)]
        )
    }

    func testMembershipOnlyChangeProducesAStructuralSummary() {
        let changes = ContextChangeSet(membershipChanged: true)

        XCTAssertTrue(changes.currentChangedArtifactIDs.isEmpty)
        XCTAssertEqual(
            changes.nonArtifactSummaries,
            [ContextChangeSummary(kind: .membershipChanged, count: 1)]
        )
    }

    func testArtifactRowsAndStructuralSummariesDoNotDoubleCountMembership() {
        let changes = ContextChangeSet(
            addedArtifactIDs: ["new-document"],
            removedArtifactIDs: ["old-document"],
            membershipChanged: true
        )

        XCTAssertEqual(changes.currentChangedArtifactIDs, ["new-document"])
        XCTAssertEqual(
            changes.nonArtifactSummaries,
            [ContextChangeSummary(kind: .removedArtifacts, count: 1)]
        )
    }

    func testComposedWorkspaceBaselineUsesTheContextsOwningProviderSource() throws {
        let owned = SourceArtifact(
            id: "folder:source:vault:document:brief",
            relativePath: "Brief.md",
            mediaKind: .markdown,
            title: "Brief",
            extractedText: "Evidence",
            modifiedAt: .distantPast,
            contentHash: "v1",
            provider: .init(pluginID: "folder", sourceID: "folder:source:vault")
        )
        let workspace = snapshot(
            sourceID: "workspace",
            artifacts: [owned],
            members: [owned.id]
        )

        let baseline = try XCTUnwrap(ContextChangeBaseline.capture(for: "apollo", in: workspace))

        XCTAssertEqual(baseline.scope.sourceID, "folder:source:vault")
        XCTAssertTrue(ContextChangeDetector.changes(for: "apollo", in: workspace, since: baseline).isEmpty)
    }

    private func snapshot(
        sourceID: String = "folder:source:vault",
        artifacts: [SourceArtifact],
        members: Set<String>,
        revision: String = UUID().uuidString
    ) -> ContextSnapshot {
        ContextSnapshot(
            sourceID: sourceID,
            revision: revision,
            artifacts: artifacts,
            anchors: [
                Anchor(
                    id: "apollo",
                    canonicalName: "Apollo",
                    provenance: [.folder],
                    memberArtifactIDs: members
                )
            ],
            relations: [],
            diagnostics: [],
            indexedAt: .now
        )
    }

    private func artifact(
        _ id: String,
        revision: String,
        modifiedAt: Date = .distantPast
    ) -> SourceArtifact {
        SourceArtifact(
            id: id,
            relativePath: "\(id).md",
            mediaKind: .markdown,
            title: id.capitalized,
            extractedText: "Evidence for \(id)",
            modifiedAt: modifiedAt,
            contentHash: revision
        )
    }

    private func remoteTask(state: SourceTaskState, revision: String) -> SourceArtifact {
        SourceArtifact(
            id: "kontext:source:account-1:task:ship",
            relativePath: "task-ship",
            mediaKind: .markdown,
            title: "Ship the app",
            extractedText: "Ship the app",
            modifiedAt: Date(timeIntervalSince1970: 100),
            contentHash: revision,
            location: .provider(pluginID: "kontext", externalID: "ship"),
            provider: .init(pluginID: "kontext", sourceID: "kontext:source:account-1"),
            metadata: .init(
                tasks: [.init(id: "ship", text: "Ship the app", state: state)],
                modificationDateReliable: false
            )
        )
    }
}
