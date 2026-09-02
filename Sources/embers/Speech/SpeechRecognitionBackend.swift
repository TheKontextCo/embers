import AVFoundation
import Speech

struct SpeechRecognitionUpdate {
    var text: String
    var isFinal: Bool
}

enum SpeechAudioStartError: Error {
    case microphoneInputUnavailable
    case engineStartFailed
}

/// Apple documents these domain/code pairs; localized error wording is not a capability signal.
/// https://developer.apple.com/documentation/speech/sfspeechrecognitiontask/error
enum SpeechRecognitionFailure {
    case transient, noSpeech, dictationDisabled, authorizationDenied, missingAssets

    init(_ error: Error) {
        let error = error as NSError
        switch (error.domain, error.code) {
        case ("kLSRErrorDomain", 201): self = .dictationDisabled
        case ("kLSRErrorDomain", 102): self = .missingAssets
        case ("kAFAssistantErrorDomain", 1700): self = .authorizationDenied
        case ("kAFAssistantErrorDomain", 1110): self = .noSpeech
        default: self = .transient
        }
    }
}

/// OS boundary only. Listening intent, callback ownership, and restart policy stay in SpeechListener.
@MainActor
protocol SpeechRecognitionBackend: AnyObject {
    var supportedLocaleIdentifiers: [String] { get }
    var effectiveLocaleIdentifier: String? { get }
    var isAvailable: Bool { get }
    var supportsOnDeviceRecognition: Bool { get }
    func authorizationState(isListening: Bool, needsDictation: Bool) -> SpeechAuthorizationState
    func requestSpeechAuthorization() async
    func requestMicrophoneAuthorization() async
    func prepareAudio(vocabulary: [String], onLevel: @escaping @MainActor (Float) -> Void) throws
    func beginRecognition(_ handler: @escaping @MainActor (SpeechRecognitionUpdate?, Error?) -> Void)
    func stopAudio()
}

@MainActor
final class SystemSpeechRecognitionBackend: SpeechRecognitionBackend {
    private var resolution: SpeechLocalePolicy.Resolution
    private var recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hasInputTap = false

    var supportedLocaleIdentifiers: [String] { resolution.supportedIdentifiers }
    private(set) var effectiveLocaleIdentifier: String?
    var isAvailable: Bool { recognizer?.isAvailable == true }
    var supportsOnDeviceRecognition: Bool { recognizer?.supportsOnDeviceRecognition == true }

    init() {
        let resolution = Self.localeResolution()
        self.resolution = resolution
        effectiveLocaleIdentifier = resolution.effectiveIdentifier
        recognizer = Self.makeRecognizer(localeIdentifier: resolution.effectiveIdentifier)
    }

    func authorizationState(isListening: Bool, needsDictation: Bool) -> SpeechAuthorizationState {
        resolution = Self.localeResolution()
        // Installed language assets can change while idle. Never replace a live recognizer here.
        if !isListening, effectiveLocaleIdentifier != resolution.effectiveIdentifier {
            effectiveLocaleIdentifier = resolution.effectiveIdentifier
            recognizer = Self.makeRecognizer(localeIdentifier: resolution.effectiveIdentifier)
        }
        return .evaluate(
            microphone: Self.microphonePermission(AVCaptureDevice.authorizationStatus(for: .audio)),
            speechRecognition: Self.speechPermission(SFSpeechRecognizer.authorizationStatus()),
            recognizerAvailable: isAvailable,
            supportsOnDeviceRecognition: supportsOnDeviceRecognition,
            selectedLocaleIsUnsupported: resolution.selectedLocaleIsUnsupported,
            needsDictation: needsDictation
        )
    }

    func requestSpeechAuthorization() async {
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    func requestMicrophoneAuthorization() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    func prepareAudio(vocabulary: [String], onLevel: @escaping @MainActor (Float) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard AudioInputFormatPolicy.isUsable(
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        ) else {
            throw SpeechAudioStartError.microphoneInputUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true   // offline-only; never fall back to a server
        request.contextualStrings = vocabulary
        self.request = request

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
            guard let ch = buffer.floatChannelData?[0] else { return }
            let rms = MicMeter.rms(ch, Int(buffer.frameLength))
            DispatchQueue.main.async { onLevel(rms) }
        }
        hasInputTap = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw SpeechAudioStartError.engineStartFailed
        }
    }

    func beginRecognition(_ handler: @escaping @MainActor (SpeechRecognitionUpdate?, Error?) -> Void) {
        guard let recognizer, let request else { return }
        task = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor in
                let update = result.map {
                    SpeechRecognitionUpdate(text: $0.bestTranscription.formattedString, isFinal: $0.isFinal)
                }
                handler(update, error)
            }
        }
    }

    func stopAudio() {
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private static func localeResolution() -> SpeechLocalePolicy.Resolution {
        SpeechLocalePolicy.resolve(
            supportedIdentifiers: SFSpeechRecognizer.supportedLocales().map(\.identifier),
            systemIdentifier: Locale.current.identifier
        )
    }

    private static func makeRecognizer(localeIdentifier: String?) -> SFSpeechRecognizer? {
        guard let localeIdentifier else { return nil }
        return SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    private static func microphonePermission(_ status: AVAuthorizationStatus) -> SpeechPermission {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }

    private static func speechPermission(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechPermission {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }
}
