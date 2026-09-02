import XCTest
import AppKit
import SwiftUI
@testable import embers

final class IndexingTrailGraphTests: XCTestCase {
    func testGraphIsDeterministicBoundedAndParentFirst() {
        let first = IndexingTrailGraph.graph
        let second = IndexingTrailGraph.graph

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.nodes.count, 72)
        XCTAssertNil(first.nodes.first?.parentID)

        var seen = Set<Int>()
        for node in first.nodes {
            XCTAssertTrue((0 ... 1).contains(node.x))
            XCTAssertTrue((0 ... 1).contains(node.y))
            if let parentID = node.parentID {
                XCTAssertTrue(seen.contains(parentID), "Node \(node.id) must follow its parent")
            }
            seen.insert(node.id)
        }

        for edge in first.edges {
            XCTAssertTrue(seen.contains(edge.startID))
            XCTAssertTrue(seen.contains(edge.endID))
            XCTAssertNotEqual(edge.startID, edge.endID)
        }
    }

    @MainActor
    func testIndexingViewRendersAtNotchSize() throws {
        let renderer = ImageRenderer(
            content: IndexingTrailView(initialNodeCount: 15)
                .frame(width: NotchMetrics.openSize.width, height: NotchMetrics.openSize.height - 47)
                .background(Style.panelFill)
        )
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, Int(NotchMetrics.openSize.width * 2))
        XCTAssertEqual(image.height, Int((NotchMetrics.openSize.height - 47) * 2))

        if let capturePath = ProcessInfo.processInfo.environment["EMBERS_CAPTURE_INDEXING_TRAIL"],
           let representation = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try representation.write(to: URL(fileURLWithPath: capturePath), options: .atomic)
        }
    }
}
