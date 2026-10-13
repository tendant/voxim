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

    private(set) var phase: Phase = .idle
    /// Last transcript that could not be typed; offered for copying. Cleared on the next recording.
    private(set) var undelivered = ""
    private(set) var activeEngine = ""
    let modelStatus: ModelStatus

    private let transcriber: FallbackTranscriber
    private let sink: any DictationSink
    private let capture = AudioCapture()
    private var pressStarted: ContinuousClock.Instant?
    private var keyHeld = false
    private var focusAtStart: FocusedApp?

    /// Called whenever the HUD should change visibility.
    var onHUDVisibilityChange: ((Bool) -> Void)?

    init(sink: any DictationSink = PasteInserter()) {
        let modelStatus = ModelStatus()
        let parakeet = ParakeetTranscriber { event in
            switch event {
            case .downloading(let fraction): modelStatus.post(.downloading(fraction: fraction))
            case .compiling: modelStatus.post(.compiling)
            }
        }
        self.modelStatus = modelStatus
        self.transcriber = FallbackTranscriber(primary: parakeet, fallback: AppleSpeechTranscriber())
        self.sink = sink

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

    func keyDown() {
        keyHeld = true
        switch phase {
        case .idle, .inserted, .failed: break
        case .recording, .transcribing: return
        }
        if !AXAccess.isTrusted {
            AXAccess.requestTrust()
            fail(InsertionError.accessibilityDenied.localizedDescription)
            return
        }
        Task {
            guard await AudioCapture.requestPermission() else {
                fail(AudioCaptureError.microphoneDenied.localizedDescription)
                return
            }
            // Released while the permission check was pending: don't start a recording.
            guard keyHeld else { return }
            do {
                try capture.start()
                pressStarted = .now
                focusAtStart = FocusedApp.current
                undelivered = ""
                setPhase(.recording)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func keyUp() {
        keyHeld = false
        guard phase == .recording else { return }
        let clip = capture.stop()
        let held = pressStarted.map { ContinuousClock.now - $0 } ?? .zero
        pressStarted = nil
        guard held >= Self.minimumHold else {
            setPhase(.idle)
            return
        }
        setPhase(.transcribing)
        Task { await transcribeAndInsert(clip) }
    }

    /// Esc while recording: discard the audio without transcribing or typing anything.
    func cancelRecording() {
        guard phase == .recording else { return }
        _ = capture.stop()
        pressStarted = nil
        Log.app.info("recording cancelled")
        setPhase(.idle)
    }

    func dismiss() {
        undelivered = ""
        setPhase(.idle)
    }

    // MARK: Pipeline

    private func transcribeAndInsert(_ clip: AudioClip) async {
        let text: String
        do {
            let started = ContinuousClock.now
            text = try await transcriber.transcribe(clip)
            let elapsedMS = (ContinuousClock.now - started).timeInterval * 1000
            Log.asr.info("transcribed \(clip.duration, format: .fixed(precision: 1))s audio in \(elapsedMS, format: .fixed(precision: 0)) ms")
            await refreshEngineName()
        } catch {
            fail(error.localizedDescription)
            return
        }
        guard !text.trimmed.isEmpty else {
            fail("Nothing was recognized. Hold the shortcut and try again.")
            return
        }

        do {
            try await sink.insert(text, expecting: focusAtStart)
            Log.app.info("inserted \(text.count) characters")
            setPhase(.inserted)
        } catch {
            undelivered = text
            fail(error.localizedDescription)
        }
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
