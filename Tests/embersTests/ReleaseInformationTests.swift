import Foundation
import XCTest
@testable import embers

final class ReleaseInformationTests: XCTestCase {
    func testSupportLinksAreTheCanonicalRepositoryRoutes() {
        XCTAssertEqual(ReleaseInformation.projectURL.absoluteString, "https://github.com/TheKontextCo/embers")
        XCTAssertEqual(ReleaseInformation.issueURL.absoluteString, "https://github.com/TheKontextCo/embers/issues/new")
        XCTAssertEqual(ReleaseInformation.securityURL.absoluteString, "https://github.com/TheKontextCo/embers/security")
        XCTAssertEqual(
            ReleaseInformation.url(
                for: "EmbersIssueURL",
                metadata: ["EmbersIssueURL": "https://example.invalid/issues"],
                fallback: ReleaseInformation.issueURL
            ).absoluteString,
            "https://example.invalid/issues"
        )
    }

    func testVersionAndBuildUseBundleMetadataWithReleaseFallbacks() {
        XCTAssertEqual(ReleaseInformation.version(metadata: [:]), "0.1.0")
        XCTAssertEqual(ReleaseInformation.build(metadata: [:]), "1")
        XCTAssertEqual(ReleaseInformation.version(metadata: ["CFBundleShortVersionString": "2.3.4"]), "2.3.4")
        XCTAssertEqual(ReleaseInformation.build(metadata: ["CFBundleVersion": "42"]), "42")
    }
}
