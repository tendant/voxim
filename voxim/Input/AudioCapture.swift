//
//  AudioCapture.swift
//  voxim
//

@preconcurrency import AVFoundation

nonisolated enum AudioCaptureError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is off. Enable voxim in System Settings › Privacy & Security › Microphone."
        case .noInputDevice: "No microphone input is available."
        case .conversionFailed: "Could not convert microphone audio."
        }
    }
}

nonisolated enum AudioFormatConversion {
    /// One-shot conversion of a complete buffer (sample rate, channel count and/or sample format).
    static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw AudioCaptureError.conversionFailed
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AudioCaptureError.conversionFailed
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || conversionError != nil { throw AudioCaptureError.conversionFailed }
        return output
    }
}

/// Seam so the controller can be tested without a microphone.
nonisolated protocol AudioCapturing: AnyObject {
    func start() throws
    /// Stops capture and returns everything recorded since `start()`.
    func stop() -> AudioClip
    /// Everything recorded so far, without stopping (for live preview).
    func snapshot() -> AudioClip
    /// Receives each new buffer as it's captured (audio thread). Set before `start()`.
    /// While set, audio is handed off rather than also kept here.
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
    /// Seconds captured since the last `start()` (also after `stop()`).
    var capturedSeconds: TimeInterval { get }
}

/// Push-to-talk microphone capture. The engine runs only between `start()` and `stop()`;
/// samples stay in memory and are handed off as an `AudioClip`.
nonisolated final class AudioCapture: AudioCapturing, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var isRunning = false
    private var _onSamples: (@Sendable ([Float]) -> Void)?
    private var capturedCount = 0

    var capturedSeconds: TimeInterval {
        lock.withLock { Double(capturedCount) / AudioClip.sampleRate }
    }

    var onSamples: (@Sendable ([Float]) -> Void)? {
        get { lock.withLock { _onSamples } }
        set { lock.withLock { _onSamples = newValue } }
    }

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioClip.sampleRate, channels: 1, interleaved: false
    )!

    /// Granted already; never prompts.
    static var isGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: await AVAudioApplication.requestRecordPermission()
        }
    }

    func start() throws {
        guard !isRunning else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw AudioCaptureError.microphoneDenied
        }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        // One converter per session keeps resampler state continuous across tap buffers.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.conversionFailed
        }
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            capturedCount = 0
        }
        let targetFormat = self.targetFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(
                (Double(buffer.frameLength) * targetFormat.sampleRate / inputFormat.sampleRate).rounded(.up)
            ) + 64
            guard let self,
                  let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
            else { return }
            var supplied = false
            let status = converter.convert(to: output, error: nil) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let channel = output.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            let push = self.lock.withLock {
                self.capturedCount += chunk.count
                // A consumer (the dictation session) owns the audio; don't keep a second copy,
                // so long hands-free recordings use constant memory.
                if self._onSamples == nil { self.samples.append(contentsOf: chunk) }
                return self._onSamples
            }
            push?(chunk)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
    }

    func snapshot() -> AudioClip {
        lock.withLock { AudioClip(samples: samples) }
    }

    func stop() -> AudioClip {
        guard isRunning else { return AudioClip(samples: []) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        return lock.withLock {
            let clip = AudioClip(samples: samples)
            samples.removeAll()
            return clip
        }
    }
}
