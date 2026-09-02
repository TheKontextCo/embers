//  HoverMonitor.swift
//  Notch hover detection that works even when embers isn't the active app. SwiftUI's
//  .onHover only fires while the app is frontmost — useless for an accessory overlay you
//  hover from inside another app. Instead we watch the global cursor position against the
//  notch's screen rect (global + local mouse-moved monitors, plus a low-frequency timer
//  fallback) and report enter/leave, debounced.

import AppKit

@MainActor
final class HoverMonitor {
    private var monitors: [Any] = []
    private var timer: Timer?
    private var inside = false
    private var reportedInside = false
    private var debounce: Task<Void, Never>?

    private var region: (() -> CGRect)?
    private var onChange: ((Bool) -> Void)?
    /// Re-entering during the exit delay cancels the pending close, keeping the
    /// interaction fully interruptible.
    private let enterDelayMs = 180
    private let exitDelayMs = 500

    func start(region: @escaping () -> CGRect, onChange: @escaping (Bool) -> Void) {
        stop()
        self.region = region
        self.onChange = onChange

        let bump: (NSEvent?) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.evaluate() }
        }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { bump($0) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { e in bump(e); return e }) { monitors.append(l) }
        // Fallback: catches motion that produced no monitored event (e.g. a fast jump in).
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.evaluate() }
        }
        evaluate()
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        timer?.invalidate(); timer = nil
        debounce?.cancel(); debounce = nil
        inside = false
        reportedInside = false
    }

    /// An explicit click can open the notch before the debounced enter callback
    /// fires. Treat that as a completed enter so the subsequent mouse exit is
    /// still reported and can collapse the panel.
    func armExitIfPointerInside() {
        guard (region?() ?? .zero).contains(NSEvent.mouseLocation) else { return }
        armExit()
    }

    /// A SwiftUI label hover has already established that the pointer is inside, even if
    /// the global-coordinate region changes while the notch expands around that pointer.
    func armExit() {
        debounce?.cancel()
        debounce = nil
        inside = true
        reportedInside = true
    }

    private func evaluate() {
        let now = (region?() ?? .zero).contains(NSEvent.mouseLocation)
        guard now != inside else { return }
        inside = now
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            let delay = now ? (self?.enterDelayMs ?? 180) : (self?.exitDelayMs ?? 500)
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self, self.inside == now else { return }
            guard self.reportedInside != now else { return }
            self.reportedInside = now
            self.onChange?(now)
        }
    }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }
}
