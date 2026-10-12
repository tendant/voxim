//
//  AppleSpeechTranscriber.swift
//  voxim
//

import AVFoundation
import Speech

/// On-device transcription using the macOS 26 SpeechAnalyzer stack.
actor AppleSpeechTranscriber: Transcriber {
    nonisolated let name = "Apple SpeechTranscriber"

    private let requestedLocale: Locale
    private var locale: Locale?
    private var analyzerFormat: AVAudioFormat?

    init(locale: Locale = .current) {
        requestedLocale = locale
    }

    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriberError.unavailable("SpeechTranscriber is not available on this Mac.")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriberError.unsupportedLocale(requestedLocale)
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        self.locale = locale
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    }

    func transcribe(_ clip: AudioClip) async throws -> String {
        guard !clip.samples.isEmpty else { throw TranscriberError.emptyAudio }
        if locale == nil { try await prepare() }
        guard let locale, let analyzerFormat else {
            throw TranscriberError.unavailable("No compatible audio format.")
        }

        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let buffer = try Self.makeBuffer(clip, format: analyzerFormat)

        // .transcription reports final results only; join them in order.
        let collector = Task {
            var parts: [String] = []
            for try await result in module.results {
                parts.append(String(result.text.characters))
            }
            return parts.joined()
        }

        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        do {
            try await analyzer.start(inputSequence: inputs)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeBuffer(_ clip: AudioClip, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioClip.sampleRate, channels: 1, interleaved: false
        )!
        let frames = AVAudioFrameCount(clip.samples.count)
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frames) else {
            throw TranscriberError.unavailable("Could not allocate audio buffer.")
        }
        source.frameLength = frames
        clip.samples.withUnsafeBufferPointer { samples in
            source.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        }
        if format == sourceFormat { return source }
        return try AudioFormatConversion.convert(source, to: format)
    }
}
