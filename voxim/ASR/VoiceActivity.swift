//
//  VoiceActivity.swift
//  voxim
//
//  Speech / non-speech decisions for pause detection: Silero VAD via FluidAudio (1 MB model,
//  downloaded once). Chosen over an energy threshold, which fragments speech in noise
//  (docs/long-dictation-spike.md).
//

import FluidAudio
import Foundation
import os

nonisolated protocol SpeechClassifier: AnyObject, Sendable {
    /// Samples per decision.
    var chunkSize: Int { get }
    func isSpeech(_ chunk: [Float]) async throws -> Bool
}

/// One streaming Silero state per dictation.
actor SileroSpeechClassifier: SpeechClassifier {
    nonisolated let chunkSize = VadManager.chunkSize  // 4096 samples = 256 ms
    private let vad: VadManager
    private var state: VadStreamState

    init(vad: VadManager, state: VadStreamState) {
        self.vad = vad
        self.state = state
    }

    func isSpeech(_ chunk: [Float]) async throws -> Bool {
        let result = try await vad.processStreamingChunk(chunk, state: state)
        state = result.state
        return result.probability > 0.5
    }
}

/// Loads the Silero model once and hands out per-dictation classifiers.
actor VoiceActivityModel {
    private var loading: Task<VadManager?, Never>?

    /// Starts loading in the background; safe to call repeatedly.
    func prepare() {
        guard loading == nil else { return }
        loading = Task {
            do {
                return try await VadManager()
            } catch {
                Log.asr.error("voice activity model unavailable: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// nil when the model can't be loaded; dictation then falls back to one pass at release.
    func makeClassifier() async -> (any SpeechClassifier)? {
        prepare()
        guard let vad = await loading?.value else { return nil }
        let state = await vad.makeStreamState()
        // The app's default isolation makes the initializer main-actor bound.
        return await MainActor.run { SileroSpeechClassifier(vad: vad, state: state) }
    }
}
