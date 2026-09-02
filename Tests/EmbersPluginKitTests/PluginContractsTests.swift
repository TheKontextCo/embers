import XCTest
@testable import EmbersCore
@testable import EmbersPluginKit

final class PluginContractsTests: XCTestCase {
    func testNamespacedIdentifiersAreStableAndRoundTripProviderCharacters() throws {
        let plugin = try XCTUnwrap(PluginIdentifier(rawValue: "kontext"))
        let source = PluginSourceIdentifier(pluginID: plugin, sourceID: "account:sample/user")
        let entity = PluginEntityIdentifier(source: source, kind: "document", externalID: "doc:abc/123")

        XCTAssertEqual(source.rawValue, "kontext:source:account%3Asample%2Fuser")
        XCTAssertEqual(entity.rawValue, "kontext:source:account%3Asample%2Fuser:document:doc%3Aabc%2F123")
        XCTAssertEqual(PluginSourceIdentifier(rawValue: source.rawValue), source)
        XCTAssertEqual(PluginEntityIdentifier(rawValue: entity.rawValue), entity)
        XCTAssertNil(PluginIdentifier(rawValue: "not a plugin"))
    }

    func testProviderDeclarationsProjectMembershipAndAuthoredRelations() throws {
        let artifact = SourceArtifact(
            id: "kontext:source:account:document:one",
            relativePath: "Projects/Apollo",
            mediaKind: .text,
            title: "Apollo brief",
            extractedText: "",
            modifiedAt: .distantPast,
            contentHash: "one",
            location: .provider(pluginID: "kontext", externalID: "document:one")
        )
        let declarations = ContextDeclarations(
            contexts: [
                .init(id: "kontext:source:account:project:apollo", name: "Apollo", artifactIDs: [artifact.id]),
                .init(id: "kontext:source:account:team:product", name: "Product")
            ],
            relations: [.init(from: "kontext:source:account:project:apollo", to: "kontext:source:account:team:product", kind: "belongs-to", detail: "provider")]
        )

        let snapshot = try DeterministicGraphBuilder().build(from: .init(sourceID: "kontext:source:account", artifacts: [artifact], declarations: declarations, diagnostics: [], indexedAt: .distantPast))

        XCTAssertEqual(snapshot.anchors.first(where: { $0.id == "kontext:source:account:project:apollo" })?.memberArtifactIDs, [artifact.id])
        XCTAssertTrue(snapshot.relations.contains {
            $0.source == "kontext:source:account:project:apollo" && $0.target == "kontext:source:account:team:product" && $0.evidence == .authored && $0.provenance.detail == "provider"
        })
    }

    func testNonFileLocationsAndPluginDescriptorRoundTripCodable() throws {
        let artifact = SourceArtifact(
            id: "remote",
            relativePath: "Remote document",
            mediaKind: .text,
            title: "Remote document",
            extractedText: "text",
            modifiedAt: .distantPast,
            contentHash: "hash",
            location: .web(try XCTUnwrap(URL(string: "https://app.kontext.example/doc/1")))
        )
        let decodedArtifact = try JSONDecoder().decode(SourceArtifact.self, from: JSONEncoder().encode(artifact))
        XCTAssertEqual(decodedArtifact.location, artifact.location)
        XCTAssertNil(decodedArtifact.localURL)

        let plugin = try XCTUnwrap(PluginIdentifier(rawValue: "kontext"))
        let descriptor = PluginDescriptor(id: plugin, displayName: "Kontext", version: "1", capabilities: [.connection, .sourceRefresh, .artifactActions])
        XCTAssertEqual(try JSONDecoder().decode(PluginDescriptor.self, from: JSONEncoder().encode(descriptor)), descriptor)
    }

    func testLegacyArtifactLocalURLDecodesAsAFileLocation() throws {
        let data = Data(#"{"id":"legacy","relativePath":"Legacy.md","mediaKind":"markdown","title":"Legacy","extractedText":"","modifiedAt":0,"contentHash":"hash","localURL":"file:///tmp/Legacy.md","metadata":{"aliases":[],"tags":[],"headings":[],"links":[],"uncheckedTasks":[]}}"#.utf8)
        let artifact = try JSONDecoder().decode(SourceArtifact.self, from: data)

        XCTAssertEqual(artifact.location, .file(URL(fileURLWithPath: "/tmp/Legacy.md")))
        XCTAssertEqual(artifact.localURL, URL(fileURLWithPath: "/tmp/Legacy.md"))
    }
}
