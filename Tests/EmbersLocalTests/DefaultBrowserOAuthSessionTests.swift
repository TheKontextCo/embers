import XCTest
@testable import EmbersLocal

@MainActor
final class DefaultBrowserOAuthSessionTests: XCTestCase {
    func testCallbackRegistrationPrecedesBrowserLaunchAndFailureDoesNotOpenBrowser() async {
        var events: [String] = []
        let session = DefaultBrowserOAuthSession(prepareCallback: { scheme in
            events.append("prepare:\(scheme)")
        }, openURL: { _ in events.append("open"); return false })
        do {
            _ = try await session.authenticate(at: authorizationURL(), callbackScheme: "embers")
        } catch { XCTAssertEqual(error as? OAuthError, .browserUnavailable) }
        XCTAssertEqual(events, ["prepare:embers", "open"])

        events = []
        let unavailable = DefaultBrowserOAuthSession(prepareCallback: { _ in
            throw OAuthError.invalidCallback
        }, openURL: { _ in events.append("open"); return true })
        do {
            _ = try await unavailable.authenticate(at: authorizationURL(), callbackScheme: "embers")
            XCTFail("Expected callback registration failure")
        } catch { XCTAssertEqual(error as? OAuthError, .invalidCallback) }
        XCTAssertTrue(events.isEmpty)
    }

    func testOpensAuthorizationURLAndCompletesOnlyMatchingCallbackOnce() async throws {
        let opened = expectation(description: "System URL opener called")
        var openedURLs: [URL] = []
        let session = DefaultBrowserOAuthSession { url in
            openedURLs.append(url)
            opened.fulfill()
            return true
        }
        let authorization = authorizationURL(state: "attempt-one")
        let operation = Task { try await session.authenticate(at: authorization, callbackScheme: "embers") }
        defer { operation.cancel() }
        await fulfillment(of: [opened], timeout: 1)
        XCTAssertEqual(openedURLs, [authorization])
        for invalid in [
            "other://oauth/callback?code=test&state=attempt-one",
            "embers://wrong/callback?code=test&state=attempt-one",
            "embers://oauth/wrong?code=test&state=attempt-one",
            "embers://oauth/callback?code=test&state=stale",
            "embers://oauth/callback?code=test&state=attempt-one&state=attempt-one",
            "embers://oauth/callback?code=test&code=duplicate&state=attempt-one",
            "embers://oauth/callback?state=attempt-one",
            "embers://oauth/callback?code=test&error=denied&state=attempt-one",
        ] {
            XCTAssertFalse(session.handleCallback(URL(string: invalid)!))
        }
        let callback = URL(string: "embers://oauth/callback?code=test&state=attempt-one")!
        XCTAssertTrue(session.handleCallback(callback))
        XCTAssertFalse(session.handleCallback(callback))
        let received = try await operation.value
        XCTAssertEqual(received, callback)
    }

    func testBrowserLaunchFailureDoesNotLeavePendingLogin() async {
        let session = DefaultBrowserOAuthSession { _ in false }
        do {
            _ = try await session.authenticate(at: authorizationURL(), callbackScheme: "embers")
            XCTFail("Expected browser launch failure")
        } catch { XCTAssertEqual(error as? OAuthError, .browserUnavailable) }
        XCTAssertFalse(session.handleCallback(callbackURL()))
    }

    func testCancellationBeforeLaunchDoesNotOpenBrowser() async {
        var opens = 0
        let session = DefaultBrowserOAuthSession { _ in opens += 1; return true }
        let operation = Task { try await session.authenticate(at: authorizationURL(), callbackScheme: "embers") }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? OAuthError, .cancelled) }
        XCTAssertEqual(opens, 0)
    }

    func testCancelledOldAttemptCannotCancelReplacementLogin() async throws {
        let firstOpened = expectation(description: "First attempt opened")
        let secondOpened = expectation(description: "Replacement opened")
        var opens = 0
        let session = DefaultBrowserOAuthSession { _ in
            opens += 1
            if opens == 1 { firstOpened.fulfill() } else { secondOpened.fulfill() }
            return true
        }
        let first = Task { try await session.authenticate(at: authorizationURL(state: "old"), callbackScheme: "embers") }
        await fulfillment(of: [firstOpened], timeout: 1)
        let second = Task { try await session.authenticate(at: authorizationURL(state: "new"), callbackScheme: "embers") }
        defer { first.cancel(); second.cancel() }
        await fulfillment(of: [secondOpened], timeout: 1)
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected old attempt cancellation") }
        catch { XCTAssertEqual(error as? OAuthError, .cancelled) }
        XCTAssertFalse(session.handleCallback(callbackURL(state: "old")))
        XCTAssertTrue(session.handleCallback(callbackURL(state: "new")))
        let received = try await second.value
        XCTAssertEqual(received, callbackURL(state: "new"))
    }

    func testTimeoutAllowsRetryAndRejectsLateCallback() async throws {
        let session = DefaultBrowserOAuthSession(timeout: .zero) { _ in true }
        for state in ["first", "retry"] {
            do {
                _ = try await session.authenticate(at: authorizationURL(state: state), callbackScheme: "embers")
                XCTFail("Expected timeout")
            } catch { XCTAssertEqual(error as? OAuthError, .authorizationTimedOut) }
            XCTAssertFalse(session.handleCallback(callbackURL(state: state)))
        }
    }

    func testMatchingDenialReturnsToOAuthConnectionForErrorHandling() async throws {
        let opened = expectation(description: "Authorization opened")
        let session = DefaultBrowserOAuthSession { _ in opened.fulfill(); return true }
        let operation = Task { try await session.authenticate(at: authorizationURL(), callbackScheme: "embers") }
        defer { operation.cancel() }
        await fulfillment(of: [opened], timeout: 1)
        let denial = URL(string: "embers://oauth/callback?error=access_denied&state=expected")!
        XCTAssertTrue(session.handleCallback(denial))
        let received = try await operation.value
        XCTAssertEqual(received, denial)
    }

    private func authorizationURL(state: String = "expected") -> URL {
        var url = URLComponents(string: "https://identity.example/authorize")!
        url.queryItems = [
            .init(name: "redirect_uri", value: "embers://oauth/callback"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: "synthetic-pkce-challenge"),
        ]
        return url.url!
    }

    private func callbackURL(state: String = "expected") -> URL {
        URL(string: "embers://oauth/callback?code=test&state=\(state)")!
    }
}
