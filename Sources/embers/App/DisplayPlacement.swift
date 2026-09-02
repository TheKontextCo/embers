// DisplayPlacement.swift
// Stable display identity and selection policy for the notch window.

import AppKit
import CoreGraphics
import Foundation

/// A display represented by a persistent identifier and a human-readable name.
///
/// `persistentIdentifier` is deliberately not the localized name: users can attach two
/// identical monitors, change the system language, or rename a display. A display UUID is
/// stable across those changes. The numeric display identifier is a last-resort fallback
/// for hardware where macOS cannot supply a UUID.
struct DisplayPlacement: Equatable, Hashable, Identifiable {
    let persistentIdentifier: String
    let localizedName: String
    let displayNumber: UInt32

    var id: String { persistentIdentifier }

    init(persistentIdentifier: String, localizedName: String, displayNumber: UInt32) {
        self.persistentIdentifier = persistentIdentifier
        self.localizedName = localizedName
        self.displayNumber = displayNumber
    }

    init(displayNumber: UInt32, localizedName: String, uuidString: String?) {
        self.init(
            persistentIdentifier: Self.persistentIdentifier(displayNumber: displayNumber, uuidString: uuidString),
            localizedName: localizedName,
            displayNumber: displayNumber
        )
    }

    static func persistentIdentifier(displayNumber: UInt32, uuidString: String?) -> String {
        if let uuidString, !uuidString.isEmpty {
            return "display-uuid:\(uuidString.lowercased())"
        }
        return "display-id:\(displayNumber)"
    }
}

/// Pure policy keeps persistence migration and missing-display behavior testable without
/// asking AppKit for the user's actual monitor configuration.
enum DisplayPlacementPolicy {
    /// Migrates the previous localized-name preference only if it names exactly one current
    /// display. Ambiguous duplicate names intentionally fall back to Automatic.
    static func migratedIdentifier(legacyLocalizedName: String, displays: [DisplayPlacement]) -> String? {
        let matches = displays.filter { $0.localizedName == legacyLocalizedName }
        guard matches.count == 1 else { return nil }
        return matches[0].persistentIdentifier
    }

    /// Uses a persisted stable identifier when its display is present. A disconnected display
    /// is kept in preferences so reconnecting it restores the user's choice; callers use the
    /// automatic fallback for the current placement in the meantime.
    static func selectedDisplay(savedIdentifier: String, displays: [DisplayPlacement]) -> DisplayPlacement? {
        guard !savedIdentifier.isEmpty else { return nil }
        return displays.first { $0.persistentIdentifier == savedIdentifier }
    }

    /// Resolves a present saved choice or the current automatic display. This is intentionally
    /// non-destructive: a missing saved identifier remains persisted for a future reconnect.
    static func resolvedDisplay(
        savedIdentifier: String,
        displays: [DisplayPlacement],
        automaticDisplay: DisplayPlacement?
    ) -> DisplayPlacement? {
        selectedDisplay(savedIdentifier: savedIdentifier, displays: displays) ?? automaticDisplay
    }

    static func displayLabel(for display: DisplayPlacement, among displays: [DisplayPlacement]) -> String {
        let duplicateCount = displays.filter { $0.localizedName == display.localizedName }.count
        guard duplicateCount > 1 else { return display.localizedName }
        return "\(display.localizedName) • Display \(display.displayNumber)"
    }
}

extension NSScreen {
    /// The CoreGraphics display UUID is the persistent identity used for the preference.
    /// `NSScreenNumber` remains available as a safe fallback on uncommon display drivers.
    var embersDisplayPlacement: DisplayPlacement? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = deviceDescription[key] as? NSNumber else { return nil }
        let displayNumber = number.uint32Value
        let displayID = CGDirectDisplayID(displayNumber)
        let uuidString = CGDisplayCreateUUIDFromDisplayID(displayID)
            .map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
        return DisplayPlacement(
            displayNumber: displayNumber,
            localizedName: localizedName,
            uuidString: uuidString
        )
    }

    static var embersDisplayPlacements: [(screen: NSScreen, placement: DisplayPlacement)] {
        screens.compactMap { screen in
            screen.embersDisplayPlacement.map { (screen, $0) }
        }
    }
}
