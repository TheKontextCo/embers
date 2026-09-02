import Foundation
import Testing

@testable import embers

struct PrivacySafeLoggingTests {
    @Test func releaseLoggerHasNoOutputOrPersistentTraceSideChannel() throws {
        let source = try readSource("Sources/embers/App/Log.swift")

        #expect(source.contains("StaticString"))
        #expect(!source.contains("Swift.print"))
        #expect(!source.contains("fflush"))
        #expect(!source.contains("EmbersLogFile"))
        #expect(!source.contains("Logs/Embers"))
        #expect(!source.contains("privacy: .public"))
    }

    @Test func appLogCallsAreAllowlistedEventsWithoutInterpolation() throws {
        let sourceRoot = try repositoryRoot().appendingPathComponent("Sources/embers", isDirectory: true)
        let files = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }

        let dynamicLog = try NSRegularExpression(
            pattern: #"Log\.[A-Za-z]+\.(?:debug|info|notice|error)\(\s*\"(?:[^\"\\]|\\.)*\\\("#
        )
        let eventLog = try NSRegularExpression(
            pattern: #"Log\.[A-Za-z]+\.(?:debug|info|notice|error)\(\s*\"([^\"]*)\"\s*\)"#
        )
        let eventName = try NSRegularExpression(pattern: #"^[a-z][a-z0-9_]*$"#)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            #expect(dynamicLog.firstMatch(in: source, range: range) == nil, "dynamic log interpolation in \(file.lastPathComponent)")

            for match in eventLog.matches(in: source, range: range) {
                guard let eventRange = Range(match.range(at: 1), in: source) else { continue }
                let event = String(source[eventRange])
                let eventNSRange = NSRange(event.startIndex..., in: event)
                #expect(eventName.firstMatch(in: event, range: eventNSRange) != nil, "non-allowlisted log event in \(file.lastPathComponent): \(event)")
            }
        }
    }

    @Test func appSourcesDoNotUsePublicOSLogOrConsoleLogging() throws {
        let sourceRoot = try repositoryRoot().appendingPathComponent("Sources/embers", isDirectory: true)
        let files = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )!.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let forbidden = ["privacy: .public", "NSLog(", "Swift.print(", "EmbersLogFile", "Logs/Embers"]

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden {
                #expect(!source.contains(token), "unsafe diagnostics token in \(file.lastPathComponent): \(token)")
            }
        }
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func repositoryRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
