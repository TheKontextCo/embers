import AppKit
import Foundation

/// Opens authorization as a normal web URL, using the user's default browser.
/// The app delegate delivers its registered callback URLs to this same instance.
@MainActor
public final class DefaultBrowserOAuthSession: OAuthBrowserSession {
    private struct Pending {
        let id: UUID
        let redirect: URL
        let state: String
        let continuation: CheckedContinuation<URL, Error>
    }

    private let openURL: @MainActor (URL) -> Bool
    private let prepareCallback: @MainActor (String) async throws -> Void
    private let timeout: Duration
    private var pending: Pending?
    private var timeoutTask: Task<Void, Never>?

    public init(timeout: Duration = .seconds(300),
                prepareCallback: @escaping @MainActor (String) async throws -> Void = { _ in },
                openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.timeout = timeout
        self.prepareCallback = prepareCallback
        self.openURL = openURL
    }

    public func authenticate(at authorizationURL: URL, callbackScheme: String) async throws -> URL {
        guard !Task.isCancelled else { throw OAuthError.cancelled }
        guard authorizationURL.scheme?.lowercased() == "https",
              let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false),
              let query = Self.uniqueQuery(components),
              let state = query["state"], !state.isEmpty,
              let rawRedirect = query["redirect_uri"], let redirect = URL(string: rawRedirect),
              redirect.scheme?.lowercased() == callbackScheme.lowercased() else {
            throw OAuthError.invalidConfiguration("Authorization requires an HTTPS URL, state, and matching redirect URI.")
        }
        try await prepareCallback(callbackScheme)
        guard !Task.isCancelled else { throw OAuthError.cancelled }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: OAuthError.cancelled)
                    return
                }
                cancel()
                pending = .init(id: id, redirect: redirect, state: state, continuation: continuation)
                timeoutTask = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.finish(id: id, result: .failure(OAuthError.authorizationTimedOut))
                }
                // Do not select an application or invoke ASWebAuthenticationSession:
                // normal URL dispatch honors the default browser even if it does not
                // implement Apple's authentication-session browser integration.
                if !openURL(authorizationURL) {
                    finish(id: id, result: .failure(OAuthError.browserUnavailable))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: id, result: .failure(OAuthError.cancelled))
            }
        }
    }

    /// Ignore unsolicited, stale, malformed, and mismatched callbacks. PKCE and
    /// token exchange remain owned by OAuthConnection after this correlation check.
    @discardableResult
    public func handleCallback(_ url: URL) -> Bool {
        guard let pending,
              url.scheme?.lowercased() == pending.redirect.scheme?.lowercased(),
              url.host?.lowercased() == pending.redirect.host?.lowercased(),
              url.port == pending.redirect.port, url.path == pending.redirect.path,
              url.user == pending.redirect.user, url.password == pending.redirect.password,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = Self.uniqueQuery(components), query["state"] == pending.state,
              (query["code"]?.isEmpty == false) != (query["error"]?.isEmpty == false) else { return false }
        finish(id: pending.id, result: .success(url))
        return true
    }

    public func cancel() {
        guard let pending else { return }
        finish(id: pending.id, result: .failure(OAuthError.cancelled))
    }

    private func finish(id: UUID, result: Result<URL, Error>) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        current.continuation.resume(with: result)
    }

    private static func uniqueQuery(_ components: URLComponents) -> [String: String]? {
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else { return nil }
            values[item.name] = item.value ?? ""
        }
        return values
    }
}
