//  GlobalHotKey.swift
//  A system-wide hotkey via Carbon's RegisterEventHotKey. We deliberately AVOID
//  NSEvent.addGlobalMonitorForEvents(.keyDown): installing a global keyboard monitor puts the
//  process into a keystroke-monitoring state that makes macOS STOP routing mouse events to our
//  borderless, non-key notch panel (clicks die entirely). RegisterEventHotKey registers a single
//  combo with the system instead of observing every keystroke, so it never touches mouse routing.

import AppKit
import Carbon.HIToolbox

/// Carbon hot-key events are delivered on the main run loop, so `action` runs on main.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// keyCode is a Carbon virtual key (e.g. kVK_ANSI_L); modifiers are Carbon flags (cmdKey, optionKey…).
    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        // Route the C callback back to this instance via the handler's userData (refcon) —
        // no static table, no actor-isolation headaches.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, refcon, &handlerRef)

        let hkID = EventHotKeyID(signature: OSType(0x454D4252) /* 'EMBR' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hkID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
