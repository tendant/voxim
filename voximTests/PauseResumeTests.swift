//
//  PauseResumeTests.swift
//  voximTests
//
//  Type as you speak, with the user switching to another app mid-dictation.
//

import Foundation
import Testing
@testable import voxim

/// Which app is in front: "Notes" (where dictation started) or "Safari" while away.
@MainActor
final class FocusSimulation {
    var away = false
    var current: FocusedApp { away ? FocusedApp(pid: 2, name: "Safari") : FocusedApp(pid: 1, name: "Notes") }
}

/// Refuses to type while another app is in front, like the real focus check.
@MainActor
final class FocusAwareSink: DictationSink {
    let focus: FocusSimulation
    private(set) var inserted: [String] = []

    init(focus: FocusSimulation) { self.focus = focus }

    func insert(_ text: String, expecting app: FocusedApp?) async throws -> ContinuousClock.Instant {
        if focus.away { throw InsertionError.focusChanged(from: "Notes", to: "Safari") }
        inserted.append(text)
        return .now
    }
}

@MainActor
struct PauseResumeTests {
    let focus = FocusSimulation()
    let sink: FocusAwareSink
    let capture = FakeCapture()
    let engine = ScriptedEngine()
    let defaults = UserDefaults(suiteName: "voxim-pause-\(UUID().uuidString)")!
    let metrics = MetricsStore(
        fileURL: FileManager.default.temporaryDirectory.appending(path: "voxim-pause-\(UUID().uuidString).jsonl")
    )

    init() { sink = FocusAwareSink(focus: focus) }

    private func sentence() -> [Float] {
        Array(repeating: 0.5, count: 32_000) + Array(repeating: 0, count: 9_600)   // 2 s speech + pause
    }

    private func makeController() -> AppController {
        var permissions = AppController.Permissions()
        permissions.isAccessibilityTrusted = { true }
        permissions.isMicrophoneGranted = { true }
        permissions.requestMicrophone = { true }
        defaults.set(false, forKey: AppController.smartFormattingKey)
        defaults.set(false, forKey: AppController.livePreviewKey)
        let focus = self.focus
        return AppController(
            sink: sink, metrics: metrics, capture: capture, permissions: permissions,
            engine: engine, voiceActivity: nil, speechClassifier: { LoudnessClassifier() },
            isTerminalFrontmost: { false }, currentFocus: { focus.current }, defaults: defaults
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

    @Test func sentencesWaitWhileAwayAndAreTypedOnReturn() async throws {
        let controller = makeController()
        startRecording(controller)
        capture.push(sentence())
        try await waitUntil { sink.inserted == ["p0"] }

        focus.away = true                              // user switches to Safari
        capture.push(sentence())
        try await waitUntil { controller.typingPausedFor == "Notes" }
        capture.push(sentence())                       // keeps talking while away
        try await waitUntil { await engine.pieceSeconds.count == 3 }
        #expect(sink.inserted == ["p0"])               // nothing typed into Safari
        #expect(controller.phase == .recording)

        focus.away = false                             // back in Notes
        try await waitUntil { sink.inserted == ["p0", " p1", " p2"] }
        #expect(controller.typingPausedFor == nil)

        try await Task.sleep(for: AppController.minimumHold)
        controller.handle(.release)
        try await waitUntil { controller.phase == .inserted }
        #expect(sink.inserted.count == 4)              // + the fake mic's final second
    }

    @Test func finishingWhileAwayKeepsTheRestToCopy() async throws {
        let controller = makeController()
        startRecording(controller)
        capture.push(sentence())
        try await waitUntil { sink.inserted == ["p0"] }

        focus.away = true
        capture.push(sentence())
        try await waitUntil { controller.typingPausedFor != nil }
        try await Task.sleep(for: AppController.minimumHold)
        controller.handle(.release)
        try await waitUntil { if case .failed = controller.phase { true } else { false } }

        #expect(sink.inserted == ["p0"])               // what was typed stays
        #expect(controller.undelivered == "p1 p2")     // the rest is offered to copy
        #expect(controller.typingPausedFor == nil)
        #expect(metrics.events.last?.reason == .focusChanged)
    }

    @Test func escWhilePausedStopsWaiting() async throws {
        let controller = makeController()
        startRecording(controller)
        focus.away = true
        capture.push(sentence())
        try await waitUntil { controller.typingPausedFor != nil }

        controller.handle(.cancel)
        #expect(controller.phase == .idle)
        #expect(controller.typingPausedFor == nil)
        focus.away = false
        try await Task.sleep(for: .milliseconds(400))
        #expect(sink.inserted.isEmpty)                 // returning later types nothing
    }
}
