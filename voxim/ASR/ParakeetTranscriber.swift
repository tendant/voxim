//
//  ParakeetTranscriber.swift
//  voxim
//
//  Parakeet TDT via FluidAudio (Apache-2.0). Models download from HuggingFace on first
//  run into ~/Library/Application Support/FluidAudio/Models. See docs/asr-spike.md.
//

import FluidAudio
import Foundation

actor ParakeetTranscriber: Transcriber {
    nonisolated let name: String
    private let version: AsrModelVersion
    private var manager: AsrManager?

    init(version: AsrModelVersion = .v2, label: String = "TDT v2") {
        self.version = version
        name = "Parakeet \(label)"
    }

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version)
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
