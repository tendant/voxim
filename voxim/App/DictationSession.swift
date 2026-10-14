//
//  DictationSession.swift
//  voxim
//
//  One dictation, committed as you go (docs/long-dictation-plan.md): audio is pushed in as it
//  arrives, pauses end pieces, and each finished piece is transcribed in the background, in
//  order. At release only the last piece is left, so release latency doesn't grow with length.
//  Piece audio is dropped once it's handed to the engine.
//

import Foundation
import os

nonisolated struct SessionResult: Equatable, Sendable {
    var text: String
    /// "en", "zh", "yue", "mixed" (more than one), or nil.
    var language: String?
    var engine: String?
    var pieces: Int
    /// Pieces whose transcription failed; their text is missing from `text`.
    var failures: Int
    /// Pieces that were transcribed but came back with no words (silence, noise, or misses).
    var emptyPieces: Int = 0
}

/// One finished piece, delivered in order; nil text means its transcription failed.
nonisolated struct CommittedPiece: Sendable {
    var transcript: Transcript?
}

protocol DictationSessioning: AnyObject, Sendable {
    /// Called from the audio thread with each new buffer of 16 kHz mono samples.
    nonisolated func feed(_ samples: [Float])
    /// Every piece as soon as it's transcribed, strictly in order (also the last one at
    /// `finish()`). Ends when the session finishes or is cancelled.
    nonisolated var committedPieces: AsyncStream<CommittedPiece> { get }
    /// For the live preview: text committed so far, the audio of the piece in progress, and the
    /// language the dictation has settled on (so the preview doesn't flip languages either).
    func previewState() async -> (committed: String, tail: AudioClip, language: String?)
    /// Seconds since speech was last detected (for hands-free auto-stop); nil without a VAD.
    func secondsSinceSpeech() async -> TimeInterval?
    /// Ends the dictation: cuts the last piece and waits for every piece's transcription.
    func finish() async -> SessionResult
    /// Discards everything; nothing is transcribed after this.
    func cancel() async
}

actor DictationSession: DictationSessioning {
    private let engine: any SpeechEngine
    private let mode: LanguageMode
    private let voiceActivity: VoiceActivityModel?
    private let input: AsyncStream<[Float]>.Continuation
    /// Set once in `init`; a box so the task can be stored after `self` is captured.
    private nonisolated let consumer = TaskHandle()
    nonisolated let committedPieces: AsyncStream<CommittedPiece>
    private let committedOutput: AsyncStream<CommittedPiece>.Continuation

    private var classifier: (any SpeechClassifier)?
    private var detector = PauseDetector()
    private var pending: [Float] = []        // samples not yet classified
    private var pieceAudio: [Float] = []     // current piece, index 0 = absolute `pieceBase`
    private var pieceBase = 0
    private var transcription: Task<Void, Never>?  // tail of the in-order transcription chain
    private var transcripts: [Int: Transcript] = [:]
    private var failures = 0
    private var pieceCount = 0
    private var cancelled = false
    /// Samples classified so far, and where the last speech chunk ended.
    private var classifiedSamples = 0
    private var lastSpeechEnd = 0
    /// The dictation's language so far (from transcribed pieces); hints Auto-mode routing.
    private var language: String?

    /// - Parameters:
    ///   - voiceActivity: supplies the speech classifier; nil (and no `classifier`) disables
    ///     pause detection, giving one piece at release.
    ///   - classifier: use this classifier directly (tests).
    init(engine: any SpeechEngine, mode: LanguageMode, voiceActivity: VoiceActivityModel?,
         classifier: (any SpeechClassifier)? = nil) {
        self.engine = engine
        self.mode = mode
        self.voiceActivity = voiceActivity
        self.classifier = classifier
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        input = continuation
        (committedPieces, committedOutput) = AsyncStream.makeStream(of: CommittedPiece.self)
        consumer.task = Task { [weak self] in
            await self?.loadClassifier()
            for await samples in stream {
                await self?.ingest(samples)
            }
        }
    }

    nonisolated func feed(_ samples: [Float]) {
        input.yield(samples)
    }

    func finish() async -> SessionResult {
        input.finish()
        await consumer.task?.value
        // The rest is the last piece. The VAD may not have scored its final words yet (it works
        // in 256 ms chunks), so only loudness decides whether it's worth transcribing.
        if !pieceAudio.isEmpty && (pieceCount == 0 || Self.hasSound(pieceAudio[...])) {
            enqueue(pieceAudio)
        }
        pieceAudio = []
        await transcription?.value
        committedOutput.finish()
        return result()
    }

    func secondsSinceSpeech() -> TimeInterval? {
        guard classifier != nil else { return nil }
        return Double(classifiedSamples - lastSpeechEnd) / AudioClip.sampleRate
    }

    func previewState() -> (committed: String, tail: AudioClip, language: String?) {
        let committed = (0..<pieceCount).compactMap { transcripts[$0] }
            .reduce("") { $1.text.trimmed.isEmpty ? $0 : ChineseText.join($0, $1.text.trimmed) }
        return (committed, AudioClip(samples: pieceAudio), language)
    }

    func cancel() async {
        cancelled = true
        input.finish()
        consumer.task?.cancel()
        transcription?.cancel()
        committedOutput.finish()
        pieceAudio = []
        pending = []
    }

    /// Loudness floor for "something was said": 100 ms RMS above ≈ −48 dBFS. Used instead of the
    /// VAD whenever audio would otherwise be thrown away, so quiet or clipped speech is kept.
    nonisolated static let soundFloor: Float = 0.004

    nonisolated static func hasSound(_ samples: ArraySlice<Float>) -> Bool {
        let frame = 1_600
        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + frame, samples.endIndex)
            var energy: Float = 0
            for i in start..<end { energy += samples[i] * samples[i] }
            if (energy / Float(end - start)).squareRoot() > soundFloor { return true }
            start = end
        }
        return false
    }

    // MARK: Ingest

    private func loadClassifier() async {
        if classifier == nil { classifier = await voiceActivity?.makeClassifier() }
    }

    private func ingest(_ samples: [Float]) async {
        guard !cancelled else { return }
        pieceAudio += samples
        guard let classifier else { return }
        pending += samples
        while pending.count >= classifier.chunkSize {
            let chunk = Array(pending.prefix(classifier.chunkSize))
            pending.removeFirst(classifier.chunkSize)
            // If the VAD errors, treat the chunk as speech: worst case, no cut here.
            let speech = (try? await classifier.isSpeech(chunk)) ?? true
            classifiedSamples += chunk.count
            if speech { lastSpeechEnd = classifiedSamples }
            guard let cut = detector.feed(samples: chunk.count, isSpeech: speech) else { continue }
            switch cut {
            case .pause(let at):
                commit(upTo: at)
            case .forced(let range):
                // A long stretch without speech (idle hands-free) is dropped, not transcribed:
                // engines can "hear" stray words in silence.
                let cut = PauseDetector.quietestPoint(pieceAudio, base: pieceBase, in: range)
                let audible = Self.hasSound(pieceAudio.prefix(max(cut - pieceBase, 0)))
                commit(upTo: cut, transcribe: detector.pieceHasSpeech || audible)
            }
        }
    }

    private func commit(upTo cut: Int, transcribe: Bool = true) {
        let count = min(max(cut - pieceBase, 0), pieceAudio.count)
        detector.startPiece(at: pieceBase + count)
        guard count > 0 else { return }
        if transcribe { enqueue(Array(pieceAudio.prefix(count))) }
        pieceAudio.removeFirst(count)
        pieceBase += count
    }

    /// Transcribes pieces strictly in order, one at a time.
    private func enqueue(_ samples: [Float]) {
        let index = pieceCount
        pieceCount += 1
        let previous = transcription
        let engine = self.engine, mode = self.mode
        transcription = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            // Read after the previous piece finished, so the hint reflects everything before this one.
            let hint = await self?.language
            do {
                let transcript = try await engine.transcribe(AudioClip(samples: samples), mode: mode, languageHint: hint)
                await self?.store(transcript, at: index)
            } catch {
                await self?.storeFailure(error, at: index)
            }
        }
    }

    private func store(_ transcript: Transcript, at index: Int) {
        var transcript = transcript
        // Engines sometimes return only punctuation ("。", ".") for silence: nothing to type.
        if !transcript.text.contains(where: { $0.isLetter || $0.isNumber }) { transcript.text = "" }
        transcripts[index] = transcript
        if !transcript.text.isEmpty, let language = transcript.language { self.language = language }
        // The chain runs one piece at a time, so pieces are yielded in order.
        if !cancelled { committedOutput.yield(CommittedPiece(transcript: transcript)) }
    }

    private func storeFailure(_ error: any Error, at index: Int) {
        failures += 1
        if !cancelled { committedOutput.yield(CommittedPiece(transcript: nil)) }
        Log.asr.error("piece \(index) failed: \(error.localizedDescription, privacy: .public)")
    }

    private func result() -> SessionResult {
        let all = (0..<pieceCount).compactMap { transcripts[$0] }
        let ordered = all.filter { !$0.text.trimmed.isEmpty }
        let text = ordered.reduce("") { ChineseText.join($0, $1.text.trimmed) }
        let languages = Set(ordered.compactMap(\.language))
        let engines = Dictionary(grouping: ordered, by: \.engine).max { $0.value.count < $1.value.count }?.key
        return SessionResult(
            text: text,
            language: languages.count > 1 ? "mixed" : languages.first,
            engine: engines,
            pieces: pieceCount,
            failures: failures,
            emptyPieces: all.count - ordered.count
        )
    }
}

/// Thread-safe holder for a task created in an initializer.
private nonisolated final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _task: Task<Void, Never>?

    var task: Task<Void, Never>? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }
}
