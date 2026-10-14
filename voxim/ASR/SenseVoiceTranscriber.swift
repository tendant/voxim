//
//  SenseVoiceTranscriber.swift
//  voxim
//
//  SenseVoice Small via FluidAudio: Mandarin / English / Cantonese with built-in language ID.
//  Downloaded (~450 MB) only when a Chinese-capable language mode is chosen. See docs/zh-spike.md.
//

import FluidAudio
import Foundation

actor SenseVoiceTranscriber {
    nonisolated let name = "SenseVoice"

    /// FunASR SenseVoice embed indices: language auto = 0, zh = 3; text norm "withitn" = 14
    /// (punctuation and inverse text normalization).
    private static let autoLanguage: Int32 = 0
    private static let chineseLanguage: Int32 = 3
    private static let withPunctuation: Int32 = 14

    private let onProgress: (@Sendable (ModelLoadEvent) -> Void)?
    private var auto: SenseVoiceManager?
    private var chinese: SenseVoiceManager?

    init(onProgress: (@Sendable (ModelLoadEvent) -> Void)? = nil) {
        self.onProgress = onProgress
    }

    var isReady: Bool { auto != nil }

    func prepare() async throws {
        guard auto == nil else { return }
        let onProgress = self.onProgress
        let models = try await SenseVoiceModels.downloadAndLoad(precision: .fp16) { progress in
            switch progress.phase {
            case .listing: onProgress?(.downloading(fraction: 0))
            case .downloading: onProgress?(.downloading(fraction: progress.fractionCompleted))
            case .compiling: onProgress?(.compiling)
            }
        }
        auto = SenseVoiceManager(models: models, language: Self.autoLanguage, textNorm: Self.withPunctuation)
        chinese = SenseVoiceManager(models: models, language: Self.chineseLanguage, textNorm: Self.withPunctuation)
    }

    /// Returns the text and the model's language tag (`zh`, `en`, `yue`, `ja`, `ko`, `nospeech`).
    /// Audio longer than the model's 30 s limit is split at quiet points and the parts joined.
    func transcribe(_ clip: AudioClip, forceChinese: Bool) async throws -> (text: String, language: String?) {
        guard !clip.samples.isEmpty else { throw TranscriberError.emptyAudio }
        if auto == nil { try await prepare() }
        let manager = forceChinese ? chinese! : auto!
        var text = ""
        var language: String?
        for range in Self.segments(clip.samples.count, samples: clip.samples) {
            var part = Array(clip.samples[range])
            if part.count < Self.minSamples { part += Array(repeating: 0, count: Self.minSamples - part.count) }
            let result = try await manager.transcribeDetailed(audio: part)
            if language == nil || language == "nospeech" { language = result.language }
            text = Self.join(text, result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (text, language)
    }

    // MARK: Long audio

    /// The model's input range: 0.2 s to 30 s at 16 kHz.
    nonisolated static let minSamples = 3_200
    nonisolated static let maxSamples = 480_000
    /// Segments stay under this (28 s), leaving margin below the hard limit.
    nonisolated static let segmentSamples = 448_000
    /// Where to look for a quiet cut point: the last 3 s of each segment.
    nonisolated static let cutSearchSamples = 48_000

    /// Splits `count` samples into consecutive ranges of at most `segmentSamples`, cutting
    /// each at the quietest 100 ms in its final 3 s so words aren't sliced.
    nonisolated static func segments(_ count: Int, samples: [Float]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while count - start > segmentSamples {
            let end = start + segmentSamples
            let cut = quietestPoint(samples, in: (end - cutSearchSamples)..<end)
            ranges.append(start..<cut)
            start = cut
        }
        ranges.append(start..<count)
        return ranges
    }

    private nonisolated static func quietestPoint(_ samples: [Float], in window: Range<Int>) -> Int {
        let frame = 1_600, hop = 400
        var best = window.upperBound, bestEnergy = Float.greatestFiniteMagnitude
        var position = window.lowerBound
        while position + frame <= window.upperBound {
            var energy: Float = 0
            for i in position..<(position + frame) { energy += samples[i] * samples[i] }
            if energy < bestEnergy { bestEnergy = energy; best = position + frame / 2 }
            position += hop
        }
        return best
    }

    nonisolated static func join(_ a: String, _ b: String) -> String { ChineseText.join(a, b) }
}
