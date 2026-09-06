import XCTest
import EmbersCore
@testable import EmbersLocal

final class FolderPipelineTests: XCTestCase {
    private struct ScanFailure: LocalizedError {
        var errorDescription: String? { "synthetic scan failure" }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    private final class ScopeProbe: FolderSecurityScopedAccessing, @unchecked Sendable {
        private(set) var isAccessing = true
        private(set) var closeCount = 0

        func close() {
            guard isAccessing else { return }
            isAccessing = false
            closeCount += 1
        }
    }

    private final class SyntheticScanner: FolderFileScanning, @unchecked Sendable {
        var available = true
        var entries: [FolderFileEntry]
        var data: [URL: Data]
        var enumerationError: Error?
        var readErrorURLs = Set<URL>()
        var becomesUnavailableAfterEnumeration = false
        private(set) var directives: [URL: FolderTraversalDirective] = [:]

        init(entries: [FolderFileEntry], data: [URL: Data]) {
            self.entries = entries
            self.data = data
        }

        func isAvailableDirectory(at url: URL) -> Bool { available }

        func enumerate(at rootURL: URL, visit: (FolderFileEntry) throws -> FolderTraversalDirective) throws {
            for entry in entries {
                directives[entry.url] = try visit(entry)
            }
            if becomesUnavailableAfterEnumeration { available = false }
            if let enumerationError { throw enumerationError }
        }

        func readData(at url: URL) throws -> Data {
            if readErrorURLs.contains(url) { throw ScanFailure() }
            guard let data = data[url] else { throw ScanFailure() }
            return data
        }
    }

    private func entry(_ url: URL, bytes: Int? = nil) -> FolderFileEntry {
        .init(url: url, isDirectory: false, isRegularFile: true, isSymbolicLink: false, fileSize: bytes ?? 12, contentModificationDate: .now)
    }

    private struct SelectivelyFailingParser: ContextParser {
        func parse(_ input: ParseInput) throws -> ParsedDocument {
            if input.relativePath == "Bad.md" { throw ScanFailure() }
            return try MarkdownTextParser().parse(input)
        }
    }

    private final class RecordingParser: ContextParser, @unchecked Sendable {
        private(set) var paths: [String] = []

        func reset() { paths.removeAll() }

        func parse(_ input: ParseInput) throws -> ParsedDocument {
            paths.append(input.relativePath)
            return try MarkdownTextParser().parse(input)
        }
    }

    func testScanCanonicalizesContentOrderAndSkipsSymlinkAndIgnoredDirectories() async throws {
        let root = URL(fileURLWithPath: "/synthetic-vault", isDirectory: true)
        let ignored = root.appendingPathComponent(".git", isDirectory: true)
        let symlink = root.appendingPathComponent("linked", isDirectory: true)
        let alpha = root.appendingPathComponent("Alpha.md")
        let beta = root.appendingPathComponent("Beta.md")
        let scanner = SyntheticScanner(entries: [
            entry(beta),
            .init(url: ignored, isDirectory: true, isRegularFile: false, isSymbolicLink: false, fileSize: 0, contentModificationDate: nil),
            .init(url: symlink, isDirectory: true, isRegularFile: false, isSymbolicLink: true, fileSize: 0, contentModificationDate: nil),
            entry(alpha),
        ], data: [alpha: Data("# Alpha".utf8), beta: Data("# Beta".utf8)])

        let scan = try await FolderContextSource(sourceID: "fixture", rootURL: root, scanner: scanner, cancellationCheck: {}).scan()

        XCTAssertEqual(scan.artifacts.map(\.relativePath), ["Alpha.md", "Beta.md"])
        XCTAssertEqual(scanner.directives[ignored], .skipDescendants)
        XCTAssertEqual(scanner.directives[symlink], .skipDescendants)
    }

    func testParseFailureWarnsAndKeepsOtherArtifacts() async throws {
        let root = URL(fileURLWithPath: "/synthetic-vault", isDirectory: true)
        let bad = root.appendingPathComponent("Bad.md")
        let good = root.appendingPathComponent("Good.md")
        let scanner = SyntheticScanner(entries: [entry(bad), entry(good)], data: [
            bad: Data("# Bad".utf8), good: Data("# Good".utf8),
        ])

        let scan = try await FolderContextSource(sourceID: "fixture", rootURL: root,
            parser: SelectivelyFailingParser(), scanner: scanner, cancellationCheck: {}).scan()

        XCTAssertEqual(scan.artifacts.map(\.relativePath), ["Good.md"])
        XCTAssertEqual(scan.diagnostics.filter { $0.path == "Bad.md" }.map(\.severity), [.warning])
    }

    func testUnderreportedContentBytesFailBeforeParsing() async throws {
        let root = URL(fileURLWithPath: "/synthetic-vault", isDirectory: true)
        let note = root.appendingPathComponent("Note.md")
        let oversized = Data(repeating: 0x20, count: FolderContextSource.maximumParsedBytes + 1)
        let source = FolderContextSource(sourceID: "fixture", rootURL: root,
            scanner: SyntheticScanner(entries: [entry(note, bytes: 0)], data: [note: oversized]), cancellationCheck: {})

        do {
            _ = try await source.scan()
            XCTFail("Expected the read-time content bound to reject the scan")
        } catch let error as FolderSourceError {
            guard case .fileReadFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testFailedScanDoesNotPublishPartialParseCache() async throws {
        let root = URL(fileURLWithPath: "/synthetic-vault", isDirectory: true)
        let alpha = root.appendingPathComponent("Alpha.md")
        let beta = root.appendingPathComponent("Beta.md")
        let scanner = SyntheticScanner(entries: [entry(alpha), entry(beta)], data: [
            alpha: Data("# Alpha old".utf8), beta: Data("# Beta old".utf8),
        ])
        let parser = RecordingParser()
        let source = FolderContextSource(sourceID: "fixture", rootURL: root, parser: parser, scanner: scanner, cancellationCheck: {})
        _ = try await source.scan()

        scanner.data[alpha] = Data("# Alpha new".utf8)
        scanner.data[beta] = Data("# Beta new".utf8)
        parser.reset()
        scanner.readErrorURLs = [beta]
        do {
            _ = try await source.scan()
            XCTFail("Expected the failed read to reject the scan")
        } catch {
            XCTAssertTrue(error is FolderSourceError)
        }
        XCTAssertEqual(parser.paths, ["Alpha.md"])

        parser.reset()
        scanner.readErrorURLs = []
        _ = try await source.scan()
        XCTAssertEqual(parser.paths, ["Alpha.md", "Beta.md"])
    }

    func testScanFailsClosedAtFileAndParsedByteLimits() async throws {
        let root = URL(fileURLWithPath: "/synthetic-vault", isDirectory: true)
        let first = root.appendingPathComponent("one.md")
        let second = root.appendingPathComponent("two.md")
        let contents = Data("hello".utf8)

        let tooManyFiles = SyntheticScanner(entries: [entry(first), entry(second)], data: [first: contents, second: contents])
        let fileLimited = FolderContextSource(
            sourceID: "fixture", rootURL: root,
            limits: .init(maximumFileCount: 1, maximumTotalParsedBytes: 100),
            scanner: tooManyFiles, cancellationCheck: {}
        )
        do {
            _ = try await fileLimited.scan()
            XCTFail("Expected the file-count limit to reject the scan")
        } catch let error as FolderSourceError {
            guard case .fileCountLimitExceeded(let limit) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(limit, 1)
        }

        let tooManyBytes = SyntheticScanner(entries: [entry(first, bytes: 5), entry(second, bytes: 5)], data: [first: contents, second: contents])
        let byteLimited = FolderContextSource(
            sourceID: "fixture", rootURL: root,
            limits: .init(maximumFileCount: 10, maximumTotalParsedBytes: 9),
            scanner: tooManyBytes, cancellationCheck: {}
        )
        do {
            _ = try await byteLimited.scan()
            XCTFail("Expected the parsed-byte limit to reject the scan")
        } catch let error as FolderSourceError {
            guard case .totalParsedBytesLimitExceeded(let limit) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(limit, 9)
        }
    }

    func testManifestReadIsBoundedEvenWhenProviderReportsZeroBytes() async throws {
        let root = URL(fileURLWithPath: "/synthetic-vault", isDirectory: true)
        let manifest = root.appendingPathComponent(".embers/context.json")
        let oversized = Data(repeating: 0x20, count: (2 * 1_024 * 1_024) + 1)
        let scanner = SyntheticScanner(
            entries: [entry(manifest, bytes: 0)],
            data: [manifest: oversized]
        )
        let source = FolderContextSource(sourceID: "fixture", rootURL: root, scanner: scanner, cancellationCheck: {})

        do {
            _ = try await source.scan()
            XCTFail("Expected the manifest byte limit to reject the scan")
        } catch let error as FolderSourceError {
            guard case .manifestBytesLimitExceeded(let limit) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(limit, 2 * 1_024 * 1_024)
        }
    }

    func testScanCancellationAndIncompleteFilesystemFailuresNeverProduceAScan() async throws {
        let root = URL(fileURLWithPath: "/synthetic-vault", isDirectory: true)
        let note = root.appendingPathComponent("note.md")
        let contents = Data("# Note\ntext".utf8)

        let cancellationChecks = Counter()
        let cancelling = FolderContextSource(
            sourceID: "fixture", rootURL: root,
            scanner: SyntheticScanner(entries: [entry(note)], data: [note: contents]),
            cancellationCheck: {
                if cancellationChecks.increment() > 1 { throw CancellationError() }
            }
        )
        do {
            _ = try await cancelling.scan()
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let enumerationFailure = SyntheticScanner(entries: [entry(note)], data: [note: contents])
        enumerationFailure.enumerationError = ScanFailure()
        let incompleteWalk = FolderContextSource(sourceID: "fixture", rootURL: root, scanner: enumerationFailure, cancellationCheck: {})
        do {
            _ = try await incompleteWalk.scan()
            XCTFail("Expected incomplete enumeration to fail")
        } catch {
            XCTAssertTrue(error is ScanFailure)
        }

        let readFailure = SyntheticScanner(entries: [entry(note)], data: [note: contents])
        readFailure.readErrorURLs = [note]
        let incompleteRead = FolderContextSource(sourceID: "fixture", rootURL: root, scanner: readFailure, cancellationCheck: {})
        do {
            _ = try await incompleteRead.scan()
            XCTFail("Expected incomplete read to fail")
        } catch {
            guard case .fileReadFailed = error as? FolderSourceError else { return XCTFail("Unexpected error: \(error)") }
        }

        let vanishedRoot = SyntheticScanner(entries: [entry(note)], data: [note: contents])
        vanishedRoot.becomesUnavailableAfterEnumeration = true
        let incompleteRoot = FolderContextSource(sourceID: "fixture", rootURL: root, scanner: vanishedRoot, cancellationCheck: {})
        do {
            _ = try await incompleteRoot.scan()
            XCTFail("Expected an unavailable root to fail")
        } catch {
            guard case .unavailable = error as? FolderSourceError else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testConfiguredFolderRetainsSecurityScopeUntilExplicitClose() async throws {
        let root = URL(fileURLWithPath: "/synthetic-vault", isDirectory: true)
        let note = root.appendingPathComponent("note.md")
        let scope = ScopeProbe()
        let source = FolderContextSource(
            sourceID: "fixture",
            rootURL: root,
            scanner: SyntheticScanner(entries: [entry(note)], data: [note: Data("# Note".utf8)]),
            cancellationCheck: {},
            securityScopedAccess: scope
        )

        _ = try await source.scan()
        XCTAssertTrue(scope.isAccessing, "A scan must not release the scope used by later file events and writes.")
        XCTAssertEqual(scope.closeCount, 0)

        source.close()
        source.close()
        XCTAssertFalse(scope.isAccessing)
        XCTAssertEqual(scope.closeCount, 1, "Folder removal must balance the security scope exactly once.")
    }

    func testCommittedSampleVaultScansThroughRealPipeline() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vault = root.appendingPathComponent("Sources/embers/Resources/SampleVault")
        let source = FolderContextSource(sourceID: "fixture", rootURL: vault)
        let scan = try await source.scan()
        let snapshot = try DeterministicGraphBuilder().build(from: scan)
        XCTAssertEqual(snapshot.artifacts.count, 10)

        let graph = DeterministicContextGraphProjector().project(snapshot)
        let addressableNames = Set(
            VoiceRoutingAddressabilityPolicy()
                .nodes(in: graph, snapshot: snapshot)
                .map(\.name)
        )
        XCTAssertEqual(
            addressableNames,
            Set([
                "San Francisco Trip",
                "Building a Second Brain",
                "No Local Model Required",
            ]),
            "The demo vault must expose exactly the three contexts in its activation journey."
        )

        let search = GraphContextSearch(graph: graph, snapshot: snapshot)
        let homeNames = Set(search.homeSummaries(in: snapshot).map(\.name))
        XCTAssertEqual(
            homeNames,
            Set([
                "San Francisco Trip",
                "Building a Second Brain",
                "No Local Model Required",
            ])
        )

        let sanFrancisco = try XCTUnwrap(
            graph.activationNodes.first(where: { $0.name == "San Francisco Trip" })
        )
        let tripDetail = try XCTUnwrap(search.detail(nodeID: sanFrancisco.id, in: snapshot))
        XCTAssertEqual(tripDetail.hits.count, 3)
        XCTAssertTrue(tripDetail.tasks.contains(where: { $0.text == "Book the hotel in Hayes Valley" }))
        XCTAssertTrue(tripDetail.tasks.contains(where: { $0.text == "Say “San Francisco” and see the trip peek appear" }))
        XCTAssertTrue(tripDetail.tasks.contains(where: { $0.text == "Open Itinerary from the trip context and read the source file" }))

        let secondBrain = try XCTUnwrap(
            graph.activationNodes.first(where: { $0.name == "Building a Second Brain" })
        )
        let secondBrainDetail = try XCTUnwrap(search.detail(nodeID: secondBrain.id, in: snapshot))
        XCTAssertEqual(secondBrainDetail.hits.count, 3)
        XCTAssertTrue(secondBrainDetail.tasks.contains(where: { $0.text == "Review the weekly capture inbox" }))
        XCTAssertTrue(secondBrainDetail.tasks.contains(where: { $0.text == "Say “second brain” and see its peek appear" }))

        let localModel = try XCTUnwrap(
            graph.activationNodes.first(where: { $0.name == "No Local Model Required" })
        )
        let localModelDetail = try XCTUnwrap(search.detail(nodeID: localModel.id, in: snapshot))
        XCTAssertEqual(localModelDetail.hits.count, 3)
        XCTAssertTrue(localModelDetail.tasks.contains(where: { $0.text == "Say “local model” and see this context's peek appear" }))
        XCTAssertTrue(localModelDetail.tasks.contains(where: { $0.text == "Open Context Lens and find a title-based matching rule" }))
        XCTAssertTrue(snapshot.artifacts.contains(where: { $0.title == "Local Intelligence" }))
        XCTAssertFalse(snapshot.artifacts.contains(where: { $0.title == "Optional Intelligence" }))

        for detail in [tripDetail, secondBrainDetail, localModelDetail] {
            XCTAssertTrue(detail.hits.allSatisfy { $0.artifact.localURL?.isFileURL == true })
        }

        let seedByName = Dictionary(
            uniqueKeysWithValues: VoiceRoutingSeedBuilder()
                .build(graph: graph, snapshot: snapshot)
                .map { ($0.canonicalName, $0) }
        )
        XCTAssertTrue(
            seedByName["No Local Model Required"]?.directHeadingsAndTags.contains("Local Model") == true,
            "The natural local-model heading is bounded evidence for the semantic route."
        )
        XCTAssertTrue(
            seedByName["Building a Second Brain"]?.directHeadingsAndTags.contains("Knowledge System") == true
        )
        XCTAssertTrue(
            seedByName["San Francisco Trip"]?.directHeadingsAndTags.contains("San Francisco") == true,
            "The trip's ordinary shortened name must be present as direct authored evidence."
        )
        XCTAssertTrue(snapshot.relations.allSatisfy { $0.evidence != .authored })
    }

    func testRepositoryRoundTripAndCorruptCacheRecovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("embers-repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("snapshot.json")
        let repository = JSONSnapshotRepository(fileURL: url)
        let snapshot = ContextSnapshot(sourceID: "s", revision: "r", artifacts: [], anchors: [], relations: [], diagnostics: [], indexedAt: Date(timeIntervalSince1970: 100))
        try await repository.replace(with: snapshot)
        let loaded = await repository.load()
        XCTAssertEqual(loaded?.revision, "r")
        try Data("broken".utf8).write(to: url)
        let recovered = await repository.load()
        XCTAssertNil(recovered)
        try await repository.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
