import Foundation
import XCTest
@testable import EmbersLocal
@testable import EmbersPluginKit
@testable import KontextPlugin

final class KontextBoundaryCharacterizationTests: XCTestCase {
    func testSnapshotRestartBudgetFailsClosedWithoutReturningPartialContent() async throws {
        let restart = OAuthHTTPResponse(
            statusCode: 409,
            body: kontextBoundaryJSON([
                "ok": false,
                "version": 1,
                "restart": true,
                "error": ["code": "snapshot_changed"],
            ])
        )
        let transport = RestartingKontextTransport(responses: [restart, restart])
        let client = KontextGraphSnapshotClient(
            transport: transport,
            origin: KontextPlugin.productionOrigin,
            maximumRestarts: 1
        )

        do {
            _ = try await client.fetch()
            XCTFail("Repeated snapshot changes must not return a partial graph")
        } catch let error as KontextPluginError {
            XCTAssertEqual(error, .snapshotChangedTooOften)
        }

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { !$0.url.absoluteString.contains("cursor=") })
    }

    func testOfflineDisconnectClearsCredentialAndRestoredSourceIdentity() async throws {
        let suiteName = "KontextBoundaryCharacterizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = KontextSourceConfigurationStore(defaults: defaults)
        let source = PluginSourceDescriptor(
            id: .init(pluginID: KontextPlugin.identifier, sourceID: "account"),
            displayName: "Kontext Library",
            kind: "kontext-library"
        )
        configuration.save(source)

        let secrets = DisconnectSecrets(credential: oauthCredential())
        let connection = OAuthConnection(
            configuration: .init(
                issuer: KontextPlugin.productionOrigin,
                clientName: "test",
                redirectURI: KontextPlugin.redirectURI,
                scopes: ["kontext"]
            ),
            http: OfflineOAuthHTTP(),
            credentials: OAuthCredentialStore(key: "kontext", secrets: secrets)
        )
        let emptyTransport = RestartingKontextTransport(responses: [])
        let plugin = KontextPlugin(
            connection: connection,
            transport: emptyTransport,
            actionOpener: NoopKontextOpener(),
            sourceConfiguration: configuration
        )

        let restoredSourceIDs = try await plugin.sources().map(\.id)
        XCTAssertEqual(restoredSourceIDs, [source.id])
        try await plugin.disconnect()

        let storedCredential = try await connection.storedCredential()
        XCTAssertNil(storedCredential)
        XCTAssertNil(configuration.load())
        let connectionState = await plugin.connectionStatus().state
        XCTAssertEqual(connectionState, .requiresAuthentication)
        do {
            _ = try await plugin.sources()
            XCTFail("A disconnected plugin must not resurrect the former source while offline")
        } catch {
            let requestCount = await emptyTransport.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }
}

private actor RestartingKontextTransport: KontextAPITransport {
    private var responses: [OAuthHTTPResponse]
    private var capturedRequests: [OAuthHTTPRequest] = []

    init(responses: [OAuthHTTPResponse]) {
        self.responses = responses
    }

    func execute(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        capturedRequests.append(request)
        guard !responses.isEmpty else {
            throw KontextPluginError.invalidResponse("offline")
        }
        return responses.removeFirst()
    }

    func requests() -> [OAuthHTTPRequest] { capturedRequests }
    func requestCount() -> Int { capturedRequests.count }
}

private struct OfflineOAuthHTTP: OAuthHTTPClient {
    func execute(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

private final class DisconnectSecrets: OAuthSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    init(credential: OAuthCredential) {
        value = try! JSONEncoder().encode(credential)
    }

    func loadSecret(for key: String) throws -> Data? {
        lock.withLock { value }
    }

    func saveSecret(_ data: Data, for key: String) throws {
        lock.withLock { value = data }
    }

    func removeSecret(for key: String) throws {
        lock.withLock { value = nil }
    }
}

private struct NoopKontextOpener: KontextArtifactActionOpening {
    func open(_ url: URL) async throws {}
    func copyLink(_ url: URL) async throws {}
}

private func oauthCredential() -> OAuthCredential {
    OAuthCredential(
        metadata: .init(
            issuer: KontextPlugin.productionOrigin,
            authorizationEndpoint: KontextPlugin.productionOrigin.appendingPathComponent("oauth/authorize"),
            tokenEndpoint: KontextPlugin.productionOrigin.appendingPathComponent("oauth/token")
        ),
        registration: .init(clientID: "client"),
        token: .init(
            accessToken: "access",
            expiresAt: Date().addingTimeInterval(3_600),
            refreshToken: "refresh"
        )
    )
}

private func kontextBoundaryJSON(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
