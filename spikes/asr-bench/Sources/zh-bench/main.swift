// zh-bench: Chinese / English / mixed ASR + language-ID spike.
// Usage: zh-bench <clip-dir-with-manifest.tsv> [--details]
//
// Scores with a mixed error rate (MER): CJK characters and Latin words are each one token,
// punctuation and spacing ignored, Traditional folded to Simplified. For pure English this
// is WER, for pure Chinese it's CER.
@preconcurrency import AVFoundation
import FluidAudio
import Foundation

struct Clip {
    let file: String
    let lang: String     // en | zh | mix
    let length: String   // short | normal
    let voice: String
    let reference: String
    let audio: AudioClip
    var category: String { "\(lang)-\(length)" }
    /// Expected SenseVoice language tag: mixed speech should route to the Chinese path.
    var expectedLID: String { lang == "en" ? "en" : "zh" }
}

struct Result {
    let text: String
    let lid: String?
    let ms: Double
}

func loadClip(_ url: URL) throws -> AudioClip {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioClip.sampleRate, channels: 1, interleaved: false)!
    let mono = buffer.format == target ? buffer : try AudioFormatConversion.convert(buffer, to: target)
    return AudioClip(samples: Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength))))
}

func isCJK(_ s: Unicode.Scalar) -> Bool {
    (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) || (0xF900...0xFAFF).contains(s.value)
}

func containsCJK(_ text: String) -> Bool { text.unicodeScalars.contains(where: isCJK) }

/// CJK chars as single tokens, Latin/digit runs as words, everything else dropped.
func tokens(_ text: String) -> [String] {
    let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    var result: [String] = []
    var word = ""
    for scalar in simplified.lowercased().unicodeScalars {
        if isCJK(scalar) {
            if !word.isEmpty { result.append(word); word = "" }
            result.append(String(scalar))
        } else if CharacterSet.alphanumerics.contains(scalar) {
            word.unicodeScalars.append(scalar)
        } else if !word.isEmpty {
            result.append(word); word = ""
        }
    }
    if !word.isEmpty { result.append(word) }
    return result
}

func editDistance(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty { return b.count }
    var row = Array(0...b.count)
    for i in 1...a.count {
        var prev = row[0]; row[0] = i
        for j in stride(from: 1, through: b.count, by: 1) {
            let cur = row[j]
            row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
            prev = cur
        }
    }
    return row[b.count]
}

func ms(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted(); return s.isEmpty ? .nan : s[s.count / 2]
}

// MARK: Load clips

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args[1])
let details = args.contains("--details")
let manifest = try String(contentsOf: dir.appending(path: "manifest.tsv"), encoding: .utf8)
let clips: [Clip] = try manifest.split(separator: "\n").map { line in
    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    return Clip(file: f[0], lang: f[1], length: f[2], voice: f[3], reference: f[4],
                audio: try loadClip(dir.appending(path: f[0])))
}
print("clips: \(clips.count)")

// MARK: Engines

func timed(_ body: () async throws -> (String, String?)) async throws -> Result {
    let start = ContinuousClock.now
    let (text, lid) = try await body()
    return Result(text: text, lid: lid, ms: ms(since: start))
}

print("loading SenseVoice…")
var t0 = ContinuousClock.now
let senseModels = try await SenseVoiceModels.downloadAndLoad(precision: .fp16)
// FunASR SenseVoice embed indices: language auto=0, zh=3, en=4; text norm withitn=14 (punctuation).
let senseAuto = SenseVoiceManager(models: senseModels, language: 0, textNorm: 14)
let senseZh = SenseVoiceManager(models: senseModels, language: 3, textNorm: 14)
print(String(format: "  %.1f s", ms(since: t0) / 1000))

print("loading Paraformer (int8)…")
t0 = ContinuousClock.now
let paraformer = try await ParaformerManager.load(precision: .int8)
print(String(format: "  %.1f s", ms(since: t0) / 1000))

print("loading Parakeet v2, Apple zh_CN / en_US…")
let parakeet = ParakeetTranscriber(version: .v2, label: "TDT v2")
try await parakeet.prepare()
let appleZh = AppleSpeechTranscriber(locale: Locale(identifier: "zh_CN"))
try await appleZh.prepare()
let appleEn = AppleSpeechTranscriber(locale: Locale(identifier: "en_US"))
try await appleEn.prepare()
typealias Engine = (name: String, applies: (Clip) -> Bool, run: (AudioClip) async throws -> (String, String?))
let engines: [Engine] = [
    ("SenseVoice auto", { _ in true }, { a in
        let r = try await senseAuto.transcribeDetailed(audio: a.samples); return (r.text, r.language) }),
    ("SenseVoice zh", { $0.lang != "en" }, { a in
        let r = try await senseZh.transcribeDetailed(audio: a.samples); return (r.text, r.language) }),
    ("Paraformer", { $0.lang != "en" }, { a in (try await paraformer.transcribe(audio: a.samples), nil) }),
    ("Apple zh_CN", { $0.lang != "en" }, { a in (try await appleZh.transcribe(a), nil) }),
    ("Apple en_US", { $0.lang == "en" }, { a in (try await appleEn.transcribe(a), nil) }),
    ("Parakeet v2", { _ in true }, { a in (try await parakeet.transcribe(a), nil) }),
    // Proposed Auto mode: SenseVoice LID; English with no CJK → re-run on Parakeet.
    ("Auto (SV LID→Parakeet)", { _ in true }, { a in
        let r = try await senseAuto.transcribeDetailed(audio: a.samples)
        if r.language == "nospeech" { return ("", r.language) }
        if !containsCJK(r.text) && r.language != "zh" && r.language != "yue" {
            return (try await parakeet.transcribe(a), r.language)
        }
        return (r.text, r.language)
    }),
]

// Warm-up: one clip per engine, excluded.
for e in engines { if let c = clips.first(where: e.applies) { _ = try? await e.run(c.audio) } }

// MARK: Run

let categories = ["en-short", "en-normal", "zh-short", "zh-normal", "mix-short", "mix-normal"]
var table: [String: [String: (errors: Int, total: Int, ms: [Double])]] = [:]
var lidHits: [String: (ok: Int, n: Int, wrong: [String])] = [:]

for e in engines {
    for clip in clips where e.applies(clip) {
        let r: Result
        do { r = try await timed { try await e.run(clip.audio) } }
        catch { r = Result(text: "<error: \(error)>", lid: nil, ms: .nan) }
        let ref = tokens(clip.reference), hyp = tokens(r.text)
        let err = editDistance(ref, hyp)
        var cell = table[e.name, default: [:]][clip.category, default: (0, 0, [])]
        cell.errors += err; cell.total += ref.count; cell.ms.append(r.ms)
        table[e.name, default: [:]][clip.category] = cell
        if e.name == "SenseVoice auto" {
            var h = lidHits[clip.category, default: (0, 0, [])]
            h.n += 1
            if r.lid == clip.expectedLID { h.ok += 1 } else { h.wrong.append("\(clip.file)=\(r.lid ?? "nil")") }
            lidHits[clip.category] = h
        }
        if details {
            print(String(format: "%-24@ %@ %-10@ %4.0f ms %2d err  lid=%-4@ %@  ⟵ %@",
                         e.name, clip.file, clip.category, r.ms, err, r.lid ?? "-", r.text, clip.reference))
        }
    }
}

// MARK: Report

print("\n## Language ID (SenseVoice auto; mixed expected → zh)")
for c in categories { if let h = lidHits[c] {
    print(String(format: "%-11@ %2d/%2d  %@", c, h.ok, h.n, h.wrong.isEmpty ? "" : "wrong: " + h.wrong.joined(separator: ", ")))
} }

print("\n## Mixed error rate (lower is better) · median latency")
print("engine".padding(toLength: 24, withPad: " ", startingAt: 0) + categories.map { $0.padding(toLength: 17, withPad: " ", startingAt: 0) }.joined())
for e in engines {
    var line = e.name.padding(toLength: 24, withPad: " ", startingAt: 0)
    for c in categories {
        if let cell = table[e.name]?[c], cell.total > 0 {
            line += String(format: "%5.1f%% %5.0fms    ", 100 * Double(cell.errors) / Double(cell.total), median(cell.ms))
        } else {
            line += "      —          "
        }
    }
    print(line)
}
