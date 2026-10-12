//
//  ASRDebugModel.swift
//  voxim
//
//  Day 1 harness: record from the menu bar, transcribe locally, show latency.
//  Replaced by AppController + push-to-talk on Day 2.
//

import Foundation
import Observation

@Observable
final class ASRDebugModel {
    enum Phase: Equatable {
        case preparing
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    private(set) var phase: Phase = .preparing
    private(set) var transcript = ""
    private(set) var clipDuration: TimeInterval = 0
    private(set) var latency: TimeInterval = 0

    let transcriber: any Transcriber
    private let capture = AudioCapture()

    init(transcriber: any Transcriber = AppleSpeechTranscriber()) {
        self.transcriber = transcriber
        Task { await prepare() }
    }

    func prepare() async {
        phase = .preparing
        do {
            try await transcriber.prepare()
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func toggleRecording() {
        switch phase {
        case .recording: Task { await stopAndTranscribe() }
        case .idle, .failed: Task { await startRecording() }
        case .preparing, .transcribing: break
        }
    }

    private func startRecording() async {
        guard await AudioCapture.requestPermission() else {
            phase = .failed(AudioCaptureError.microphoneDenied.localizedDescription)
            return
        }
        do {
            try capture.start()
            phase = .recording
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func stopAndTranscribe() async {
        let clip = capture.stop()
        clipDuration = clip.duration
        phase = .transcribing
        let started = ContinuousClock.now
        do {
            let text = try await transcriber.transcribe(clip)
            latency = (ContinuousClock.now - started).timeInterval
            transcript = text
            phase = text.isEmpty ? .failed("Nothing was recognized. Try again.") : .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

extension Duration {
    nonisolated var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
