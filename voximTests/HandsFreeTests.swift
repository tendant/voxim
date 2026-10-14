//
//  HandsFreeTests.swift
//  voximTests
//

import Foundation
import Testing
@testable import voxim

@MainActor
struct HandsFreeTests {
    let capture = FakeCapture()
    let sink = FakeSink()
    let engine = ScriptedEngine()
    let defaults = UserDefaults(suiteName: "voxim-hf-\(UUID().uuidString)")!
    let metrics = MetricsStore(
        fileURL: FileManager.default.temporaryDirectory.appending(path: "voxim-hf-\(UUID().uuidString).jsonl")
    )

    private final class Changes { var values: [Bool] = [] }
    private let changes = Changes()

    private func speech(_ seconds: Double) -> [Float] { Array(repeating: 0.5, count: Int(seconds * 16_000)) }
    private func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * 16_000)) }

    private func makeController(limits: AppController.HandsFreeLimits = .init()) -> AppController {
        var permissions = AppController.Permissions()
        permissions.isAccessibilityTrusted = { true }
        permissions.isMicrophoneGranted = { true }
        permissions.requestMicrophone = { true }
        defaults.set(false, forKey: AppController.smartFormattingKey)
        defaults.set(false, forKey: AppController.livePreviewKey)
        let controller = AppController(
            sink: sink, metrics: metrics, capture: capture, permissions: permissions,
            engine: engine, voiceActivity: nil, speechClassifier: { LoudnessClassifier() },
            isTerminalFrontmost: { false }, handsFreeLimits: limits, defaults: defaults
        )
        let changes = self.changes
        controller.onHandsFreeChange = { changes.values.append($0) }
        return controller
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// What the shortcut layer sends for a double-tap: first tap (arm, tap), second (arm, lock).
    private func doubleTap(_ controller: AppController) {
        controller.handle(.arm)
        controller.handle(.tap)
        controller.handle(.arm)
        controller.handle(.lock)
    }

    @Test func doubleTapLocksRecordingAndATapFinishes() async throws {
        let controller = makeController()
        doubleTap(controller)
        #expect(controller.phase == .recording)
        #expect(controller.isHandsFree)
        #expect(changes.values == [true])
        #expect(capture.starts == 2)                 // the first tap's pre-roll was discarded

        capture.push(speech(2) + silence(0.6))
        try await waitUntil { sink.inserted == ["p0"] }   // typed while locked

        try await Task.sleep(for: AppController.minimumHold)
        controller.handle(.arm)                        // tap fn to finish
        controller.handle(.tap)
        try await waitUntil { controller.phase == .inserted }

        #expect(sink.inserted == ["p0", " p1"])
        #expect(!controller.isHandsFree)
        #expect(changes.values == [true, false])
        #expect(metrics.events.last?.handsFree == true)
    }

    @Test func escCancelsHandsFree() async throws {
        let controller = makeController()
        doubleTap(controller)
        controller.handle(.cancel)
        #expect(controller.phase == .idle)
        #expect(!controller.isHandsFree)
        #expect(metrics.events.last?.outcome == .cancelled)
    }

    @Test func longSilenceFinishesAutomatically() async throws {
        let controller = makeController(limits: .init(silence: 0.5, maximum: 60, warning: 10, checkInterval: .milliseconds(50)))
        doubleTap(controller)
        capture.push(speech(2) + silence(1))
        try await waitUntil { controller.phase == .inserted }
        // p1 is the extra second the fake mic delivers when stopped.
        #expect(sink.inserted == ["p0", " p1"])
        #expect(!controller.isHandsFree)
        #expect(metrics.events.last?.outcome == .inserted)
    }

    @Test func capFinishesWithACountdownFirst() async throws {
        let controller = makeController(limits: .init(silence: 60, maximum: 0.8, warning: 0.6, checkInterval: .milliseconds(50)))
        doubleTap(controller)
        capture.push(speech(1))
        try await waitUntil { controller.handsFreeNotice != nil }
        #expect(controller.handsFreeNotice?.hasPrefix("Stops in") == true)
        try await waitUntil { controller.phase == .inserted }
        #expect(controller.handsFreeNotice == nil)
    }

    @Test func doubleTapIsIgnoredWhenTurnedOff() {
        defaults.set(false, forKey: AppController.handsFreeKey)
        let controller = makeController()
        doubleTap(controller)
        #expect(controller.phase == .idle)
        #expect(!controller.isHandsFree)
    }

    @Test func holdingAndReleasingFnAlsoFinishes() async throws {
        let controller = makeController()
        doubleTap(controller)
        capture.push(speech(1))
        try await Task.sleep(for: AppController.minimumHold)
        controller.handle(.arm)
        controller.handle(.press)                      // ignored while recording
        controller.handle(.release)
        try await waitUntil { controller.phase == .inserted }
        #expect(!controller.isHandsFree)
    }

    @Test func goesIdleInSilenceAndWakesOnSpeech() async throws {
        let controller = makeController(limits: .init(silence: .infinity, maximum: .infinity, warning: 1,
                                                      idleAfter: 0.5, checkInterval: .milliseconds(50)))
        doubleTap(controller)
        capture.push(speech(2) + silence(1))
        try await waitUntil { controller.isListeningIdle }
        #expect(controller.phase == .recording)      // idle, still listening

        capture.push(speech(1))
        try await waitUntil { !controller.isListeningIdle }
        controller.handle(.cancel)
    }

    @Test func neverFinishesOnSilenceWhenSetToNever() async throws {
        let controller = makeController(limits: .init(silence: .infinity, maximum: .infinity, warning: 1,
                                                      idleAfter: 0.5, checkInterval: .milliseconds(20)))
        doubleTap(controller)
        capture.push(speech(2) + silence(40))
        try await Task.sleep(for: .milliseconds(400))
        #expect(controller.phase == .recording)
        #expect(controller.handsFreeNotice == nil)    // no cap, no countdown
        controller.handle(.cancel)
    }
}
