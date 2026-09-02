import Foundation

protocol RecentAccessStore: AnyObject {
    func accessDates() -> [String: Date]
    func markAccessed(_ artifactID: String, at date: Date)
}

extension RecentAccessStore {
    func markAccessed(_ artifactID: String) { markAccessed(artifactID, at: Date()) }
}

final class InMemoryRecentAccess: RecentAccessStore {
    private var dates: [String: Date]

    init(_ dates: [String: Date] = [:]) { self.dates = dates }
    func accessDates() -> [String: Date] { dates }
    func markAccessed(_ artifactID: String, at date: Date) { dates[artifactID] = date }
}

final class UserDefaultsRecentAccess: RecentAccessStore {
    private let defaults: UserDefaults
    private let key = "recentArtifactAccesses.v1"
    private let capacity = 200

    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }

    func accessDates() -> [String: Date] {
        (defaults.dictionary(forKey: key) ?? [:]).compactMapValues { value in
            (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        }
    }

    func markAccessed(_ artifactID: String, at date: Date) {
        var dates = accessDates()
        dates[artifactID] = date
        let retained = dates.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(capacity)
        defaults.set(
            Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value.timeIntervalSince1970) }),
            forKey: key
        )
    }
}
