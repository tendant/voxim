// Usage: asr-bench <dir-with-NN.wav> <phrases.txt> [apple|parakeet-v2|parakeet-v3 ...]
// Each line N of phrases.txt is the reference for <dir>/NN.wav (01-based, zero-padded).
@preconcurrency import AVFoundation
import FluidAudio
import Foundation

func loadClip(_ url: URL) throws -> AudioClip {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioClip.sampleRate, channels: 1, interleaved: false)!
    let mono = buffer.format == target ? buffer : try AudioFormatConversion.convert(buffer, to: target)
    return AudioClip(samples: Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength))))
}

func words(_ s: String) -> [String] {
    s.lowercased()
        .replacingOccurrences(of: "-", with: " ")
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

func wordErrors(_ ref: [String], _ hyp: [String]) -> Int {
    var row = Array(0...hyp.count)
    for i in 1...max(ref.count, 1) where !ref.isEmpty {
        var prev = row[0]; row[0] = i
        for j in stride(from: 1, through: hyp.count, by: 1) {
            let cur = row[j]
            row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (ref[i - 1] == hyp[j - 1] ? 0 : 1))
            prev = cur
        }
    }
    return ref.isEmpty ? hyp.count : row[hyp.count]
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted(); return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args[1])
let refs = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map(String.init)
let engines = args.count > 3 ? Array(args[3...]) : ["apple", "parakeet-v2", "parakeet-v3"]
let clips = try refs.indices.map { try loadClip(dir.appendingPathComponent(String(format: "%02d.wav", $0 + 1))) }

for engine in engines {
    let t: any Transcriber = switch engine {
    case "apple": AppleSpeechTranscriber(locale: Locale(identifier: "en-US"))
    case "parakeet-v2": ParakeetTranscriber(version: .v2, label: "TDT v2 (en)")
    case "parakeet-v3": ParakeetTranscriber(version: .v3, label: "TDT v3")
    default: fatalError("unknown engine \(engine)")
    }
    let prepStart = ContinuousClock.now
    try await t.prepare()
    let prep = ContinuousClock.now - prepStart
    _ = try await t.transcribe(clips[0]) // warm-up, excluded

    var latencies: [Double] = [], errors = 0, total = 0, exact = 0
    print("\n## \(t.name)  (prepare \(prep.formatted(.units(allowed: [.seconds, .milliseconds]))))")
    for (i, clip) in clips.enumerated() {
        let start = ContinuousClock.now
        let text = try await t.transcribe(clip)
        let ms = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
            + Double((ContinuousClock.now - start).components.seconds) * 1000
        latencies.append(ms)
        let e = wordErrors(words(refs[i]), words(text))
        errors += e; total += words(refs[i]).count; exact += e == 0 ? 1 : 0
        print(String(format: "%02d %5.0f ms  %d err  %@", i + 1, ms, e, text))
    }
    print(String(format: "WER %.1f%%  exact %d/%d  latency p50 %.0f ms  p95 %.0f ms",
                 100 * Double(errors) / Double(total), exact, clips.count,
                 percentile(latencies, 0.5), percentile(latencies, 0.95)))
}
