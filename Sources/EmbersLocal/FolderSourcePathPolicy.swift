import Foundation

enum FolderSourcePathPolicy {
    private static let supportedContentExtensions = Set(["md", "markdown", "txt"])
    private static let ignoredDirectoryNames: Set<String> = [
        ".git", ".obsidian", ".build", ".cache", ".dart_tool", ".next",
        "node_modules", "bower_components", "Pods", "DerivedData",
        "build", "dist", "bin", "obj", "out", "target", "coverage"
    ]

    static func isManifest(_ relativePath: String) -> Bool {
        normalized(relativePath) == ".embers/context.json"
    }

    static func isSupportedContentFile(_ relativePath: String) -> Bool {
        supportedContentExtensions.contains(
            URL(fileURLWithPath: normalized(relativePath)).pathExtension.lowercased()
        )
    }

    static func shouldIgnore(components: [String], isDirectory: Bool) -> Bool {
        guard let name = components.last else { return false }
        if ignoredDirectoryNames.contains(name) { return true }
        if name == ".DS_Store" { return true }
        if name.hasPrefix(".") {
            return !(components == [".embers"] && isDirectory)
                && components != [".embers", "context.json"]
        }
        return components.dropLast().contains { $0.hasPrefix(".") && $0 != ".embers" }
    }

    private static func normalized(_ relativePath: String) -> String {
        relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
