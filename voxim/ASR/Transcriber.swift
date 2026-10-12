//
//  Transcriber.swift
//  voxim
//

import Foundation

/// Mono 16 kHz Float32 audio held in memory only; discarded after transcription.
nonisolated struct AudioClip: Sendable {
    static let sampleRate: Double = 16_000

    var samples: [Float]

    var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
}

nonisolated enum TranscriberError: LocalizedError {
    case unsupportedLocale(Locale)
    case unavailable(String)
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let locale): "Speech recognition does not support \(locale.identifier)."
        case .unavailable(let reason): "Speech recognition is unavailable: \(reason)"
        case .emptyAudio: "No audio was captured."
        }
    }
}

/// Local ASR boundary. Implementations must not send audio off-device.
nonisolated protocol Transcriber: Sendable {
    var name: String { get }
    /// Loads or downloads the model ahead of the first utterance.
    func prepare() async throws
    func transcribe(_ clip: AudioClip) async throws -> String
}
