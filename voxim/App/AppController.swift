//
//  AppController.swift
//  voxim
//
//  Runs dictations. The lifecycle lives in `DictationMachine` (pure); this class feeds it
//  inputs, runs the effects it asks for (microphone, session, typing, metrics), and exposes
//  observable state to the UI. Never presses Return; if typing isn't possible, the transcript
//  stays available to copy.
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
    /// How often the live preview refreshes (it backs off when transcription is slower).
    static let previewInterval: Duration = .milliseconds(450)
    /// Too little audio to be worth a preview pass.
    static let minimumPreviewAudio: TimeInterval = 0.4

    // Settings keys, kept here for the UI's `@AppStorage` and tests.
    static let smartFormattingKey = Preferences.Key.smartFormatting
    static let preRollKey = Preferences.Key.preRoll
    static let languageModeKey = Preferences.Key.languageMode
    static let chineseScriptKey = Preferences.Key.chineseScript
    static let cjkSpacingKey = Preferences.Key.cjkSpacing
    static let livePreviewKey = Preferences.Key.livePreview
    static let typeAsYouSpeakKey = Preferences.Key.typeAsYouSpeak
    static let handsFreeKey = Preferences.Key.handsFree
    static let handsFreeSilenceKey = Preferences.Key.handsFreeSilence
    static let handsFreeMaximumKey = Preferences.Key.handsFreeMaximum
    static let defaultHandsFreeSilence = Preferences.defaultHandsFreeSilence
    static let defaultHandsFreeMaximum = Preferences.defaultHandsFreeMaximum

    /// Hands-free limits. Normally from settings; injectable so tests don't wait minutes.
    struct HandsFreeLimits {
        /// Finish automatically after this much continuous silence (`.infinity` = never).
        var silence: TimeInterval = Preferences.defaultHandsFreeSilence
        /// Hard cap on a hands-free recording (`.infinity` = no limit).
        var maximum: TimeInterval = Preferences.defaultHandsFreeMaximum
        /// Show a countdown this long before the cap.
        var warning: TimeInterval = 60
        /// After this much silence the HUD shrinks to a small "listening" pill.
        var idleAfter: TimeInterval = 5
        var checkInterval: Duration = .seconds(1)
    }

    /// System access the controller needs; injectable so the flow can be tested headless.
    struct Permissions {
        var isAccessibilityTrusted: () -> Bool = { AXAccess.isTrusted }
        var requestAccessibility: () -> Void = { AXAccess.requestTrust() }
        /// Already granted; must not prompt (used for pre-roll on every fn press).
        var isMicrophoneGranted: () -> Bool = { AudioCapture.isGranted }
        /// May show the system prompt.
        var requestMicrophone: () async -> Bool = { await AudioCapture.requestPermission() }
    }

    // MARK: Observable state

    /// The dictation lifecycle; everything below about the current recording derives from it.
    private(set) var state: DictationMachine.State = .idle(nil)
    /// Last transcript that could not be typed; offered for copying. Cleared on the next recording.
    private(set) var undelivered = ""
    private(set) var activeEngine = ""
    /// Language of the last successful dictation ("en", "zh", "mixed"), shown in the menu.
    private(set) var lastLanguage: String?
    /// Text recognized so far while recording; on screen only, never typed, stored or counted.
    private(set) var livePreview = ""
    /// When the current recording started (HUD elapsed time).
    private(set) var recordingStartedAt: Date?
    /// Hands-free countdown before the cap, e.g. "Stops in 42 s".
    private(set) var handsFreeNotice: String?
    /// Hands-free and nobody has spoken for a few seconds: the HUD shrinks to a small pill.
    private(set) var isListeningIdle = false
    /// Typing is paused because another app is in front; the app to return to.
    private(set) var typingPausedFor: String?

    var phase: Phase {
        switch state {
        case .idle(nil), .armed, .starting: .idle
        case .idle(.inserted): .inserted
        case .idle(.failed(let message)): .failed(message)
        case .recording: .recording
        case .finishing: .transcribing
        }
    }

    /// Recording is locked on by a double-tap of fn; a tap finishes it.
    var isHandsFree: Bool { state == .recording(.handsFree) }

    var isHUDVisible: Bool {
        switch phase {
        case .recording, .transcribing, .failed: true
        case .idle, .inserted: false
        }
    }

    var isHandsFreeEnabled: Bool { Preferences(defaults).handsFree }

    var languageMode: LanguageMode {
        didSet {
            defaults.set(languageMode.rawValue, forKey: Preferences.Key.languageMode)
            if languageMode.needsChineseModel { loadChineseModel() }
        }
    }

    let modelStatus: ModelStatus
    /// Load state of the Chinese model (SenseVoice); only loaded when the language mode needs it.
    let chineseModelStatus = ModelStatus()
    let replacements = ReplacementStore()
    let metrics: MetricsStore

    /// Called whenever the HUD should change visibility.
    var onHUDVisibilityChange: ((Bool) -> Void)?
    /// Called when the HUD's content changed size (live preview text grew).
    var onHUDContentChange: (() -> Void)?
    /// Tells the shortcut layer whether hands-free is running (Esc handling).
    var onHandsFreeChange: ((Bool) -> Void)?

    // MARK: Dependencies

    private let engine: any SpeechEngine
    private let voiceActivity: VoiceActivityModel?
    private let speechClassifier: (@Sendable () -> (any SpeechClassifier)?)?
    private let isTerminalFrontmost: () -> Bool
    /// The frontmost app (injectable so tests can switch apps).
    private let currentFocus: @MainActor () -> FocusedApp?
    private let injectedHandsFreeLimits: HandsFreeLimits?
    private let sink: any DictationSink
    private let capture: any AudioCapturing
    private let permissions: Permissions
    private let defaults: UserDefaults

    // MARK: The current dictation (resources owned while not idle)

    /// Settings and text rules, fixed when the dictation starts.
    private var preferences = Preferences()
    private var pipeline = TextPipeline(rules: [], preferences: Preferences())
    /// Pieces are transcribed as pauses end them.
    private var session: (any DictationSessioning)?
    /// Types the session's pieces as they're committed ("type as you speak"); nil when typing at the end.
    private var typer: ProgressiveTyper?
    private var focusAtStart: FocusedApp?
    private var pressStarted: ContinuousClock.Instant?
    private var previewTask: Task<Void, Never>?
    private var handsFreeMonitor: Task<Void, Never>?
    private var chineseModelRequested = false

    init(
        sink: any DictationSink = PasteInserter(),
        metrics: MetricsStore = MetricsStore(),
        capture: any AudioCapturing = AudioCapture(),
        permissions: Permissions = Permissions(),
        engine: (any SpeechEngine)? = nil,
        voiceActivity: VoiceActivityModel? = VoiceActivityModel(),
        speechClassifier: (@Sendable () -> (any SpeechClassifier)?)? = nil,
        isTerminalFrontmost: @escaping () -> Bool = { FocusContext.isTerminalFrontmost },
        currentFocus: @escaping @MainActor () -> FocusedApp? = { FocusedApp.current },
        handsFreeLimits: HandsFreeLimits? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.injectedHandsFreeLimits = handsFreeLimits
        self.isTerminalFrontmost = isTerminalFrontmost
        self.currentFocus = currentFocus
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
        languageMode = LanguageMode(rawValue: defaults.string(forKey: Preferences.Key.languageMode) ?? "") ?? .english

        let engine = self.engine
        Task {
            do {
                try await engine.prepareEnglish()
            } catch {
                state = .idle(.failed(error.localizedDescription))
                onHUDVisibilityChange?(isHUDVisible)
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

    // MARK: Inputs

    /// Push-to-talk actions from the fn key.
    func handle(_ action: FnHoldDetector.Action) {
        switch action {
        case .arm: send(.fnDown)
        case .disarm: send(.fnDisarmed)
        case .press: send(.holdStarted)
        case .release: send(.fnReleased)
        case .cancel: send(.escape)
        case .tap: send(.tap)
        case .lock: send(.doubleTap)
        }
    }

    func dismiss() {
        undelivered = ""
        send(.dismiss)
    }

    #if DEBUG
    /// Debug-only: puts the HUD in the recording state with the given preview text.
    func debugShowPreview(_ text: String) {
        setState(.recording(.hold))
        livePreview = text
        onHUDContentChange?()
    }
    #endif

    /// Reduces one input and runs the resulting effects.
    private func send(_ input: DictationMachine.Input) {
        let transition = DictationMachine.reduce(state, input, facts())
        let previous = state
        setState(transition.state)
        if previous.isRecording && !transition.state.isRecording { endRecordingUI() }
        for effect in transition.effects { run(effect) }
    }

    private func facts() -> DictationMachine.Facts {
        let preferences = Preferences(defaults)
        let held = pressStarted.map { ContinuousClock.now - $0 } ?? .zero
        return DictationMachine.Facts(
            canPreRoll: preferences.preRoll && permissions.isAccessibilityTrusted() && permissions.isMicrophoneGranted(),
            accessibilityTrusted: permissions.isAccessibilityTrusted(),
            handsFreeEnabled: preferences.handsFree,
            heldLongEnough: held >= Self.minimumHold
        )
    }

    private func setState(_ newState: DictationMachine.State) {
        let wasHandsFree = isHandsFree
        let wasVisible = isHUDVisible
        state = newState
        if isHandsFree != wasHandsFree { onHandsFreeChange?(isHandsFree) }
        if isHUDVisible != wasVisible || newState.isRecording { onHUDVisibilityChange?(isHUDVisible) }
    }

    // MARK: Effects

    private func run(_ effect: DictationMachine.Effect) {
        switch effect {
        case .startCapture:
            startCapture()
        case .discardCapture:
            _ = capture.stop()
            discardSession()
        case .beginRecording(let trigger):
            beginRecording(trigger)
        case .finish(let trigger):
            finish(handsFree: trigger == .handsFree)
        case .cancel:
            _ = capture.stop()
            discardSession()
            metrics.record(DictationEvent(date: .now, outcome: .cancelled, audioSeconds: capture.capturedSeconds))
            Log.app.info("recording cancelled")
        case .requestMicrophone:
            Task {
                let granted = await permissions.requestMicrophone()
                send(.microphoneAnswered(granted: granted))
            }
        case .requestAccessibility:
            permissions.requestAccessibility()
        case .recordTooShort:
            metrics.record(DictationEvent(date: .now, outcome: .tooShort, audioSeconds: capture.capturedSeconds))
        case .recordFailure(let reason):
            metrics.record(DictationEvent(date: .now, outcome: .failed, reason: reason))
        }
    }

    /// Snapshots the settings, creates the session (and typer), and starts the microphone.
    private func startCapture() {
        discardSession()
        preferences = Preferences(defaults)
        pipeline = TextPipeline(rules: replacements.rules, preferences: preferences)
        let session = DictationSession(
            engine: engine, mode: languageMode, voiceActivity: voiceActivity, classifier: speechClassifier?()
        )
        self.session = session
        capture.onSamples = { session.feed($0) }
        // Terminals type at the end: terminal style (no trailing period) needs the whole text.
        if preferences.typeAsYouSpeak, !isTerminalFrontmost() {
            let pipeline = self.pipeline
            typer = ProgressiveTyper(
                pieces: session.committedPieces,
                format: { text, typedSoFar in
                    // Only the first piece needs the real field (an Accessibility read).
                    pipeline.piece(text, after: typedSoFar, context: typedSoFar.isEmpty ? FocusContext.current() : .unknown)
                },
                insert: { [weak self] text in
                    guard let self else { throw CancellationError() }
                    return try await self.sink.insert(text, expecting: self.focusAtStart)
                },
                waitForFocus: { [weak self] in await self?.waitForHomeApp() ?? false },
                onPauseChange: { [weak self] app in
                    self?.typingPausedFor = app
                    self?.onHUDContentChange?()
                }
            )
        }
        do {
            try capture.start()
        } catch {
            send(.captureFailed(error.localizedDescription))
        }
    }

    private func discardSession() {
        capture.onSamples = nil
        if let session { Task { await session.cancel() } }
        session = nil
        typer?.cancel()
        typer = nil
        typingPausedFor = nil
    }

    /// Polls until the app the dictation started in is frontmost again (or the wait is cancelled).
    private func waitForHomeApp() async -> Bool {
        guard let home = focusAtStart else { return false }
        while !Task.isCancelled {
            if currentFocus()?.pid == home.pid { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private func beginRecording(_ trigger: DictationMachine.Trigger) {
        pressStarted = .now
        recordingStartedAt = .now
        focusAtStart = currentFocus()
        undelivered = ""
        if trigger == .handsFree { startHandsFreeMonitor() }
        startLivePreview()
    }

    /// Leaving the recording state, however it happened.
    private func endRecordingUI() {
        previewTask?.cancel()
        previewTask = nil
        livePreview = ""
        handsFreeMonitor?.cancel()
        handsFreeMonitor = nil
        handsFreeNotice = nil
        isListeningIdle = false
        recordingStartedAt = nil
        pressStarted = nil
    }

    /// Stops the microphone and hands the session to the typing pipeline.
    private func finish(handsFree: Bool) {
        _ = capture.stop()
        let capturedSeconds = capture.capturedSeconds
        capture.onSamples = nil
        guard let session else {
            send(.finished(.failed("Nothing was recorded. Try again.")))
            return
        }
        let typer = self.typer
        self.session = nil
        self.typer = nil
        let releasedAt = ContinuousClock.now
        Task {
            let outcome = if let typer {
                await finishTypingAsYouSpeak(session, typer: typer, audioSeconds: capturedSeconds,
                                             handsFree: handsFree, releasedAt: releasedAt)
            } else {
                await transcribeAndInsert(session, audioSeconds: capturedSeconds, handsFree: handsFree,
                                          releasedAt: releasedAt)
            }
            send(.finished(outcome))
        }
    }

    // MARK: Hands-free monitor

    private var handsFreeLimits: HandsFreeLimits {
        if let injectedHandsFreeLimits { return injectedHandsFreeLimits }
        var limits = HandsFreeLimits()
        limits.silence = preferences.handsFreeSilence
        limits.maximum = preferences.handsFreeMaximum
        return limits
    }

    /// Finishes a hands-free recording on long silence or at the cap (with a countdown first),
    /// and flags the idle state for the compact HUD.
    private func startHandsFreeMonitor() {
        handsFreeMonitor?.cancel()
        let limits = handsFreeLimits
        handsFreeMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: limits.checkInterval)
                guard let self, !Task.isCancelled, self.isHandsFree, let started = self.recordingStartedAt else { return }
                let elapsed = Date.now.timeIntervalSince(started)
                if elapsed >= limits.maximum {
                    Log.app.info("hands-free: reached the time limit")
                    self.send(.autoStop)
                    return
                }
                let remaining = limits.maximum - elapsed
                let notice = remaining <= limits.warning ? "Stops in \(Int(remaining.rounded(.up))) s" : nil
                if notice != self.handsFreeNotice {
                    self.handsFreeNotice = notice
                    self.onHUDContentChange?()
                }
                guard let silence = await self.session?.secondsSinceSpeech(), self.isHandsFree else { continue }
                let idle = silence >= limits.idleAfter
                if idle != self.isListeningIdle {
                    self.isListeningIdle = idle
                    self.onHUDContentChange?()
                }
                if silence >= limits.silence {
                    Log.app.info("hands-free: stopped after \(Int(silence)) s of silence")
                    self.send(.autoStop)
                    return
                }
            }
        }
    }

    // MARK: Live preview

    /// Re-transcribes the piece in progress, repeatedly, while recording.
    private func startLivePreview() {
        previewTask?.cancel()
        guard preferences.livePreview else { return }
        previewTask = Task { [weak self] in
            var interval = Self.previewInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, self.state.isRecording else { return }
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
                guard !Task.isCancelled, self.state.isRecording else { return }
                // When typing as you speak, committed text is already in the app: show just the tail.
                let shown = self.typer != nil ? tailText : ChineseText.join(committed, tailText)
                let text = self.pipeline.applyRules(shown).trimmed
                if text != self.livePreview {
                    self.livePreview = text
                    self.onHUDContentChange?()
                }
                // Spend at most about half the time transcribing, so long dictations don't pile up.
                interval = max(Self.previewInterval, (ContinuousClock.now - started) * 2)
            }
        }
    }

    // MARK: Typing pipeline

    /// Typing at the end: finish the session, format the whole text, type it once.
    private func transcribeAndInsert(
        _ session: any DictationSessioning, audioSeconds: TimeInterval, handsFree: Bool,
        releasedAt: ContinuousClock.Instant
    ) async -> DictationMachine.Outcome {
        // Text-free metrics event, filled in as the pipeline progresses.
        var event = DictationEvent(date: .now, outcome: .failed, audioSeconds: audioSeconds)
        if handsFree { event.handsFree = true }
        // Earlier pieces are already transcribed; this waits only for the last one.
        let result = await session.finish()
        event.transcribeMS = (ContinuousClock.now - releasedAt).timeInterval * 1000
        record(result, into: &event)
        Log.asr.info("transcribed \(audioSeconds, format: .fixed(precision: 1))s audio in \(result.pieces) pieces; release → text \(event.transcribeMS ?? 0, format: .fixed(precision: 0)) ms (\(result.language ?? "?", privacy: .public))")

        let text = result.text
        if result.failures > 0 {
            event.reason = .recognitionFailed
            metrics.record(event)
            // Keep what was recognized: offer it to copy rather than losing the whole dictation.
            undelivered = pipeline.forTyping(text, context: FocusContext.current()).trimmed
            return .failed(text.trimmed.isEmpty
                ? "Speech recognition failed. Try again."
                : "Part of the dictation couldn't be recognized, so nothing was typed. The rest is below.")
        }
        guard !text.trimmed.isEmpty else {
            event.reason = .nothingRecognized
            metrics.record(event)
            return .failed("Nothing was recognized. Hold fn and try again.")
        }
        let transcriptReady = ContinuousClock.now
        let formatted = pipeline.forTyping(text, context: FocusContext.current())
        event.words = ChineseText.wordCount(formatted)
        do {
            let pastedAt = try await sink.insert(formatted, expecting: focusAtStart)
            event.typeMS = (pastedAt - transcriptReady).timeInterval * 1000
            event.outcome = .inserted
            lastLanguage = event.language
            metrics.record(event)
            Log.app.info("inserted \(formatted.count) characters")
            return .inserted
        } catch {
            event.reason = .init(error)
            metrics.record(event)
            undelivered = formatted.trimmed
            return .failed(error.localizedDescription)
        }
    }

    /// "Type as you speak": earlier pieces are already typed; finish the session, type the
    /// last piece, and report what happened.
    private func finishTypingAsYouSpeak(
        _ session: any DictationSessioning, typer: ProgressiveTyper, audioSeconds: TimeInterval,
        handsFree: Bool, releasedAt: ContinuousClock.Instant
    ) async -> DictationMachine.Outcome {
        var event = DictationEvent(date: .now, outcome: .failed, audioSeconds: audioSeconds)
        if handsFree { event.handsFree = true }
        let result = await session.finish()
        let finishedAt = ContinuousClock.now
        // If typing is paused (user is in another app), don't wait for them to come back.
        typer.finishWithoutWaiting()
        await typer.wait()
        typingPausedFor = nil
        event.transcribeMS = (finishedAt - releasedAt).timeInterval * 1000
        if let typedAt = typer.lastTypedAt { event.typeMS = max(0, (typedAt - finishedAt).timeInterval * 1000) }
        record(result, into: &event)
        event.words = ChineseText.wordCount(typer.typed + " " + typer.untyped.joined(separator: " "))
        Log.app.info("typed as you speak: \(result.pieces) pieces, release → done \((ContinuousClock.now - releasedAt).timeInterval * 1000, format: .fixed(precision: 0)) ms")

        if typer.stopped {
            event.reason = typer.insertionError.map { DictationEvent.Reason($0) } ?? .recognitionFailed
            metrics.record(event)
            undelivered = typer.untyped.joined(separator: " ")
            let why = typer.insertionError?.localizedDescription ?? "Part of the dictation couldn't be recognized."
            return .failed(typer.typed.isEmpty ? why : "Typing stopped partway. \(why)")
        }
        guard !typer.typed.trimmed.isEmpty else {
            event.reason = .nothingRecognized
            metrics.record(event)
            return .failed("Nothing was recognized. Hold fn and try again.")
        }
        event.outcome = .inserted
        lastLanguage = event.language
        metrics.record(event)
        return .inserted
    }

    private func record(_ result: SessionResult, into event: inout DictationEvent) {
        event.engine = result.engine
        event.language = result.language
        event.pieces = result.pieces
        event.emptyPieces = result.emptyPieces
        if let engine = result.engine { activeEngine = engine }
    }

    private func refreshEngineName() async {
        activeEngine = await engine.englishEngineName()
    }
}
