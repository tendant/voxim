// segment-bench: phase 0 of docs/long-dictation-plan.md.
// Replays long clips in 100 ms buffers, cuts pieces at pauses (energy vs Silero VAD),
// transcribes each piece with the app's DictationEngine, and compares with one batch pass.
// Usage: segment-bench <scratch dir containing tts-long/, tts-zh-long/, tts-zh/>
@preconcurrency import AVFoundation
import FluidAudio
import Foundation

let sampleRate = 16_000

func loadSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    let mono = buffer.format == target ? buffer : try AudioFormatConversion.convert(buffer, to: target)
    return Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength)))
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

func mer(_ reference: String, _ hypothesis: String) -> Double {
    let a = tokens(reference), b = tokens(hypothesis)
    if a.isEmpty { return b.isEmpty ? 0 : 1 }
    var row = Array(0...b.count)
    for i in 1...a.count {
        var prev = row[0]; row[0] = i
        for j in stride(from: 1, through: b.count, by: 1) {
            let cur = row[j]; row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1)); prev = cur
        }
    }
    return Double(row[b.count]) / Double(a.count)
}

func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

/// Deterministic white noise at the given SNR relative to the speech's RMS.
func addNoise(_ samples: [Float], snrDB: Double, seed: UInt64) -> [Float] {
    let voiced = samples.filter { abs($0) > 1e-4 }
    let speechRMS = sqrt(voiced.reduce(0) { $0 + Double($1 * $1) } / Double(max(voiced.count, 1)))
    let noiseRMS = speechRMS / pow(10, snrDB / 20)
    var state = seed
    return samples.map { s in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u = Double(state >> 11) / Double(1 << 53)           // [0, 1)
        return s + Float((u * 2 - 1) * noiseRMS * sqrt(3.0))    // uniform noise with the target RMS
    }
}

/// Silero VAD via FluidAudio's streaming API; 4096-sample chunks expanded to 512-sample frames.
struct SileroClassifier: FrameClassifier {
    let vad: VadManager
    var state: VadStreamState
    var pending: [Float] = []

    mutating func classify(_ samples: ArraySlice<Float>) async throws -> [Bool] {
        pending.append(contentsOf: samples)
        var out: [Bool] = []
        while pending.count >= VadManager.chunkSize {
            let chunk = Array(pending.prefix(VadManager.chunkSize))
            pending.removeFirst(VadManager.chunkSize)
            let result = try await vad.processStreamingChunk(chunk, state: state)
            state = result.state
            out += Array(repeating: result.probability > 0.5, count: VadManager.chunkSize / 512)
        }
        return out
    }
}

struct Clip { let name: String; let samples: [Float]; let reference: String; let modes: [LanguageMode] }

// MARK: Clips

let scratch = URL(fileURLWithPath: CommandLine.arguments[1])
let longRefs = try String(contentsOf: URL(fileURLWithPath: "long-phrases.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
var clips: [Clip] = []
for (i, name) in ["en-46s", "en-86s", "en-133s"].enumerated() {
    clips.append(Clip(name: name, samples: try loadSamples(scratch.appending(path: "tts-long/0\(i + 1).wav")),
                      reference: longRefs[i], modes: [.english]))
}
let zhRef = try String(contentsOf: scratch.appending(path: "tts-zh-long/manifest.tsv"), encoding: .utf8)
    .split(separator: "\t").map(String.init)[4].trimmingCharacters(in: .whitespacesAndNewlines)
clips.append(Clip(name: "zh-153s", samples: try loadSamples(scratch.appending(path: "tts-zh-long/01.wav")),
                  reference: zhRef, modes: [.chinese, .auto]))
// Code-switching: English / Chinese / mixed sentences alternating, 0.7 s apart.
let manifest = try String(contentsOf: scratch.appending(path: "tts-zh/manifest.tsv"), encoding: .utf8)
    .split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
var mixSamples: [Float] = [], mixRef: [String] = []
for index in [6, 16, 23, 7, 17, 24, 8, 18, 25, 9, 19, 26, 10, 20, 27, 28] {
    let row = manifest.first { $0[0] == String(format: "%02d_1.wav", index) }!
    mixSamples += try loadSamples(scratch.appending(path: "tts-zh/\(row[0])")) + [Float](repeating: 0, count: 11_200)
    mixRef.append(row[4])
}
clips.append(Clip(name: "codeswitch-\(mixSamples.count / sampleRate)s", samples: mixSamples,
                  reference: mixRef.joined(separator: " "), modes: [.auto]))

// MARK: Engines

let engine = DictationEngine(
    english: FallbackTranscriber(primary: ParakeetTranscriber(), fallback: AppleSpeechTranscriber(locale: Locale(identifier: "en_US"))),
    senseVoice: SenseVoiceTranscriber()
)
try await engine.prepareEnglish()
_ = await engine.waitForEnglishPrimary()
_ = await engine.prepareChinese()
print("loading Silero VAD…")
let vad = try await VadManager()

func transcribe(_ samples: ArraySlice<Float>, _ mode: LanguageMode) async throws -> (String, Double) {
    let start = ContinuousClock.now
    let t = try await engine.transcribe(AudioClip(samples: Array(samples)), mode: mode)
    return (t.text, seconds(ContinuousClock.now - start) * 1000)
}

// MARK: Run

print("\nclip            noise  mode     detector  pieces  len min/med/max s  forced  MER piece/batch  release ms piece/batch  max piece ms")
for clip in clips {
    for snr in [nil, 20.0, 10.0] as [Double?] {
        let audio = snr.map { addNoise(clip.samples, snrDB: $0, seed: 42) } ?? clip.samples
        for mode in clip.modes {
            let (batchText, batchMS) = try await transcribe(audio[...], mode)
            let batchMER = mer(clip.reference, batchText)
            let detectors = ProcessInfo.processInfo.environment["DETECTORS"]?.split(separator: ",").map(String.init) ?? ["energy", "silero"]
            for detectorName in detectors {
                var classifier: any FrameClassifier = detectorName == "energy"
                    ? EnergyClassifier() : SileroClassifier(vad: vad, state: await vad.makeStreamState())
                var config = PauseDetectorConfig()
                if let v = ProcessInfo.processInfo.environment["MIN_PAUSE"], let d = Double(v) { config.minPause = d }
                var detector = PauseDetector(config: config)
                var pending: [Float] = []
                var pieces: [Piece] = []
                var text = ""
                var busyUntil = 0.0     // simulated wall clock (s) when the transcription queue frees up
                var maxPieceMS = 0.0
                var position = 0
                func run(_ piece: Piece, cutAt: Double) async throws -> Double {
                    let (t, ms) = try await transcribe(audio[piece.range], mode)
                    text = SenseVoiceTranscriber.join(text, t)
                    maxPieceMS = max(maxPieceMS, ms)
                    busyUntil = max(busyUntil, cutAt) + ms / 1000
                    return ms
                }
                // Real-time replay in 100 ms buffers.
                while position < audio.count {
                    let end = min(position + 1_600, audio.count)
                    pending += audio[position..<end]
                    position = end
                    let usable = pending.count - pending.count % 512
                    let decisions = try await classifier.classify(pending[..<usable])
                    pending.removeFirst(usable)
                    for piece in detector.feed(decisions, audio: audio) {
                        pieces.append(piece)
                        _ = try await run(piece, cutAt: Double(position) / Double(sampleRate))
                    }
                }
                let audioEnd = Double(audio.count) / Double(sampleRate)
                var releaseMS = 0.0
                if let last = detector.finish(totalSamples: audio.count) {
                    pieces.append(last)
                    let backlog = max(0, busyUntil - audioEnd)
                    releaseMS = backlog * 1000 + (try await run(last, cutAt: audioEnd))
                }
                let lengths = pieces.map { Double($0.range.count) / Double(sampleRate) }.sorted()
                print(String(format: "%-15@ %-6@ %-8@ %-8@ %6d  %5.1f/%5.1f/%5.1f      %6d  %5.1f%% / %5.1f%%   %6.0f / %6.0f       %6.0f",
                             clip.name, snr.map { "\(Int($0))dB" } ?? "clean", mode.rawValue, detectorName,
                             pieces.count, lengths.first ?? 0, lengths[lengths.count / 2], lengths.last ?? 0,
                             pieces.filter(\.forced).count, mer(clip.reference, text) * 100, batchMER * 100,
                             releaseMS, batchMS, maxPieceMS))
            }
        }
    }
}

if ProcessInfo.processInfo.environment["SKIP_NATIVE"] != nil { exit(0) }

// MARK: Native streaming baseline (Parakeet SlidingWindowAsrManager)

print("\n## Native streaming: SlidingWindowAsrManager(.streaming) on en-86s, fed as fast as possible")
let streaming = SlidingWindowAsrManager(config: .streaming)
try await streaming.loadModels(try await AsrModels.downloadAndLoad(version: .v2))
let updates = await streaming.transcriptionUpdates
let counter = Task { var n = 0, confirmed = 0; for await u in updates { n += 1; if u.isConfirmed { confirmed += 1 } }; return (n, confirmed) }
try await streaming.startStreaming(source: .microphone)
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
let samples86 = clips[1].samples
let started = ContinuousClock.now
var p = 0
while p < samples86.count {
    let n = min(1_600, samples86.count - p)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buffer.frameLength = AVAudioFrameCount(n)
    samples86[p..<(p + n)].withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
    await streaming.streamAudio(buffer)
    p += n
}
let final = try await streaming.finish()
let total = seconds(ContinuousClock.now - started) * 1000
counter.cancel()
let (updateCount, confirmedCount) = await counter.value
print(String(format: "MER %.1f%%  total compute %.0f ms for 86 s  updates %d (confirmed %d)",
             mer(clips[1].reference, final) * 100, total, updateCount, confirmedCount))
