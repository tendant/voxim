//
//  AppController.swift
//  voxim
//
//  Hold shortcut → record → transcribe locally → type into the focused field.
//  Never presses Return. If typing isn't possible, the transcript stays available to copy.
//

import Foundation
import os
import Observation

@Observable
final class AppController {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case inserted
        case failed(String)
    }

    /// Presses shorter than this are treated as accidental taps and discarded.
    static let minimumHold: Duration = .milliseconds(250)
    /// UserDefaults key for context-aware cleanup (spacing, mid-sentence case, terminal style).
    static let smartFormattingKey = "smartFormatting"
    /// UserDefaults key: start the microphone when fn goes down rather than when the hold qualifies.
    static let preRollKey = "preRoll"

    /// System access the controller needs; injectable so the flow can be tested headless.
    struct Permissions {
        var isAccessibilityTrusted: () -> Bool = { AXAccess.isTrusted }
        var requestAccessibility: () -> Void = { AXAccess.requestTrust() }
        /// Already granted; must not prompt (used for pre-roll on every fn press).
        var isMicrophoneGranted: () -> Bool = { AudioCapture.isGranted }
        /// May show the system prompt.
        var requestMicrophone: () async -> Bool = { await AudioCapture.requestPermission() }
    }

    private(set) var phase: Phase = .idle
    /// Last transcript that could not be typed; offered for copying. Cleared on the next recording.
    private(set) var undelivered = ""
    private(set) var activeEngine = ""
    let modelStatus: ModelStatus
    let replacements = ReplacementStore()
    let metrics: MetricsStore

    private let transcriber: FallbackTranscriber
    private let sink: any DictationSink
    private let capture: any AudioCapturing
    private let permissions: Permissions
    private let defaults: UserDefaults
    private var pressStarted: ContinuousClock.Instant?
    private var keyHeld = false
    private var focusAtStart: FocusedApp?
    /// Mic started on fn-down, before the hold qualified. Discarded on disarm.
    private var preRolling = false

    /// Called whenever the HUD should change visibility.
    var onHUDVisibilityChange: ((Bool) -> Void)?

    init(
        sink: any DictationSink = PasteInserter(),
        metrics: MetricsStore = MetricsStore(),
        capture: any AudioCapturing = AudioCapture(),
        permissions: Permissions = Permissions(),
        transcriber: FallbackTranscriber? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.metrics = metrics
        let modelStatus = ModelStatus()
        self.modelStatus = modelStatus
        self.transcriber = transcriber ?? FallbackTranscriber(
            primary: ParakeetTranscriber { event in
                switch event {
                case .downloading(let fraction): modelStatus.post(.downloading(fraction: fraction))
                case .compiling: modelStatus.post(.compiling)
                }
            },
            fallback: AppleSpeechTranscriber()
        )
        self.sink = sink
        self.capture = capture
        self.permissions = permissions
        self.defaults = defaults

        let transcriber = self.transcriber
        Task {
            do {
                try await transcriber.prepare()
            } catch {
                fail(error.localizedDescription)
            }
            await refreshEngineName()
            if let error = await transcriber.waitForPrimary() {
                modelStatus.update(.failed(error.localizedDescription))
            } else {
                modelStatus.update(.ready)
            }
            await refreshEngineName()
        }
    }

    var isHUDVisible: Bool {
        switch phase {
        case .recording, .transcribing, .failed: true
        case .idle, .inserted: false
        }
    }

    // MARK: Push-to-talk

    func handle(_ action: FnHoldDetector.Action) {
        switch action {
        case .arm: armed()
        case .disarm: disarmed()
        case .press: keyDown()
        case .release: keyUp()
        case .cancel: cancelRecording()
        }
    }

    private var isReady: Bool {
        switch phase {
        case .idle, .inserted, .failed: true
        case .recording, .transcribing: false
        }
    }

    /// fn went down alone: start the mic now so the first syllable isn't lost while waiting
    /// out the hold threshold. Silent (no HUD) and only if both permissions are already granted;
    /// anything else is handled by `keyDown()` once the hold qualifies.
    func armed() {
        guard defaults.object(forKey: Self.preRollKey) as? Bool ?? true,
              isReady, !preRolling,
              permissions.isAccessibilityTrusted(), permissions.isMicrophoneGranted()
        else { return }
        do {
            try capture.start()
            preRolling = true
        } catch {
            Log.app.error("pre-roll start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The fn press was a tap or a modifier: throw the pre-roll audio away unheard.
    func disarmed() {
        guard preRolling else { return }
        preRolling = false
        _ = capture.stop()
    }

    func keyDown() {
        keyHeld = true
        guard isReady else { return }
        if preRolling {
            // Already capturing since fn-down; the clip keeps that audio.
            preRolling = false
            beginRecording()
            return
        }
        if !permissions.isAccessibilityTrusted() {
            permissions.requestAccessibility()
            fail(InsertionError.accessibilityDenied)
            return
        }
        Task {
            guard await permissions.requestMicrophone() else {
                fail(AudioCaptureError.microphoneDenied)
                return
            }
            // Released while the permission check was pending: don't start a recording.
            guard keyHeld else { return }
            do {
                try capture.start()
                beginRecording()
            } catch {
                fail(error)
            }
        }
    }

    private func beginRecording() {
        pressStarted = .now
        focusAtStart = FocusedApp.current
        undelivered = ""
        setPhase(.recording)
    }

    func keyUp() {
        keyHeld = false
        guard phase == .recording else { return }
        let clip = capture.stop()
        let held = pressStarted.map { ContinuousClock.now - $0 } ?? .zero
        pressStarted = nil
        guard held >= Self.minimumHold else {
            metrics.record(DictationEvent(date: .now, outcome: .tooShort, audioSeconds: clip.duration))
            setPhase(.idle)
            return
        }
        setPhase(.transcribing)
        let releasedAt = ContinuousClock.now
        Task { await transcribeAndInsert(clip, releasedAt: releasedAt) }
    }

    /// Esc while recording: discard the audio without transcribing or typing anything.
    func cancelRecording() {
        guard phase == .recording else { return }
        let clip = capture.stop()
        pressStarted = nil
        metrics.record(DictationEvent(date: .now, outcome: .cancelled, audioSeconds: clip.duration))
        Log.app.info("recording cancelled")
        setPhase(.idle)
    }

    func dismiss() {
        undelivered = ""
        setPhase(.idle)
    }

    // MARK: Pipeline

    private func transcribeAndInsert(_ clip: AudioClip, releasedAt: ContinuousClock.Instant) async {
        // Text-free metrics event, filled in as the pipeline progresses.
        var event = DictationEvent(date: .now, outcome: .failed, audioSeconds: clip.duration)
        let text: String
        do {
            text = try await transcriber.transcribe(clip)
            event.transcribeMS = (ContinuousClock.now - releasedAt).timeInterval * 1000
            Log.asr.info("transcribed \(clip.duration, format: .fixed(precision: 1))s audio in \(event.transcribeMS ?? 0, format: .fixed(precision: 0)) ms")
            await refreshEngineName()
            event.engine = activeEngine
        } catch {
            event.reason = .recognitionFailed
            metrics.record(event)
            fail(error.localizedDescription)
            return
        }
        guard !text.trimmed.isEmpty else {
            event.reason = .nothingRecognized
            metrics.record(event)
            fail("Nothing was recognized. Hold fn and try again.")
            return
        }
        let transcriptReady = ContinuousClock.now

        let corrected = replacements.apply(to: text)
        let formatted = defaults.object(forKey: Self.smartFormattingKey) as? Bool ?? true
            ? TextFormatter.format(corrected, context: FocusContext.current())
            : corrected.trimmed

        event.words = formatted.split(whereSeparator: \.isWhitespace).count
        do {
            let pastedAt = try await sink.insert(formatted, expecting: focusAtStart)
            event.typeMS = (pastedAt - transcriptReady).timeInterval * 1000
            event.outcome = .inserted
            metrics.record(event)
            Log.app.info("inserted \(formatted.count) characters")
            setPhase(.inserted)
        } catch {
            event.reason = .init(error)
            metrics.record(event)
            undelivered = formatted.trimmed
            fail(error.localizedDescription)
        }
    }

    /// A failure before any audio was captured (permissions, no input device).
    private func fail(_ error: any Error) {
        metrics.record(DictationEvent(date: .now, outcome: .failed, reason: .init(error)))
        fail(error.localizedDescription)
    }

    private func fail(_ message: String) {
        setPhase(.failed(message))
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        onHUDVisibilityChange?(isHUDVisible)
    }

    private func refreshEngineName() async {
        activeEngine = await transcriber.activeName
    }
}

extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
