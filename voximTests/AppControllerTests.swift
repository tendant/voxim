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
        return AudioClip(samples: Array(repeating: 0.1, count: 16_000))
    }
}

actor FakeTranscriber: Transcriber {
    nonisolated let name = "Fake"
    let text: String
    private(set) var calls = 0

    init(text: String) { self.text = text }

    func prepare() async throws {}

    func transcribe(_ clip: AudioClip) async throws -> String {
        calls += 1
        return text
    }
}

/// Primary engine that never loads, so the fake fallback handles everything.
actor UnavailableTranscriber: Transcriber {
    nonisolated let name = "Unavailable"
    func prepare() async throws { throw TranscriberError.unavailable("test") }
    func transcribe(_ clip: AudioClip) async throws -> String { throw TranscriberError.unavailable("test") }
}

@MainActor
final class FakeSink: DictationSink {
    private(set) var inserted: [String] = []

    func insert(_ text: String, expecting app: FocusedApp?) async throws -> ContinuousClock.Instant {
        inserted.append(text)
        return .now
    }
}

@MainActor
struct AppControllerTests {
    let capture = FakeCapture()
    let sink = FakeSink()
    let engine = FakeTranscriber(text: "Hello world.")
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

    private func makeController() -> AppController {
        let flags = self.flags
        var permissions = AppController.Permissions()
        permissions.isAccessibilityTrusted = { flags.accessibility }
        permissions.requestAccessibility = { flags.accessibilityRequests += 1 }
        permissions.isMicrophoneGranted = { flags.microphone }
        permissions.requestMicrophone = { flags.microphoneRequests += 1; return flags.microphone }
        defaults.set(false, forKey: AppController.smartFormattingKey)
        return AppController(
            sink: sink, metrics: metrics, capture: capture, permissions: permissions,
            transcriber: FallbackTranscriber(primary: UnavailableTranscriber(), fallback: engine),
            defaults: defaults
        )
    }

    /// Hold long enough to pass the accidental-tap filter.
    private func holdPastMinimum() async throws {
        try await Task.sleep(for: AppController.minimumHold + .milliseconds(50))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
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
}
