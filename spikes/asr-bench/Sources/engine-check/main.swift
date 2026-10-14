// engine-check: runs the app's real DictationEngine in each language mode over a clip set.
// Usage: engine-check <dir with manifest.tsv>
@preconcurrency import AVFoundation
import Foundation

func loadClip(_ url: URL) throws -> AudioClip {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioClip.sampleRate, channels: 1, interleaved: false)!
    let mono = buffer.format == target ? buffer : try AudioFormatConversion.convert(buffer, to: target)
    return AudioClip(samples: Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength))))
}

func tokens(_ text: String) -> [String] {
    let s = ChineseText.converting(text, to: .simplified).lowercased()
    var out: [String] = [], word = ""
    for c in s.unicodeScalars {
        if ChineseText.isCJK(c) { if !word.isEmpty { out.append(word); word = "" }; out.append(String(c)) }
        else if CharacterSet.alphanumerics.contains(c) { word.unicodeScalars.append(c) }
        else if !word.isEmpty { out.append(word); word = "" }
    }
    if !word.isEmpty { out.append(word) }
    return out
}

func distance(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    var row = Array(0...b.count)
    for i in 1...a.count {
        var prev = row[0]; row[0] = i
        for j in stride(from: 1, through: b.count, by: 1) {
            let cur = row[j]; row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1)); prev = cur
        }
    }
    return row[b.count]
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let rows = try String(contentsOf: dir.appending(path: "manifest.tsv"), encoding: .utf8)
    .split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }

let engine = DictationEngine(
    english: FallbackTranscriber(primary: ParakeetTranscriber(), fallback: AppleSpeechTranscriber(locale: Locale(identifier: "en_US"))),
    senseVoice: SenseVoiceTranscriber()
)
try await engine.prepareEnglish()
_ = await engine.waitForEnglishPrimary()
if let error = await engine.prepareChinese() { print("Chinese model failed: \(error)"); exit(1) }

for mode in LanguageMode.allCases {
    var errors: [String: (Int, Int)] = [:]
    var languages: [String: [String: Int]] = [:]
    var engines: [String: Int] = [:]
    for row in rows {
        let clip = try loadClip(dir.appending(path: row[0]))
        let t = try await engine.transcribe(clip, mode: mode)
        let ref = tokens(row[4])
        let e = distance(ref, tokens(t.text))
        let group = row[1]
        errors[group, default: (0, 0)].0 += e; errors[group, default: (0, 0)].1 += ref.count
        languages[group, default: [:]][t.language ?? "nil", default: 0] += 1
        engines[t.engine, default: 0] += 1
    }
    print("\n## \(mode.rawValue)   engines: \(engines.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", "))")
    for g in ["en", "zh", "mix"] {
        let (e, n) = errors[g] ?? (0, 1)
        print(String(format: "  %-4@ MER %5.1f%%   reported language: %@", g, 100 * Double(e) / Double(n),
                     (languages[g] ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")))
    }
}

// Optional: preview cost on growing prefixes of one long clip.
if CommandLine.arguments.count > 2 {
    let long = try loadClip(URL(fileURLWithPath: CommandLine.arguments[2]))
    print("\n## Preview pass time on growing audio (\(Int(long.duration)) s clip)")
    for mode in [LanguageMode.english, .auto, .chinese] {
        var line = "  \(mode.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))"
        for seconds in [2.0, 5, 10, 30, 60, long.duration] {
            let prefix = AudioClip(samples: Array(long.samples.prefix(Int(seconds * AudioClip.sampleRate))))
            let start = ContinuousClock.now
            _ = try await engine.transcribe(prefix, mode: mode)
            let d = ContinuousClock.now - start
            line += String(format: "  %3.0fs: %4.0f ms", seconds, Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        print(line)
    }
}
