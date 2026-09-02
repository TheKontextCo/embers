import Foundation

public extension SourceArtifact {
    /// Text that a person can actually read in the document. Import IDs, link targets,
    /// URLs and frontmatter remain available as metadata but cannot become semantic evidence.
    var semanticText: String { semanticBodyText(extractedText) }
}

public func semanticBodyText(_ raw: String) -> String {
    var lines = raw.components(separatedBy: .newlines)
    if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
       let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) {
        lines.removeSubrange(0...end)
    }
    lines.removeAll { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("notion-id:") }
    var text = lines.joined(separator: "\n")
    text = replacingMatches(in: text, pattern: "(?<!!)\\[([^\\]]+)\\]\\([^)]+\\)") { match, source in
        source.substring(with: match.range(at: 1))
    }
    text = replacingMatches(in: text, pattern: "(!?)\\[\\[([^\\]|#]+)(?:#[^\\]|]+)?(?:\\|([^\\]]+))?\\]\\]") { match, source in
        if match.range(at: 3).location != NSNotFound { return source.substring(with: match.range(at: 3)) }
        // An unlabelled wiki/embed link is a relationship or attachment, not
        // prose. Its target remains available through parsed metadata and
        // graph relations; indexing the path/basename as body text creates
        // false literal hits (for example, a file named `passport-number`).
        return ""
    }
    text = text.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func replacingMatches(in text: String, pattern: String, replacement: (NSTextCheckingResult, NSString) -> String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let source = text as NSString
    var result = text
    for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        result.replaceSubrange(range, with: replacement(match, source))
    }
    return result
}
