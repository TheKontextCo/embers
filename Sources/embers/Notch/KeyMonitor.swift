//  KeyMonitor.swift
//  Arrow/Escape capture for a keyboard-focused Embers panel. This is deliberately an
//  app-local monitor: macOS only delivers it while Embers is active, so the app never
//  observes keys typed into another application and does not need Accessibility or Input
//  Monitoring permission. The monitor exists only after an explicit user interaction has
//  promoted the notch panel to a key window, and is removed when that focus ends.

import AppKit

@MainActor
final class KeyMonitor {
    enum Key { case left, right, up, down, escape }

    private var local: Any?
    private var handler: ((Key) -> Void)?
    private let addLocalMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let removeMonitor: (Any) -> Void

    init(
        addLocalMonitor: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = { handler in
            NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        },
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
    ) {
        self.addLocalMonitor = addLocalMonitor
        self.removeMonitor = removeMonitor
    }

    func start(_ handler: @escaping (Key) -> Void) {
        guard local == nil else { return }
        self.handler = handler

        local = addLocalMonitor { [weak self] event in
            guard let key = Self.map(event) else { return event }
            self?.handler?(key)
            return nil // Swallow handled navigation keys so AppKit does not beep.
        }
    }

    func stop() {
        if let local { removeMonitor(local) }
        local = nil
        handler = nil
    }

    deinit {
        if let local { removeMonitor(local) }
    }

    private static func map(_ event: NSEvent) -> Key? {
        switch event.keyCode {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 53:  return .escape
        default:  return nil
        }
    }
}
