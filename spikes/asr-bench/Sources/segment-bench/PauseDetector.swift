// Prototype of the app's PauseDetector (docs/long-dictation-plan.md, phase 0).
// Consumes per-frame speech/non-speech decisions and decides where a piece ends.
import Foundation

struct PauseDetectorConfig {
    var frameSamples = 512            // 32 ms at 16 kHz
    var minPause: Double = 0.30       // silence needed to end a piece
    var minPiece: Double = 1.5        // don't cut pieces shorter than this
    var maxPiece: Double = 25.0       // force a cut by this length
    var forcedCutSearch: Double = 3.0 // look for the quietest point in the last N s
}

/// Speech decision per frame. Energy: adaptive noise floor. Silero: model probability.
protocol FrameClassifier {
    /// Returns one decision per `frameSamples` frame of `samples` (which starts at `offset`).
    mutating func classify(_ samples: ArraySlice<Float>) async throws -> [Bool]
}

/// RMS energy against an adaptive noise floor (slowly rising minimum).
struct EnergyClassifier: FrameClassifier {
    var frameSamples = 512
    var marginDB: Float = 12
    private var floorDB: Float = -70

    init(frameSamples: Int = 512, marginDB: Float = 12) {
        self.frameSamples = frameSamples
        self.marginDB = marginDB
    }

    mutating func classify(_ samples: ArraySlice<Float>) async throws -> [Bool] {
        var out: [Bool] = []
        var i = samples.startIndex
        while i + frameSamples <= samples.endIndex {
            var sum: Float = 0
            for j in i..<(i + frameSamples) { sum += samples[j] * samples[j] }
            let db = 10 * log10(max(sum / Float(frameSamples), 1e-10))
            // Floor follows quiet frames quickly, loud frames very slowly.
            floorDB = db < floorDB ? 0.7 * floorDB + 0.3 * db : floorDB + 0.02
            out.append(db > max(floorDB + marginDB, -55))
            i += frameSamples
        }
        return out
    }
}

struct Piece {
    var range: Range<Int>
    var forced: Bool
}

/// Streaming piece segmentation over frame decisions.
struct PauseDetector {
    let config: PauseDetectorConfig
    private(set) var pieceStart = 0
    private var silenceRun = 0         // frames
    private var speechFramesInPiece = 0
    private var position = 0           // samples consumed

    init(config: PauseDetectorConfig = .init()) { self.config = config }

    var sr: Double { 16_000 }

    /// Feed decisions for the next frames; returns pieces completed by them.
    mutating func feed(_ decisions: [Bool], audio: [Float]) -> [Piece] {
        var pieces: [Piece] = []
        for isSpeech in decisions {
            position += config.frameSamples
            if isSpeech { silenceRun = 0; speechFramesInPiece += 1 } else { silenceRun += 1 }
            let pieceLength = Double(position - pieceStart) / sr
            let silence = Double(silenceRun * config.frameSamples) / sr
            if silence >= config.minPause && pieceLength >= config.minPiece && speechFramesInPiece > 3 {
                // Cut in the middle of the pause.
                let cut = position - silenceRun * config.frameSamples / 2
                pieces.append(Piece(range: pieceStart..<cut, forced: false))
                pieceStart = cut; speechFramesInPiece = 0
            } else if pieceLength >= config.maxPiece {
                let searchStart = max(pieceStart, position - Int(config.forcedCutSearch * sr))
                let cut = Self.quietest(audio, in: searchStart..<position, frame: config.frameSamples)
                pieces.append(Piece(range: pieceStart..<cut, forced: true))
                pieceStart = cut; speechFramesInPiece = 0
            }
        }
        return pieces
    }

    /// Whatever is left at release.
    func finish(totalSamples: Int) -> Piece? {
        pieceStart < totalSamples ? Piece(range: pieceStart..<totalSamples, forced: false) : nil
    }

    static func quietest(_ audio: [Float], in range: Range<Int>, frame: Int) -> Int {
        var best = range.upperBound, bestEnergy = Float.greatestFiniteMagnitude
        var i = range.lowerBound
        while i + frame <= range.upperBound {
            var e: Float = 0
            for j in i..<(i + frame) { e += audio[j] * audio[j] }
            if e < bestEnergy { bestEnergy = e; best = i + frame / 2 }
            i += frame / 2
        }
        return best
    }
}
