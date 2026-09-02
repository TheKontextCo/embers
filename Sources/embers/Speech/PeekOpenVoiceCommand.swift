import Foundation

enum PeekOpenVoiceCommandResolution: Equatable {
    case notACommand
    case held(Peek)
    case ambiguous
    case open(Peek)
}

enum PeekOpenVoiceCommand {
    /// Continuous recognition does not reliably finalize a short standalone utterance. Treat an
    /// unchanged exact partial as stable after this window; any newer partial cancels the timer.
    static let partialStabilityDelay: Duration = .milliseconds(700)

    /// Recognition results grow cumulatively within one utterance. A peek may therefore be
    /// followed by "open" in a transcript shaped like "second brain open". Only the words
    /// appended after the transcript that produced the peek are eligible as a command.
    static func textAfterPeek(
        in event: SpeechTranscript,
        prefix: (utteranceID: UUID, text: String)?
    ) -> String {
        let normalized = PhraseMatcher.normalize(event.text)
        guard let prefix,
              prefix.utteranceID == event.utteranceID else {
            return normalized
        }
        let prefixWords = prefix.text.split(separator: " ")
        let currentWords = normalized.split(separator: " ")
        guard currentWords.count >= prefixWords.count,
              currentWords.prefix(prefixWords.count).elementsEqual(prefixWords) else {
            return normalized
        }
        return currentWords.dropFirst(prefixWords.count).joined(separator: " ")
    }

    /// A bare "open" is an executable command only while exactly one peek is visible.
    /// Hold partial recognition so a transient prefix cannot open before Apple finishes a
    /// longer utterance such as "open the project notes".
    static func resolve(
        _ event: SpeechTranscript,
        visiblePeeks: [Peek],
        isEnabled: Bool = false
    ) -> PeekOpenVoiceCommandResolution {
        guard isEnabled,
              !visiblePeeks.isEmpty,
              PhraseMatcher.normalize(event.text) == "open" else {
            return .notACommand
        }
        guard visiblePeeks.count == 1, let peek = visiblePeeks.first else {
            return .ambiguous
        }
        guard event.isFinal else { return .held(peek) }
        return .open(peek)
    }
}
