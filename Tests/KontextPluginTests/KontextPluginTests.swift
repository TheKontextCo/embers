import Foundation
import XCTest
@testable import EmbersCore
@testable import EmbersLocal
@testable import EmbersPluginKit
@testable import KontextPlugin

final class KontextPluginTests: XCTestCase {
    func testClientReadsEveryPageBeforeReturningSnapshot() async throws {
        let transport = ScriptedTransport(responses: [
            snapshotResponse(page: 0, total: 3, complete: false, cursor: "second", entities: [project("p"), task("t", project: "p")]),
            snapshotResponse(page: 2, total: 3, complete: true, entities: [document("d", projects: ["p"])])
        ])

        let snapshot = try await KontextGraphSnapshotClient(transport: transport, origin: KontextPlugin.productionOrigin, maximumRestarts: 0).fetch()
        let urls = await transport.urls()

        XCTAssertEqual(snapshot.entities.map(\.key), ["project:p", "task:t", "document:d"])
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls.allSatisfy { $0.contains("includeShared=true") })
        XCTAssertTrue(urls[1].contains("cursor=second"))
    }

    func testClientRejectsAResponseThatOmitsRequestedSharedScope() async throws {
        let transport = ScriptedTransport(responses: [
            snapshotResponse(page: 0, total: 1, complete: true, entities: [project("p")], scope: nil),
        ])

        do {
            _ = try await KontextGraphSnapshotClient(transport: transport, origin: KontextPlugin.productionOrigin, maximumRestarts: 0).fetch()
            XCTFail("An owned-only response must not silently drop Shared with me")
        } catch let error as KontextPluginError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    func testClientRestartsFromFirstPageAfterSnapshotChanged() async throws {
        let transport = ScriptedTransport(responses: [
            .init(statusCode: 409, body: json(["ok": false, "version": 1, "restart": true, "error": ["code": "snapshot_changed"]])),
            snapshotResponse(page: 0, total: 1, complete: true, entities: [project("p")])
        ])

        let snapshot = try await KontextGraphSnapshotClient(transport: transport, origin: KontextPlugin.productionOrigin, maximumRestarts: 1).fetch()
        let urls = await transport.urls()

        XCTAssertEqual(snapshot.revision, revision)
        XCTAssertEqual(urls.count, 2)
        XCTAssertFalse(urls[1].contains("cursor="))
    }

    func testClientRejectsTruncatedOrMixedRevisionSnapshot() async throws {
        let truncated = ScriptedTransport(responses: [
            snapshotResponse(page: 0, total: 2, complete: false, cursor: nil, entities: [project("p")])
        ])
        do {
            _ = try await KontextGraphSnapshotClient(transport: truncated, origin: KontextPlugin.productionOrigin, maximumRestarts: 0).fetch()
            XCTFail("A partial graph must never be accepted")
        } catch let error as KontextPluginError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected error \(error)") }
        }

        let mixed = ScriptedTransport(responses: [
            snapshotResponse(page: 0, total: 2, complete: false, cursor: "next", entities: [project("p")]),
            snapshotResponse(page: 1, total: 2, complete: true, entities: [task("t", project: "p")], revision: String(repeating: "b", count: 64))
        ])
        do {
            _ = try await KontextGraphSnapshotClient(transport: mixed, origin: KontextPlugin.productionOrigin, maximumRestarts: 0).fetch()
            XCTFail("Mixed-revision pages must not be accepted")
        } catch let error as KontextPluginError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    func testPluginMapsProjectsAsContextsAndLeavesTasksAndDocumentsSearchable() async throws {
        let entities: [[String: Any]] = [
            project("p", title: "Apollo"),
            task("t", title: "Apollo", project: "p"),
            document("d", title: "Apollo", projects: ["p"], truncated: true),
        ]
        let edges: [[String: Any]] = [[
            // The public graph-snapshot contract deliberately exposes no
            // database edge ID. The client derives a stable public identity
            // from this full observable edge instead.
            "kind": "depends-on",
            "from": ["type": "document", "id": "d"],
            "to": ["type": "task", "id": "t"],
            "evidence": ["source": "kontext", "assertedAt": date, "metadata": ["reason": "fixture", "weight": 1]],
        ]]
        let response = snapshotResponse(page: 0, total: 3, complete: true, entities: entities, edges: edges)
        let transport = ScriptedTransport(responses: [response, response])
        let secrets = MemorySecrets()
        let oauth = OAuthConnection(
            configuration: .init(issuer: KontextPlugin.productionOrigin, clientName: "test", redirectURI: KontextPlugin.redirectURI, scopes: ["kontext"]),
            credentials: OAuthCredentialStore(key: "kontext-tests", secrets: secrets)
        )
        let plugin = KontextPlugin(connection: oauth, transport: transport, actionOpener: RecordingOpener())
        let source = try await plugin.sources().single()
        let result = try await plugin.refresh(source)
        let snapshot = try XCTUnwrap(result.snapshot)
        let sourceID = source.id
        let projectID = PluginEntityIdentifier(source: sourceID, kind: "project", externalID: "p").rawValue
        let taskID = PluginEntityIdentifier(source: sourceID, kind: "task", externalID: "t").rawValue
        let documentID = PluginEntityIdentifier(source: sourceID, kind: "document", externalID: "d").rawValue

        XCTAssertEqual(snapshot.sourceID, source.id.rawValue)
        XCTAssertEqual(snapshot.revision, revision)
        XCTAssertEqual(Set(snapshot.artifacts.map(\.id)), [taskID, documentID])
        XCTAssertEqual(snapshot.artifacts.map(\.location).allSatisfy { if case .web = $0 { return true }; return false }, true)
        XCTAssertTrue(snapshot.artifacts.allSatisfy { $0.provider == .init(pluginID: "kontext", sourceID: source.id.rawValue) })
        XCTAssertEqual(snapshot.anchors.first(where: { $0.id == projectID })?.memberArtifactIDs, [taskID, documentID])
        XCTAssertFalse(snapshot.relations.contains { $0.source == projectID && $0.target == "artifact:\(taskID)" })
        XCTAssertTrue(snapshot.relations.contains { $0.source == "artifact:\(documentID)" && $0.target == "artifact:\(taskID)" && $0.kind == "depends-on" && $0.evidence == .authored })
        let graph = DeterministicContextGraphProjector().project(snapshot)
        XCTAssertEqual(graph.edges.filter { $0.source == projectID && $0.target == "artifact:\(taskID)" }.map(\.kind), ["includes"])
        XCTAssertEqual(Set(snapshot.anchors.filter { $0.canonicalName == "Apollo" }.map(\.id)), [projectID])
        XCTAssertEqual(Set(snapshot.artifacts.map(\.metadata.kind)), ["task", "memory"])
        XCTAssertTrue(snapshot.diagnostics.contains { $0.id.contains("kontext-truncated") })
    }

    func testNormalizedContentRevisionIgnoresModifiedAtOnlyChanges() async throws {
        let first = snapshotResponse(
            page: 0,
            total: 1,
            complete: true,
            entities: [document("d", updatedAt: "2026-08-17T00:00:00.000Z")]
        )
        let second = snapshotResponse(
            page: 0,
            total: 1,
            complete: true,
            entities: [document("d", updatedAt: "2026-08-23T12:34:56.000Z")]
        )
        let plugin = KontextPlugin(
            connection: testConnection(),
            transport: ScriptedTransport(responses: [first, second]),
            actionOpener: RecordingOpener()
        )
        let source = try await plugin.sources().single()
        let oldResult = try await plugin.refresh(source)
        let newResult = try await plugin.refresh(source)
        let oldArtifact = try XCTUnwrap(oldResult.snapshot?.artifacts.single())
        let newArtifact = try XCTUnwrap(newResult.snapshot?.artifacts.single())

        XCTAssertNotEqual(oldArtifact.modifiedAt, newArtifact.modifiedAt)
        XCTAssertEqual(
            oldArtifact.contentHash,
            newArtifact.contentHash,
            "Provider timestamps order evidence but do not prove normalized content changed."
        )
    }

    func testNormalizedContentRevisionChangesWithDocumentContent() async throws {
        let plugin = KontextPlugin(
            connection: testConnection(),
            transport: ScriptedTransport(responses: [
                snapshotResponse(page: 0, total: 1, complete: true, entities: [document("d", body: "Original evidence")]),
                snapshotResponse(page: 0, total: 1, complete: true, entities: [document("d", body: "Updated evidence")]),
            ]),
            actionOpener: RecordingOpener()
        )
        let source = try await plugin.sources().single()
        let oldResult = try await plugin.refresh(source)
        let newResult = try await plugin.refresh(source)
        let oldArtifact = try XCTUnwrap(oldResult.snapshot?.artifacts.single())
        let newArtifact = try XCTUnwrap(newResult.snapshot?.artifacts.single())

        XCTAssertNotEqual(oldArtifact.contentHash, newArtifact.contentHash)
    }

    func testNormalizedContentRevisionChangesWithTaskStatusAndProjectMembership() async throws {
        let initialEntities = [
            project("alpha", title: "Alpha"),
            project("beta", title: "Beta"),
            task("t", project: "alpha", status: "open"),
        ]
        let completedEntities = [
            project("alpha", title: "Alpha"),
            project("beta", title: "Beta"),
            task("t", project: "alpha", status: "done"),
        ]
        let movedEntities = [
            project("alpha", title: "Alpha"),
            project("beta", title: "Beta"),
            task("t", project: "beta", status: "done"),
        ]
        let plugin = KontextPlugin(
            connection: testConnection(),
            transport: ScriptedTransport(responses: [
                snapshotResponse(page: 0, total: 3, complete: true, entities: initialEntities),
                snapshotResponse(page: 0, total: 3, complete: true, entities: completedEntities),
                snapshotResponse(page: 0, total: 3, complete: true, entities: movedEntities),
            ]),
            actionOpener: RecordingOpener()
        )
        let source = try await plugin.sources().single()
        let openResult = try await plugin.refresh(source)
        let completedResult = try await plugin.refresh(source)
        let movedResult = try await plugin.refresh(source)
        let openTask = try XCTUnwrap(openResult.snapshot?.artifacts.single())
        let completedTask = try XCTUnwrap(completedResult.snapshot?.artifacts.single())
        let movedTask = try XCTUnwrap(movedResult.snapshot?.artifacts.single())

        XCTAssertNotEqual(openTask.contentHash, completedTask.contentHash, "Task status is normalized content.")
        XCTAssertNotEqual(completedTask.contentHash, movedTask.contentHash, "Project membership is normalized content.")
    }

    func testNormalizedContentRevisionCanonicalizesProjectMembershipOrder() async throws {
        let plugin = KontextPlugin(
            connection: testConnection(),
            transport: ScriptedTransport(responses: [
                snapshotResponse(page: 0, total: 1, complete: true, entities: [document("d", projects: ["alpha", "beta"])]),
                snapshotResponse(page: 0, total: 1, complete: true, entities: [document("d", projects: ["beta", "alpha"])]),
            ]),
            actionOpener: RecordingOpener()
        )
        let source = try await plugin.sources().single()
        let firstResult = try await plugin.refresh(source)
        let reorderedResult = try await plugin.refresh(source)
        let first = try XCTUnwrap(firstResult.snapshot?.artifacts.single())
        let reordered = try XCTUnwrap(reorderedResult.snapshot?.artifacts.single())

        XCTAssertEqual(first.contentHash, reordered.contentHash)
    }

    func testTaskMutationUsesNativeStatusContractAndProviderIdentity() async throws {
        let snapshot = snapshotResponse(page: 0, total: 2, complete: true, entities: [
            task("parent", project: nil),
            task("t", project: nil),
        ])
        let mutation = OAuthHTTPResponse(statusCode: 200, body: json([
            "ok": true,
            "version": 1,
            "item": ["id": "t", "isCompleted": true, "contextLabel": "Done"],
            "taskStatusUpdates": [
                ["taskId": "parent", "status": "done"],
                ["taskId": "t", "status": "done"],
            ],
        ]))
        let transport = ScriptedTransport(responses: [snapshot, mutation])
        let plugin = KontextPlugin(connection: testConnection(), transport: transport, actionOpener: RecordingOpener())
        let source = try await plugin.sources().single()
        let result = try await plugin.refresh(source)
        let artifact = try XCTUnwrap(result.snapshot?.artifacts.first { $0.metadata.tasks.first?.id == "t" })
        let sourceTask = try XCTUnwrap(artifact.metadata.tasks.single())

        XCTAssertEqual(sourceTask.id, "t")
        XCTAssertEqual(sourceTask.state, .open)
        let supportedStates = await plugin.supportedTaskStates(for: sourceTask, in: artifact)
        XCTAssertTrue(supportedStates.contains(.completed))
        let updates = try await plugin.setTaskStateWithAcknowledgement(.completed, for: sourceTask, in: artifact)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2, "A task acknowledgement must not fetch the graph snapshot again.")
        XCTAssertEqual(requests.last?.method, "PATCH")
        XCTAssertEqual(requests.last?.url.path, "/api/v1/tasks/t")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(requests.last?.body)) as? [String: String], ["status": "done"])
        XCTAssertEqual(updates.map(\.taskID), ["parent", "t"])
        XCTAssertTrue(updates.allSatisfy { $0.state == .completed })
        XCTAssertTrue(updates.allSatisfy { $0.contentHash != nil })
    }

    func testPluginAdaptsEveryKontextTaskStatusWithoutRejectingTheSnapshot() async throws {
        let entities = [
            task("a-open", project: nil, status: "open"),
            task("b-in-progress", project: nil, status: "in_progress"),
            task("c-done", project: nil, status: "done"),
            task("d-cancelled", project: nil, status: "cancelled"),
        ]
        let plugin = KontextPlugin(
            connection: testConnection(),
            transport: ScriptedTransport(responses: [snapshotResponse(page: 0, total: entities.count, complete: true, entities: entities)]),
            actionOpener: RecordingOpener()
        )

        let source = try await plugin.sources().single()
        let result = try await plugin.refresh(source)
        let statesByTaskID = Dictionary(uniqueKeysWithValues: try XCTUnwrap(result.snapshot).artifacts.map { artifact in
            let task = try artifact.metadata.tasks.single()
            return (task.id, task.state)
        })

        XCTAssertEqual(statesByTaskID, [
            "a-open": .open,
            "b-in-progress": .open,
            "c-done": .completed,
            "d-cancelled": .completed,
        ])
    }

    func testSharedItemsHydrateIntoTheGraphAndRemainReadOnly() async throws {
        let entities = [
            shared(project("shr_project", title: "Shared Apollo"), permission: "edit"),
            shared(task("shr_task", title: "Shared task", project: "shr_project"), permission: "edit"),
            shared(document("shr_document", title: "Shared note", unavailable: true), permission: "read"),
        ]
        let transport = ScriptedTransport(responses: [
            snapshotResponse(page: 0, total: entities.count, complete: true, entities: entities),
        ])
        let plugin = KontextPlugin(connection: testConnection(), transport: transport, actionOpener: RecordingOpener())
        let source = try await plugin.sources().single()
        let result = try await plugin.refresh(source)
        let snapshot = try XCTUnwrap(result.snapshot)
        let projectID = PluginEntityIdentifier(source: source.id, kind: "project", externalID: "shr_project").rawValue
        let taskID = PluginEntityIdentifier(source: source.id, kind: "task", externalID: "shr_task").rawValue
        let documentID = PluginEntityIdentifier(source: source.id, kind: "document", externalID: "shr_document").rawValue
        let sharedTask = try XCTUnwrap(snapshot.artifacts.first { $0.id == taskID })
        let task = try XCTUnwrap(sharedTask.metadata.tasks.single())
        let supportedStates = await plugin.supportedTaskStates(for: task, in: sharedTask)

        XCTAssertEqual(snapshot.anchors.first { $0.id == projectID }?.kind, "shared project")
        XCTAssertEqual(snapshot.anchors.first { $0.id == projectID }?.memberArtifactIDs, [taskID])
        XCTAssertNotNil(snapshot.artifacts.first { $0.id == documentID })
        XCTAssertNil(task.mutationToken)
        XCTAssertTrue(supportedStates.isEmpty)
        XCTAssertTrue(snapshot.diagnostics.contains { $0.id.contains("kontext-unavailable") })
    }

    func testPluginRejectsSourceSwitchAndExposesOnlyWebActions() async throws {
        let initial = snapshotResponse(page: 0, total: 1, complete: true, entities: [document("d")], accountID: "account-a")
        let changed = snapshotResponse(page: 0, total: 1, complete: true, entities: [document("d")], accountID: "account-b")
        let transport = ScriptedTransport(responses: [initial, changed])
        let plugin = KontextPlugin(connection: testConnection(), transport: transport, actionOpener: RecordingOpener())
        let source = try await plugin.sources().single()
        do {
            _ = try await plugin.refresh(source)
            XCTFail("Changing opaque account IDs must require disconnect")
        } catch let error as KontextPluginError {
            XCTAssertEqual(error, .accountChanged)
        }
        let actions = plugin.artifactActions(for: .init(id: "x", relativePath: "x", mediaKind: .text, title: "x", extractedText: "", modifiedAt: .distantPast, contentHash: "x", location: .web(URL(string: "https://thekontextco.ai/library/document/d")!)))
        XCTAssertEqual(actions.map(\.kind), [.open, .copyLink])
    }

    func testConfiguredAccountRestoresOfflineWithoutRediscovery() async throws {
        let suite = "KontextPluginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = KontextSourceConfigurationStore(defaults: defaults)
        let source = PluginSourceDescriptor(
            id: .init(pluginID: KontextPlugin.identifier, sourceID: "opaque-account-id"),
            displayName: "Kontext Library",
            kind: "kontext-library"
        )
        store.save(source)
        let plugin = KontextPlugin(
            connection: testConnection(),
            transport: ScriptedTransport(responses: []),
            actionOpener: RecordingOpener(),
            sourceConfiguration: store
        )
        let restored = try await plugin.sources()
        var expected = source
        expected.presentsUnassignedArtifactsAtRoot = true
        XCTAssertEqual(restored, [expected])
        defaults.removePersistentDomain(forName: suite)
    }
}

private let revision = String(repeating: "a", count: 64)
private let date = "2026-08-17T00:00:00.000Z"

private func snapshotResponse(
    page offset: Int,
    total: Int,
    complete: Bool,
    cursor: String? = nil,
    entities: [[String: Any]],
    edges: [[String: Any]] = [],
    revision: String = revision,
    accountID: String = "opaque-account-id",
    scope: String? = "owned_and_shared"
) -> OAuthHTTPResponse {
    var page: [String: Any] = ["limit": 100, "offset": offset, "totalEntities": total, "complete": complete]
    page["nextCursor"] = complete ? NSNull() : (cursor ?? NSNull())
    var snapshot: [String: Any] = [
        "source": ["provider": "kontext", "accountId": accountID],
        "schemaVersion": 1, "revision": revision, "page": page,
        "entities": entities, "edges": edges,
    ]
    if let scope { snapshot["scope"] = scope }
    return .init(statusCode: 200, body: json([
        "ok": true, "version": 1,
        "snapshot": snapshot,
    ]))
}

private func project(_ id: String, title: String = "Project") -> [String: Any] {
    ["type": "project", "id": id, "title": title, "description": NSNull(), "stage": NSNull(), "projectType": NSNull(), "createdAt": date, "permanentLink": "https://thekontextco.ai/library/project/\(id)"]
}

private func task(_ id: String, title: String = "Task", content: String = "Task content", project: String?, status: String = "open") -> [String: Any] {
    ["type": "task", "id": id, "title": title, "content": content, "projectId": project ?? NSNull(), "status": status, "priority": "normal", "taskType": "task", "dueDate": NSNull(), "createdAt": date, "permanentLink": "https://thekontextco.ai/library/task/\(id)"]
}

private func document(_ id: String, title: String = "Document", body: String = "Document body", projects: [String] = [], truncated: Bool = false, unavailable: Bool = false, updatedAt: String = date) -> [String: Any] {
    ["type": "document", "id": id, "title": title, "body": unavailable ? NSNull() : body, "bodyTruncated": truncated, "bodyUnavailable": unavailable, "kind": "memory", "filename": NSNull(), "projectIds": projects, "createdAt": date, "updatedAt": updatedAt, "permanentLink": "https://thekontextco.ai/library/document/\(id)"]
}

private func shared(_ entity: [String: Any], permission: String) -> [String: Any] {
    var shared = entity
    let id = entity["id"] as! String
    shared["permanentLink"] = "https://thekontextco.ai/library/shared/\(id)"
    shared["access"] = ["scope": "shared", "readOnly": true, "permission": permission, "sharedBy": "Kontext user"]
    return shared
}

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private actor ScriptedTransport: KontextAPITransport {
    private var responses: [OAuthHTTPResponse]
    private var requestedRequests: [OAuthHTTPRequest] = []

    init(responses: [OAuthHTTPResponse]) { self.responses = responses }

    func execute(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        requestedRequests.append(request)
        guard !responses.isEmpty else { throw KontextPluginError.invalidResponse("unexpected request") }
        return responses.removeFirst()
    }

    func urls() -> [String] { requestedRequests.map(\.url.absoluteString) }
    func requests() -> [OAuthHTTPRequest] { requestedRequests }
}

private struct MemorySecrets: OAuthSecretStore {
    func loadSecret(for key: String) throws -> Data? { nil }
    func saveSecret(_ data: Data, for key: String) throws {}
    func removeSecret(for key: String) throws {}
}

private struct RecordingOpener: KontextArtifactActionOpening {
    func open(_ url: URL) async throws {}
    func copyLink(_ url: URL) async throws {}
}

private func testConnection() -> OAuthConnection {
    OAuthConnection(
        configuration: .init(issuer: KontextPlugin.productionOrigin, clientName: "test", redirectURI: KontextPlugin.redirectURI, scopes: ["kontext"]),
        credentials: OAuthCredentialStore(key: "kontext-tests-source", secrets: MemorySecrets())
    )
}

private extension Array {
    func single() throws -> Element {
        guard count == 1, let first else { throw KontextPluginError.invalidResponse("expected one source") }
        return first
    }
}
