import Foundation
import EmbersCore

public struct ManifestLoader: Sendable {
    public init() {}

    public func load(_ data: Data) -> (ContextManifest?, [ContextDiagnostic]) {
        var diagnostics: [ContextDiagnostic] = []
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let version = root["version"] as? Int else {
            return (nil, [.init(id: "manifest-decode", severity: .warning, message: "Could not decode the Embers manifest.", path: ".embers/context.json")])
        }
        var anchors: [ManifestAnchor] = []
        for (index, value) in (root["anchors"] as? [Any] ?? []).enumerated() {
            guard let item = value as? [String: Any], let id = item["id"] as? String, !id.isEmpty, let name = item["name"] as? String, !name.isEmpty else {
                diagnostics.append(.init(id: "manifest-anchor-\(index)", severity: .warning, message: "Ignored invalid manifest anchor at index \(index).", path: ".embers/context.json"))
                continue
            }
            let aliases = item["aliases"] as? [String] ?? []
            let paths = item["paths"] as? [String] ?? []
            anchors.append(.init(id: id, name: name, aliases: aliases, kind: item["kind"] as? String, paths: paths))
        }
        var relations: [ManifestRelation] = []
        for (index, value) in (root["relations"] as? [Any] ?? []).enumerated() {
            guard let item = value as? [String: Any], let from = item["from"] as? String, let to = item["to"] as? String, let kind = item["kind"] as? String, !from.isEmpty, !to.isEmpty, !kind.isEmpty else {
                diagnostics.append(.init(id: "manifest-relation-\(index)", severity: .warning, message: "Ignored invalid manifest relation at index \(index).", path: ".embers/context.json"))
                continue
            }
            relations.append(.init(from: from, to: to, kind: kind))
        }
        return (.init(version: version, anchors: anchors, relations: relations), diagnostics)
    }
}
