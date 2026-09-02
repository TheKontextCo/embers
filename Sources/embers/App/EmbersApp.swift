//  EmbersApp.swift
//  Entry point. A menu-bar agent (LSUIElement) — no dock icon, no main window. The
//  notch panel is created imperatively by the AppDelegate.

import SwiftUI

@main
struct EmbersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var app = AppCompositionRoot.app
    // Observe the speech object directly — isListening is @Published on it, not on AppState,
    // so the menu label wouldn't update if we only watched AppState.
    @ObservedObject private var speech = AppCompositionRoot.app.speech

    var body: some Scene {
        MenuBarExtra("embers", systemImage: "flame.fill") {
            Button(L10n.string("menu.open")) { app.openNotch(takeKeyboardFocus: true) }
                .keyboardShortcut("o")
            Button(L10n.string(speech.isListening ? "menu.stopListening" : "menu.startListening")) {
                app.toggleListening()
            }
            if !speech.isListening {
                Text(speech.authorizationState.label)
                    .foregroundStyle(.secondary)
                if speech.authorizationState.needsMicrophoneSettings {
                    Button("Open Microphone Privacy…") { speech.openMicrophonePrivacySettings() }
                }
                if speech.authorizationState.needsSpeechRecognitionSettings {
                    Button("Open Speech Recognition Privacy…") { speech.openSpeechRecognitionPrivacySettings() }
                }
            }
            if speech.needsDictation {
                Button("⚠ Enable Dictation…") { speech.openDictationSettings() }
            }
            Button(L10n.string("menu.chooseFolder")) { app.presentFolderPicker() }
            Divider()
            Button(L10n.string("menu.quit")) { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
