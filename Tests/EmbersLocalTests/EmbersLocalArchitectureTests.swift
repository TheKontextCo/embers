import Foundation
import Testing

struct EmbersLocalArchitectureTests {
    @Test func localLayerDoesNotDependOnPluginHost() throws {
        let root = repositoryRoot()
        let localSources = try swiftSources(
            under: root.appendingPathComponent("Sources/EmbersLocal", isDirectory: true)
        )

        for sourceURL in localSources {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            #expect(
                !source.contains("import EmbersPluginHost"),
                "EmbersLocal must implement inward-facing PluginKit contracts without importing PluginHost: \(sourceURL.lastPathComponent)"
            )
        }

        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let localTargetStart = try #require(
            manifest.range(of: ".target(\n            name: \"EmbersLocal\"")
        )
        let targetTail = manifest[localTargetStart.lowerBound...]
        let nextTarget = try #require(targetTail.dropFirst().range(of: "\n        .target("))
        let localTarget = targetTail[..<nextTarget.lowerBound]

        #expect(
            !localTarget.contains("\"EmbersPluginHost\""),
            "The EmbersLocal package target must depend inward on Core and PluginKit, never outward on PluginHost."
        )
    }

    private func swiftSources(under root: URL) throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func repositoryRoot() -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        preconditionFailure("Could not locate Package.swift from \(#filePath)")
    }
}
