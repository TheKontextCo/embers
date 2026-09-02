import Foundation
import EmbersCore
import EmbersLocal
import EmbersPluginKit

/// Serialize explicit refreshes and watcher follow-ups for one configured source.
/// Every request checks current bytes; no time-based suppression can hide an external edit.
actor FolderRefreshState {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastScan: SourceScan?
    private var lastSnapshot: ContextSnapshot?
    private let mentionCache = GraphMentionCache()
    private var taskWrites: Set<URL> = []

    func recordTaskWrite(at url: URL) { taskWrites.insert(url) }

    func refresh(_ descriptor: PluginSourceDescriptor, from source: FolderContextSource,
                 builder: DeterministicGraphBuilder) async throws -> PluginRefreshResult {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let pendingWrites = taskWrites
        taskWrites.removeAll()
        let scan: SourceScan
        if pendingWrites.count == 1, let url = pendingWrites.first {
            scan = try await source.scanAfterTaskWrite(at: url)
        } else {
            scan = try await source.scan()
        }
        if let lastScan, let lastSnapshot,
           scan.artifacts == lastScan.artifacts,
           scan.declarations == lastScan.declarations,
           scan.diagnostics == lastScan.diagnostics {
            // Include the authoritative snapshot so a host can retry a failed persistence
            // operation even if this provider has already cached the successful build.
            var result = PluginRefreshResult(source: descriptor, snapshot: lastSnapshot)
            result.disposition = .unchanged
            return result
        }
        var snapshot = try builder.build(from: scan, mentionCache: mentionCache)
        snapshot.artifacts = snapshot.artifacts.map { artifact in
            var artifact = artifact
            artifact.provider = .init(pluginID: FolderPlugin.identifier.rawValue, sourceID: descriptor.id.rawValue)
            return artifact
        }
        lastScan = scan
        lastSnapshot = snapshot
        return .init(source: descriptor, snapshot: snapshot)
    }

    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }

    private func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
}
