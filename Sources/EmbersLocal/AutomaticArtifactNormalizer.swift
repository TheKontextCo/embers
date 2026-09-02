import Foundation
import EmbersCore

public struct AutomaticArtifactNormalizer: ArtifactNormalizer, Sendable {
    public init() {}

    public func normalize(_ artifacts: [SourceArtifact]) -> [SourceArtifact] {
        guard !artifacts.isEmpty else { return artifacts }
        let notionCount = artifacts.filter { notionPayloadPath($0.relativePath) != nil }.count
        let notionImport = notionCount * 2 >= artifacts.count
        let unreliableDates = hasCollapsedModificationDates(artifacts)

        return artifacts.map { artifact in
            var artifact = artifact
            if notionImport, let logical = notionPayloadPath(artifact.relativePath) {
                artifact.metadata.logicalPath = logical
                artifact.metadata.importKind = "notion"
            }
            if notionImport && unreliableDates { artifact.metadata.modificationDateReliable = false }
            return artifact
        }
    }
}

private func notionPayloadPath(_ path: String) -> String? {
    let components = path.split(separator: "/").map(String.init)
    guard let exportIndex = components.firstIndex(where: isNotionExportWrapper), exportIndex + 1 < components.count else { return nil }
    return components[(exportIndex + 1)...].joined(separator: "/")
}

private func isNotionExportWrapper(_ component: String) -> Bool {
    guard component.hasPrefix("Export-") else { return false }
    let suffix = component.dropFirst("Export-".count)
    return suffix.count >= 8 && suffix.allSatisfy { $0.isHexDigit || $0 == "-" }
}

private func hasCollapsedModificationDates(_ artifacts: [SourceArtifact]) -> Bool {
    guard artifacts.count >= 10 else { return false }
    let calendar = Calendar(identifier: .gregorian)
    let days = artifacts.map { calendar.startOfDay(for: $0.modifiedAt) }
    let largestBucket = Dictionary(grouping: days, by: { $0 }).values.map(\.count).max() ?? 0
    return Double(largestBucket) / Double(artifacts.count) >= 0.8
}
