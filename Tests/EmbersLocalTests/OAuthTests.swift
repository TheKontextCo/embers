import Foundation
import XCTest
@testable import EmbersLocal

final class OAuthTests: XCTestCase {
    func testConnectUsesDiscoveryPublicRegistrationPKCEAndPersistsOnlyAfterExchange() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let secrets = MemorySecrets()
        let http = ScriptedHTTP(responses: [
            .init(statusCode: 200, body: json([
                "issuer": "https://identity.example",
                "authorization_endpoint": "https://identity.example/authorize",
                "token_endpoint": "https://identity.example/token",
                "registration_endpoint": "https://identity.example/register",
            ])),
            .init(statusCode: 201, body: json(["client_id": "public-client"])),
            .init(statusCode: 200, body: json([
                "access_token": "access-1",
                "token_type": "Bearer",
                "expires_in": 3600,
                "refresh_token": "refresh-1",
            ])),
        ])
        let browser = CallbackBrowser()
        let connection = OAuthConnection(
            configuration: configuration(refreshLifetime: 30 * 24 * 60 * 60),
            http: http,
            browser: browser,
            credentials: OAuthCredentialStore(key: "test.connection", secrets: secrets),
            now: { now },
            random: { count in Data(repeating: 7, count: count) }
        )

        let token = try await connection.connect()

        XCTAssertEqual(token.accessToken, "access-1")
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(token.refreshExpiresAt, now.addingTimeInterval(30 * 24 * 60 * 60))
        let credential = try await connection.storedCredential()
        XCTAssertEqual(credential?.registration.clientID, "public-client")

        let authorization = try XCTUnwrap(browser.authorizationURL)
        let queryItems = try XCTUnwrap(URLComponents(url: authorization, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["redirect_uri"], "embers://oauth/callback")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["scope"], "graph.read")
        XCTAssertEqual(query["code_challenge"], try OAuthPKCE(verifier: OAuthPKCE.base64URL(Data(repeating: 7, count: 64))).challenge)

        let requests = http.requests
        XCTAssertEqual(requests.map(\.url.path), ["/.well-known/oauth-authorization-server", "/register", "/token"])
        let registration = try XCTUnwrap(requests[1].body).jsonObject() as? [String: Any]
        XCTAssertEqual(registration?["token_endpoint_auth_method"] as? String, "none")
        XCTAssertEqual(registration?["application_type"] as? String, "native")
        XCTAssertNil(registration?["client_secret"])
        let exchange = form(try XCTUnwrap(requests[2].body))
        XCTAssertEqual(exchange["grant_type"], "authorization_code")
        XCTAssertEqual(exchange["code_verifier"], OAuthPKCE.base64URL(Data(repeating: 7, count: 64)))
        XCTAssertEqual(exchange["client_id"], "public-client")
    }

    func testRefreshPreservesStoredAbsoluteRefreshExpiryWhenServerDoesNotReplaceIt() async throws {
        let initial = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 1_100)
        let clock = TestClock(initial)
        let metadata = OAuthAuthorizationServerMetadata(
            issuer: URL(string: "https://identity.example")!,
            authorizationEndpoint: URL(string: "https://identity.example/authorize")!,
            tokenEndpoint: URL(string: "https://identity.example/token")!,
            registrationEndpoint: nil
        )
        let refreshExpiry = initial.addingTimeInterval(2_592_000)
        let secrets = MemorySecrets()
        let store = OAuthCredentialStore(key: "test.refresh", secrets: secrets)
        try store.save(.init(metadata: metadata, registration: .init(clientID: "client"), token: .init(accessToken: "old", expiresAt: initial.addingTimeInterval(10), refreshToken: "refresh", refreshExpiresAt: refreshExpiry)))
        let http = ScriptedHTTP(responses: [.init(statusCode: 200, body: json([
            "access_token": "new",
            "expires_in": 3600,
        ]))])
        let connection = OAuthConnection(configuration: configuration(), http: http, browser: CallbackBrowser(), credentials: store, now: { clock.value })

        clock.value = later
        let token = try await connection.accessToken()

        XCTAssertEqual(token.accessToken, "new")
        XCTAssertEqual(token.refreshToken, "refresh")
        XCTAssertEqual(token.refreshExpiresAt, refreshExpiry)
        XCTAssertEqual(form(try XCTUnwrap(http.requests.first?.body))["grant_type"], "refresh_token")
    }

    func testAuthorizedRequestRefreshesAndRetriesExactlyOnceAfter401() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let metadata = OAuthAuthorizationServerMetadata(
            issuer: URL(string: "https://identity.example")!,
            authorizationEndpoint: URL(string: "https://identity.example/authorize")!,
            tokenEndpoint: URL(string: "https://identity.example/token")!,
            registrationEndpoint: nil
        )
        let secrets = MemorySecrets()
        let store = OAuthCredentialStore(key: "test.401", secrets: secrets)
        try store.save(.init(metadata: metadata, registration: .init(clientID: "client"), token: .init(accessToken: "old", expiresAt: now.addingTimeInterval(3600), refreshToken: "refresh", refreshExpiresAt: now.addingTimeInterval(3600))))
        let http = ScriptedHTTP(responses: [
            .init(statusCode: 401),
            .init(statusCode: 200, body: json(["access_token": "new", "expires_in": 3600])),
            .init(statusCode: 200, body: Data("ok".utf8)),
        ])
        let connection = OAuthConnection(configuration: configuration(), http: http, browser: CallbackBrowser(), credentials: store, now: { now })

        let response = try await connection.authorizedRequest(.init(url: URL(string: "https://api.example/resource")!))

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(http.requests.map(\.url.path), ["/resource", "/token", "/resource"])
        XCTAssertEqual(http.requests[0].headers["Authorization"], "Bearer old")
        XCTAssertEqual(http.requests[2].headers["Authorization"], "Bearer new")
    }

    func testExpiredRefreshCredentialFailsWithoutCallingTheNetwork() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let metadata = OAuthAuthorizationServerMetadata(
            issuer: URL(string: "https://identity.example")!,
            authorizationEndpoint: URL(string: "https://identity.example/authorize")!,
            tokenEndpoint: URL(string: "https://identity.example/token")!,
            registrationEndpoint: nil
        )
        let secrets = MemorySecrets()
        let store = OAuthCredentialStore(key: "test.expired", secrets: secrets)
        try store.save(.init(metadata: metadata, registration: .init(clientID: "client"), token: .init(accessToken: "old", expiresAt: now.addingTimeInterval(-1), refreshToken: "refresh", refreshExpiresAt: now.addingTimeInterval(-1))))
        let http = ScriptedHTTP(responses: [])
        let connection = OAuthConnection(configuration: configuration(), http: http, browser: CallbackBrowser(), credentials: store, now: { now })

        do {
            _ = try await connection.accessToken()
            XCTFail("Expected refresh expiry")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .refreshExpired)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testCancellationLeavesExistingCredentialUntouched() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let metadata = OAuthAuthorizationServerMetadata(
            issuer: URL(string: "https://identity.example")!,
            authorizationEndpoint: URL(string: "https://identity.example/authorize")!,
            tokenEndpoint: URL(string: "https://identity.example/token")!,
            registrationEndpoint: URL(string: "https://identity.example/register")!
        )
        let original = OAuthCredential(metadata: metadata, registration: .init(clientID: "existing"), token: .init(accessToken: "old", expiresAt: now.addingTimeInterval(3600), refreshToken: "refresh"))
        let secrets = MemorySecrets()
        let store = OAuthCredentialStore(key: "test.cancel", secrets: secrets)
        try store.save(original)
        let http = ScriptedHTTP(responses: [.init(statusCode: 200, body: json([
            "issuer": "https://identity.example",
            "authorization_endpoint": "https://identity.example/authorize",
            "token_endpoint": "https://identity.example/token",
            "registration_endpoint": "https://identity.example/register",
        ]))])
        let connection = OAuthConnection(configuration: configuration(), http: http, browser: CancellingBrowser(), credentials: store, now: { now })

        do {
            _ = try await connection.connect()
            XCTFail("Expected cancellation")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .cancelled)
        }
        let preserved = try await connection.storedCredential()
        XCTAssertEqual(preserved, original)
        XCTAssertEqual(http.requests.count, 1)
    }

    func testDiscoveryPlacesWellKnownPathBeforeIssuerPath() {
        XCTAssertEqual(
            OAuthConnection.discoveryURL(for: URL(string: "https://identity.example/tenant/a")!),
            URL(string: "https://identity.example/.well-known/oauth-authorization-server/tenant/a")!
        )
    }

    func testDiscoveryRejectsAnInsecureDynamicRegistrationEndpoint() async throws {
        let http = ScriptedHTTP(responses: [.init(statusCode: 200, body: json([
            "issuer": "https://identity.example",
            "authorization_endpoint": "https://identity.example/authorize",
            "token_endpoint": "https://identity.example/token",
            "registration_endpoint": "http://identity.example/register",
        ]))])
        let connection = OAuthConnection(
            configuration: configuration(),
            http: http,
            browser: CallbackBrowser(),
            credentials: OAuthCredentialStore(key: "test.insecure-registration", secrets: MemorySecrets())
        )

        do {
            _ = try await connection.discover()
            XCTFail("Dynamic registration must not disclose app metadata over HTTP")
        } catch let error as OAuthError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected error \(error)") }
        }
        XCTAssertEqual(http.requests.count, 1)
    }

    private func configuration(refreshLifetime: TimeInterval? = nil) -> OAuthConfiguration {
        .init(issuer: URL(string: "https://identity.example")!, clientName: "Embers test", scopes: ["graph.read"], refreshTokenLifetime: refreshLifetime)
    }
}

private final class MemorySecrets: OAuthSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func loadSecret(for key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func saveSecret(_ data: Data, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }

    func removeSecret(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

private final class ScriptedHTTP: OAuthHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var scriptedResponses: [OAuthHTTPResponse]
    private var capturedRequests: [OAuthHTTPRequest] = []

    init(responses: [OAuthHTTPResponse]) { scriptedResponses = responses }

    func execute(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        try lock.withLock {
            capturedRequests.append(request)
            guard !scriptedResponses.isEmpty else { throw OAuthError.invalidResponse("Unexpected HTTP request") }
            return scriptedResponses.removeFirst()
        }
    }

    var requests: [OAuthHTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests
    }
}

private final class CallbackBrowser: OAuthBrowserSession, @unchecked Sendable {
    private(set) var authorizationURL: URL?

    func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL {
        self.authorizationURL = authorizationURL
        let state = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value)
        return URL(string: "\(callbackScheme)://oauth/callback?code=code-1&state=\(state)")!
    }
}

private struct CancellingBrowser: OAuthBrowserSession {
    func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL {
        throw OAuthError.cancelled
    }
}

private final class TestClock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func form(_ data: Data) -> [String: String] {
    let components = URLComponents(string: "https://example.invalid/?\(String(decoding: data, as: UTF8.self))")
    return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private extension Data {
    func jsonObject() -> Any? { try? JSONSerialization.jsonObject(with: self) }
}
