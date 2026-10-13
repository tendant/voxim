//
//  ParakeetTranscriber.swift
//  voxim
//
//  Parakeet TDT via FluidAudio (Apache-2.0). Models download from HuggingFace on first
//  run into ~/Library/Application Support/FluidAudio/Models. See docs/asr-spike.md.
//

import FluidAudio
import Foundation

/// First-run model download/compile progress, independent of FluidAudio's types.
nonisolated enum ModelLoadEvent: Sendable {
    case downloading(fraction: Double)
    case compiling
}

actor ParakeetTranscriber: Transcriber {
    nonisolated let name: String
    private let version: AsrModelVersion
    private var manager: AsrManager?
    private let onProgress: (@Sendable (ModelLoadEvent) -> Void)?

    init(
        version: AsrModelVersion = .v2,
        label: String = "TDT v2",
        onProgress: (@Sendable (ModelLoadEvent) -> Void)? = nil
    ) {
        self.version = version
        self.onProgress = onProgress
        name = "Parakeet \(label)"
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let onProgress = self.onProgress
        let models = try await AsrModels.downloadAndLoad(version: version) { progress in
            switch progress.phase {
            case .listing: onProgress?(.downloading(fraction: 0))
            case .downloading: onProgress?(.downloading(fraction: progress.fractionCompleted))
            case .compiling: onProgress?(.compiling)
            }
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ clip: AudioClip) async throws -> String {
        guard !clip.samples.isEmpty else { throw TranscriberError.emptyAudio }
        if manager == nil { try await prepare() }
        var state = try TdtDecoderState()
        return try await manager!.transcribe(clip.samples, decoderState: &state).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
