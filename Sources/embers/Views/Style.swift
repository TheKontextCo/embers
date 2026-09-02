//  Style.swift
//  Design tokens for embers. The aesthetic: dark Liquid Glass (shiny, substantial — not
//  see-through) with a warm ember accent and a specular top gleam.

import SwiftUI

enum Style {
    // Spacing scale
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 22
    static let xxl: CGFloat = 28

    // Radii
    static let chip: CGFloat = 13
    static let card: CGFloat = 16

    // Ember accent
    static let ember = LinearGradient(
        colors: [Color(red: 1.00, green: 0.60, blue: 0.24), Color(red: 1.00, green: 0.36, blue: 0.30)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let emberSolid = Color(red: 1.00, green: 0.49, blue: 0.27)
    static let emberGlow = Color(red: 1.00, green: 0.42, blue: 0.22)

    /// Green glow that haloes the notch while embers is actively listening.
    static let listenGlow = Color(red: 0.26, green: 0.92, blue: 0.45)
    /// Quiet ember-orange edge when listening is disabled.
    static let listenIdle = Color(red: 0.96, green: 0.48, blue: 0.18)

    /// Dark warm tint applied to glass so the surface reads as a solid object with a
    /// gleam rather than a transparent pane.
    static let glassTint = Color(red: 0.06, green: 0.05, blue: 0.06).opacity(0.55)

    /// The open panel's fill — solid, opaque, bleeding from the hardware-black notch.
    /// Pure black at the top (where it meets the cutout) easing to a hair of warmth below.
    static let notchSurface = LinearGradient(
        colors: [.black, Color(red: 0.07, green: 0.07, blue: 0.08)],
        startPoint: .top, endPoint: .bottom)

    /// Thin specular highlight raked across the top edge of glass surfaces.
    static let gleam = LinearGradient(
        colors: [.white.opacity(0.55), .white.opacity(0.06), .clear],
        startPoint: .top, endPoint: .bottom)

    /// Subtle translucent fill for controls *inside* a glass surface (avoid glass-on-glass).
    static let innerFill = Color.white.opacity(0.06)
    static let innerFillHover = Color.white.opacity(0.12)

    // MARK: - Dashboard palette
    static let panelFill = Color(red: 0.075, green: 0.078, blue: 0.098)   // #131419
    static let cardFill  = Color(red: 0.094, green: 0.102, blue: 0.125)   // #181a20
    static let hairline  = Color.white.opacity(0.08)
    static let ember2    = Color(red: 0.878, green: 0.573, blue: 0.180)   // #E0922E
    static let emberHi   = Color(red: 1.00,  green: 0.541, blue: 0.298)   // #ff8a4c
    static let green2    = Color(red: 0.275, green: 0.824, blue: 0.478)   // #46d27a
    static let amber2    = Color(red: 1.00,  green: 0.827, blue: 0.416)   // #ffd36a
    static let blue2     = Color(red: 0.420, green: 0.659, blue: 1.00)    // #6ba8ff
    static let inkMut    = Color.white.opacity(0.56)
    static let inkDim    = Color.white.opacity(0.34)

    // MARK: - Stage colours
    /// 20 evenly-spaced, vivid hues — legible on the dark panel. Teams use any stage vocabulary
    /// (building / discovery / concept / planning / research / …), so we DON'T enumerate stages:
    /// each status string is hashed into this palette, guaranteeing the same status always gets
    /// the same colour. (With 20 colours, >20 distinct statuses must eventually share one — but
    /// the mapping is always stable per status.)
    static let stagePalette: [Color] = (0 ..< 20).map {
        Color(hue: Double($0) / 20.0, saturation: 0.62, brightness: 0.95)
    }

    /// Stable colour for a status. Hashes the normalised string (FNV-1a, deterministic across
    /// launches — unlike Swift's per-process `hashValue`) into `stagePalette`.
    static func stageColor(_ raw: String?) -> Color {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty
        else { return inkDim }
        var h: UInt64 = 1469598103934665603                       // FNV-1a 64-bit offset basis
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }  // ×FNV prime, wrapping
        return stagePalette[Int(h % UInt64(stagePalette.count))]
    }
}

extension View {
    /// A hairline gleam stroke around a shape, in additive blend for a wet-glass edge.
    func gleamEdge(_ shape: some Shape, on: Bool = true) -> some View {
        overlay(shape.stroke(Style.gleam, lineWidth: 0.9)
            .blendMode(.plusLighter)
            .opacity(on ? 0.9 : 0))
    }
}
