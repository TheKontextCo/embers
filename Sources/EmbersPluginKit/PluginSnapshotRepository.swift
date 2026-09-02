import EmbersCore

/// Persists each source independently. A source cache is deliberately not the
/// workspace cache: one provider becoming unavailable must never evict another
/// provider's last verified graph.
public protocol PluginSnapshotRepository: Sendable {
    func load(for source: PluginSourceIdentifier) async -> ContextSnapshot?
    func replace(_ snapshot: ContextSnapshot, for source: PluginSourceIdentifier) async throws
    func remove(source: PluginSourceIdentifier) async throws
}
