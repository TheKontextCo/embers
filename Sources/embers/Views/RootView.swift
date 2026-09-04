//  RootView.swift
//  The notch is ONE continuous black shape that grows. Closed it's the hardware-notch width;
//  as peeks arrive it widens and lengthens to hold them (the notch getting bigger, no seam);
//  open it becomes the fixed Filament walker. A single morphing container (NotchFlareShape)
//  carries all three states, so the growth reads as the notch itself, never a stacked element.

import SwiftUI

struct RootView: View {
    let app: AppState
    @ObservedObject var notch: NotchViewModel
    @ObservedObject var peeks: PeekQueue
    @ObservedObject var voiceLearning: VoiceLearningCoordinator
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    let speech: SpeechListener
    private let dash: DashboardViewModel

    init(app: AppState) {
        self.app = app
        self._notch = ObservedObject(wrappedValue: app.notch)
        self._peeks = ObservedObject(wrappedValue: app.peeks)
        self._voiceLearning = ObservedObject(wrappedValue: app.voiceLearning)
        self.speech = app.speech
        self.dash = app.dash
    }

    private let peekRowHeight: CGFloat = 38

    private var isOpen: Bool { notch.state == .open }
    private var hasPeeks: Bool { !peeks.peeks.isEmpty }
    private var displayedPeeks: [Peek] {
        PeekPresentationPolicy().displayedPeeks(peeks.peeks, notchIsOpen: isOpen)
    }
    private var hasDisplayedPeeks: Bool { !displayedPeeks.isEmpty }
    private var notchWidth: CGFloat { notch.closedSize.width }
    private var notchHeight: CGFloat { max(notch.closedSize.height, 30) }
    private var physicalNotchSize: CGSize {
        notch.physicalExclusionSize ?? CGSize(width: notchWidth, height: notchHeight)
    }
    private var reduceMotion: Bool { accessibilityReduceMotion || NotchViewModel.reduced }

    private var slabWidth: CGFloat {
        let longestTitle = peeks.peeks.map(\.title.count).max() ?? 0
        // Peek labels use 11.5 pt monospaced type (roughly 7 pt per glyph). Give every
        // visible item the same cell width, expanded enough for the longest current title.
        let adaptiveCellWidth = min(220, max(155, CGFloat(longestTitle) * 7 + 24))
        return min(NotchMetrics.openSize.width,
                   max(notchWidth + 60, CGFloat(peeks.peeks.count) * adaptiveCellWidth))
    }

    private var containerWidth: CGFloat {
        if isOpen { return NotchMetrics.openSize.width }
        return hasPeeks ? slabWidth : notchWidth
    }
    private var containerHeight: CGFloat {
        if isOpen { return NotchMetrics.openSize.height }
        return notchHeight + (hasPeeks ? peekRowHeight : 0)
    }

    /// The notch silhouette. Every state is one solid black block hanging from the screen's
    /// top edge — full container width at the top (no gaps beside the notch), square top
    /// corners flush to the edge, rounded bottom. The hardware notch is just its top-center.
    private var shape: NotchFlareShape {
        if isOpen {
            // Straight, square top corners (no flare) — full-width block, rounded bottom only.
            return NotchFlareShape(topWidth: NotchMetrics.openSize.width,
                                   straightTop: 0, flareLength: 0, bottomRadius: 28)
        }
        // Full-width tab from the top: topWidth == containerWidth means no flare, so the black
        // reaches the screen edge across the whole width and closes the wedges beside the notch.
        return NotchFlareShape(topWidth: containerWidth, straightTop: 0,
                               flareLength: 0, bottomRadius: hasPeeks ? 18 : 14)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                Color.black
                Style.notchSurface.opacity(isOpen ? 1 : 0)

                DashboardView(
                    vm: dash,
                    isPresented: isOpen,
                    notchWidth: physicalNotchSize.width,
                    notchHeight: physicalNotchSize.height
                )
                    .frame(width: NotchMetrics.openSize.width, height: NotchMetrics.openSize.height)
                    .opacity(isOpen ? 1 : 0)
                    .allowsHitTesting(isOpen)
                    .animation(
                        isOpen ? NotchViewModel.dashboardReveal : NotchViewModel.dashboardHide,
                        value: isOpen
                    )

                VStack(spacing: 0) {
                    Color.clear.frame(height: notchHeight)
                    if hasDisplayedPeeks {
                        PeekRow(peeks: peeks, notchIsOpen: isOpen) { peek in
                            app.openPeek(peek, closeWhenPointerLeaves: true)
                        }
                        // RootView's transparent host window is wider than the visible notch.
                        // Give PeekRow the slab's explicit width so its equal-cell geometry is
                        // measured inside the clipped surface, not across the host window.
                        .frame(width: containerWidth, height: peekRowHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .opacity(hasDisplayedPeeks ? 1 : 0)
                .allowsHitTesting(hasDisplayedPeeks)
                .animation(NotchViewModel.dashboardHide, value: isOpen)
            }
            .frame(width: containerWidth, height: containerHeight, alignment: .top)
            .clipShape(shape)
            .gleamEdge(shape, on: !isOpen && hasPeeks)
            .shadow(color: .black.opacity(isOpen ? 0.55 : 0), radius: 30, y: 14)
            .shadow(color: Style.emberGlow.opacity(isOpen ? 0.16 : 0), radius: 44)
            .overlay {
                SignalOutline(shape: shape, speech: speech, scale: isOpen ? .expanded : .notch)
                    .mask {
                        Rectangle()
                            .padding(.top, isOpen || hasPeeks ? 5 : 0)
                            .padding(.bottom, -14)
                    }
            }
            .contentShape(shape)
            .onTapGesture {
                if !isOpen {
                    app.openNotch(takeKeyboardFocus: true)
                } else {
                    app.activateKeyboardNavigation()
                }
            }
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil }
            }
            .animation(isOpen ? NotchViewModel.openSpring : NotchViewModel.closeSpring, value: notch.state)
            .animation(NotchViewModel.peekLayout, value: peeks.peeks.map(\.id))

            if let notice = voiceLearning.notice {
                HStack(spacing: 8) {
                    Text(notice.message)
                    Button("Undo") { app.undoVoiceRejection() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Style.emberSolid)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.black.opacity(0.94), in: Capsule())
                .overlay(Capsule().strokeBorder(Style.hairline))
                .offset(y: containerHeight + 7)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(notice.id)
            }
        }
        .frame(width: NotchMetrics.windowSize.width,
               height: NotchMetrics.windowSize.height, alignment: .top)
        .sensoryFeedback(.alignment, trigger: notch.state)
        .sensoryFeedback(.levelChange, trigger: peeks.peeks.count)
        .animation(NotchViewModel.dashboardReveal, value: voiceLearning.notice?.id)
        .preferredColorScheme(.dark)
    }

}
