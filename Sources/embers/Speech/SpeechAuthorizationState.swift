import Foundation

/// A testable representation of the system privacy decisions Embers needs before it can listen.
///
/// This deliberately keeps `notDetermined` separate from denial: only an explicit user action may
/// turn the former into a system prompt, while the latter requires recovery in System Settings.
enum SpeechPermission: Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted

    var canPrompt: Bool { self == .notDetermined }
    var permitsListening: Bool { self == .authorized }
}

enum SpeechCapability: Equatable {
    case ready
    case selectedLocaleUnsupported
    case recognizerUnavailable
    case onDeviceRecognitionUnsupported
    case dictationDisabled
}

struct SpeechAuthorizationState: Equatable {
    var microphone: SpeechPermission
    var speechRecognition: SpeechPermission
    var capability: SpeechCapability

    static func evaluate(
        microphone: SpeechPermission,
        speechRecognition: SpeechPermission,
        recognizerAvailable: Bool,
        supportsOnDeviceRecognition: Bool,
        selectedLocaleIsUnsupported: Bool = false,
        needsDictation: Bool = false
    ) -> Self {
        let capability: SpeechCapability
        if needsDictation {
            capability = .dictationDisabled
        } else if selectedLocaleIsUnsupported {
            capability = .selectedLocaleUnsupported
        } else if !recognizerAvailable {
            capability = .recognizerUnavailable
        } else if !supportsOnDeviceRecognition {
            capability = .onDeviceRecognitionUnsupported
        } else {
            capability = .ready
        }
        return Self(microphone: microphone, speechRecognition: speechRecognition, capability: capability)
    }

    var hasPermissions: Bool {
        microphone.permitsListening && speechRecognition.permitsListening
    }

    var canStart: Bool { hasPermissions && capability == .ready }

    var canRequestAuthorization: Bool {
        microphone.canPrompt || speechRecognition.canPrompt
    }

    var needsMicrophoneSettings: Bool { microphone == .denied }
    var needsSpeechRecognitionSettings: Bool { speechRecognition == .denied }

    /// One concise, user-facing status for menus and the settings pane.
    var label: String {
        if microphone == .denied { return "Microphone access is off" }
        if speechRecognition == .denied { return "Speech Recognition access is off" }
        if microphone == .restricted { return "Microphone access is restricted" }
        if speechRecognition == .restricted { return "Speech Recognition access is restricted" }
        if capability == .selectedLocaleUnsupported { return "Selected speech language is not available on this Mac" }
        if canRequestAuthorization { return "Microphone and Speech Recognition access required" }
        switch capability {
        case .ready: return "Ready to listen on this Mac"
        case .selectedLocaleUnsupported: return "Selected speech language is not available on this Mac"
        case .recognizerUnavailable: return "Speech recognition is currently unavailable"
        case .onDeviceRecognitionUnsupported: return "This Mac does not support offline speech recognition"
        case .dictationDisabled: return "Dictation is required for offline speech recognition"
        }
    }

    var detail: String {
        if microphone == .denied || speechRecognition == .denied {
            return "Allow Embers in Privacy & Security, then try listening again."
        }
        if microphone == .restricted || speechRecognition == .restricted {
            return "This Mac's Screen Time, device-management, or privacy policy prevents access."
        }
        if capability == .selectedLocaleUnsupported {
            return "Choose Automatic or a language listed below. Embers will not fall back to server recognition."
        }
        if canRequestAuthorization {
            return "Choose Start Listening to review Apple's permission prompts."
        }
        switch capability {
        case .ready: return "Audio stays on this Mac; Embers never falls back to server recognition."
        case .selectedLocaleUnsupported: return "Choose Automatic or a language listed below. Embers will not fall back to server recognition."
        case .recognizerUnavailable: return "Try again after Speech Recognition becomes available."
        case .onDeviceRecognitionUnsupported: return "Embers requires on-device recognition, so audio is never sent to a server."
        case .dictationDisabled: return "Turn on Dictation in Keyboard settings. Embers will remain offline-only."
        }
    }
}
