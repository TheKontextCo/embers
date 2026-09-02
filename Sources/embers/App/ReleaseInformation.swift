import AppKit
import Foundation

enum ReleaseInformation {
    private static let fallbackProjectURL = URL(string: "https://github.com/TheKontextCo/embers")!
    private static let fallbackIssueURL = URL(string: "https://github.com/TheKontextCo/embers/issues/new")!
    private static let fallbackSecurityURL = URL(string: "https://github.com/TheKontextCo/embers/security")!

    static var projectURL: URL { url(for: "EmbersProjectURL", fallback: fallbackProjectURL) }
    static var issueURL: URL { url(for: "EmbersIssueURL", fallback: fallbackIssueURL) }
    static var securityURL: URL { url(for: "EmbersSecurityURL", fallback: fallbackSecurityURL) }

    static func version(in bundle: Bundle = .main) -> String {
        version(metadata: bundle.infoDictionary ?? [:])
    }

    static func build(in bundle: Bundle = .main) -> String {
        build(metadata: bundle.infoDictionary ?? [:])
    }

    static func version(metadata: [String: Any]) -> String {
        metadata["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    static func build(metadata: [String: Any]) -> String {
        metadata["CFBundleVersion"] as? String ?? "1"
    }

    static func url(for key: String, metadata: [String: Any] = Bundle.main.infoDictionary ?? [:], fallback: URL) -> URL {
        guard let value = metadata[key] as? String, let url = URL(string: value) else { return fallback }
        return url
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
