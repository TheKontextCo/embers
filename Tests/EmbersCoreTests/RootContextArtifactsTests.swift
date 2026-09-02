import XCTest
@testable import EmbersCore

final class RootContextArtifactsTests: XCTestCase {
    func testOnlyArtifactsWithoutContextMembershipAppearAtRoot() {
        let assigned = artifact("assigned", title: "Assigned", pluginID: "kontext")
        let looseB = artifact("loose-b", title: "Beta", pluginID: "kontext")
        let looseA = artifact("loose-a", title: "Alpha", pluginID: "kontext")
        let local = artifact("local", title: "Local")
        let project = Anchor(
            id: "project",
            canonicalName: "Project",
            provenance: [.manifest],
            memberArtifactIDs: [assigned.id]
        )
        let snapshot = ContextSnapshot(
            sourceID: "s",
            revision: "r",
            artifacts: [looseB, assigned, local, looseA],
            anchors: [project],
            relations: [],
            diagnostics: [],
            indexedAt: .distantPast
        )

        XCTAssertEqual(
            LinearContextSearch().unassignedArtifacts(in: snapshot, ownedByPluginID: "kontext").map(\.id),
            [looseA.id, looseB.id]
        )
    }

    private func artifact(_ id: String, title: String, pluginID: String? = nil) -> SourceArtifact {
        SourceArtifact(
            id: id,
            relativePath: "\(id).md",
            mediaKind: .markdown,
            title: title,
            extractedText: title,
            modifiedAt: .distantPast,
            contentHash: id,
            provider: pluginID.map { ArtifactProviderReference(pluginID: $0) }
        )
    }
}
