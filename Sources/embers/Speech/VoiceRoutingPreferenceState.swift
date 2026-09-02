import Combine
import EmbersLocal
import Foundation

@MainActor
final class VoiceRoutingPreferenceState: ObservableObject {
    @Published private(set) var sourceSummaries: [String: VoiceRoutingPreferenceSummary] = [:]
    @Published private(set) var isResetting = false
    @Published private(set) var error: String?

    var resetAction: (() -> Void)?

    var detail: String {
        if let error { return error }
        guard !sourceSummaries.isEmpty else { return "No context sources selected" }
        let associationCount = sourceSummaries.values.reduce(0) { $0 + $1.associationCount }
        let totalOpenCount = sourceSummaries.values.reduce(0) { $0 + $1.totalOpenCount }
        guard associationCount > 0 else { return "No learned choices for these sources" }
        let choices = associationCount == 1 ? "choice" : "choices"
        let opens = totalOpenCount == 1 ? "open" : "opens"
        var result = "\(associationCount) learned \(choices) · \(totalOpenCount) \(opens)"
        if let lastOpenedAt = sourceSummaries.values.compactMap(\.lastOpenedAt).max() {
            let relative = RelativeDateTimeFormatter().localizedString(for: lastOpenedAt, relativeTo: .now)
            result += " · updated \(relative)"
        }
        return result
    }

    var canReset: Bool {
        sourceSummaries.values.contains { $0.associationCount > 0 } && !isResetting
    }

    func install(sourceSummaries: [String: VoiceRoutingPreferenceSummary]) {
        self.sourceSummaries = sourceSummaries
        error = nil
    }

    func report(error: String) {
        self.error = error
    }

    func beginReset() {
        guard canReset else { return }
        isResetting = true
        error = nil
        resetAction?()
    }

    func finishReset(error: String? = nil) {
        isResetting = false
        self.error = error
    }
}
