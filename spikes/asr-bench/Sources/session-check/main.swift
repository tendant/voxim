// session-check: the app's real DictationSession (Silero + engines) on long clips, replayed at 10× real time.
// Usage: session-check <scratch dir with tts-long/, tts-zh-long/>   (run from spikes/asr-bench)
@preconcurrency import AVFoundation
import Foundation

func load(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let mono = buffer.format == target ? buffer : try AudioFormatConversion.convert(buffer, to: target)
    return Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength)))
}

func tokens(_ t: String) -> [String] {
    let s = ChineseText.converting(t, to: .simplified).lowercased(); var out: [String] = [], w = ""
    for c in s.unicodeScalars {
        if ChineseText.isCJK(c) { if !w.isEmpty { out.append(w); w = "" }; out.append(String(c)) }
        else if CharacterSet.alphanumerics.contains(c) { w.unicodeScalars.append(c) } else if !w.isEmpty { out.append(w); w = "" }
    }
    if !w.isEmpty { out.append(w) }; return out
}
func mer(_ r: String, _ h: String) -> Double {
    let a = tokens(r), b = tokens(h); var row = Array(0...b.count)
    for i in 1...a.count { var p = row[0]; row[0] = i
        for j in stride(from: 1, through: b.count, by: 1) { let c = row[j]; row[j] = min(row[j] + 1, row[j - 1] + 1, p + (a[i - 1] == b[j - 1] ? 0 : 1)); p = c } }
    return Double(row[b.count]) / Double(a.count)
}

let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
let refs = try String(contentsOfFile: "long-phrases.txt", encoding: .utf8).split(separator: "\n").map(String.init)
let zhRef = try String(contentsOf: scratch.appending(path: "tts-zh-long/manifest.tsv"), encoding: .utf8).split(separator: "\t").map(String.init)[4]
var cases: [(String, URL, String, LanguageMode)] = [
    ("en-46s", scratch.appending(path: "tts-long/01.wav"), refs[0], .english),
    ("en-133s", scratch.appending(path: "tts-long/03.wav"), refs[2], .english),
    ("zh-153s", scratch.appending(path: "tts-zh-long/01.wav"), zhRef, .chinese),
    ("zh-153s", scratch.appending(path: "tts-zh-long/01.wav"), zhRef, .auto),
]

// Chinese-dominant dictation with English terms: Chinese and mixed sentences, 0.7 s apart.
let zhManifest = try String(contentsOf: scratch.appending(path: "tts-zh/manifest.tsv"), encoding: .utf8)
    .split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
var zhMix: [Float] = [], zhMixRef: [String] = []
for name in ["16_1", "21_1", "17_1", "23_1", "18_2", "22_2", "19_1", "24_2", "20_2", "25_1", "26_1", "27_2", "28_1"] {
    let row = zhManifest.first { $0[0] == name + ".wav" }!
    zhMix += try load(scratch.appending(path: "tts-zh/\(row[0])")) + [Float](repeating: 0, count: 11_200)
    zhMixRef.append(row[4])
}
let zhMixURL = scratch.appending(path: "zh-mix.wav")
do {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: zhMixURL, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(zhMix.count))!
    buffer.frameLength = AVAudioFrameCount(zhMix.count)
    zhMix.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: zhMix.count) }
    try file.write(from: buffer)
}
// Alternating whole sentences: English / Chinese / mixed (the spike's code-switching clip).
var alt: [Float] = [], altRef: [String] = []
for index in [6, 16, 23, 7, 17, 24, 8, 18, 25, 9, 19, 26, 10, 20, 27, 28] {
    let row = zhManifest.first { $0[0] == String(format: "%02d_1.wav", index) }!
    alt += try load(scratch.appending(path: "tts-zh/\(row[0])")) + [Float](repeating: 0, count: 11_200)
    altRef.append(row[4])
}
let altURL = scratch.appending(path: "alternating.wav")
do {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: altURL, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(alt.count))!
    buffer.frameLength = AVAudioFrameCount(alt.count)
    alt.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: alt.count) }
    try file.write(from: buffer)
}
cases.append(("alternate", altURL, altRef.joined(separator: " "), .auto))
cases.append(("zh+terms", zhMixURL, zhMixRef.joined(separator: " "), .auto))
cases.append(("zh+terms", zhMixURL, zhMixRef.joined(separator: " "), .chinese))

let engine = DictationEngine(
    english: FallbackTranscriber(primary: ParakeetTranscriber(), fallback: AppleSpeechTranscriber(locale: Locale(identifier: "en_US"))),
    senseVoice: SenseVoiceTranscriber())
try await engine.prepareEnglish(); _ = await engine.waitForEnglishPrimary(); _ = await engine.prepareChinese()
let voiceActivity = VoiceActivityModel()
await voiceActivity.prepare()

for (name, url, reference, mode) in cases {
    let audio = try load(url)
    let session = DictationSession(engine: engine, mode: mode, voiceActivity: voiceActivity)
    // Tally where each piece was routed, to see language flips.
    let routes = Task { () -> [String: Int] in
        var tally: [String: Int] = [:]
        for await piece in session.committedPieces {
            if let t = piece.transcript, !t.text.isEmpty {
                tally["\(t.engine)/\(t.language ?? "?")", default: 0] += 1
                if ProcessInfo.processInfo.environment["PIECES"] != nil { print("    [\(t.language ?? "?")] \(t.text)") }
            }
        }
        return tally
    }
    var i = 0
    while i < audio.count {                       // 100 ms buffers every 10 ms = 10× real time
        session.feed(Array(audio[i..<min(i + 1_600, audio.count)])); i += 1_600
        try await Task.sleep(for: .milliseconds(10))
    }
    let released = ContinuousClock.now
    let result = await session.finish()
    let ms = Double((ContinuousClock.now - released).components.attoseconds) / 1e15
    let tally = await routes.value.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    print(String(format: "%-8@ %-8@ pieces %2d  failures %d  MER %4.1f%%  release → text %4.0f ms  language %@  routes %@",
                 name, mode.rawValue, result.pieces, result.failures, mer(reference, result.text) * 100, ms, result.language ?? "-", tally))
}
