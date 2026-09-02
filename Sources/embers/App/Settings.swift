//  Settings.swift
//  User preferences, persisted in UserDefaults. A single observable source the views bind
//  to and the behavior reads from. Each property writes through on change; a few have side
//  effects (launch-at-login registration).

import AppKit
import Foundation
import ServiceManagement

extension Notification.Name {
    static let embersDisplayChanged = Notification.Name("embers.displayChanged")
}

/// The states reported by the system login-item service, plus a transient failure while
/// attempting to change that state. Keeping this separate from preferences means the UI
/// never claims an item is enabled just because the user previously asked for it.
enum LaunchAtLoginStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case error(String)

    var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .notRegistered:
            return "Off"
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Approval required in Login Items"
        case .notFound:
            return "Unavailable in this app build"
        case .error(let description):
            return "Couldn’t update: \(description)"
        }
    }

    var shouldOfferLoginItemsSettings: Bool {
        switch self {
        case .requiresApproval, .notFound, .error:
            return true
        case .notRegistered, .enabled:
            return false
        }
    }
}

/// A deliberately small adapter around `SMAppService` so login-item behavior can be
/// verified without talking to the user's actual Login Items configuration.
@MainActor
protocol LaunchAtLoginService {
    var currentLaunchAtLoginStatus: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginService {
    var currentLaunchAtLoginStatus: LaunchAtLoginStatus {
        switch status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .error("The system returned an unknown Login Items status.")
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let d: UserDefaults
    private let launchAtLoginService: any LaunchAtLoginService
    private var activationObserver: NSObjectProtocol?

    // MARK: Listening
    @Published var listenOnLaunch: Bool { didSet { d.set(listenOnLaunch, forKey: "listenOnLaunch") } }
    @Published var muteHotkeyEnabled: Bool { didSet { d.set(muteHotkeyEnabled, forKey: "muteHotkeyEnabled") } }

    // MARK: Notch
    /// Stable UUID-backed id of the chosen display; empty = the screen with the notch (or main).
    @Published var displayIdentifier: String {
        didSet {
            d.set(displayIdentifier, forKey: "displayIdentifier")
            NotificationCenter.default.post(name: .embersDisplayChanged, object: nil)
        }
    }

    // MARK: General
    /// The last state returned by macOS. This is the authority for the toggle.
    @Published private(set) var launchAtLoginServiceStatus: LaunchAtLoginStatus
    /// A transient explanation of a failed register/unregister request.
    @Published private(set) var launchAtLoginError: String?
    var launchAtLoginStatus: LaunchAtLoginStatus {
        if let launchAtLoginError { return .error(launchAtLoginError) }
        return launchAtLoginServiceStatus
    }
    var launchAtLogin: Bool { launchAtLoginServiceStatus.isEnabled }

    init(
        defaults: UserDefaults = .standard,
        appService: any LaunchAtLoginService = SMAppService.mainApp,
        displays: [DisplayPlacement] = NSScreen.embersDisplayPlacements.map(\.placement)
    ) {
        self.d = defaults
        self.launchAtLoginService = appService
        listenOnLaunch    = d.object(forKey: "listenOnLaunch") as? Bool ?? false
        muteHotkeyEnabled = d.object(forKey: "muteHotkeyEnabled") as? Bool ?? true
        let storedDisplayIdentifier = d.string(forKey: "displayIdentifier")
        if let storedDisplayIdentifier {
            displayIdentifier = storedDisplayIdentifier
        } else if let legacyLocalizedName = d.string(forKey: "displayID"),
                  let migratedIdentifier = DisplayPlacementPolicy.migratedIdentifier(
                    legacyLocalizedName: legacyLocalizedName,
                    displays: displays
                  ) {
            displayIdentifier = migratedIdentifier
            d.set(migratedIdentifier, forKey: "displayIdentifier")
        } else {
            // A legacy name with duplicate matches must not choose an arbitrary monitor.
            // The old key is left intact for diagnostics, but placement safely uses Automatic.
            displayIdentifier = ""
        }
        for retiredKey in ["reduceMotion", "hoverOpenMs", "peekSeconds", "semanticVoiceMatching", "speechLocaleIdentifier"] {
            defaults.removeObject(forKey: retiredKey)
        }
        launchAtLoginServiceStatus = appService.currentLaunchAtLoginStatus
        launchAtLoginError = nil
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLaunchAtLoginStatus()
            }
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginServiceStatus = launchAtLoginService.currentLaunchAtLoginStatus
        launchAtLoginError = nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try launchAtLoginService.register()
            } else {
                try launchAtLoginService.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            Log.app.error("launch_at_login_update_failed")
            // Re-read macOS before reporting the error: an unregister failure can leave
            // the item enabled, and the toggle must continue to show that truth.
            launchAtLoginServiceStatus = launchAtLoginService.currentLaunchAtLoginStatus
            launchAtLoginError = error.localizedDescription
        }
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }
}
