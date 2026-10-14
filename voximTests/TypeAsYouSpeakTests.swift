//
//  TypeAsYouSpeakTests.swift
//  voximTests
//
//  The controller with real DictationSessions (loudness classifier, scripted engine) and a fake mic.
//

import Foundation
import Testing
@testable import voxim

@MainActor
struct TypeAsYouSpeakTests {
    let capture = FakeCapture()
    let sink = FakeSink()
    let engine = ScriptedEngine()
    let defaults = UserDefaults(suiteName: "voxim-tays-\(UUID().uuidString)")!
    let metrics = MetricsStore(
        fileURL: FileManager.default.temporaryDirectory.appending(path: "voxim-tays-\(UUID().uuidString).jsonl")
    )

    private func speech(_ seconds: Double) -> [Float] { Array(repeating: 0.5, count: Int(seconds * 16_000)) }
    private func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * 16_000)) }

    private func makeController(terminal: Bool = false) -> AppController {
        var permissions = AppController.Permissions()
        permissions.isAccessibilityTrusted = { true }
        permissions.isMicrophoneGranted = { true }
        permissions.requestMicrophone = { true }
        defaults.set(false, forKey: AppController.smartFormattingKey)
        defaults.set(false, forKey: AppController.livePreviewKey)
        return AppController(
            sink: sink, metrics: metrics, capture: capture, permissions: permissions,
            engine: engine, voiceActivity: nil, speechClassifier: { LoudnessClassifier() },
            isTerminalFrontmost: { terminal }, currentFocus: { FocusedApp(pid: 1, name: "Notes") },
            defaults: defaults
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func startRecording(_ controller: AppController) {
        controller.handle(.arm)
        controller.handle(.press)
    }

    @Test func typesEachSentenceBeforeRelease() async throws {
        let controller = makeController()
        startRecording(controller)

        capture.push(speech(2) + silence(0.6))
        try await waitUntil { sink.inserted == ["p0"] }
        #expect(controller.phase == .recording)      // typed while still holding fn

        capture.push(speech(2))
        try await Task.sleep(for: AppController.minimumHold)
        controller.handle(.release)                   // the fake mic delivers one more second on stop
        try await waitUntil { controller.phase == .inserted }

        #expect(sink.inserted == ["p0", " p1"])
        #expect(metrics.events.last?.outcome == .inserted)
    }

    @Test func escStopsTypingButKeepsWhatWasTyped() async throws {
        let controller = makeController()
        startRecording(controller)
        capture.push(speech(2) + silence(0.6))
        try await waitUntil { sink.inserted.count == 1 }

        capture.push(speech(2) + silence(0.6))
        controller.handle(.cancel)
        try await Task.sleep(for: .milliseconds(200))

        #expect(sink.inserted == ["p0"])
        #expect(controller.phase == .idle)
        #expect(metrics.events.last?.outcome == .cancelled)
    }

    @Test func turnedOffTypesEverythingAtRelease() async throws {
        defaults.set(false, forKey: AppController.typeAsYouSpeakKey)
        let controller = makeController()
        startRecording(controller)
        capture.push(speech(2) + silence(0.6) + speech(2))
        try await waitUntil { await engine.pieceSeconds.count == 1 }
        #expect(sink.inserted.isEmpty)               // transcribed, but held back

        try await Task.sleep(for: AppController.minimumHold)
        controller.handle(.release)
        try await waitUntil { controller.phase == .inserted }
        #expect(sink.inserted == ["p0 p1"])
    }

    @Test func terminalsTypeAtRelease() async throws {
        let controller = makeController(terminal: true)
        startRecording(controller)
        capture.push(speech(2) + silence(0.6) + speech(2))
        try await waitUntil { await engine.pieceSeconds.count == 1 }
        #expect(sink.inserted.isEmpty)

        try await Task.sleep(for: AppController.minimumHold)
        controller.handle(.release)
        try await waitUntil { controller.phase == .inserted }
        #expect(sink.inserted == ["p0 p1"])
    }

    @Test func aBriefFocusChangePausesThenResumesWithNothingLost() async throws {
        // The second paste finds another app in front; by the time typing checks again the user
        // is back, so it resumes (see PauseResumeTests for longer absences).
        sink.failOnCall = 1
        let controller = makeController()
        startRecording(controller)
        capture.push(speech(2) + silence(0.6))
        try await waitUntil { sink.inserted.count == 1 }
        capture.push(speech(2) + silence(0.6) + speech(2))

        try await Task.sleep(for: AppController.minimumHold)
        controller.handle(.release)
        try await waitUntil { controller.phase == .inserted }

        // p2 is the last sentence plus the fake mic's final second (no pause between them).
        #expect(sink.inserted == ["p0", " p1", " p2"])
        #expect(controller.undelivered.isEmpty)
    }
}
