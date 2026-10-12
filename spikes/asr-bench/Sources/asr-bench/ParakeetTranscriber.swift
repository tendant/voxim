import FluidAudio
import Foundation

/// Spike-only adapter; moves into the app if Parakeet wins.
actor ParakeetTranscriber: Transcriber {
    nonisolated let name: String
    private let version: AsrModelVersion
    private var manager: AsrManager?

    init(version: AsrModelVersion, label: String) {
        self.version = version
        name = "Parakeet \(label)"
    }

    func prepare() async throws {
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
