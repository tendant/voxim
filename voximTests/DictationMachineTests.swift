//
//  DictationMachineTests.swift
//  voximTests
//
//  The dictation lifecycle as a table: (state, input, facts) → (state, effects).
//

import Foundation
import Testing
@testable import voxim

struct DictationMachineTests {
    typealias M = DictationMachine

    private func reduce(_ state: M.State, _ input: M.Input, _ facts: M.Facts = M.Facts()) -> M.Transition {
        M.reduce(state, input, facts)
    }

    // MARK: Pre-roll

    @Test func fnDownPreRollsWhenAllowed() {
        #expect(reduce(.idle(nil), .fnDown) == M.Transition(state: .armed, effects: [.startCapture]))
    }

    @Test func fnDownWithoutPreRollDoesNothing() {
        #expect(reduce(.idle(nil), .fnDown, M.Facts(canPreRoll: false)) == M.Transition(state: .idle(nil)))
    }

    @Test func aPreviousOutcomeDoesNotBlockTheNextDictation() {
        #expect(reduce(.idle(.failed("x")), .fnDown).state == .armed)
        #expect(reduce(.idle(.inserted), .holdStarted).state == .starting(.hold))
    }

    @Test(arguments: [M.Input.tap, .fnDisarmed])
    func tapOrFnAsModifierDiscardsThePreRollUnheard(input: M.Input) {
        #expect(reduce(.armed, input) == M.Transition(state: .idle(nil), effects: [.discardCapture]))
    }

    @Test func holdTurnsThePreRollIntoARecording() {
        #expect(reduce(.armed, .holdStarted) == M.Transition(state: .recording(.hold), effects: [.beginRecording(.hold)]))
    }

    @Test func doubleTapTurnsThePreRollIntoHandsFree() {
        #expect(reduce(.armed, .doubleTap)
                == M.Transition(state: .recording(.handsFree), effects: [.beginRecording(.handsFree)]))
    }

    @Test func doubleTapIsJustATapWhenHandsFreeIsOff() {
        #expect(reduce(.armed, .doubleTap, M.Facts(handsFreeEnabled: false))
                == M.Transition(state: .idle(nil), effects: [.discardCapture]))
        #expect(reduce(.idle(nil), .doubleTap, M.Facts(handsFreeEnabled: false)).state == .idle(nil))
    }

    // MARK: Starting without pre-roll

    @Test func holdWithoutPreRollAsksForTheMicrophone() {
        #expect(reduce(.idle(nil), .holdStarted) == M.Transition(state: .starting(.hold), effects: [.requestMicrophone]))
    }

    @Test func withoutAccessibilityItAsksAndFails() {
        let t = reduce(.idle(nil), .holdStarted, M.Facts(accessibilityTrusted: false))
        #expect(t.state == .idle(.failed(M.accessibilityMessage)))
        #expect(t.effects == [.requestAccessibility, .recordFailure(.accessibilityDenied)])
    }

    @Test func microphoneGrantedStartsRecording() {
        #expect(reduce(.starting(.handsFree), .microphoneAnswered(granted: true))
                == M.Transition(state: .recording(.handsFree), effects: [.startCapture, .beginRecording(.handsFree)]))
    }

    @Test func microphoneDeniedFails() {
        #expect(reduce(.starting(.hold), .microphoneAnswered(granted: false))
                == M.Transition(state: .idle(.failed(M.microphoneMessage)), effects: [.recordFailure(.microphoneDenied)]))
    }

    @Test func releasedWhileThePromptIsUpNeverRecords() {
        // Previously guarded by a separate `keyHeld` flag.
        #expect(reduce(.starting(.hold), .fnReleased) == M.Transition(state: .idle(nil)))
        #expect(reduce(.idle(nil), .microphoneAnswered(granted: true)) == M.Transition(state: .idle(nil)))
    }

    // MARK: Finishing

    @Test func releaseFinishesAHold() {
        #expect(reduce(.recording(.hold), .fnReleased) == M.Transition(state: .finishing(.hold), effects: [.finish(.hold)]))
    }

    @Test func aTooShortHoldIsDiscarded() {
        #expect(reduce(.recording(.hold), .fnReleased, M.Facts(heldLongEnough: false))
                == M.Transition(state: .idle(nil), effects: [.discardCapture, .recordTooShort]))
    }

    @Test(arguments: [M.Input.tap, .fnReleased, .autoStop])
    func handsFreeFinishesEvenIfVeryShort(input: M.Input) {
        // Previously the hold-to-talk accidental-tap filter threw these away.
        #expect(reduce(.recording(.handsFree), input, M.Facts(heldLongEnough: false))
                == M.Transition(state: .finishing(.handsFree), effects: [.finish(.handsFree)]))
    }

    @Test func autoStopDoesNotApplyToHolds() {
        #expect(reduce(.recording(.hold), .autoStop) == M.Transition(state: .recording(.hold)))
    }

    @Test(arguments: [M.Trigger.hold, .handsFree])
    func escapeCancelsEitherRecording(trigger: M.Trigger) {
        #expect(reduce(.recording(trigger), .escape) == M.Transition(state: .idle(nil), effects: [.cancel]))
    }

    @Test func captureFailureWhileRecordingFails() {
        let t = reduce(.recording(.hold), .captureFailed("No microphone input is available."))
        #expect(t.state == .idle(.failed("No microphone input is available.")))
        #expect(t.effects == [.discardCapture, .recordFailure(.noInputDevice)])
    }

    @Test func thePipelineResultEndsFinishing() {
        #expect(reduce(.finishing(.hold), .finished(.inserted)) == M.Transition(state: .idle(.inserted)))
        #expect(reduce(.finishing(.handsFree), .finished(.failed("Focus moved"))) == M.Transition(state: .idle(.failed("Focus moved"))))
    }

    @Test func dismissClearsTheOutcome() {
        #expect(reduce(.idle(.failed("x")), .dismiss) == M.Transition(state: .idle(nil)))
    }

    // MARK: Things that must not happen

    @Test(arguments: [M.Input.fnDown, .holdStarted, .doubleTap, .tap, .fnReleased, .escape, .autoStop, .dismiss])
    func nothingInterruptsFinishing(input: M.Input) {
        // No pre-roll, new recording or cancel while the last one is still being typed.
        #expect(reduce(.finishing(.hold), input) == M.Transition(state: .finishing(.hold)))
    }

    @Test(arguments: [M.Input.fnDown, .holdStarted, .doubleTap, .tap])
    func aRecordingIgnoresNewStarts(input: M.Input) {
        #expect(reduce(.recording(.hold), input) == M.Transition(state: .recording(.hold)))
    }

    @Test func stateHelpers() {
        #expect(M.State.recording(.handsFree).isRecording)
        #expect(!M.State.finishing(.hold).isRecording)
        #expect(M.State.starting(.handsFree).trigger == .handsFree)
        #expect(M.State.armed.trigger == nil)
    }
}

struct PreferencesTests {
    @Test func defaultsWhenNothingIsSet() {
        let p = Preferences(UserDefaults(suiteName: "voxim-prefs-\(UUID().uuidString)")!)
        #expect(p == Preferences())
        #expect(p.handsFreeSilence == 300 && p.handsFreeMaximum == 3600)
    }

    @Test func readsStoredValuesAndZeroMeansNever() {
        let defaults = UserDefaults(suiteName: "voxim-prefs-\(UUID().uuidString)")!
        defaults.set(false, forKey: Preferences.Key.typeAsYouSpeak)
        defaults.set(ChineseScript.traditional.rawValue, forKey: Preferences.Key.chineseScript)
        defaults.set(0.0, forKey: Preferences.Key.handsFreeSilence)
        defaults.set(600.0, forKey: Preferences.Key.handsFreeMaximum)
        let p = Preferences(defaults)
        #expect(!p.typeAsYouSpeak)
        #expect(p.chineseScript == .traditional)
        #expect(p.handsFreeSilence == .infinity)
        #expect(p.handsFreeMaximum == 600)
    }
}

struct TextPipelineTests {
    private let unknown = InsertionContext.unknown

    @Test func rulesScriptAndSpacingFromTheSnapshot() {
        var preferences = Preferences()
        preferences.chineseScript = .traditional
        let pipeline = TextPipeline(rules: [Replacement(spoken: "NTM", written: "npm")], preferences: preferences)
        #expect(pipeline.applyRules("用NTM安装依赖") == "用 npm 安裝依賴")
    }

    @Test func piecesContinueFromWhatWasTyped() {
        var preferences = Preferences()
        preferences.smartFormatting = true
        let pipeline = TextPipeline(rules: [], preferences: preferences)
        #expect(pipeline.piece("The build failed.", after: "", context: unknown) == "The build failed.")
        #expect(pipeline.piece("Then retry", after: "The build failed.", context: unknown) == " Then retry")
        #expect(pipeline.piece("And deploy.", after: "Then retry", context: unknown) == " and deploy.")
    }

    @Test func withoutSmartFormattingPiecesAreJustJoined() {
        var preferences = Preferences()
        preferences.smartFormatting = false
        let pipeline = TextPipeline(rules: [], preferences: preferences)
        #expect(pipeline.piece("p1", after: "p0", context: unknown) == " p1")
        #expect(pipeline.piece("然后修复", after: "先运行测试", context: unknown) == "然后修复")
    }
}
