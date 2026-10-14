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
    static let languageModeKey = "languageMode"
    static let chineseScriptKey = "chineseScript"
    /// UserDefaults key: space between Chinese and English ("用 npm 安装").
    static let cjkSpacingKey = "cjkLatinSpacing"
    /// UserDefaults key: show what's been recognized so far while fn is held.
    static let livePreviewKey = "livePreview"
    /// UserDefaults key: type each sentence as soon as it's finished, instead of all at release.
    static let typeAsYouSpeakKey = "typeAsYouSpeak"
    /// UserDefaults key: double-tap fn locks recording on (hands-free).
    static let handsFreeKey = "handsFree"
    /// UserDefaults keys: hands-free silence auto-finish and maximum length, in seconds (0 = never).
    static let handsFreeSilenceKey = "handsFreeSilence"
    static let handsFreeMaximumKey = "handsFreeMaximum"
    static let defaultHandsFreeSilence: TimeInterval = 300
    static let defaultHandsFreeMaximum: TimeInterval = 3600

    /// Hands-free safety limits. Normally read from settings when hands-free starts;
    /// injectable so tests don't wait minutes.
    struct HandsFreeLimits {
        /// Finish automatically after this much continuous silence (`.infinity` = never).
        var silence: TimeInterval = AppController.defaultHandsFreeSilence
        /// Hard cap on a hands-free recording (`.infinity` = no limit).
        var maximum: TimeInterval = AppController.defaultHandsFreeMaximum
        /// Show a countdown this long before the cap.
        var warning: TimeInterval = 60
        /// After this much silence the HUD shrinks to a small "listening" pill.
        var idleAfter: TimeInterval = 5
        var checkInterval: Duration = .seconds(1)
    }
    /// How often the live preview refreshes (it backs off when transcription is slower).
    static let previewInterval: Duration = .milliseconds(450)
    /// Too little audio to be worth a preview pass.
    static let minimumPreviewAudio: TimeInterval = 0.4

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
    /// Language of the last successful dictation ("en", "zh"), shown in the menu.
    private(set) var lastLanguage: String?
    /// Text recognized so far while recording; on screen only, never typed, stored or counted.
    private(set) var livePreview = ""
    /// Recording is locked on by a double-tap of fn; a tap finishes it.
    private(set) var isHandsFree = false
    /// When the current recording started (HUD elapsed time).
    private(set) var recordingStartedAt: Date?
    /// Hands-free countdown before the cap, e.g. "Stops in 42 s".
    private(set) var handsFreeNotice: String?
    /// Hands-free and nobody has spoken for a few seconds: the HUD shrinks to a small pill.
    private(set) var isListeningIdle = false
    /// Tells the shortcut layer whether hands-free is running (Esc handling).
    var onHandsFreeChange: ((Bool) -> Void)?
    let modelStatus: ModelStatus
    /// Load state of the Chinese model (SenseVoice); only loaded when the language mode needs it.
    let chineseModelStatus = ModelStatus()

    var languageMode: LanguageMode {
        didSet {
            defaults.set(languageMode.rawValue, forKey: Self.languageModeKey)
            if languageMode.needsChineseModel { loadChineseModel() }
        }
    }
    let replacements = ReplacementStore()
    let metrics: MetricsStore

    private let engine: any SpeechEngine
    private let voiceActivity: VoiceActivityModel?
    /// The dictation being recorded; pieces are transcribed as pauses end them.
    private var session: (any DictationSessioning)?
    /// Types the session's pieces as they're committed ("type as you speak"); nil when typing at release.
    private var typer: ProgressiveTyper?
    private let speechClassifier: (@Sendable () -> (any SpeechClassifier)?)?
    private let isTerminalFrontmost: () -> Bool
    private let injectedHandsFreeLimits: HandsFreeLimits?
    private var handsFreeMonitor: Task<Void, Never>?
    private var chineseModelRequested = false
    private let sink: any DictationSink
    private let capture: any AudioCapturing
    private let permissions: Permissions
    private let defaults: UserDefaults
    private var pressStarted: ContinuousClock.Instant?
    private var keyHeld = false
    private var focusAtStart: FocusedApp?
    /// Mic started on fn-down, before the hold qualified. Discarded on disarm.
    private var preRolling = false
    private var previewTask: Task<Void, Never>?

    /// Called whenever the HUD should change visibility.
    var onHUDVisibilityChange: ((Bool) -> Void)?
    /// Called when the HUD's content changed size (live preview text grew).
    var onHUDContentChange: (() -> Void)?

    init(
        sink: any DictationSink = PasteInserter(),
        metrics: MetricsStore = MetricsStore(),
        capture: any AudioCapturing = AudioCapture(),
        permissions: Permissions = Permissions(),
        engine: (any SpeechEngine)? = nil,
        voiceActivity: VoiceActivityModel? = VoiceActivityModel(),
        speechClassifier: (@Sendable () -> (any SpeechClassifier)?)? = nil,
        isTerminalFrontmost: @escaping () -> Bool = { FocusContext.isTerminalFrontmost },
        handsFreeLimits: HandsFreeLimits? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.injectedHandsFreeLimits = handsFreeLimits
        self.isTerminalFrontmost = isTerminalFrontmost
        self.voiceActivity = voiceActivity
        self.speechClassifier = speechClassifier
        self.metrics = metrics
        let modelStatus = ModelStatus()
        self.modelStatus = modelStatus
        let chineseModelStatus = self.chineseModelStatus
        self.engine = engine ?? DictationEngine(
            english: FallbackTranscriber(
                primary: ParakeetTranscriber { modelStatus.post($0.status) },
                fallback: AppleSpeechTranscriber(locale: Locale(identifier: "en_US"))
            ),
            senseVoice: SenseVoiceTranscriber { chineseModelStatus.post($0.status) }
        )
        self.sink = sink
        self.capture = capture
        self.permissions = permissions
        self.defaults = defaults
        languageMode = LanguageMode(rawValue: defaults.string(forKey: Self.languageModeKey) ?? "") ?? .english

        let engine = self.engine
        Task {
            do {
                try await engine.prepareEnglish()
            } catch {
                fail(error.localizedDescription)
            }
            await refreshEngineName()
            if let error = await engine.waitForEnglishPrimary() {
                modelStatus.update(.failed(error.localizedDescription))
            } else {
                modelStatus.update(.ready)
            }
            await refreshEngineName()
        }
        if languageMode.needsChineseModel { loadChineseModel() }
        if let voiceActivity { Task { await voiceActivity.prepare() } }
    }

    /// Downloads/loads SenseVoice once, the first time a Chinese-capable mode is active.
    private func loadChineseModel() {
        guard !chineseModelRequested else { return }
        chineseModelRequested = true
        let engine = self.engine
        let status = chineseModelStatus
        Task {
            if let error = await engine.prepareChinese() {
                status.update(.failed(error.localizedDescription))
            } else {
                status.update(.ready)
            }
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
        case .tap:
            // In hands-free, a tap finishes; otherwise it's a press too short to dictate.
            if isHandsFree && phase == .recording { stopRecording() } else { disarmed() }
        case .lock: lockRecording()
        }
    }

    var isHandsFreeEnabled: Bool { defaults.object(forKey: Self.handsFreeKey) as? Bool ?? true }

    /// Double-tap of fn: start a recording that stays on until fn is tapped again.
    func lockRecording() {
        guard isReady, isHandsFreeEnabled else { return }
        if preRolling {
            // The second tap's pre-roll is already capturing: keep it.
            preRolling = false
            beginRecording(handsFree: true)
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
            guard isReady else { return }
            startSession()
            do {
                try capture.start()
                beginRecording(handsFree: true)
            } catch {
                discardSession()
                fail(error)
            }
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
        startSession()
        do {
            try capture.start()
            preRolling = true
        } catch {
            discardSession()
            Log.app.error("pre-roll start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The fn press was a tap or a modifier: throw the pre-roll audio away unheard.
    func disarmed() {
        guard preRolling else { return }
        preRolling = false
        _ = capture.stop()
        discardSession()
    }

    /// Starts a dictation session and routes captured audio into it. Call before `capture.start()`.
    private func startSession() {
        discardSession()
        let session = DictationSession(
            engine: engine, mode: languageMode, voiceActivity: voiceActivity, classifier: speechClassifier?()
        )
        self.session = session
        capture.onSamples = { session.feed($0) }
        // Terminals type at release: terminal style (no trailing period) needs the whole text.
        if defaults.object(forKey: Self.typeAsYouSpeakKey) as? Bool ?? true, !isTerminalFrontmost() {
            typer = ProgressiveTyper(
                pieces: session.committedPieces,
                format: { [weak self] text, typedSoFar in self?.formatPiece(text, after: typedSoFar) ?? "" },
                insert: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.sink.insert(text, expecting: self.focusAtStart)
                }
            )
        }
    }

    private func discardSession() {
        capture.onSamples = nil
        if let session { Task { await session.cancel() } }
        session = nil
        typer?.cancel()
        typer = nil
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
            startSession()
            do {
                try capture.start()
                beginRecording()
            } catch {
                discardSession()
                fail(error)
            }
        }
    }

    private func beginRecording(handsFree: Bool = false) {
        pressStarted = .now
        recordingStartedAt = .now
        focusAtStart = FocusedApp.current
        undelivered = ""
        if handsFree {
            isHandsFree = true
            onHandsFreeChange?(true)
            startHandsFreeMonitor()
        }
        setPhase(.recording)
        startLivePreview()
    }

    // MARK: Hands-free

    /// Finishes a hands-free recording on long silence, and at the cap (with a countdown first).
    /// Current limits: injected (tests) or from settings, where 0 means "never".
    private var handsFreeLimits: HandsFreeLimits {
        if let injectedHandsFreeLimits { return injectedHandsFreeLimits }
        func seconds(_ key: String, _ fallback: TimeInterval) -> TimeInterval {
            let value = defaults.object(forKey: key) as? Double ?? fallback
            return value > 0 ? value : .infinity
        }
        var limits = HandsFreeLimits()
        limits.silence = seconds(Self.handsFreeSilenceKey, Self.defaultHandsFreeSilence)
        limits.maximum = seconds(Self.handsFreeMaximumKey, Self.defaultHandsFreeMaximum)
        return limits
    }

    private func startHandsFreeMonitor() {
        handsFreeMonitor?.cancel()
        let limits = handsFreeLimits
        handsFreeMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: limits.checkInterval)
                guard let self, !Task.isCancelled, self.isHandsFree, self.phase == .recording,
                      let started = self.recordingStartedAt else { return }
                let elapsed = Date.now.timeIntervalSince(started)
                if elapsed >= limits.maximum {
                    Log.app.info("hands-free: reached the time limit")
                    self.stopRecording()
                    return
                }
                let remaining = limits.maximum - elapsed
                let notice = remaining <= limits.warning ? "Stops in \(Int(remaining.rounded(.up))) s" : nil
                if notice != self.handsFreeNotice {
                    self.handsFreeNotice = notice
                    self.onHUDContentChange?()
                }
                guard let silence = await self.session?.secondsSinceSpeech(),
                      self.isHandsFree, self.phase == .recording else { continue }
                let idle = silence >= limits.idleAfter
                if idle != self.isListeningIdle {
                    self.isListeningIdle = idle
                    self.onHUDContentChange?()
                }
                if silence >= limits.silence {
                    Log.app.info("hands-free: stopped after \(Int(silence)) s of silence")
                    self.stopRecording()
                    return
                }
            }
        }
    }

    private func endHandsFree() {
        handsFreeMonitor?.cancel()
        handsFreeMonitor = nil
        handsFreeNotice = nil
        isListeningIdle = false
        if isHandsFree {
            isHandsFree = false
            onHandsFreeChange?(false)
        }
    }

    #if DEBUG
    /// Debug-only: puts the HUD in the recording state with the given preview text.
    func debugShowPreview(_ text: String) {
        setPhase(.recording)
        livePreview = text
        onHUDContentChange?()
    }
    #endif

    // MARK: Live preview

    /// Re-transcribes the audio captured so far, repeatedly, while recording. None of the
    /// engines stream natively, but they're fast enough (≈10–60 ms) to rerun on the growing clip.
    private func startLivePreview() {
        stopLivePreview()
        guard defaults.object(forKey: Self.livePreviewKey) as? Bool ?? true else { return }
        previewTask = Task { [weak self] in
            var interval = Self.previewInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.phase == .recording else { return }
                // Only the piece in progress is re-transcribed; committed pieces are already text.
                let (committed, tail, language) = await self.session?.previewState()
                    ?? ("", self.capture.snapshot(), nil)
                let started = ContinuousClock.now
                var tailText = ""
                if tail.duration >= Self.minimumPreviewAudio {
                    guard let transcript = try? await self.engine.transcribe(
                        tail, mode: self.languageMode, languageHint: language) else { continue }
                    tailText = transcript.text.trimmed
                }
                guard !Task.isCancelled, self.phase == .recording else { return }
                // When typing as you speak, committed text is already in the app: show just the tail.
                let shown = self.typer != nil ? tailText : ChineseText.join(committed, tailText)
                let text = self.applyTextRules(shown).trimmed
                if text != self.livePreview {
                    self.livePreview = text
                    self.onHUDContentChange?()
                }
                // Spend at most about half the time transcribing, so long dictations don't pile up.
                interval = max(Self.previewInterval, (ContinuousClock.now - started) * 2)
            }
        }
    }

    private func stopLivePreview() {
        previewTask?.cancel()
        previewTask = nil
        livePreview = ""
    }

    func keyUp() {
        keyHeld = false
        stopRecording()
    }

    /// Ends the recording (fn released, or tapped in hands-free) and types the result.
    func stopRecording() {
        guard phase == .recording else { return }
        let handsFree = isHandsFree
        endHandsFree()
        recordingStartedAt = nil
        stopLivePreview()
        _ = capture.stop()
        let capturedSeconds = capture.capturedSeconds
        capture.onSamples = nil
        let held = pressStarted.map { ContinuousClock.now - $0 } ?? .zero
        pressStarted = nil
        // The accidental-tap filter is for hold-to-talk; hands-free was started deliberately.
        guard held >= Self.minimumHold || handsFree, let session else {
            discardSession()
            metrics.record(DictationEvent(date: .now, outcome: .tooShort, audioSeconds: capturedSeconds))
            setPhase(.idle)
            return
        }
        self.session = nil
        let typer = self.typer
        self.typer = nil
        setPhase(.transcribing)
        let releasedAt = ContinuousClock.now
        Task {
            if let typer {
                await finishTypingAsYouSpeak(session, typer: typer, audioSeconds: capturedSeconds,
                                             handsFree: handsFree, releasedAt: releasedAt)
            } else {
                await transcribeAndInsert(session, audioSeconds: capturedSeconds, handsFree: handsFree, releasedAt: releasedAt)
            }
        }
    }

    /// Esc while recording: discard the audio without transcribing or typing anything.
    func cancelRecording() {
        guard phase == .recording else { return }
        endHandsFree()
        recordingStartedAt = nil
        stopLivePreview()
        _ = capture.stop()
        discardSession()
        pressStarted = nil
        metrics.record(DictationEvent(date: .now, outcome: .cancelled, audioSeconds: capture.capturedSeconds))
        Log.app.info("recording cancelled")
        setPhase(.idle)
    }

    func dismiss() {
        undelivered = ""
        setPhase(.idle)
    }

    // MARK: Pipeline

    private func transcribeAndInsert(
        _ session: any DictationSessioning, audioSeconds: TimeInterval, handsFree: Bool,
        releasedAt: ContinuousClock.Instant
    ) async {
        // Text-free metrics event, filled in as the pipeline progresses.
        var event = DictationEvent(date: .now, outcome: .failed, audioSeconds: audioSeconds)
        if handsFree { event.handsFree = true }
        // Earlier pieces are already transcribed; this waits only for the last one.
        let result = await session.finish()
        let text = result.text
        event.transcribeMS = (ContinuousClock.now - releasedAt).timeInterval * 1000
        event.engine = result.engine
        event.language = result.language
        event.pieces = result.pieces
        event.emptyPieces = result.emptyPieces
        if let engine = result.engine { activeEngine = engine }
        Log.asr.info("transcribed \(audioSeconds, format: .fixed(precision: 1))s audio in \(result.pieces) pieces; release → text \(event.transcribeMS ?? 0, format: .fixed(precision: 0)) ms (\(result.language ?? "?", privacy: .public))")

        if result.failures > 0 {
            event.reason = .recognitionFailed
            metrics.record(event)
            // Keep what was recognized: offer it to copy rather than losing the whole dictation.
            undelivered = prepareForTyping(text).trimmed
            fail(text.trimmed.isEmpty
                 ? "Speech recognition failed. Try again."
                 : "Part of the dictation couldn't be recognized, so nothing was typed. The rest is below.")
            return
        }
        guard !text.trimmed.isEmpty else {
            event.reason = .nothingRecognized
            metrics.record(event)
            fail("Nothing was recognized. Hold fn and try again.")
            return
        }
        let transcriptReady = ContinuousClock.now

        let formatted = prepareForTyping(text)
        event.words = ChineseText.wordCount(formatted)
        do {
            let pastedAt = try await sink.insert(formatted, expecting: focusAtStart)
            event.typeMS = (pastedAt - transcriptReady).timeInterval * 1000
            event.outcome = .inserted
            lastLanguage = event.language
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

    /// "Type as you speak": earlier pieces are already typed; finish the session, type the
    /// last piece, and report what happened.
    private func finishTypingAsYouSpeak(
        _ session: any DictationSessioning, typer: ProgressiveTyper, audioSeconds: TimeInterval,
        handsFree: Bool, releasedAt: ContinuousClock.Instant
    ) async {
        var event = DictationEvent(date: .now, outcome: .failed, audioSeconds: audioSeconds)
        if handsFree { event.handsFree = true }
        let result = await session.finish()
        let finishedAt = ContinuousClock.now
        await typer.wait()
        event.transcribeMS = (finishedAt - releasedAt).timeInterval * 1000
        if let typedAt = typer.lastTypedAt { event.typeMS = max(0, (typedAt - finishedAt).timeInterval * 1000) }
        event.engine = result.engine
        event.language = result.language
        event.pieces = result.pieces
        event.emptyPieces = result.emptyPieces
        if let engine = result.engine { activeEngine = engine }
        event.words = ChineseText.wordCount(typer.typed + " " + typer.untyped.joined(separator: " "))
        Log.app.info("typed as you speak: \(result.pieces) pieces, release → done \((ContinuousClock.now - releasedAt).timeInterval * 1000, format: .fixed(precision: 0)) ms")

        if typer.stopped {
            event.reason = typer.insertionError.map { DictationEvent.Reason($0) } ?? .recognitionFailed
            metrics.record(event)
            undelivered = typer.untyped.joined(separator: " ")
            let why = typer.insertionError?.localizedDescription ?? "Part of the dictation couldn't be recognized."
            fail(typer.typed.isEmpty ? why : "Typing stopped partway. \(why)")
            return
        }
        guard !typer.typed.trimmed.isEmpty else {
            event.reason = .nothingRecognized
            metrics.record(event)
            fail("Nothing was recognized. Hold fn and try again.")
            return
        }
        event.outcome = .inserted
        lastLanguage = event.language
        metrics.record(event)
        setPhase(.inserted)
    }

    /// One committed piece → text to type, continuing from what this dictation already typed.
    private func formatPiece(_ text: String, after typedSoFar: String) -> String {
        let ruled = applyTextRules(text).trimmed
        guard !ruled.isEmpty else { return "" }
        guard defaults.object(forKey: Self.smartFormattingKey) as? Bool ?? true else {
            return String(ChineseText.join(typedSoFar, ruled).dropFirst(typedSoFar.count))
        }
        // The first piece sees the real field; later ones continue from what was just typed.
        let context = typedSoFar.isEmpty
            ? FocusContext.current()
            : InsertionContext(precedingText: String(typedSoFar.suffix(3)), isTerminal: false)
        return TextFormatter.format(ruled, context: context, spaceBetweenCJKAndLatin: cjkSpacing)
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

    private var cjkSpacing: Bool { defaults.object(forKey: Self.cjkSpacingKey) as? Bool ?? true }

    /// Vocabulary rules, Chinese script and Chinese/English spacing. Shared by the live
    /// preview and the typed text so both read the same.
    private func applyTextRules(_ text: String) -> String {
        var result = replacements.apply(to: text)
        if ChineseText.containsCJK(result) {
            let script = ChineseScript(rawValue: defaults.string(forKey: Self.chineseScriptKey) ?? "") ?? .simplified
            result = ChineseText.converting(result, to: script)
            if cjkSpacing { result = ChineseText.spacingCJKAndLatin(result) }
        }
        return result
    }

    /// Transcript → typed text: text rules, then context-aware formatting for the focused field.
    private func prepareForTyping(_ text: String) -> String {
        let result = applyTextRules(text)
        guard defaults.object(forKey: Self.smartFormattingKey) as? Bool ?? true else { return result.trimmed }
        return TextFormatter.format(result, context: FocusContext.current(), spaceBetweenCJKAndLatin: cjkSpacing)
    }

    private func refreshEngineName() async {
        activeEngine = await engine.englishEngineName()
    }
}
