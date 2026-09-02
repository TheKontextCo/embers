import Foundation
import CoreServices

enum FolderChangeEventPolicy {
    static let streamCreateFlags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot
    )

    private static let contentMutationFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed
            | kFSEventStreamEventFlagItemModified
    )
    private static let recoveryFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount
    )

    static func shouldRefresh(relativePath: String, flags: FSEventStreamEventFlags) -> Bool {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { return false }
        if flags & recoveryFlags != 0 { return true }
        guard flags & contentMutationFlags != 0 else { return false }

        let normalized = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return false }
        let components = normalized.split(separator: "/").map(String.init)
        let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        guard !FolderSourcePathPolicy.shouldIgnore(components: components, isDirectory: isDirectory) else { return false }
        if isDirectory { return true }
        return FolderSourcePathPolicy.isManifest(normalized)
            || FolderSourcePathPolicy.isSupportedContentFile(normalized)
    }
}

public final class FSEventsChangeMonitor: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(url: URL) { self.url = url }
    deinit { stop() }

    public func events() -> AsyncStream<Void> {
        // A directory move or deletion can produce filesystem events much
        // faster than a graph rebuild can consume them. Only the newest
        // pending signal matters because every refresh scans the full source.
        // Keeping this bounded prevents an event burst from queuing hundreds
        // of redundant rebuilds and making source removal appear to hang.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock(); continuations[id] = continuation; let shouldStart = stream == nil; lock.unlock()
            if shouldStart { start() }
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    private func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<FSEventsChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray
            for index in 0..<count {
                guard let path = paths[index] as? String else { continue }
                monitor.emit(path: path, flags: flags[index])
            }
        }
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            FolderChangeEventPolicy.streamCreateFlags
        ) else { return }
        lock.lock(); stream = created; lock.unlock()
        FSEventStreamSetDispatchQueue(created, DispatchQueue(label: "app.embers.folder-events"))
        FSEventStreamStart(created)
    }

    private func emit(path: String, flags: FSEventStreamEventFlags) {
        let rootPath = url.standardizedFileURL.path
        let eventPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard eventPath == rootPath || eventPath.hasPrefix(rootPath + "/") else { return }
        let relativePath = String(eventPath.dropFirst(rootPath.count))
        guard FolderChangeEventPolicy.shouldRefresh(relativePath: relativePath, flags: flags) else { return }
        yieldChange()
    }

    private func yieldChange() {
        lock.lock(); let current = Array(continuations.values); lock.unlock()
        current.forEach { $0.yield(()) }
    }

    private func remove(_ id: UUID) {
        lock.lock(); continuations.removeValue(forKey: id); let empty = continuations.isEmpty; lock.unlock()
        if empty { stop() }
    }

    private func stop() {
        lock.lock(); let current = stream; stream = nil; lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current); FSEventStreamInvalidate(current); FSEventStreamRelease(current)
    }
}
