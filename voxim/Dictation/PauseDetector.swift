//
//  PauseDetector.swift
//  voxim
//
//  Decides where a dictation piece ends, from per-chunk speech decisions.
//  Tuned in docs/long-dictation-spike.md: pause ≥ 0.25 s (one Silero chunk), pieces ≥ 1.5 s,
//  forced cut by 25 s at the quietest point in the last 3 s.
//

import Foundation

nonisolated struct PauseDetector {
    struct Config {
        var minPause: TimeInterval = 0.25
        var minPiece: TimeInterval = 1.5
        var maxPiece: TimeInterval = 25
        var forcedCutSearch: TimeInterval = 3
        /// A piece needs at least this much speech before a pause can end it.
        var minSpeech: TimeInterval = 0.2
    }

    enum Cut: Equatable {
        /// End the piece here: the middle of a pause.
        case pause(at: Int)
        /// The piece is too long: cut at the quietest point inside this range.
        case forced(searchIn: Range<Int>)
    }

    let config: Config
    let sampleRate: Double

    /// Absolute sample positions since the start of the dictation.
    private(set) var pieceStart = 0
    private(set) var position = 0
    private var silenceRun = 0
    private var speechSamples = 0

    init(config: Config = Config(), sampleRate: Double = AudioClip.sampleRate) {
        self.config = config
        self.sampleRate = sampleRate
    }

    var pieceHasSpeech: Bool { Double(speechSamples) >= config.minSpeech * sampleRate }

    /// Feed the decision for the next `count` samples. A returned cut must be followed by
    /// `startPiece(at:)` with the chosen position.
    mutating func feed(samples count: Int, isSpeech: Bool) -> Cut? {
        position += count
        if isSpeech {
            silenceRun = 0
            speechSamples += count
        } else {
            silenceRun += count
        }
        let length = Double(position - pieceStart)
        if Double(silenceRun) >= config.minPause * sampleRate, length >= config.minPiece * sampleRate, pieceHasSpeech {
            return .pause(at: position - silenceRun / 2)
        }
        if length >= config.maxPiece * sampleRate {
            let from = max(pieceStart, position - Int(config.forcedCutSearch * sampleRate))
            return .forced(searchIn: from..<position)
        }
        return nil
    }

    mutating func startPiece(at cut: Int) {
        pieceStart = cut
        speechSamples = 0
        // Audio after the cut that was silent stays counted as silence.
        silenceRun = min(silenceRun, position - cut)
    }

    /// Center of the quietest 100 ms window in `range` of `samples` (whose index 0 is `base`).
    static func quietestPoint(_ samples: [Float], base: Int, in range: Range<Int>, frame: Int = 1_600) -> Int {
        let lower = max(range.lowerBound - base, 0), upper = min(range.upperBound - base, samples.count)
        var best = range.upperBound, bestEnergy = Float.greatestFiniteMagnitude
        var i = lower
        while i + frame <= upper {
            var energy: Float = 0
            for j in i..<(i + frame) { energy += samples[j] * samples[j] }
            if energy < bestEnergy { bestEnergy = energy; best = base + i + frame / 2 }
            i += frame / 4
        }
        return best
    }
}
