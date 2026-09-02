import AppKit

struct NotchPanelPresentationPolicy {
    let styleMask: NSWindow.StyleMask
    let level: NSWindow.Level
    let appearanceName: NSAppearance.Name
    let spaceBehavior: NSWindow.CollectionBehavior

    static let standard = NotchPanelPresentationPolicy(
        styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
        level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3),
        appearanceName: .darkAqua,
        spaceBehavior: [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    )

    func apply(to panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = level
        panel.appearance = NSAppearance(named: appearanceName)
        panel.collectionBehavior = spaceBehavior
    }
}

final class NotchWindow: NSPanel {
    init(contentRect: NSRect) {
        let presentation = NotchPanelPresentationPolicy.standard
        super.init(
            contentRect: contentRect,
            styleMask: presentation.styleMask,
            backing: .buffered,
            defer: false
        )
        presentation.apply(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NotchWindow must be created with init(contentRect:)")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
