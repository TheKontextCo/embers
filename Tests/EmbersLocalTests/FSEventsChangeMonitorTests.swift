import CoreServices
import XCTest
@testable import EmbersLocal

final class FSEventsChangeMonitorTests: XCTestCase {
    func testMonitorWatchesTheSelectedRootForRenameOrDeletion() {
        XCTAssertNotEqual(
            FolderChangeEventPolicy.streamCreateFlags
                & FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot),
            0
        )
    }

    func testOpeningOneTwoOrThreeMarkdownFilesDoesNotRequestRefreshForLastUsedMetadata() {
        let flags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemXattrMod
        )

        for paths in [
            ["Notes/One.md"],
            ["Notes/One.md", "Notes/Two.markdown"],
            ["Notes/One.md", "Notes/Two.markdown", "Notes/Three.txt"],
        ] {
            XCTAssertTrue(
                paths.allSatisfy {
                    !FolderChangeEventPolicy.shouldRefresh(relativePath: $0, flags: flags)
                },
                "Opening \(paths.count) files must not request a refresh."
            )
        }
    }

    func testContentChangesToSupportedFilesRequestRefresh() {
        let flags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified
        )

        XCTAssertTrue(
            FolderChangeEventPolicy.shouldRefresh(
                relativePath: "Notes/README.md",
                flags: flags
            )
        )
    }

    func testIgnoredAndUnsupportedPathsDoNotRequestRefresh() {
        let modifiedFile = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified
        )

        XCTAssertFalse(FolderChangeEventPolicy.shouldRefresh(relativePath: ".git/index", flags: modifiedFile))
        XCTAssertFalse(FolderChangeEventPolicy.shouldRefresh(relativePath: "build/debug.db", flags: modifiedFile))
        XCTAssertFalse(FolderChangeEventPolicy.shouldRefresh(relativePath: "Images/cover.png", flags: modifiedFile))
    }

    func testScannerAndMonitorShareOneSupportedContentPolicy() {
        XCTAssertTrue(FolderSourcePathPolicy.isSupportedContentFile("Notes/README.md"))
        XCTAssertTrue(FolderSourcePathPolicy.isSupportedContentFile("Notes/README.markdown"))
        XCTAssertTrue(FolderSourcePathPolicy.isSupportedContentFile("Notes/README.txt"))
        XCTAssertFalse(FolderSourcePathPolicy.isSupportedContentFile("Images/cover.png"))
        XCTAssertTrue(FolderSourcePathPolicy.isManifest(".embers/context.json"))
    }

    func testRelevantDirectoryAndRecoveryEventsRequestRefreshButHistoryMarkerDoesNot() {
        let renamedDirectory = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed
        )

        XCTAssertTrue(
            FolderChangeEventPolicy.shouldRefresh(
                relativePath: "Projects/Renamed",
                flags: renamedDirectory
            )
        )
        XCTAssertTrue(
            FolderChangeEventPolicy.shouldRefresh(
                relativePath: "",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            )
        )
        XCTAssertFalse(
            FolderChangeEventPolicy.shouldRefresh(
                relativePath: "",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
            )
        )
    }
}
