import Foundation

/// Renders a compact document preview without carrying block-level Markdown styling
/// (such as a large heading) into the dashboard row.
func markdownSnippet(_ source: String) -> AttributedString {
    let inlineSource = source.replacingOccurrences(
        of: #"^#{1,6}[ \t]+"#,
        with: "",
        options: .regularExpression
    )

    return (try? AttributedString(
        markdown: inlineSource,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(inlineSource)
}
