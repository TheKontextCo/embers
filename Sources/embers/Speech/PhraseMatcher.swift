//  PhraseMatcher.swift
//  Pure transcript → match-target logic, kept separate from the audio plumbing so it
//  stays testable. Matches whole-word phrases against the live transcript tail.

import Foundation

struct PhraseMatcher {
    private let targets: [(target: MatchTarget, phrase: String)]

    init(targets: [MatchTarget]) {
        // Pre-normalize each target's phrase once (e.g. "Pitch - 1 Pager" → "pitch 1 pager").
        self.targets = targets.map { ($0, PhraseMatcher.normalize($0.phrase)) }
    }

    /// Returns the targets whose (normalized) name appears as whole words in the transcript
    /// tail. Normalizing both sides makes matching punctuation/spacing insensitive, so a
    /// name like "Pitch - 1 Pager" matches the spoken "… the pitch 1 pager …".
    func matches(in transcript: String, window: Int = 120) -> [MatchTarget] {
        let tail = PhraseMatcher.normalize(String(transcript.suffix(window)))
        return targets.filter { !$0.phrase.isEmpty && contains(tail, phrase: $0.phrase) }
            .map(\.target)
    }

    /// Lowercase and collapse every run of non-alphanumerics to a single space.
    static func normalize(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                out.append(ch); pendingSpace = false
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    private func contains(_ haystack: String, phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        let isBoundary: (Character?) -> Bool = { c in
            guard let c else { return true }
            return !(c.isLetter || c.isNumber)
        }
        var start = haystack.startIndex
        while start < haystack.endIndex, let range = haystack.range(of: phrase, range: start..<haystack.endIndex) {
            let before = range.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: range.lowerBound)]
            let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
            if isBoundary(before) && isBoundary(after) { return true }
            start = range.upperBound
        }
        return false
    }
}
