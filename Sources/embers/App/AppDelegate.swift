//  AppDelegate.swift
//  Creates the notch panel, sizes it to the open footprint, measures the closed notch
//  for the active screen, and keeps it centered when the display config changes.

import AppKit
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let singleton = ProcessSingleton()
    private var window: NotchWindow?
    private let app = AppCompositionRoot.app

    func applicationWillFinishLaunching(_ notification: Notification) {
        if isDebuggerAttached || ProcessInfo.processInfo.environment["EMBERS_XCODE_RUN"] == "1" {
            let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.embers.app")
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            existing.forEach { $0.terminate() }
            if !existing.isEmpty {
                for _ in 0..<40 {
                    if singleton.acquire() {
                        Log.app.info("development_instance_replaced")
                        return
                    }
                    usleep(50_000)
                }
            }
        }
        guard singleton.acquire() else {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.embers.app")
                .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
                .activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
    }

    /// Xcode can run Embers through either the project scheme or SwiftPM's generated
    /// scheme. Detect LLDB directly so both launch paths replace a detached menu-bar
    /// instance and leave the debugger attached to the process doing the real work.
    private var isDebuggerAttached: Bool {
        var processInfo = kinfo_proc()
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let queryCount = UInt32(query.count)
        var processInfoSize = MemoryLayout<kinfo_proc>.stride
        let result = query.withUnsafeMutableBufferPointer { queryBuffer in
            sysctl(queryBuffer.baseAddress, queryCount, &processInfo, &processInfoSize, nil, 0)
        }
        return result == 0 && (processInfo.kp_proc.p_flag & P_TRACED) != 0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard singleton.ownsLock else { return }
        removeObsoleteGraphEnrichmentData()
        NSApp.setActivationPolicy(.accessory)

        let rect = NSRect(origin: .zero, size: NotchMetrics.windowSize)
        let window = NotchWindow(contentRect: rect)
        let container = NSView(frame: rect)
        let hostingView = NSHostingView(rootView: RootView(app: app))
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.setContentSize(NotchMetrics.windowSize)
        self.window = window
        app.hostWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(notchWindowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )

        reposition()
        window.orderFrontRegardless()
        app.startNotchHover()
        Log.app.info("application_launched")

        if ProcessInfo.processInfo.environment["EMBERS_DEMO"] != nil {
            app.runDemo()
        }
        if let goto = ProcessInfo.processInfo.environment["EMBERS_GOTO"] {
            app.runTour(goto)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: .embersDisplayChanged, object: nil)
    }

    private func removeObsoleteGraphEnrichmentData() {
        UserDefaults.standard.removeObject(forKey: "localLLMConfiguration")
        let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Embers", isDirectory: true)
            .appendingPathComponent("local-llm-cache.json")
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        do { try FileManager.default.removeItem(at: cacheURL) }
        catch { Log.app.error("obsolete_graph_enrichment_cache_delete_failed") }
    }

    @objc private func screenChanged() { reposition() }

    @objc private func notchWindowDidResignKey(_ notification: Notification) {
        app.deactivateKeyboardNavigation()
    }

    func reposition() {
        guard let window else { return }
        let displays = NSScreen.embersDisplayPlacements
        let automaticDisplay = displays.first { $0.screen.safeAreaInsets.top > 0 }?.placement
        let preferredDisplay = DisplayPlacementPolicy.resolvedDisplay(
            savedIdentifier: Settings.shared.displayIdentifier,
            displays: displays.map(\.placement),
            automaticDisplay: automaticDisplay
        )
        let screen = preferredDisplay.flatMap { selected in
            displays.first { $0.placement.persistentIdentifier == selected.persistentIdentifier }?.screen
        }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        app.notch.closedSize = NotchMetrics.closedSize(for: screen)
        app.notch.physicalExclusionSize = NotchMetrics.physicalExclusionSize(for: screen)
        window.setFrameOrigin(NotchMetrics.origin(for: window, on: screen))
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCompositionRoot.oauthBrowser.cancel()
        app.speech.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if AppCompositionRoot.oauthBrowser.handleCallback(url) {
                application.activate(ignoringOtherApps: true)
            }
        }
    }
}

private final class ProcessSingleton {
    private var descriptor: Int32 = -1
    private(set) var ownsLock = false

    func acquire() -> Bool {
        guard !ownsLock else { return true }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.embers.app.\(getuid()).lock").path
        descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
            return false
        }
        ownsLock = true
        return true
    }

    deinit {
        if descriptor >= 0 {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }
}
