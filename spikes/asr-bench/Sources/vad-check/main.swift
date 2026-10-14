// vad-check: how Silero's speech probability holds up when audio is quieter, like a real mic.
// Usage: vad-check <wav>...
@preconcurrency import AVFoundation
import FluidAudio
import Foundation

func load(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let mono = buffer.format == target ? buffer : try AudioFormatConversion.convert(buffer, to: target)
    return Array(UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength)))
}

let vad = try await VadManager()
print("file        gain    speech RMS dBFS   chunks with energy   Silero >0.5   >0.3   >0.15")
for path in CommandLine.arguments.dropFirst() {
    let audio = try load(path)
    for gain: Float in [1, 0.3, 0.1, 0.03] {
        let samples = audio.map { $0 * gain }
        var state = await vad.makeStreamState()
        var voiced = 0, p50 = 0, p30 = 0, p15 = 0, total = 0, energySum = 0.0, energyCount = 0
        var i = 0
        while i + VadManager.chunkSize <= samples.count {
            let chunk = Array(samples[i..<(i + VadManager.chunkSize)])
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
            let hasEnergy = rms > 0.003 * gain   // relative to the original level: "this chunk has speech in it"
            let r = try await vad.processStreamingChunk(chunk, state: state)
            state = r.state
            if hasEnergy {
                voiced += 1; energySum += Double(20 * log10(max(rms, 1e-9))); energyCount += 1
                if r.probability > 0.5 { p50 += 1 }
                if r.probability > 0.3 { p30 += 1 }
                if r.probability > 0.15 { p15 += 1 }
            }
            total += 1
            i += VadManager.chunkSize
        }
        print(String(format: "%-11@ %5.2f   %6.1f            %4d / %4d          %5.1f%%   %5.1f%%   %5.1f%%",
                     (path as NSString).lastPathComponent, gain, energySum / Double(max(energyCount, 1)), voiced, total,
                     100 * Double(p50) / Double(max(voiced, 1)), 100 * Double(p30) / Double(max(voiced, 1)),
                     100 * Double(p15) / Double(max(voiced, 1))))
    }
}
