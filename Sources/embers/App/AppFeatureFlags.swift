import Foundation

struct AppFeatureFlags: Equatable, Sendable {
    static let voiceOpenSinglePeekEnvironmentKey = "EMBERS_FEATURE_VOICE_OPEN_SINGLE_PEEK"

    var voiceOpenSinglePeek: Bool = false

    static func from(environment: [String: String]) -> AppFeatureFlags {
        AppFeatureFlags(
            voiceOpenSinglePeek: environment[voiceOpenSinglePeekEnvironmentKey] == "1"
        )
    }
}
