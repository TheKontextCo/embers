import AppKit

struct NotchDisplayGeometry: Equatable {
    struct TopExclusions: Equatable {
        let leadingWidth: CGFloat
        let trailingWidth: CGFloat
    }

    let frame: CGRect
    let visibleFrame: CGRect
    let safeAreaTopInset: CGFloat
    let topExclusions: TopExclusions?

    init(screen: NSScreen) {
        frame = screen.frame
        visibleFrame = screen.visibleFrame
        safeAreaTopInset = screen.safeAreaInsets.top

        if let leading = screen.auxiliaryTopLeftArea,
           let trailing = screen.auxiliaryTopRightArea {
            topExclusions = TopExclusions(
                leadingWidth: leading.width,
                trailingWidth: trailing.width
            )
        } else {
            topExclusions = nil
        }
    }

    init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTopInset: CGFloat,
        topExclusions: TopExclusions?
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTopInset = safeAreaTopInset
        self.topExclusions = topExclusions
    }
}

struct NotchPanelMetricsPolicy {
    let fallbackClosedSize: CGSize
    let topExclusionAllowance: CGFloat

    func closedSize(for display: NotchDisplayGeometry?) -> CGSize {
        guard let display else { return fallbackClosedSize }
        let topInset = topInset(for: display)
        let height = max(topInset, fallbackClosedSize.height)
        let width = physicalExclusionSize(for: display).map {
            $0.width + topExclusionAllowance
        } ?? fallbackClosedSize.width

        return CGSize(width: width, height: height)
    }

    func physicalExclusionSize(for display: NotchDisplayGeometry?) -> CGSize? {
        guard let display, let exclusions = display.topExclusions else { return nil }
        let width = display.frame.width - exclusions.leadingWidth - exclusions.trailingWidth
        let height = topInset(for: display)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    func topCenteredOrigin(windowSize: CGSize, displayFrame: CGRect) -> CGPoint {
        CGPoint(
            x: displayFrame.midX - windowSize.width / 2,
            y: displayFrame.maxY - windowSize.height
        )
    }

    private func topInset(for display: NotchDisplayGeometry) -> CGFloat {
        display.safeAreaTopInset > 0
            ? display.safeAreaTopInset
            : display.frame.maxY - display.visibleFrame.maxY
    }
}

enum NotchMetrics {
    struct Radii: Equatable {
        let top: CGFloat
        let bottom: CGFloat
    }

    static let openSize = CGSize(width: 720, height: 420)
    static let peekRow: CGFloat = 60
    static let windowSize = CGSize(
        width: openSize.width,
        height: openSize.height + peekRow + 34
    )

    static let closedRadii = Radii(top: 6, bottom: 14)
    static let openRadii = Radii(top: 22, bottom: 30)
    static let fallbackClosed = CGSize(width: 200, height: 32)

    private static let policy = NotchPanelMetricsPolicy(
        fallbackClosedSize: fallbackClosed,
        topExclusionAllowance: 4
    )

    static func closedSize(for screen: NSScreen?) -> CGSize {
        policy.closedSize(for: screen.map(NotchDisplayGeometry.init(screen:)))
    }

    static func physicalExclusionSize(for screen: NSScreen?) -> CGSize? {
        policy.physicalExclusionSize(for: screen.map(NotchDisplayGeometry.init(screen:)))
    }

    static func origin(for window: NSWindow, on screen: NSScreen) -> CGPoint {
        policy.topCenteredOrigin(
            windowSize: window.frame.size,
            displayFrame: NotchDisplayGeometry(screen: screen).frame
        )
    }
}
