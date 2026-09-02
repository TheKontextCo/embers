//  NotchViewModel.swift
//  The binary state machine + tuned springs. `open()`/`close()` only flip state and
//  size; the views react. Springs are asymmetric: open is snappy, close is critically
//  damped so it settles without overshoot.

import AppKit
import SwiftUI

enum NotchState { case closed, open }

/// What the open notch is focused on.
enum OpenFocus: Equatable {
    case hybrid                 // generic walk, focused on the "You" node
    case entity(String)         // deep-open an anchor by stable id — reached by hovering a peek
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var state: NotchState = .closed
    @Published var focus: OpenFocus = .hybrid

    @Published var closedSize: CGSize = NotchMetrics.fallbackClosed
    @Published var physicalExclusionSize: CGSize?

    // Embers motion follows the interaction's meaning: opening carries a trace of energy,
    // closing settles immediately, and frequent hover/navigation changes stay crisp.
    // Reduce Motion replaces spatial movement with a short, calm transition.
    /// Non-view animation owners cannot read SwiftUI's environment, so query the same
    /// macOS accessibility authority at the moment each interaction selects its curve.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private static let calm = Animation.linear(duration: 0.12)
    static var openSpring: Animation {
        reduced ? calm : .spring(duration: 0.30, bounce: 0.08)
    }
    static var closeSpring: Animation {
        reduced ? calm : .spring(duration: 0.20, bounce: 0)
    }
    static var hoverSpring: Animation { reduced ? calm : .spring(duration: 0.16, bounce: 0) }
    static var peekLayout: Animation {
        reduced ? calm : .spring(duration: 0.24, bounce: 0.04)
    }
    static var peekReveal: Animation {
        reduced ? calm : .timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
    }
    static var dashboardReveal: Animation {
        reduced ? calm : .timingCurve(0.23, 1, 0.32, 1, duration: 0.14).delay(0.10)
    }
    static var dashboardHide: Animation {
        reduced ? calm : .timingCurve(0.23, 1, 0.32, 1, duration: 0.10)
    }
    static var tabReveal: Animation {
        reduced ? calm : .spring(duration: 0.22, bounce: 0.03).delay(0.10)
    }
    static var tabHide: Animation {
        reduced ? calm : .timingCurve(0.23, 1, 0.32, 1, duration: 0.10)
    }
    /// Frequent in-panel navigation stays crisp. Motion exists only to preserve spatial
    /// continuity between a context card and its detail, never as decoration.
    static var contentNavigate: Animation {
        reduced ? calm : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    }
    static var contentReveal: Animation {
        reduced ? calm : .timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    }
    static var evidenceReveal: Animation {
        reduced ? calm : .timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
    }
    static var emphasizedEvidenceReveal: Animation {
        reduced ? calm : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    }

    func open(focus: OpenFocus = .hybrid) {
        self.focus = focus
        state = .open
    }

    func close() {
        state = .closed
        focus = .hybrid
    }

    func toggle() { state == .open ? close() : open() }

    var topRadius: CGFloat { state == .open ? NotchMetrics.openRadii.top : NotchMetrics.closedRadii.top }
    var bottomRadius: CGFloat { state == .open ? NotchMetrics.openRadii.bottom : NotchMetrics.closedRadii.bottom }
}
