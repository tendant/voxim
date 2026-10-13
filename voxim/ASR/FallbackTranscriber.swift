//
//  FallbackTranscriber.swift
//  voxim
//

import Foundation
import os

/// Uses `primary` once it has loaded; until then (first-run model download) or if it
/// fails to load, uses `fallback`. Both are local engines.
actor FallbackTranscriber: Transcriber {
    nonisolated let name = "Local ASR"

    private let primary: any Transcriber
    private let fallback: any Transcriber
    private var primaryReady = false
    private var primaryLoad: Task<(any Error)?, Never>?

    init(primary: any Transcriber, fallback: any Transcriber) {
        self.primary = primary
        self.fallback = fallback
    }

    /// Name of the engine that would handle the next utterance.
    var activeName: String { primaryReady ? primary.name : fallback.name }

    func prepare() async throws {
        if primaryLoad == nil {
            let primary = self.primary
            primaryLoad = Task {
                do {
                    try await primary.prepare()
                    self.markPrimaryReady()
                    return nil
                } catch {
                    Log.asr.error("primary ASR failed to load: \(error.localizedDescription, privacy: .public)")
                    return error
                }
            }
        }
        try await fallback.prepare()
    }

    /// Waits for the primary engine to finish loading; returns its load error, if any.
    /// Call after `prepare()`.
    func waitForPrimary() async -> (any Error)? {
        await primaryLoad?.value
    }

    func transcribe(_ clip: AudioClip) async throws -> String {
        if primaryReady {
            do {
                return try await primary.transcribe(clip)
            } catch {
                Log.asr.error("primary ASR failed, using fallback: \(error.localizedDescription, privacy: .public)")
            }
        }
        return try await fallback.transcribe(clip)
    }

    private func markPrimaryReady() {
        primaryReady = true
        Log.asr.info("primary ASR ready: \(self.primary.name, privacy: .public)")
    }
}
