import AppKit

/// Observes right-clicks delivered to Embers' own windows. Unlike a global
/// monitor, this sees no activity in other applications and needs no additional
/// privacy permission.
@MainActor
final class SecondaryClickMonitor {
    private var local: Any?
    private let addLocalMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let removeMonitor: (Any) -> Void

    init(
        addLocalMonitor: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = { handler in
            NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: handler)
        },
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
    ) {
        self.addLocalMonitor = addLocalMonitor
        self.removeMonitor = removeMonitor
    }

    func start(_ handler: @escaping (NSEvent) -> Bool) {
        guard local == nil else { return }
        local = addLocalMonitor { event in
            handler(event) ? nil : event
        }
    }

    func stop() {
        if let local { removeMonitor(local) }
        local = nil
    }

    deinit {
        if let local { removeMonitor(local) }
    }
}
