import Foundation

public enum StableHash {
    public static func hex(_ string: String) -> String { hex(Data(string.utf8)) }
    public static func hex(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }
}

public extension String {
    var embersNormalized: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }
}
