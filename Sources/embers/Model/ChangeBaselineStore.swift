import Foundation
import EmbersCore

protocol ChangeBaselineStore: AnyObject {
    func baseline(for scope: ContextChangeScope) -> ContextChangeBaseline?
    func save(_ baseline: ContextChangeBaseline)
    func removeBaseline(for scope: ContextChangeScope)
    func removeBaselines(forSourceID sourceID: String)
}

/// Persists one immutable content-revision baseline per source and context.
/// Invalid data is treated as no prior peek so corruption cannot manufacture
/// change results or leak history between scopes.
final class UserDefaultsChangeBaselineStore: ChangeBaselineStore {
    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(
        _ defaults: UserDefaults = .standard,
        storageKey: String = "changedSinceLastPeek.baselines.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func baseline(for scope: ContextChangeScope) -> ContextChangeBaseline? {
        lock.withLock { decodedBaselines()[scope] }
    }

    func save(_ baseline: ContextChangeBaseline) {
        lock.withLock {
            var baselines = decodedBaselines()
            baselines[baseline.scope] = baseline
            persist(baselines)
        }
    }

    func removeBaseline(for scope: ContextChangeScope) {
        lock.withLock {
            var baselines = decodedBaselines()
            baselines.removeValue(forKey: scope)
            persist(baselines)
        }
    }

    func removeBaselines(forSourceID sourceID: String) {
        lock.withLock {
            let retained = decodedBaselines().filter { $0.key.sourceID != sourceID }
            persist(retained)
        }
    }

    private func decodedBaselines() -> [ContextChangeScope: ContextChangeBaseline] {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? decoder.decode([ContextChangeBaseline].self, from: data)
        else { return [:] }
        return Dictionary(stored.map { ($0.scope, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func persist(_ baselines: [ContextChangeScope: ContextChangeBaseline]) {
        let ordered = baselines.values.sorted {
            if $0.scope.sourceID != $1.scope.sourceID {
                return $0.scope.sourceID < $1.scope.sourceID
            }
            return $0.scope.contextID < $1.scope.contextID
        }
        guard let data = try? encoder.encode(ordered) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
