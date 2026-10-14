//
//  DictationSessionTests.swift
//  voximTests
//

import Foundation
import Testing
@testable import voxim

/// Loud samples are speech, zeros are silence.
actor LoudnessClassifier: SpeechClassifier {
    nonisolated let chunkSize = 4096
    func isSpeech(_ chunk: [Float]) async throws -> Bool {
        chunk.reduce(0) { $0 + abs($1) } / Float(chunk.count) > 0.05
    }
}

/// Returns "p0", "p1", … per piece; records piece lengths; can fail or delay specific pieces.
actor ScriptedEngine: SpeechEngine {
    private(set) var pieceSeconds: [Double] = []
    private(set) var hints: [String?] = []
    var failing: Set<Int> = []
    var languages: [Int: String] = [:]
    var delays: [Int: Duration] = [:]

    func configure(failing: Set<Int> = [], languages: [Int: String] = [:], delays: [Int: Duration] = [:]) {
        self.failing = failing
        self.languages = languages
        self.delays = delays
    }

    func prepareEnglish() async throws {}
    func waitForEnglishPrimary() async -> (any Error)? { nil }
    func prepareChinese() async -> (any Error)? { nil }
    func englishEngineName() async -> String { "Scripted" }

    func transcribe(_ clip: AudioClip, mode: LanguageMode, languageHint: String?) async throws -> Transcript {
        let index = pieceSeconds.count
        pieceSeconds.append(clip.duration)
        hints.append(languageHint)
        if let delay = delays[index] { try await Task.sleep(for: delay) }
        if failing.contains(index) { throw TranscriberError.unavailable("scripted failure") }
        return Transcript(text: "p\(index)", language: languages[index] ?? "en", engine: "Scripted")
    }
}

struct DictationSessionTests {
    let engine = ScriptedEngine()

    private func speech(_ seconds: Double) -> [Float] { Array(repeating: 0.5, count: Int(seconds * 16_000)) }
    private func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * 16_000)) }

    private func session(segmenting: Bool = true) -> DictationSession {
        DictationSession(engine: engine, mode: .english, voiceActivity: nil,
                         classifier: segmenting ? LoudnessClassifier() : nil)
    }

    /// Feeds audio the way the microphone does: 100 ms buffers.
    private func feed(_ session: DictationSession, _ audio: [Float]) {
        var i = 0
        while i < audio.count {
            session.feed(Array(audio[i..<min(i + 1_600, audio.count)]))
            i += 1_600
        }
    }

    @Test func pausesSplitPiecesAndTextJoinsInOrder() async {
        let s = session()
        feed(s, speech(2) + silence(0.6) + speech(2) + silence(0.6) + speech(1.5))
        let result = await s.finish()
        #expect(result.pieces == 3)
        #expect(result.text == "p0 p1 p2")
        #expect(result.failures == 0)
        #expect(await engine.pieceSeconds.count == 3)
    }

    @Test func piecesAreTranscribedBeforeRelease() async throws {
        let s = session()
        feed(s, speech(2) + silence(0.6) + speech(1))
        // The first piece is transcribed while "recording" continues.
        let deadline = ContinuousClock.now + .seconds(2)
        while await engine.pieceSeconds.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await engine.pieceSeconds.count == 1)
        _ = await s.finish()
    }

    @Test func shortPausesDontSplit() async {
        let s = session()
        feed(s, speech(2) + silence(0.1) + speech(2))  // shorter than one VAD chunk of silence
        let result = await s.finish()
        #expect(result.pieces == 1)
    }

    @Test func longSpeechWithoutPausesIsForcedUnderTheLimit() async {
        let s = session()
        feed(s, speech(60))
        let result = await s.finish()
        let lengths = await engine.pieceSeconds
        #expect(result.pieces == 3)
        #expect(lengths.allSatisfy { $0 <= 25.5 })
        #expect(abs(lengths.reduce(0, +) - 60) < 0.01)   // nothing lost or duplicated
    }

    @Test func withoutVoiceActivityItIsOnePassAtRelease() async {
        let s = session(segmenting: false)
        feed(s, speech(2) + silence(1) + speech(2))
        let result = await s.finish()
        #expect(result.pieces == 1)
        #expect(await engine.pieceSeconds == [5])
    }

    @Test func trailingSilenceIsNotTranscribed() async {
        let s = session()
        feed(s, speech(2) + silence(2))
        let result = await s.finish()
        #expect(result.pieces == 1)
    }

    @Test func shortLastWordsAfterAPauseAreKept() async {
        // "…that's it. OK." — the final words are shorter than one VAD chunk.
        let s = session()
        feed(s, speech(2) + silence(0.6) + speech(0.2))
        let result = await s.finish()
        #expect(result.text == "p0 p1")
    }

    @Test func quietSpeechTheVADMissesIsStillTranscribed() async {
        // Speech the classifier scores as silence must not be thrown away.
        let s = session()
        feed(s, speech(2) + silence(0.6) + Array(repeating: 0.03, count: 16_000 * 2))
        let result = await s.finish()
        #expect(result.pieces == 2)
    }

    @Test func longSilenceIsNotTranscribed() async {
        // Idle hands-free: a minute of silence after a sentence produces no extra pieces.
        let s = session()
        feed(s, speech(2) + silence(60))
        let result = await s.finish()
        #expect(result.pieces == 1)
        #expect(await engine.pieceSeconds.count == 1)
        #expect(result.text == "p0")
    }

    @Test func reportsSecondsSinceSpeech() async {
        let s = session()
        feed(s, speech(2) + silence(3))
        _ = await s.finish()
        let quiet = await s.secondsSinceSpeech() ?? 0
        #expect(quiet > 2.5 && quiet < 3.5)
    }

    @Test func cancelDiscardsEverything() async throws {
        let s = session()
        feed(s, speech(2))
        await s.cancel()
        feed(s, silence(0.6) + speech(2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await engine.pieceSeconds.isEmpty)
    }

    @Test func failedPieceIsReportedAndTheRestKept() async {
        await engine.configure(failing: [1])
        let s = session()
        feed(s, speech(2) + silence(0.6) + speech(2) + silence(0.6) + speech(2))
        let result = await s.finish()
        #expect(result.failures == 1)
        #expect(result.text == "p0 p2")
    }

    @Test func orderIsKeptEvenWhenEarlierPiecesAreSlow() async {
        await engine.configure(delays: [0: .milliseconds(200)])
        let s = session()
        feed(s, speech(2) + silence(0.6) + speech(2))
        #expect(await s.finish().text == "p0 p1")
    }

    @Test func laterPiecesGetTheDictationsLanguageAsAHint() async {
        await engine.configure(languages: [0: "zh", 1: "zh", 2: "en"])
        let s = session()
        feed(s, speech(2) + silence(0.6) + speech(2) + silence(0.6) + speech(2))
        _ = await s.finish()
        #expect(await engine.hints == [nil, "zh", "zh"])
    }

    @Test func languagesAcrossPiecesAreSummarized() async {
        await engine.configure(languages: [0: "en", 1: "zh"])
        let s = session()
        feed(s, speech(2) + silence(0.6) + speech(2))
        #expect(await s.finish().language == "mixed")
    }
}

struct PauseDetectorTests {
    @Test func cutsInTheMiddleOfAPause() {
        var d = PauseDetector()
        #expect(d.feed(samples: 32_000, isSpeech: true) == nil)          // 2 s of speech
        #expect(d.feed(samples: 4_096, isSpeech: false) == .pause(at: 32_000 + 2_048))
    }

    @Test func doesNotCutBeforeMinimumPieceOrSpeech() {
        var d = PauseDetector()
        #expect(d.feed(samples: 8_000, isSpeech: true) == nil)           // 0.5 s: piece too short
        #expect(d.feed(samples: 4_096, isSpeech: false) == nil)
        var silent = PauseDetector()
        #expect(silent.feed(samples: 40_000, isSpeech: false) == nil)    // no speech yet
    }

    @Test func forcesACutByTheMaximumLength() {
        var d = PauseDetector()
        var cut: PauseDetector.Cut?
        var fed = 0
        while cut == nil { cut = d.feed(samples: 4_096, isSpeech: true); fed += 4_096 }
        #expect(Double(fed) >= 25 * 16_000)
        guard case .forced(let range) = cut else { Issue.record("expected forced cut"); return }
        #expect(range.upperBound == fed)
        #expect(range.count == 3 * 16_000)
    }

    @Test func quietestPointFindsTheGap() {
        var audio = [Float](repeating: 0.5, count: 48_000)
        for i in 20_000..<21_600 { audio[i] = 0 }
        let point = PauseDetector.quietestPoint(audio, base: 100_000, in: 100_000..<148_000)
        #expect((120_000..<121_600).contains(point))
    }
}
