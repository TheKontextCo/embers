import Foundation

/// Pure English-only locale selection policy for offline speech recognition.
/// Keeping this outside `SFSpeechRecognizer` makes asset selection deterministic
/// and testable without using the Speech framework.
enum SpeechLocalePolicy {
    struct Resolution: Equatable {
        var supportedIdentifiers: [String]
        var recommendedIdentifier: String?
        var effectiveIdentifier: String?
        var selectedLocaleIsUnsupported: Bool
    }

    static func resolve(
        supportedIdentifiers: some Sequence<String>,
        systemIdentifier: String
    ) -> Resolution {
        let supported = Array(Set(supportedIdentifiers.compactMap(canonicalIdentifier)))
            .filter { language(in: $0) == "en" }
            .sorted()
        let recommended = recommendedIdentifier(from: supported, systemIdentifier: systemIdentifier)
        return Resolution(
            supportedIdentifiers: supported,
            recommendedIdentifier: recommended,
            effectiveIdentifier: recommended,
            selectedLocaleIsUnsupported: false
        )
    }

    /// Canonicalize identifiers without depending on the user's current locale. This
    /// accepts Foundation's underscore spelling but returns BCP-47 hyphenated form.
    static func canonicalIdentifier(_ identifier: String) -> String? {
        let parts = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: true)
        guard let first = parts.first, first.allSatisfy({ $0.isLetter }) else { return nil }

        return parts.enumerated().map { index, part in
            if index == 0 { return part.lowercased() }
            if part.count == 4, part.allSatisfy({ $0.isLetter }) {
                return part.prefix(1).uppercased() + part.dropFirst().lowercased()
            }
            if (part.count == 2 && part.allSatisfy({ $0.isLetter })) ||
                (part.count == 3 && part.allSatisfy({ $0.isNumber })) {
                return part.uppercased()
            }
            return part.lowercased()
        }
        .joined(separator: "-")
    }

    private static func recommendedIdentifier(from supported: [String], systemIdentifier: String) -> String? {
        guard !supported.isEmpty else { return nil }
        guard let system = canonicalIdentifier(systemIdentifier) else {
            return supported.contains("en-US") ? "en-US" : supported.first
        }
        if language(in: system) == "en", supported.contains(system) { return system }

        if let systemRegion = region(in: system),
           let regionMatch = supported.first(where: { region(in: $0) == systemRegion }) {
            return regionMatch
        }
        return supported.contains("en-US") ? "en-US" : supported.first
    }

    private static func language(in identifier: String) -> String? {
        identifier.split(separator: "-", maxSplits: 1).first.map(String.init)
    }

    private static func region(in identifier: String) -> String? {
        identifier.split(separator: "-").dropFirst().first(where: { part in
            (part.count == 2 && part.allSatisfy(\.isLetter)) ||
                (part.count == 3 && part.allSatisfy(\.isNumber))
        }).map { $0.uppercased() }
    }
}
