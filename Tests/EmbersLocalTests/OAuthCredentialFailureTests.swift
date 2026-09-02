import Foundation
import XCTest
@testable import EmbersLocal

final class OAuthCredentialFailureTests: XCTestCase {
    func testConnectDoesNotReplaceExistingCredentialWhenSecretSaveFails() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let original = credential(accessToken: "old", expiresAt: now.addingTimeInterval(3_600))
        let secrets = FailingOAuthSecrets(credential: original, failSave: true)
        let http = CharacterizationOAuthHTTP(responses: [
            discoveryResponse(),
            .init(statusCode: 200, body: oauthJSON([
                "access_token": "new",
                "expires_in": 3_600,
                "refresh_token": "new-refresh",
            ])),
        ])
        let connection = OAuthConnection(
            configuration: configuration(),
            http: http,
            browser: SuccessfulCharacterizationBrowser(),
            credentials: OAuthCredentialStore(key: "credential", secrets: secrets),
            now: { now },
            random: { Data(repeating: 7, count: $0) }
        )

        do {
            _ = try await connection.connect()
            XCTFail("A connection must not report success when its credential was not persisted")
        } catch let error as CharacterizationSecretError {
            XCTAssertEqual(error, .saveFailed)
        }

        XCTAssertEqual(try secrets.storedCredential(), original)
        XCTAssertEqual(http.requests.map(\.url.path), ["/.well-known/oauth-authorization-server", "/token"])
    }

    func testRefreshDoesNotReplaceLastUsableCredentialWhenSecretSaveFails() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let original = credential(
            accessToken: "expired",
            expiresAt: now.addingTimeInterval(-1),
            refreshToken: "refresh"
        )
        let secrets = FailingOAuthSecrets(credential: original, failSave: true)
        let http = CharacterizationOAuthHTTP(responses: [
            .init(statusCode: 200, body: oauthJSON([
                "access_token": "new",
                "expires_in": 3_600,
            ])),
        ])
        let connection = OAuthConnection(
            configuration: configuration(),
            http: http,
            browser: SuccessfulCharacterizationBrowser(),
            credentials: OAuthCredentialStore(key: "credential", secrets: secrets),
            now: { now }
        )

        do {
            _ = try await connection.accessToken()
            XCTFail("A refreshed token must not escape when durable replacement failed")
        } catch let error as CharacterizationSecretError {
            XCTAssertEqual(error, .saveFailed)
        }

        XCTAssertEqual(try secrets.storedCredential(), original)
        XCTAssertEqual(http.requests.map(\.url.path), ["/token"])
    }

    func testDisconnectFailureLeavesCredentialAvailableForRetry() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let original = credential(accessToken: "current", expiresAt: now.addingTimeInterval(3_600))
        let secrets = FailingOAuthSecrets(credential: original, failRemove: true)
        let connection = OAuthConnection(
            configuration: configuration(),
            http: CharacterizationOAuthHTTP(responses: []),
            browser: SuccessfulCharacterizationBrowser(),
            credentials: OAuthCredentialStore(key: "credential", secrets: secrets),
            now: { now }
        )

        do {
            try await connection.disconnect()
            XCTFail("Disconnect must report a secret-store removal failure")
        } catch let error as CharacterizationSecretError {
            XCTAssertEqual(error, .removeFailed)
        }

        XCTAssertEqual(try secrets.storedCredential(), original)
    }

    func testInvalidStoredCredentialFailsBeforeAnyNetworkRequest() async throws {
        let secrets = FailingOAuthSecrets(rawValue: Data("not-json".utf8))
        let http = CharacterizationOAuthHTTP(responses: [])
        let connection = OAuthConnection(
            configuration: configuration(),
            http: http,
            browser: SuccessfulCharacterizationBrowser(),
            credentials: OAuthCredentialStore(key: "credential", secrets: secrets)
        )

        do {
            _ = try await connection.accessToken()
            XCTFail("A corrupt credential must fail closed")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .invalidStoredCredential)
        }

        XCTAssertTrue(http.requests.isEmpty)
    }

    private func configuration() -> OAuthConfiguration {
        .init(
            issuer: URL(string: "https://identity.example")!,
            clientName: "Embers test",
            scopes: ["graph.read"]
        )
    }

    private func credential(
        accessToken: String,
        expiresAt: Date,
        refreshToken: String = "refresh"
    ) -> OAuthCredential {
        OAuthCredential(
            metadata: .init(
                issuer: URL(string: "https://identity.example")!,
                authorizationEndpoint: URL(string: "https://identity.example/authorize")!,
                tokenEndpoint: URL(string: "https://identity.example/token")!
            ),
            registration: .init(clientID: "existing-client"),
            token: .init(
                accessToken: accessToken,
                expiresAt: expiresAt,
                refreshToken: refreshToken
            )
        )
    }
}

private enum CharacterizationSecretError: Error, Equatable {
    case saveFailed
    case removeFailed
}

private final class FailingOAuthSecrets: OAuthSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private let failSave: Bool
    private let failRemove: Bool

    init(credential: OAuthCredential, failSave: Bool = false, failRemove: Bool = false) {
        value = try! JSONEncoder().encode(credential)
        self.failSave = failSave
        self.failRemove = failRemove
    }

    init(rawValue: Data) {
        value = rawValue
        failSave = false
        failRemove = false
    }

    func loadSecret(for key: String) throws -> Data? {
        lock.withLock { value }
    }

    func saveSecret(_ data: Data, for key: String) throws {
        try lock.withLock {
            if failSave { throw CharacterizationSecretError.saveFailed }
            value = data
        }
    }

    func removeSecret(for key: String) throws {
        try lock.withLock {
            if failRemove { throw CharacterizationSecretError.removeFailed }
            value = nil
        }
    }

    func storedCredential() throws -> OAuthCredential? {
        try lock.withLock {
            try value.map { try JSONDecoder().decode(OAuthCredential.self, from: $0) }
        }
    }
}

private final class CharacterizationOAuthHTTP: OAuthHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [OAuthHTTPResponse]
    private var capturedRequests: [OAuthHTTPRequest] = []

    init(responses: [OAuthHTTPResponse]) {
        self.responses = responses
    }

    func execute(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        try lock.withLock {
            capturedRequests.append(request)
            guard !responses.isEmpty else {
                throw OAuthError.invalidResponse("Unexpected request")
            }
            return responses.removeFirst()
        }
    }

    var requests: [OAuthHTTPRequest] {
        lock.withLock { capturedRequests }
    }
}

private final class SuccessfulCharacterizationBrowser: OAuthBrowserSession, @unchecked Sendable {
    func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL {
        let state = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "state" }?
            .value
        return URL(string: "\(callbackScheme)://oauth/callback?code=code&state=\(state ?? "")")!
    }
}

private func discoveryResponse() -> OAuthHTTPResponse {
    .init(statusCode: 200, body: oauthJSON([
        "issuer": "https://identity.example",
        "authorization_endpoint": "https://identity.example/authorize",
        "token_endpoint": "https://identity.example/token",
    ]))
}

private func oauthJSON(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
