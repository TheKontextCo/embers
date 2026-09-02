import AuthenticationServices
import AppKit
import CryptoKit
import Foundation
import Security

/// The narrow transport boundary used by connected-source authentication.
///
/// Embers never makes a network request unless a connected plugin explicitly invokes this API.
public protocol OAuthHTTPClient: Sendable {
    func execute(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse
}

public struct OAuthHTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct OAuthHTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public struct URLSessionOAuthHTTPClient: OAuthHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        request.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse("OAuth server returned a non-HTTP response.")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }
        return OAuthHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

/// The browser boundary is injectable so authorization flows can be tested deterministically.
public protocol OAuthBrowserSession: Sendable {
    func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL
}

/// Uses the shared system browser session. It deliberately does not use an ephemeral session so a
/// person's existing SSO session can be reused after their single explicit consent.
public final class SystemOAuthBrowserSession: NSObject, OAuthBrowserSession, @unchecked Sendable {
    private let lock = NSLock()
    private var activeSession: ASWebAuthenticationSession?
    private var presentationContext: OAuthPresentationContextProvider?

    public override init() {}

    public func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL {
        if Task.isCancelled { throw OAuthError.cancelled }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume(throwing: OAuthError.cancelled)
                        return
                    }
                    if Task.isCancelled {
                        continuation.resume(throwing: OAuthError.cancelled)
                        return
                    }
                    var session: ASWebAuthenticationSession?
                    session = ASWebAuthenticationSession(
                        url: authorizationURL,
                        callbackURLScheme: callbackScheme
                    ) { [weak self] callbackURL, error in
                        self?.clear(session: session)
                        if let callbackURL {
                            continuation.resume(returning: callbackURL)
                        } else if let error = error as? ASWebAuthenticationSessionError,
                                  error.code == .canceledLogin {
                            continuation.resume(throwing: OAuthError.cancelled)
                        } else {
                            continuation.resume(throwing: error ?? OAuthError.invalidCallback)
                        }
                    }
                    guard let session else {
                        continuation.resume(throwing: OAuthError.browserUnavailable)
                        return
                    }
                    let presentationContext = OAuthPresentationContextProvider()
                    session.presentationContextProvider = presentationContext
                    session.prefersEphemeralWebBrowserSession = false
                    self.replaceActiveSession(with: session, presentationContext: presentationContext)
                    guard session.start() else {
                        self.clear(session: session)
                        continuation.resume(throwing: OAuthError.browserUnavailable)
                        return
                    }
                }
            }
        }, onCancel: { [weak self] in
            self?.cancelActiveSession()
        })
    }

    private func replaceActiveSession(
        with session: ASWebAuthenticationSession,
        presentationContext: OAuthPresentationContextProvider
    ) {
        lock.lock()
        let previousSession = activeSession
        activeSession = session
        self.presentationContext = presentationContext
        lock.unlock()

        // ASWebAuthenticationSession may invoke its completion synchronously from cancel().
        // That completion calls clear(session:), so cancellation must never happen under lock.
        if previousSession !== session {
            Task { @MainActor in previousSession?.cancel() }
        }
    }

    private func clear(session: ASWebAuthenticationSession?) {
        lock.lock()
        if session == nil || activeSession === session {
            activeSession = nil
            presentationContext = nil
        }
        lock.unlock()
    }

    private func cancelActiveSession() {
        lock.lock()
        let session = activeSession
        activeSession = nil
        presentationContext = nil
        lock.unlock()
        Task { @MainActor in session?.cancel() }
    }
}

@MainActor
private final class OAuthPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private lazy var fallbackAnchor = ASPresentationAnchor()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
            ?? fallbackAnchor
    }
}

/// A minimal secret primitive. Values are intentionally opaque to keep credentials out of
/// preferences, snapshots, and plugin configuration.
public protocol OAuthSecretStore: Sendable {
    func loadSecret(for key: String) throws -> Data?
    func saveSecret(_ data: Data, for key: String) throws
    func removeSecret(for key: String) throws
}

public enum OAuthSecretStoreError: Error, LocalizedError, Sendable {
    case keychainFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychainFailure(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Keychain error"
            return "Keychain failed (\(status)): \(message)"
        }
    }
}

/// Production credential storage. Each plugin chooses an opaque account key; no content graph
/// data is written to Keychain.
public struct KeychainOAuthSecretStore: OAuthSecretStore {
    public let service: String

    public init(service: String = Bundle.main.bundleIdentifier ?? "com.embers.app") {
        self.service = service
    }

    public func loadSecret(for key: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw OAuthSecretStoreError.keychainFailure(status)
        }
        return data
    }

    public func saveSecret(_ data: Data, for key: String) throws {
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let update: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw OAuthSecretStoreError.keychainFailure(updateStatus)
        }
        var create = identity
        create[kSecValueData] = data
        create[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let createStatus = SecItemAdd(create as CFDictionary, nil)
        guard createStatus == errSecSuccess else {
            throw OAuthSecretStoreError.keychainFailure(createStatus)
        }
    }

    public func removeSecret(for key: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OAuthSecretStoreError.keychainFailure(status)
        }
    }
}

public struct OAuthCredentialStore: Sendable {
    private let secrets: any OAuthSecretStore
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(key: String, secrets: any OAuthSecretStore) {
        self.key = key
        self.secrets = secrets
    }

    public func load() throws -> OAuthCredential? {
        guard let data = try secrets.loadSecret(for: key) else { return nil }
        do { return try decoder.decode(OAuthCredential.self, from: data) }
        catch { throw OAuthError.invalidStoredCredential }
    }

    public func save(_ credential: OAuthCredential) throws {
        try secrets.saveSecret(encoder.encode(credential), for: key)
    }

    public func remove() throws {
        try secrets.removeSecret(for: key)
    }
}

public struct OAuthConfiguration: Sendable {
    public var issuer: URL
    public var clientName: String
    public var redirectURI: URL
    public var scopes: [String]
    /// Used only when an authorization server does not return an absolute refresh expiry.
    public var refreshTokenLifetime: TimeInterval?

    public init(
        issuer: URL,
        clientName: String,
        redirectURI: URL = URL(string: "embers://oauth/callback")!,
        scopes: [String],
        refreshTokenLifetime: TimeInterval? = nil
    ) {
        self.issuer = issuer
        self.clientName = clientName
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.refreshTokenLifetime = refreshTokenLifetime
    }
}

public struct OAuthAuthorizationServerMetadata: Codable, Sendable, Equatable {
    public var issuer: URL
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
    }

    public init(issuer: URL, authorizationEndpoint: URL, tokenEndpoint: URL, registrationEndpoint: URL? = nil) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
    }
}

public struct OAuthClientRegistration: Codable, Sendable, Equatable {
    public var clientID: String
    public var issuedAt: Date?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case issuedAt = "client_id_issued_at"
    }

    public init(clientID: String, issuedAt: Date? = nil) {
        self.clientID = clientID
        self.issuedAt = issuedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try values.decode(String.self, forKey: .clientID)
        if let seconds = try values.decodeIfPresent(Double.self, forKey: .issuedAt) {
            issuedAt = Date(timeIntervalSince1970: seconds)
        } else {
            issuedAt = nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(clientID, forKey: .clientID)
        try values.encodeIfPresent(issuedAt?.timeIntervalSince1970, forKey: .issuedAt)
    }
}

public struct OAuthToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var tokenType: String
    public var scope: String?
    public var expiresAt: Date
    public var refreshToken: String?
    /// Stored as an absolute instant; never infer a fresh lifetime during a later refresh.
    public var refreshExpiresAt: Date?

    public init(accessToken: String, tokenType: String = "Bearer", scope: String? = nil, expiresAt: Date, refreshToken: String? = nil, refreshExpiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.refreshExpiresAt = refreshExpiresAt
    }

    public func accessIsValid(at date: Date, leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(date) > leeway
    }

    public func refreshIsValid(at date: Date) -> Bool {
        guard refreshToken != nil else { return false }
        return refreshExpiresAt.map { $0 > date } ?? true
    }
}

public struct OAuthCredential: Codable, Sendable, Equatable {
    public var metadata: OAuthAuthorizationServerMetadata
    public var registration: OAuthClientRegistration
    public var token: OAuthToken

    public init(metadata: OAuthAuthorizationServerMetadata, registration: OAuthClientRegistration, token: OAuthToken) {
        self.metadata = metadata
        self.registration = registration
        self.token = token
    }
}

public struct OAuthPKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) throws {
        guard verifier.count >= 43, verifier.count <= 128,
              verifier.unicodeScalars.allSatisfy({ Self.allowedVerifierCharacters.contains($0) }) else {
            throw OAuthError.invalidPKCEVerifier
        }
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func make(random: @Sendable (Int) throws -> Data) throws -> OAuthPKCE {
        let data = try random(64)
        return try OAuthPKCE(verifier: Self.base64URL(data))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static let allowedVerifierCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

public enum OAuthError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case invalidCallback
    case authorizationDenied(String?)
    case stateMismatch
    case cancelled
    case browserUnavailable
    case authorizationTimedOut
    case invalidPKCEVerifier
    case missingCredential
    case refreshExpired
    case invalidStoredCredential
    case httpStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail), .invalidResponse(let detail): return detail
        case .invalidCallback: return "The authorization callback was invalid."
        case .authorizationDenied(let detail): return detail ?? "Authorization was denied."
        case .stateMismatch: return "The authorization callback did not match this sign-in attempt."
        case .cancelled: return "Authorization was cancelled."
        case .browserUnavailable: return "The system browser could not start authorization."
        case .authorizationTimedOut: return "Sign-in timed out. Please connect again."
        case .invalidPKCEVerifier: return "The PKCE verifier was invalid."
        case .missingCredential: return "No connected account is available."
        case .refreshExpired: return "The connection has expired. Connect again to continue."
        case .invalidStoredCredential: return "The saved connection could not be read. Connect again to continue."
        case .httpStatus(let status, let detail): return "OAuth server returned HTTP \(status): \(detail)"
        }
    }
}

/// OAuth 2.1 authorization-code coordinator for a single connected account.
///
/// The actor serializes credential replacement. It keeps only opaque credential material in the
/// injected secret store, while discovery and registration are cached within that credential.
public actor OAuthConnection {
    private let configuration: OAuthConfiguration
    private let http: any OAuthHTTPClient
    private let browser: any OAuthBrowserSession
    private let credentials: OAuthCredentialStore
    private let now: @Sendable () -> Date
    private let random: @Sendable (Int) throws -> Data

    public init(
        configuration: OAuthConfiguration,
        http: any OAuthHTTPClient = URLSessionOAuthHTTPClient(),
        browser: any OAuthBrowserSession = SystemOAuthBrowserSession(),
        credentials: OAuthCredentialStore,
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable (Int) throws -> Data = { try OAuthConnection.secureRandom($0) }
    ) {
        self.configuration = configuration
        self.http = http
        self.browser = browser
        self.credentials = credentials
        self.now = now
        self.random = random
    }

    /// Performs browser authorization and saves the resulting credential only after a successful
    /// code exchange. Cancelling leaves any existing connection untouched.
    @discardableResult
    public func connect() async throws -> OAuthToken {
        try validateConfiguration()
        let metadata = try await discover()
        let existing = try credentials.load()
        let registration: OAuthClientRegistration
        if let existing, existing.metadata.issuer == metadata.issuer {
            registration = existing.registration
        } else {
            registration = try await register(with: metadata)
        }
        let pkce = try OAuthPKCE.make(random: random)
        let state = OAuthPKCE.base64URL(try random(32))
        let authorizationURL = try authorizationURL(metadata: metadata, clientID: registration.clientID, pkce: pkce, state: state)
        let callback = try await browser.authenticate(at: authorizationURL, callbackScheme: configuration.redirectURI.scheme ?? "embers")
        let code = try authorizationCode(from: callback, expectedState: state)
        let token = try await exchangeCode(code, pkce: pkce, registration: registration, metadata: metadata)
        try credentials.save(OAuthCredential(metadata: metadata, registration: registration, token: token))
        return token
    }

    public func disconnect() throws {
        try credentials.remove()
    }

    public func storedCredential() throws -> OAuthCredential? {
        try credentials.load()
    }

    /// Gets a usable token, refreshing before it becomes stale. If a refresh credential has an
    /// absolute expiry, it is checked before any network request.
    public func accessToken() async throws -> OAuthToken {
        let credential = try credentials.load()
        guard let credential else { throw OAuthError.missingCredential }
        if credential.token.accessIsValid(at: now()) { return credential.token }
        return try await refresh(credential)
    }

    /// Sends a bearer request and performs exactly one refresh-and-retry when the provider returns
    /// 401. Plugins can use this as their standard recovery primitive.
    public func authorizedRequest(_ request: OAuthHTTPRequest) async throws -> OAuthHTTPResponse {
        let firstToken = try await accessToken()
        let first = try await http.execute(bearerRequest(request, token: firstToken.accessToken))
        guard first.statusCode == 401 else { return first }
        let credential = try credentials.load()
        guard let credential else { throw OAuthError.missingCredential }
        let refreshed = try await refresh(credential, force: true)
        return try await http.execute(bearerRequest(request, token: refreshed.accessToken))
    }

    public func discover() async throws -> OAuthAuthorizationServerMetadata {
        try validateConfiguration()
        let response = try await http.execute(OAuthHTTPRequest(url: Self.discoveryURL(for: configuration.issuer)))
        try requireSuccess(response)
        let metadata: OAuthAuthorizationServerMetadata
        do { metadata = try JSONDecoder().decode(OAuthAuthorizationServerMetadata.self, from: response.body) }
        catch { throw OAuthError.invalidResponse("Authorization-server discovery was not valid JSON: \(error.localizedDescription)") }
        guard Self.normalizedIssuer(metadata.issuer) == Self.normalizedIssuer(configuration.issuer) else {
            throw OAuthError.invalidResponse("Authorization-server discovery returned a different issuer.")
        }
        guard metadata.authorizationEndpoint.scheme?.lowercased() == "https",
              metadata.tokenEndpoint.scheme?.lowercased() == "https",
              metadata.registrationEndpoint.map({ $0.scheme?.lowercased() == "https" }) ?? true else {
            throw OAuthError.invalidResponse("Authorization-server endpoints must use HTTPS.")
        }
        return metadata
    }

    private func register(with metadata: OAuthAuthorizationServerMetadata) async throws -> OAuthClientRegistration {
        guard let endpoint = metadata.registrationEndpoint else {
            throw OAuthError.invalidResponse("Authorization server does not support public dynamic client registration.")
        }
        let payload: [String: Any] = [
            "client_name": configuration.clientName,
            "application_type": "native",
            "redirect_uris": [configuration.redirectURI.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let response = try await http.execute(OAuthHTTPRequest(url: endpoint, method: "POST", headers: ["Content-Type": "application/json", "Accept": "application/json"], body: body))
        try requireSuccess(response)
        do { return try JSONDecoder().decode(OAuthClientRegistration.self, from: response.body) }
        catch { throw OAuthError.invalidResponse("Dynamic client registration did not return a client_id.") }
    }

    private func exchangeCode(_ code: String, pkce: OAuthPKCE, registration: OAuthClientRegistration, metadata: OAuthAuthorizationServerMetadata) async throws -> OAuthToken {
        let response = try await tokenRequest(metadata: metadata, parameters: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "client_id": registration.clientID,
            "code_verifier": pkce.verifier,
        ])
        return try decodeToken(response, prior: nil)
    }

    private func refresh(_ credential: OAuthCredential, force: Bool = false) async throws -> OAuthToken {
        if !force, credential.token.accessIsValid(at: now()) { return credential.token }
        guard credential.token.refreshIsValid(at: now()), let refreshToken = credential.token.refreshToken else {
            throw OAuthError.refreshExpired
        }
        let response = try await tokenRequest(metadata: credential.metadata, parameters: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": credential.registration.clientID,
        ])
        let token = try decodeToken(response, prior: credential.token)
        try credentials.save(OAuthCredential(metadata: credential.metadata, registration: credential.registration, token: token))
        return token
    }

    private func tokenRequest(metadata: OAuthAuthorizationServerMetadata, parameters: [String: String]) async throws -> OAuthHTTPResponse {
        let response = try await http.execute(OAuthHTTPRequest(
            url: metadata.tokenEndpoint,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
            body: Self.formEncoded(parameters)
        ))
        try requireSuccess(response)
        return response
    }

    private func decodeToken(_ response: OAuthHTTPResponse, prior: OAuthToken?) throws -> OAuthToken {
        let payload: TokenPayload
        do { payload = try JSONDecoder().decode(TokenPayload.self, from: response.body) }
        catch { throw OAuthError.invalidResponse("Token endpoint did not return a valid access token.") }
        guard !payload.accessToken.isEmpty, payload.expiresIn > 0 else {
            throw OAuthError.invalidResponse("Token endpoint omitted access_token or expires_in.")
        }
        let issuedAt = now()
        let refreshExpiry: Date?
        if let explicit = payload.refreshExpiresAt {
            refreshExpiry = explicit
        } else if let duration = payload.refreshExpiresIn {
            refreshExpiry = issuedAt.addingTimeInterval(duration)
        } else if prior != nil {
            refreshExpiry = prior?.refreshExpiresAt
        } else {
            refreshExpiry = configuration.refreshTokenLifetime.map { issuedAt.addingTimeInterval($0) }
        }
        return OAuthToken(
            accessToken: payload.accessToken,
            tokenType: payload.tokenType ?? "Bearer",
            scope: payload.scope,
            expiresAt: issuedAt.addingTimeInterval(payload.expiresIn),
            refreshToken: payload.refreshToken ?? prior?.refreshToken,
            refreshExpiresAt: refreshExpiry
        )
    }

    private func authorizationURL(metadata: OAuthAuthorizationServerMetadata, clientID: String, pkce: OAuthPKCE, state: String) throws -> URL {
        guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidConfiguration("Authorization endpoint is invalid.")
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.sorted().joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components.url else { throw OAuthError.invalidConfiguration("Authorization request could not be constructed.") }
        return url
    }

    private func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard callback.scheme?.lowercased() == configuration.redirectURI.scheme?.lowercased(),
              callback.host?.lowercased() == configuration.redirectURI.host?.lowercased(),
              callback.path == configuration.redirectURI.path,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidCallback
        }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let denied = values["error"] { throw OAuthError.authorizationDenied(values["error_description"] ?? denied) }
        guard values["state"] == expectedState else { throw OAuthError.stateMismatch }
        guard let code = values["code"], !code.isEmpty else { throw OAuthError.invalidCallback }
        return code
    }

    private func bearerRequest(_ request: OAuthHTTPRequest, token: String) -> OAuthHTTPRequest {
        var request = request
        request.headers["Authorization"] = "Bearer \(token)"
        return request
    }

    private func requireSuccess(_ response: OAuthHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            let detail = String(data: response.body, encoding: .utf8).map { String($0.prefix(500)) } ?? "no response body"
            throw OAuthError.httpStatus(response.statusCode, detail)
        }
    }

    private func validateConfiguration() throws {
        guard configuration.issuer.scheme?.lowercased() == "https", configuration.issuer.host != nil else {
            throw OAuthError.invalidConfiguration("OAuth issuer must be an HTTPS URL.")
        }
        guard configuration.redirectURI.scheme?.lowercased() == "embers" else {
            throw OAuthError.invalidConfiguration("OAuth redirect URI must use the embers callback scheme.")
        }
        guard !configuration.clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.scopes.isEmpty else {
            throw OAuthError.invalidConfiguration("OAuth client name and at least one scope are required.")
        }
    }

    public static func discoveryURL(for issuer: URL) -> URL {
        var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        let issuerPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/.well-known/oauth-authorization-server" + (issuerPath.isEmpty ? "" : "/\(issuerPath)")
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    private static func normalizedIssuer(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.query = nil
        components.fragment = nil
        return components.url!
    }

    private static func formEncoded(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.keys.sorted().map { URLQueryItem(name: $0, value: values[$0]) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    public static func secureRandom(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw OAuthSecretStoreError.keychainFailure(status) }
        return Data(bytes)
    }
}

private struct TokenPayload: Decodable {
    var accessToken: String
    var tokenType: String?
    var scope: String?
    var expiresIn: TimeInterval
    var refreshToken: String?
    var refreshExpiresIn: TimeInterval?
    var refreshExpiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshExpiresIn = "refresh_expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case refreshExpiresAt = "refresh_expires_at"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        tokenType = try values.decodeIfPresent(String.self, forKey: .tokenType)
        scope = try values.decodeIfPresent(String.self, forKey: .scope)
        expiresIn = try values.decode(TimeInterval.self, forKey: .expiresIn)
        refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshToken)
        refreshExpiresIn = try values.decodeIfPresent(TimeInterval.self, forKey: .refreshExpiresIn)
            ?? values.decodeIfPresent(TimeInterval.self, forKey: .refreshTokenExpiresIn)
        if let epoch = try values.decodeIfPresent(TimeInterval.self, forKey: .refreshExpiresAt) {
            refreshExpiresAt = Date(timeIntervalSince1970: epoch)
        } else {
            refreshExpiresAt = nil
        }
    }
}
