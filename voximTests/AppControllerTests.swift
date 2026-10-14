//
//  AppControllerTests.swift
//  voximTests
//
//  Drives the push-to-talk flow headless: fake mic, permissions, engine and sink.
//

import Foundation
import Testing
@testable import voxim

final class FakeCapture: AudioCapturing, @unchecked Sendable {
    var onSamples: (@Sendable ([Float]) -> Void)?
    private(set) var capturedSeconds: TimeInterval = 0
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var isRunning = false

    func start() throws {
        starts += 1
        isRunning = true
    }

    func stop() -> AudioClip {
        stops += 1
        isRunning = false
        // Deliver the "recorded" second of audio to whoever listens, like the real tap does.
        let samples = Array(repeating: Float(0.1), count: 16_000)
        capturedSeconds += 1
        onSamples?(samples)
        return AudioClip(samples: samples)
    }

    private(set) var snapshots = 0

    /// Simulates the microphone delivering audio while recording.
    func push(_ samples: [Float]) {
        var i = 0
        while i < samples.count {
            onSamples?(Array(samples[i..<min(i + 1_600, samples.count)]))
            i += 1_600
        }
    }

    func snapshot() -> AudioClip {
        snapshots += 1
        return AudioClip(samples: Array(repeating: 0.1, count: 16_000))
    }
}

actor FakeEngine: SpeechEngine {
    let transcript: Transcript
    private(set) var calls = 0
    private(set) var modes: [LanguageMode] = []
    private(set) var chinesePrepared = 0

    init(text: String, language: String = "en") {
        transcript = Transcript(text: text, language: language, engine: "Fake")
    }

    func prepareEnglish() async throws {}
    func waitForEnglishPrimary() async -> (any Error)? { nil }
    func prepareChinese() async -> (any Error)? { chinesePrepared += 1; return nil }
    func englishEngineName() async -> String { "Fake" }

    func transcribe(_ clip: AudioClip, mode: LanguageMode, languageHint: String?) async throws -> Transcript {
        calls += 1
        modes.append(mode)
        return transcript
    }
}

@MainActor
final class FakeSink: DictationSink {
    private(set) var inserted: [String] = []
    /// 0-based insert call that throws (e.g. focus moved).
    var failOnCall: Int?
    private var calls = 0

    func insert(_ text: String, expecting app: FocusedApp?) async throws -> ContinuousClock.Instant {
        defer { calls += 1 }
        if calls == failOnCall { throw InsertionError.focusChanged(from: "Notes", to: "Safari") }
        inserted.append(text)
        return .now
    }
}

@MainActor
struct AppControllerTests {
    let capture = FakeCapture()
    let sink = FakeSink()
    let engine = FakeEngine(text: "Hello world.")
    let defaults = UserDefaults(suiteName: "voxim-tests-\(UUID().uuidString)")!
    let metrics = MetricsStore(
        fileURL: FileManager.default.temporaryDirectory.appending(path: "voxim-ctl-\(UUID().uuidString).jsonl")
    )

    private final class Flags {
        var accessibility = true
        var microphone = true
        var accessibilityRequests = 0
        var microphoneRequests = 0
    }
    private let flags = Flags()

    private func makeController(engine: FakeEngine? = nil) -> AppController {
        let flags = self.flags
        var permissions = AppController.Permissions()
        permissions.isAccessibilityTrusted = { flags.accessibility }
        permissions.requestAccessibility = { flags.accessibilityRequests += 1 }
        permissions.isMicrophoneGranted = { flags.microphone }
        permissions.requestMicrophone = { flags.microphoneRequests += 1; return flags.microphone }
        defaults.set(false, forKey: AppController.smartFormattingKey)
        return AppController(
            sink: sink, metrics: metrics, capture: capture, permissions: permissions,
            engine: engine ?? self.engine,
            voiceActivity: nil,  // one piece per dictation; sessions are tested separately
            defaults: defaults
        )
    }

    /// Hold long enough to pass the accidental-tap filter.
    private func holdPastMinimum() async throws {
        try await Task.sleep(for: AppController.minimumHold + .milliseconds(50))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func preRollStartsMicOnArmAndKeepsItThroughTheRecording() async throws {
        let controller = makeController()

        controller.handle(.arm)
        #expect(capture.starts == 1)
        #expect(controller.phase == .idle)          // silent: no HUD before the hold qualifies

        controller.handle(.press)
        #expect(capture.starts == 1)                // reused, not restarted
        #expect(controller.phase == .recording)

        try await holdPastMinimum()
        controller.handle(.release)
        try await waitUntil { controller.phase == .inserted }
        #expect(sink.inserted == ["Hello world."])
        #expect(capture.stops == 1)
        #expect(flags.microphoneRequests == 0)      // already granted; no prompt path taken
    }

    @Test func tapDiscardsPreRollUnheard() async throws {
        let controller = makeController()

        controller.handle(.arm)
        controller.handle(.disarm)

        #expect(capture.starts == 1)
        #expect(capture.stops == 1)
        #expect(!capture.isRunning)
        #expect(controller.phase == .idle)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.calls == 0)
        #expect(sink.inserted.isEmpty)
        #expect(metrics.events.isEmpty)             // a tap or fn+key isn't a dictation attempt
    }

    @Test func preRollOffStartsMicOnlyOnPress() async throws {
        defaults.set(false, forKey: AppController.preRollKey)
        let controller = makeController()

        controller.handle(.arm)
        #expect(capture.starts == 0)

        controller.handle(.press)
        try await waitUntil { controller.phase == .recording }
        #expect(capture.starts == 1)
        #expect(flags.microphoneRequests == 1)
    }

    @Test func noPreRollWithoutMicrophoneGrantAndNoPrompt() async throws {
        flags.microphone = false
        let controller = makeController()

        controller.handle(.arm)
        #expect(capture.starts == 0)
        #expect(flags.microphoneRequests == 0)

        controller.handle(.press)
        try await waitUntil { controller.phase != .idle }
        #expect(flags.microphoneRequests == 1)
        #expect(controller.phase == .failed(AudioCaptureError.microphoneDenied.localizedDescription))
    }

    @Test func noPreRollWithoutAccessibility() {
        flags.accessibility = false
        let controller = makeController()

        controller.handle(.arm)
        #expect(capture.starts == 0)

        controller.handle(.press)
        #expect(flags.accessibilityRequests == 1)
        #expect(controller.phase == .failed(InsertionError.accessibilityDenied.localizedDescription))
    }

    @Test func escDuringPreRolledRecordingCancels() async throws {
        let controller = makeController()

        controller.handle(.arm)
        controller.handle(.press)
        controller.handle(.cancel)

        #expect(controller.phase == .idle)
        #expect(!capture.isRunning)
        try await Task.sleep(for: .milliseconds(50))
        #expect(sink.inserted.isEmpty)
        #expect(metrics.events.map(\.outcome) == [.cancelled])
    }

    @Test func armWhileTranscribingIsIgnored() async throws {
        let controller = makeController()
        controller.handle(.arm)
        controller.handle(.press)
        try await holdPastMinimum()
        controller.handle(.release)

        // A new fn press during transcription must not open the mic.
        controller.handle(.arm)
        #expect(capture.starts == 1)
        try await waitUntil { controller.phase == .inserted }
    }

    @Test func languageModeIsPassedToEngineAndPersisted() async throws {
        let controller = makeController()
        controller.languageMode = .auto
        #expect(defaults.string(forKey: AppController.languageModeKey) == "auto")
        try await waitUntil { await engine.chinesePrepared == 1 }

        controller.handle(.arm)
        controller.handle(.press)
        try await holdPastMinimum()
        controller.handle(.release)
        try await waitUntil { controller.phase == .inserted }
        #expect(await engine.modes == [.auto])

        // Switching again doesn't reload the Chinese model.
        controller.languageMode = .chinese
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.chinesePrepared == 1)
    }

    @Test func englishModeNeverLoadsChineseModel() async throws {
        _ = makeController()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.chinesePrepared == 0)
    }

    @Test func chineseTranscriptGetsSpacingScriptAndCharacterWordCount() async throws {
        let chinese = FakeEngine(text: "用npm安装依赖。", language: "zh")
        defaults.set(ChineseScript.traditional.rawValue, forKey: AppController.chineseScriptKey)
        let controller = makeController(engine: chinese)

        controller.handle(.arm)
        controller.handle(.press)
        try await holdPastMinimum()
        controller.handle(.release)
        try await waitUntil { controller.phase == .inserted }

        #expect(sink.inserted == ["用 npm 安裝依賴。"])
        #expect(controller.lastLanguage == "zh")
        #expect(metrics.events.last?.language == "zh")
        #expect(metrics.events.last?.words == 6)  // 用 安 裝 依 賴 (5 characters) + npm
    }

    @Test func livePreviewShowsTextWhileRecordingAndClearsOnRelease() async throws {
        let controller = makeController()
        controller.handle(.arm)
        controller.handle(.press)
        capture.push(Array(repeating: 0.1, count: 16_000))   // the mic delivers audio while recording

        try await waitUntil { controller.livePreview == "Hello world." }
        #expect(controller.phase == .recording)
        #expect(sink.inserted.isEmpty)              // preview is never typed
        #expect(metrics.events.isEmpty)             // nor counted

        controller.handle(.release)
        #expect(controller.livePreview.isEmpty)
        try await waitUntil { controller.phase == .inserted }
        #expect(sink.inserted == ["Hello world."])
        #expect(metrics.events.count == 1)
    }

    @Test func livePreviewStopsOnCancel() async throws {
        let controller = makeController()
        controller.handle(.arm)
        controller.handle(.press)
        capture.push(Array(repeating: 0.1, count: 16_000))
        try await waitUntil { !controller.livePreview.isEmpty }

        controller.handle(.cancel)
        #expect(controller.livePreview.isEmpty)
        let snapshots = capture.snapshots
        try await Task.sleep(for: AppController.previewInterval * 2)
        #expect(capture.snapshots == snapshots)    // loop has stopped
    }

    @Test func livePreviewCanBeTurnedOff() async throws {
        defaults.set(false, forKey: AppController.livePreviewKey)
        let controller = makeController()
        controller.handle(.arm)
        controller.handle(.press)
        try await Task.sleep(for: AppController.previewInterval * 2)
        #expect(capture.snapshots == 0)
        #expect(controller.livePreview.isEmpty)
        controller.handle(.cancel)
    }
}
