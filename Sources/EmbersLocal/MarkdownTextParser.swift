import Foundation
import EmbersCore

public struct MarkdownTextParser: ContextParser, Sendable {
    public init() {}

    public func parse(_ input: ParseInput) throws -> ParsedDocument {
        var diagnostics: [ContextDiagnostic] = []
        let raw: String
        if let utf8 = String(data: input.data, encoding: .utf8) {
            raw = utf8
        } else if let lossy = String(data: input.data, encoding: .isoLatin1) {
            raw = lossy
            diagnostics.append(.init(id: "encoding-\(StableHash.hex(input.relativePath))", severity: .warning, message: "Read non-UTF-8 text using a fallback encoding.", path: input.relativePath))
        } else {
            raw = ""
            diagnostics.append(.init(id: "encoding-\(StableHash.hex(input.relativePath))", severity: .warning, message: "Could not decode this text file.", path: input.relativePath))
        }

        let isMarkdown = ["md", "markdown"].contains(input.url.pathExtension.lowercased())
        guard isMarkdown else {
            return .init(title: input.url.deletingPathExtension().lastPathComponent, text: raw, metadata: .init(), diagnostics: diagnostics)
        }

        var lines = raw.components(separatedBy: .newlines)
        var sourceLineOffset = 0
        var fields: [String: String] = [:]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                var listKey: String?
                for line in lines[1..<end] {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("- "), let listKey {
                        let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                        fields[listKey] = [fields[listKey], item].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ",")
                        continue
                    }
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                    if ["title", "embers_id", "type", "aliases", "tags"].contains(key) {
                        fields[key] = value
                        listKey = ["aliases", "tags"].contains(key) && value.isEmpty ? key : nil
                    } else { listKey = nil }
                }
                lines.removeSubrange(0...end)
                sourceLineOffset = end + 1
            } else {
                diagnostics.append(.init(id: "frontmatter-\(StableHash.hex(input.relativePath))", severity: .warning, message: "Ignored malformed frontmatter with no closing delimiter.", path: input.relativePath))
            }
        }

        var headings: [String] = []
        var links: [ArtifactLink] = []
        var tasks: [ParsedTask] = []
        var inlineTags: [String] = []
        var firstH1: String?
        var inFence = false
        let wikiRegex = try NSRegularExpression(pattern: "(!?)\\[\\[([^\\]|#]+)(?:#[^\\]|]+)?(?:\\|([^\\]]+))?\\]\\]")
        let markdownLinkRegex = try NSRegularExpression(pattern: "(?<!!)\\[([^\\]]+)\\]\\(([^)]+)\\)")
        let tagRegex = try NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])#([\\p{L}\\p{N}_/-]+)")

        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence else { continue }
            if let match = trimmed.range(of: "^(#{1,6})\\s+(.+?)\\s*#*$", options: .regularExpression) {
                let headingLine = String(trimmed[match])
                let title = headingLine.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression).replacingOccurrences(of: "\\s*#*$", with: "", options: .regularExpression)
                headings.append(title)
                if trimmed.hasPrefix("# ") { firstH1 = firstH1 ?? title }
            }
            if let taskRange = trimmed.range(of: "^[-*+]\\s+\\[[ xX]\\]\\s+", options: .regularExpression) {
                let sourceLine = sourceLineOffset + offset + 1
                let marker = String(trimmed[..<taskRange.upperBound])
                let state: SourceTaskState = marker.range(of: "\\[[xX]\\]", options: .regularExpression) == nil ? .open : .completed
                tasks.append(.init(
                    id: "markdown-line:\(sourceLine)",
                    text: String(trimmed[taskRange.upperBound...]),
                    state: state,
                    line: sourceLine,
                    mutationToken: StableHash.hex(line)
                ))
            }
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            for match in wikiRegex.matches(in: line, range: fullRange) {
                let embed = match.range(at: 1).location != NSNotFound && !nsLine.substring(with: match.range(at: 1)).isEmpty
                let target = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                let label = match.range(at: 3).location == NSNotFound ? nil : nsLine.substring(with: match.range(at: 3))
                links.append(.init(target: target, label: label, kind: embed ? .embed : .wiki))
            }
            for match in markdownLinkRegex.matches(in: line, range: fullRange) {
                let label = nsLine.substring(with: match.range(at: 1))
                let rawTarget = nsLine.substring(with: match.range(at: 2)).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                if !rawTarget.contains("://"), !rawTarget.hasPrefix("mailto:") { links.append(.init(target: rawTarget, label: label, kind: .markdown)) }
            }
            for match in tagRegex.matches(in: line, range: fullRange) { inlineTags.append(nsLine.substring(with: match.range(at: 1))) }
        }

        let declaredTitle = cleanScalar(fields["title"])
        let title = declaredTitle ?? firstH1 ?? input.url.deletingPathExtension().lastPathComponent
        let aliases = parseList(fields["aliases"])
        let tags = Array(Set(parseList(fields["tags"]) + inlineTags)).sorted { $0.embersNormalized < $1.embersNormalized }
        let metadata = ArtifactMetadata(
            explicitID: cleanScalar(fields["embers_id"]),
            declaredTitle: declaredTitle,
            kind: cleanScalar(fields["type"]),
            aliases: aliases,
            tags: tags,
            headings: headings,
            links: links,
            tasks: tasks
        )
        return .init(title: title, text: lines.joined(separator: "\n"), metadata: metadata, diagnostics: diagnostics)
    }
}

private func cleanScalar(_ value: String?) -> String? {
    guard var value else { return nil }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
    return value.isEmpty ? nil : value
}

private func parseList(_ value: String?) -> [String] {
    guard var value else { return [] }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("[") && value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
    return value.split(separator: ",").compactMap { cleanScalar(String($0)) }
}
