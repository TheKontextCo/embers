//  PeekArea.swift
//  Peeks are NOT a separate element — they are the notch itself growing. The closed notch
//  is one continuous black shape (NotchFlareShape) that is the hardware-notch width at the
//  screen edge and flares outward, lower down, to hold up to three context labels. As peeks
//  enter, that single shape widens and lengthens — the notch getting bigger uniformly — with
//  no seam or gap. Hovering a label deep-opens that context.

import SwiftUI

struct PeekPresentationPolicy: Sendable {
    func displayedPeeks(_ peeks: [Peek], notchIsOpen: Bool) -> [Peek] {
        // Expanded detail owns the surface; keep queued candidates for the closed notch.
        notchIsOpen ? [] : peeks
    }
}

/// One continuous notch silhouette: `topWidth` at the very top (the hardware-notch width),
/// holding that width for `straightTop`, then flaring with concave shoulders out to the full
/// rect width over `flareLength`, straight down the sides, to a rounded bottom. Used for BOTH
/// the closed (notch/peek) state and the open walker — only the parameters differ — so the
/// whole thing morphs as one shape from notch → peeks → open.
struct NotchFlareShape: Shape {
    var topWidth: CGFloat
    var straightTop: CGFloat
    var flareLength: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(topWidth, straightTop), .init(flareLength, bottomRadius)) }
        set {
            topWidth = newValue.first.first
            straightTop = newValue.first.second
            flareLength = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let topHalf = min(topWidth, rect.width) / 2
        let nl = cx - topHalf
        let nr = cx + topHalf
        let br = min(bottomRadius, rect.height / 2, rect.width / 2)
        let fs = rect.minY + min(straightTop, rect.height - br)        // flare start
        let fe = min(fs + flareLength, rect.maxY - br)                  // flare end (full width)

        var p = Path()
        p.move(to: CGPoint(x: nl, y: rect.minY))
        p.addLine(to: CGPoint(x: nl, y: fs))
        p.addCurve(                                                     // left concave shoulder
            to: CGPoint(x: rect.minX, y: fe),
            control1: CGPoint(x: nl, y: fs + (fe - fs) * 0.5),
            control2: CGPoint(x: rect.minX, y: fe - (fe - fs) * 0.5))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.minX + br, y: rect.maxY),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - br),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: fe))
        p.addCurve(                                                     // right concave shoulder
            to: CGPoint(x: nr, y: fs),
            control1: CGPoint(x: rect.maxX, y: fe - (fe - fs) * 0.5),
            control2: CGPoint(x: nr, y: fs + (fe - fs) * 0.5))
        p.addLine(to: CGPoint(x: nr, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// The row of peek labels that lives in the lower (flared) band of the closed notch.
struct PeekRow: View {
    @ObservedObject var peeks: PeekQueue
    let notchIsOpen: Bool
    let onActivate: (Peek) -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var presentedPeeks: [Peek] = []

    private var reduceMotion: Bool {
        accessibilityReduceMotion || NotchViewModel.reduced
    }

    private var displayPeeks: [Peek] {
        PeekPresentationPolicy().displayedPeeks(peeks.peeks, notchIsOpen: notchIsOpen)
    }

    private var displayIDs: [String] {
        displayPeeks.map(\.id)
    }

    var body: some View {
        GeometryReader { geometry in
            let count = max(presentedPeeks.count, 1)
            let cellWidth = geometry.size.width / CGFloat(count)
            ZStack(alignment: .topLeading) {
                ForEach(Array(presentedPeeks.enumerated()), id: \.element.id) { index, peek in
                    PeekLabel(
                        peek: peek,
                        revealDelayMs: revealDelayMs(index: index, count: count),
                        entranceOffset: entranceOffset(index: index, count: count)
                    ) { onActivate(peek) }
                        .frame(width: cellWidth, height: geometry.size.height)
                        .position(
                            x: cellWidth * (CGFloat(index) + 0.5),
                            y: geometry.size.height / 2
                        )
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: displayIDs) {
            let next = displayPeeks
            let isAddingColumn = !presentedPeeks.isEmpty && next.count > presentedPeeks.count

            if isAddingColumn && !reduceMotion {
                do {
                    // Let the outer notch establish the wider physical space before the
                    // row divides into another column. Otherwise both labels briefly lay
                    // out inside the old narrow notch and clip against opposite edges.
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }

            withAnimation(NotchViewModel.peekLayout) {
                presentedPeeks = next
            }
        }
    }

    private func revealDelayMs(index: Int, count: Int) -> Int {
        guard count == 3 else { return 50 }
        return [35, 0, 70][index]
    }

    private func entranceOffset(index: Int, count: Int) -> CGSize {
        guard count == 3 else { return CGSize(width: 0, height: 4) }
        switch index {
        case 0: return CGSize(width: 4, height: 4)
        case 1: return CGSize(width: 0, height: 5)
        default: return CGSize(width: -4, height: 4)
        }
    }
}

private struct PeekLabel: View {
    let peek: Peek
    let revealDelayMs: Int
    let entranceOffset: CGSize
    let onActivate: () -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hovering = false
    @State private var revealed = false

    private var reduceMotion: Bool {
        accessibilityReduceMotion || NotchViewModel.reduced
    }

    var body: some View {
        Text(peek.title)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(hovering ? Style.emberSolid : .white.opacity(0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Style.emberSolid).frame(height: 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(revealed ? 1 : 0)
            .offset(
                x: revealed || reduceMotion ? 0 : entranceOffset.width,
                y: revealed || reduceMotion ? 0 : entranceOffset.height
            )
            .contentShape(Rectangle())
            .onHover { h in
                hovering = h
                if h { onActivate() }
            }
            .task {
                if !reduceMotion {
                    do {
                        try await Task.sleep(for: .milliseconds(revealDelayMs))
                    } catch {
                        return
                    }
                }
                withAnimation(NotchViewModel.peekReveal) {
                    revealed = true
                }
            }
    }
}
