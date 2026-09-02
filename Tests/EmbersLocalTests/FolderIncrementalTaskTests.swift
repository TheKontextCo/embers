import XCTest
import EmbersCore
@testable import EmbersLocal

final class FolderIncrementalTaskTests: XCTestCase {
    func testKnownTaskWriteReadsOnlyChangedFileWithoutEnumeratingFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("task-read-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let taskURL = root.appendingPathComponent("Tasks.md")
        try Data("# Tasks\n- [ ] Ship\n".utf8).write(to: taskURL)
        try Data("# Peer\n[Tasks](Tasks.md)\n".utf8).write(to: root.appendingPathComponent("Peer.md"))
        let scanner = RecordingFileScanner()
        let parser = CountingParser()
        let source = FolderContextSource(sourceID: "fixture", rootURL: root, parser: parser,
            scanner: scanner, cancellationCheck: {})
        _ = try await source.scan()
        scanner.reset()
        parser.reset()
        try Data("# Tasks\n- [x] Ship\n".utf8).write(to: taskURL, options: .atomic)

        let updated = try await source.scanAfterTaskWrite(at: taskURL)
        XCTAssertEqual(scanner.enumerations, 0)
        XCTAssertEqual(scanner.reads, [taskURL])
        XCTAssertEqual(parser.paths, ["Tasks.md"])
        XCTAssertEqual(updated.artifacts.first { $0.relativePath == "Tasks.md" }?.metadata.tasks.first?.state, .completed)
        let authoritative = try await FolderContextSource(sourceID: "fixture", rootURL: root).scan()
        XCTAssertEqual(updated.artifacts, authoritative.artifacts)
        XCTAssertEqual(updated.declarations, authoritative.declarations)

        // A concurrent structural edit is not eligible for the checkbox shortcut.
        try Data("# Tasks\n- [x] Ship\n[[New context]]\n".utf8).write(to: taskURL, options: .atomic)
        scanner.reset()
        let structural = try await source.scanAfterTaskWrite(at: taskURL)
        XCTAssertEqual(scanner.enumerations, 1)
        let structuralOracle = try await FolderContextSource(sourceID: "fixture", rootURL: root).scan()
        XCTAssertEqual(structural.artifacts, structuralOracle.artifacts)
    }

    private final class RecordingFileScanner: FolderFileScanning, @unchecked Sendable {
        private let base = SystemFolderFileScanner()
        var enumerations = 0
        var reads: [URL] = []
        func reset() { enumerations = 0; reads = [] }
        func isAvailableDirectory(at url: URL) -> Bool { base.isAvailableDirectory(at: url) }
        func enumerate(at rootURL: URL, visit: (FolderFileEntry) throws -> FolderTraversalDirective) throws {
            enumerations += 1
            try base.enumerate(at: rootURL, visit: visit)
        }
        func readData(at url: URL) throws -> Data {
            reads.append(url)
            return try base.readData(at: url)
        }
    }

    func testCheckboxEditReparsesOnlyChangedNoteRegardlessOfFolderSize() async throws {
        for noteCount in [2, 64] {
            let fixture = Fixture(noteCount: noteCount)
            let initial = try await fixture.source.scan()
            XCTAssertEqual(fixture.parser.paths.count, noteCount)
            fixture.parser.reset()
            fixture.completeTask()

            let updated = try await fixture.source.scan()
            let changed = try XCTUnwrap(updated.artifacts.first { $0.relativePath == "Tasks.md" })
            XCTAssertEqual(changed.metadata.tasks.first?.state, .completed)
            XCTAssertEqual(updated.artifacts.filter { $0.relativePath != "Tasks.md" },
                           initial.artifacts.filter { $0.relativePath != "Tasks.md" })

            // Correctness oracle: incremental output must match an independent full scan.
            let fresh = FolderContextSource(sourceID: "fixture", rootURL: fixture.root,
                scanner: fixture.scanner, cancellationCheck: {})
            let authoritative = try await fresh.scan()
            XCTAssertEqual(updated.artifacts, authoritative.artifacts)
            XCTAssertEqual(fixture.parser.paths, ["Tasks.md"],
                           "A one-checkbox edit must not reparse all \(noteCount) notes.")
        }
    }

    func testUnchangedFollowUpScanDoesNoParsingButLaterExternalEditIsNotLost() async throws {
        let fixture = Fixture(noteCount: 8)
        _ = try await fixture.source.scan()
        fixture.completeTask()
        let completed = try await fixture.source.scan()
        fixture.parser.reset()

        // Exercise the refresh requested by a delayed notification for our own write.
        let repeated = try await fixture.source.scan()
        XCTAssertEqual(repeated.artifacts, completed.artifacts)
        XCTAssertEqual(fixture.parser.paths, [],
                       "A follow-up notification for already indexed bytes must not reparse the folder.")

        fixture.parser.reset()
        fixture.scanner.replace("Note-1.md", with: "# External edit\nDo not discard this change.\n")
        let external = try await fixture.source.scan()
        XCTAssertEqual(external.artifacts.first { $0.relativePath == "Note-1.md" }?.title, "External edit")
        XCTAssertEqual(external.artifacts.first { $0.relativePath == "Tasks.md" }?.metadata.tasks.first?.state, .completed)
        XCTAssertEqual(fixture.parser.paths, ["Note-1.md"])
    }

    func testSameSizeSameTimestampExternalCheckboxEditIsDetected() async throws {
        let fixture = Fixture(noteCount: 2)
        let original = try await fixture.source.scan()
        let url = fixture.root.appendingPathComponent("Tasks.md")
        // Deliberately leave the scanner's file metadata unchanged.
        fixture.scanner.contents[url] = Data("# Tasks\n- [x] Ship the app\n".utf8)
        fixture.parser.reset()
        let updated = try await fixture.source.scan()
        XCTAssertEqual(original.artifacts.first { $0.relativePath == "Tasks.md" }?.metadata.tasks.first?.state, .open)
        XCTAssertEqual(updated.artifacts.first { $0.relativePath == "Tasks.md" }?.metadata.tasks.first?.state, .completed)
        XCTAssertEqual(fixture.parser.paths, ["Tasks.md"])
    }

    private final class CountingParser: ContextParser, @unchecked Sendable {
        private let lock = NSLock()
        private var parsedPaths: [String] = []
        var paths: [String] { lock.withLock { parsedPaths } }
        func reset() { lock.withLock { parsedPaths.removeAll() } }
        func parse(_ input: ParseInput) throws -> ParsedDocument {
            lock.withLock { parsedPaths.append(input.relativePath) }
            return try MarkdownTextParser().parse(input)
        }
    }

    // Scans are awaited serially; no real filesystem, watcher, or user content is involved.
    private final class Scanner: FolderFileScanning, @unchecked Sendable {
        let root: URL
        var entries: [FolderFileEntry] = []
        var contents: [URL: Data] = [:]

        init(root: URL, noteCount: Int) {
            self.root = root
            replace("Tasks.md", with: "# Tasks\n- [ ] Ship the app\n")
            for index in 1..<noteCount {
                replace("Note-\(index).md", with: "# Note \(index)\n[Tasks](Tasks.md)\n")
            }
        }

        func replace(_ path: String, with text: String) {
            let url = root.appendingPathComponent(path)
            let data = Data(text.utf8)
            let previous = entries.first { $0.url == url }?.contentModificationDate ?? .distantPast
            entries.removeAll { $0.url == url }
            entries.append(.init(url: url, isDirectory: false, isRegularFile: true,
                isSymbolicLink: false, fileSize: data.count, contentModificationDate: previous.addingTimeInterval(1)))
            contents[url] = data
        }

        func isAvailableDirectory(at url: URL) -> Bool { url == root }
        func enumerate(at rootURL: URL, visit: (FolderFileEntry) throws -> FolderTraversalDirective) throws {
            for entry in entries { _ = try visit(entry) }
        }
        func readData(at url: URL) throws -> Data { try XCTUnwrap(contents[url]) }
    }

    private struct Fixture {
        let root = URL(fileURLWithPath: "/synthetic-checkbox-vault", isDirectory: true)
        let parser: CountingParser
        let scanner: Scanner
        let source: FolderContextSource

        init(noteCount: Int) {
            parser = CountingParser()
            scanner = Scanner(root: root, noteCount: noteCount)
            source = FolderContextSource(sourceID: "fixture", rootURL: root, parser: parser,
                scanner: scanner, cancellationCheck: {})
        }

        func completeTask() { scanner.replace("Tasks.md", with: "# Tasks\n- [x] Ship the app\n") }
    }
}
