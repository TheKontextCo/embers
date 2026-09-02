//  SpeechListener.swift
//  Continuous on-device speech recognition. Streams mic audio through SFSpeechRecognizer
//  and emits the running transcript. Matching against the graph happens in AppState.
//
//  Not auto-started: requires mic + speech authorization. The menu bar "Start listening"
//  toggles it, so the app runs (and the peek queue can be exercised via the debug
//  trigger) before any permission is granted.

import AppKit

struct SpeechTranscript: Equatable, Sendable {
    var text: String
    var isFinal: Bool
    var utteranceID: UUID

    init(text: String, isFinal: Bool, utteranceID: UUID = UUID()) {
        self.text = text
        self.isFinal = isFinal
        self.utteranceID = utteranceID
    }
}

/// AVAudioEngine can report a zeroed format while an input route is unavailable or changing.
/// Installing a tap with that format raises an Objective-C exception, so this guard must happen
/// before touching the tap rather than relying on Swift error handling from `engine.start()`.
enum AudioInputFormatPolicy {
    static func isUsable(sampleRate: Double, channelCount: Int) -> Bool {
        sampleRate.isFinite && sampleRate > 0 && channelCount > 0
    }
}

/// Owns the user's listening intent independently from any one recognition task. Replacing a
/// task advances the token immediately, so late callbacks from the cancelled task cannot mutate
/// the replacement session.
struct SpeechSessionLifecycle {
    typealias Token = UInt64

    private(set) var isListening = false
    private var token: Token = 0

    mutating func beginUserSession() -> Token {
        token &+= 1
        isListening = true
        return token
    }

    mutating func beginReplacement() -> Token? {
        guard isListening else { return nil }
        token &+= 1
        return token
    }

    mutating func stop() {
        token &+= 1
        isListening = false
    }

    func acceptsCallback(for candidate: Token) -> Bool {
        isListening && candidate == token
    }
}

@MainActor
final class SpeechListener: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var authorizationState: SpeechAuthorizationState
    @Published private(set) var lastTranscript = ""
    /// Installed English Speech assets, in stable BCP-47 form.
    @Published private(set) var supportedLocaleIdentifiers: [String]
    /// The closest installed English recognizer locale.
    @Published private(set) var effectiveLocaleIdentifier: String?

    /// Recent smoothed mic levels (0…1), oldest→newest — drives the waveform indicator.
    static let levelBars = 9
    @Published private(set) var levels = [Float](repeating: 0, count: levelBars)
    private var meter = MicMeter()

    /// Called on the main actor with the latest transcript and recognition finality.
    var onTranscript: ((SpeechTranscript) -> Void)?

    /// The top-ranked anchor names and aliases fed to SFSpeech as contextual strings so the
    /// recognizer is biased toward our words. Applied on the next start/restart.
    private(set) var vocabulary: [String] = []
    private var baseVocabulary: [String] = []
    private var focusedVocabulary: [String] = []

    func setBaseVocabulary(_ phrases: [String]) {
        baseVocabulary = phrases
        rebuildVocabulary()
    }

    func prioritizeVocabulary(_ phrases: [String]) {
        focusedVocabulary = phrases
        rebuildVocabulary()
    }

    private func rebuildVocabulary() {
        var seen = Set<String>()
        let next = (focusedVocabulary + baseVocabulary).filter {
            seen.insert(PhraseMatcher.normalize($0)).inserted
        }.prefix(100).map { $0 }
        guard next != vocabulary else { return }
        vocabulary = next
        reapplyVocabulary()
    }

    private let backend: any SpeechRecognitionBackend
    private let restartDelay: @MainActor (Duration) async throws -> Void
    private var restartTask: Task<Void, Never>?
    private var restartGeneration = 0
    private var lifecycle = SpeechSessionLifecycle()
    // A started audio engine is not proof of recovery: reset only on recognition progress,
    // a normal quiet-session end, or an explicit stop/new user session.
    private var recoveryAttempt = 0
    private static let recoveryDelays: [Duration] = [
        .milliseconds(400), .milliseconds(800), .milliseconds(1600),
        .milliseconds(3200), .milliseconds(6400)
    ]

    /// True when on-device recognition is blocked because Dictation is disabled. embers is
    /// offline-only (audio never leaves the device), so we surface this instead of falling
    /// back to server recognition. The menu shows an "Enable Dictation…" action.
    @Published private(set) var needsDictation = false

    init(
        backend: (any SpeechRecognitionBackend)? = nil,
        restartDelay: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let backend = backend ?? SystemSpeechRecognitionBackend()
        self.backend = backend
        self.restartDelay = restartDelay
        authorizationState = backend.authorizationState(isListening: false, needsDictation: false)
        supportedLocaleIdentifiers = backend.supportedLocaleIdentifiers
        effectiveLocaleIdentifier = backend.effectiveLocaleIdentifier
    }

    /// Re-check the OS rather than trusting an earlier prompt result. Users can change privacy
    /// access while Embers is running, and a launch must never manufacture a permission prompt.
    @discardableResult
    func refreshAuthorizationStatus() -> SpeechAuthorizationState {
        let state = backend.authorizationState(
            isListening: isListening,
            needsDictation: needsDictation
        )
        supportedLocaleIdentifiers = backend.supportedLocaleIdentifiers
        effectiveLocaleIdentifier = backend.effectiveLocaleIdentifier
        authorizationState = state
        return state
    }

    /// Called only from an intentional listening command. This is the sole path which may show
    /// Apple's microphone or Speech Recognition prompts.
    func startFromUserAction() async {
        // A previous error is not a fresh OS permission decision. Let an explicit command
        // retry after the user enables Dictation in Settings.
        if !lifecycle.isListening { needsDictation = false }
        let current = refreshAuthorizationStatus()
        guard current.capability != .selectedLocaleUnsupported else { return }
        if current.speechRecognition.canPrompt {
            await backend.requestSpeechAuthorization()
        }
        if current.microphone.canPrompt {
            await backend.requestMicrophoneAuthorization()
        }
        await startIfAuthorized()
    }

    /// Starts only when access was already granted. Used at launch and during a recognition
    /// restart so background work can never surprise people with a TCC permission dialog.
    func startIfAuthorized() async {
        await startIfAuthorized(cancellingScheduledRestart: true, replacementToken: nil)
    }

    private func startIfAuthorized(
        cancellingScheduledRestart: Bool,
        replacementToken: SpeechSessionLifecycle.Token?
    ) async {
        if let replacementToken {
            guard lifecycle.acceptsCallback(for: replacementToken) else { return }
        } else {
            guard !lifecycle.isListening else { return }
        }
        if cancellingScheduledRestart {
            cancelScheduledRestart()
        }
        let access = refreshAuthorizationStatus()
        guard access.hasPermissions else {
            Log.speech.error("speech_start_permissions_unavailable")
            handleStartFailure(replacementToken, retryable: false)
            return
        }
        guard access.capability == .ready else {
            Log.speech.error("speech_start_offline_recognition_unavailable")
            handleStartFailure(replacementToken, retryable: access.capability == .recognizerUnavailable)
            return
        }
        guard backend.isAvailable else {
            refreshAuthorizationStatus()
            Log.speech.error("speech_start_recognizer_unavailable")
            handleStartFailure(replacementToken, retryable: true)
            return
        }
        guard backend.supportsOnDeviceRecognition else {
            refreshAuthorizationStatus()
            Log.speech.error("speech_start_on_device_unsupported")
            handleStartFailure(replacementToken, retryable: false)
            return
        }

        // A failed start must not leave a request, task, or tap behind. In particular, adding a
        // second tap to the same input bus can terminate the process with an Objective-C exception.
        tearDownAudioSession()

        do {
            try backend.prepareAudio(vocabulary: vocabulary) { [weak self] rms in
                self?.ingest(level: rms)
            }
        } catch SpeechAudioStartError.microphoneInputUnavailable {
            Log.speech.error("speech_start_microphone_input_unavailable")
            handleStartFailure(replacementToken, retryable: true)
            return
        } catch {
            Log.speech.error("audio_engine_start_failed")
            tearDownAudioSession()
            handleStartFailure(replacementToken, retryable: true)
            return
        }

        lastTranscript = ""   // fresh session — reset the diff baseline
        let utteranceID = UUID()
        let sessionToken = replacementToken ?? lifecycle.beginUserSession()
        backend.beginRecognition { [weak self] result, error in
            guard let self, self.lifecycle.acceptsCallback(for: sessionToken) else { return }
            if let result {
                let text = result.text
                if error == nil, !text.isEmpty { self.recoveryAttempt = 0 }
                // Never log transcript text. Partial results fire many times a second and
                // speech itself is private user content.
                let changed = text != self.lastTranscript
                let isFinal = result.isFinal
                if changed {
                    if isFinal {
                        Log.speech.info("speech_transcript_final")
                    } else {
                        Log.speech.info("speech_transcript_updated")
                    }
                    self.lastTranscript = text
                }
                // Speech commonly marks an unchanged final string after its last partial.
                // Emit that transition so semantic routing need not wait for the stability timer.
                if changed || isFinal {
                    self.onTranscript?(.init(text: text, isFinal: isFinal, utteranceID: utteranceID))
                }
            }
            // Transcript delivery can synchronously replace the vocabulary/session or Stop.
            guard self.lifecycle.acceptsCallback(for: sessionToken) else { return }
            if let error {
                Log.speech.error("speech_recognition_failed")
                self.handleRecognitionFailure(error)
            } else if result?.isFinal ?? false {
                // Normal finite session end — restart to stay continuous.
                self.restart()
            }
        }
        isListening = lifecycle.isListening
        needsDictation = false
        refreshAuthorizationStatus()
        Log.speech.info("speech_listening_started")
    }

    private func handleStartFailure(_ replacementToken: SpeechSessionLifecycle.Token?, retryable: Bool) {
        guard let replacementToken, lifecycle.acceptsCallback(for: replacementToken) else { return }
        if retryable {
            restart(afterFailure: true)
        } else {
            stop()
        }
    }

    private func handleRecognitionFailure(_ error: Error) {
        switch SpeechRecognitionFailure(error) {
        case .dictationDisabled:
            needsDictation = true
            refreshAuthorizationStatus()
            Log.speech.error("speech_dictation_required")
            stop()
        case .authorizationDenied, .missingAssets:
            refreshAuthorizationStatus()
            stop()
        case .noSpeech:
            // A quiet room is a normal finite session, not a failed recovery attempt.
            recoveryAttempt = 0
            restart()
        case .transient:
            let access = refreshAuthorizationStatus()
            guard access.hasPermissions,
                  access.capability == .ready || access.capability == .recognizerUnavailable else {
                stop()
                return
            }
            restart(afterFailure: true)
        }
    }

    /// Open System Settings at the Keyboard pane (where Dictation lives).
    func openDictationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Deep links are best-effort: macOS may route either one to Privacy & Security or its
    /// containing page, both of which let the user re-enable this app without another prompt.
    func openMicrophonePrivacySettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    func openSpeechRecognitionPrivacySettings() {
        openPrivacySettings(anchor: "Privacy_SpeechRecognition")
    }

    private func openPrivacySettings(anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        NSWorkspace.shared.open(url)
    }

    func stop() {
        lifecycle.stop()
        recoveryAttempt = 0
        cancelScheduledRestart()
        tearDownAudioSession()
        isListening = lifecycle.isListening
        meter.reset()
        levels = [Float](repeating: 0, count: Self.levelBars)   // flatten the waveform
    }

    private func tearDownAudioSession() {
        backend.stopAudio()
    }

    private func cancelScheduledRestart() {
        restartGeneration &+= 1
        restartTask?.cancel()
        restartTask = nil
    }

    /// Smooth one frame's RMS and shift it into the rolling level window (main actor).
    private func ingest(level rms: Float) {
        guard isListening else { return }
        let l = meter.push(rms: rms)
        levels.removeFirst()
        levels.append(l)
    }

    /// Re-arm the recognizer so a freshly-updated `vocabulary` (SFSpeech contextual strings are
    /// applied only at session start) takes effect now. No-op when not listening.
    func reapplyVocabulary() { restart() }

    private func restart(afterFailure: Bool = false) {
        guard lifecycle.isListening else { return }
        if afterFailure {
            guard recoveryAttempt < Self.recoveryDelays.count else {
                Log.speech.error("speech_recovery_exhausted")
                stop()
                return
            }
            recoveryAttempt += 1
            Log.speech.info("speech_recovery_scheduled")
        }
        guard let replacementToken = lifecycle.beginReplacement() else { return }
        cancelScheduledRestart()
        tearDownAudioSession()
        meter.reset()
        levels = [Float](repeating: 0, count: Self.levelBars)
        // Vocabulary replacements keep the current backoff/budget; they cannot reset failures.
        let duration = Self.recoveryDelays[max(0, recoveryAttempt - 1)]
        let generation = restartGeneration
        let delay = restartDelay
        restartTask = Task { [weak self] in
            try? await delay(duration)
            guard !Task.isCancelled, let self, self.restartGeneration == generation else { return }
            self.restartTask = nil
            await self.startIfAuthorized(
                cancellingScheduledRestart: false,
                replacementToken: replacementToken
            )
        }
    }
}
