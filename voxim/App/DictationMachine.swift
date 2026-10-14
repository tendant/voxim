//
//  DictationMachine.swift
//  voxim
//
//  The dictation lifecycle as one explicit state machine. `reduce` is pure: given the current
//  state, an input, and a few facts about the world right now, it returns the next state and
//  the side effects to run. `AppController` runs the effects and feeds results back as inputs.
//
//      idle ──fn down (pre-roll)──▶ armed ──hold──▶ recording(hold) ──release──▶ finishing ──▶ idle(outcome)
//        │                            │  └─double-tap─▶ recording(hands-free) ──tap/auto-stop──┘
//        │                            └─tap / fn+key──▶ idle (pre-roll discarded unheard)
//        └─hold / double-tap (no pre-roll)──▶ starting ──mic granted──▶ recording
//      recording ──Esc──▶ idle (cancelled)
//

import Foundation

nonisolated enum DictationMachine {
    enum Trigger: Equatable, Sendable {
        /// Hold fn; release to finish.
        case hold
        /// Double-tap fn; tap to finish (or silence / time limit).
        case handsFree
    }

    /// What the last dictation ended with, shown until the next one starts.
    enum Outcome: Equatable, Sendable {
        case inserted
        case failed(String)
    }

    enum State: Equatable, Sendable {
        case idle(Outcome?)
        /// fn is down alone; the mic is already capturing (pre-roll) but nothing is shown yet.
        case armed
        /// Waiting for the microphone permission answer before capturing.
        case starting(Trigger)
        case recording(Trigger)
        /// Recording ended; the last piece is being transcribed and typed.
        case finishing(Trigger)
    }

    enum Input: Equatable, Sendable {
        case fnDown
        /// fn turned out to be a modifier (fn+key) or another modifier joined.
        case fnDisarmed
        /// fn held past the threshold.
        case holdStarted
        case fnReleased
        /// fn pressed and released quickly.
        case tap
        case doubleTap
        case escape
        case microphoneAnswered(granted: Bool)
        case captureFailed(String)
        /// Hands-free silence or time limit reached.
        case autoStop
        case finished(Outcome)
        case dismiss
    }

    /// Facts about the world at the moment of the input, supplied by the controller.
    struct Facts: Equatable, Sendable {
        /// Pre-roll is on and both permissions are already granted (no prompts on fn-down).
        var canPreRoll = true
        var accessibilityTrusted = true
        var handsFreeEnabled = true
        /// The recording lasted past the accidental-tap minimum.
        var heldLongEnough = true
    }

    enum Effect: Equatable, Sendable {
        /// Create the session (and typer) and start the microphone.
        case startCapture
        /// Stop the microphone and throw the session away unheard (no metrics).
        case discardCapture
        /// Recording became visible: HUD, live preview, hands-free monitor, focus snapshot.
        case beginRecording(Trigger)
        /// Stop the microphone and finish the session: transcribe, type, report `.finished`.
        case finish(Trigger)
        /// Esc: stop and discard, recording a cancelled dictation.
        case cancel
        case requestMicrophone
        case requestAccessibility
        case recordTooShort
        case recordFailure(DictationEvent.Reason)
    }

    struct Transition: Equatable, Sendable {
        var state: State
        var effects: [Effect] = []
    }

    static let accessibilityMessage = InsertionError.accessibilityDenied.localizedDescription
    static let microphoneMessage = AudioCaptureError.microphoneDenied.localizedDescription

    static func reduce(_ state: State, _ input: Input, _ facts: Facts) -> Transition {
        switch (state, input) {

        // Idle: fn goes down, a hold begins, or a double-tap.
        case (.idle, .fnDown):
            return facts.canPreRoll ? Transition(state: .armed, effects: [.startCapture]) : Transition(state: state)
        case (.idle, .holdStarted):
            return start(.hold, facts)
        case (.idle, .doubleTap):
            return facts.handsFreeEnabled ? start(.handsFree, facts) : Transition(state: state)
        case (.idle, .dismiss):
            return Transition(state: .idle(nil))

        // Armed (pre-roll capturing): becomes a recording, or is discarded unheard.
        case (.armed, .holdStarted):
            return Transition(state: .recording(.hold), effects: [.beginRecording(.hold)])
        case (.armed, .doubleTap) where facts.handsFreeEnabled:
            return Transition(state: .recording(.handsFree), effects: [.beginRecording(.handsFree)])
        case (.armed, .tap), (.armed, .fnDisarmed), (.armed, .doubleTap), (.armed, .fnReleased):
            return Transition(state: .idle(nil), effects: [.discardCapture])
        case (.armed, .captureFailed):
            // Pre-roll couldn't start; the hold path will try (and report) again.
            return Transition(state: .idle(nil), effects: [.discardCapture])

        // Starting: waiting on the microphone permission prompt.
        case (.starting(let trigger), .microphoneAnswered(granted: true)):
            return Transition(state: .recording(trigger), effects: [.startCapture, .beginRecording(trigger)])
        case (.starting, .microphoneAnswered(granted: false)):
            return Transition(state: .idle(.failed(microphoneMessage)), effects: [.recordFailure(.microphoneDenied)])
        case (.starting(.hold), .fnReleased):
            // Released while the prompt was up: don't start recording.
            return Transition(state: .idle(nil))

        // Recording.
        case (.recording(.hold), .fnReleased):
            return facts.heldLongEnough
                ? Transition(state: .finishing(.hold), effects: [.finish(.hold)])
                : Transition(state: .idle(nil), effects: [.discardCapture, .recordTooShort])
        case (.recording(.handsFree), .tap), (.recording(.handsFree), .fnReleased), (.recording(.handsFree), .autoStop):
            // Started deliberately, so no accidental-tap filter.
            return Transition(state: .finishing(.handsFree), effects: [.finish(.handsFree)])
        case (.recording, .escape):
            return Transition(state: .idle(nil), effects: [.cancel])
        case (.recording, .captureFailed(let message)):
            return Transition(state: .idle(.failed(message)), effects: [.discardCapture, .recordFailure(.noInputDevice)])

        // Finishing: the pipeline reports back.
        case (.finishing, .finished(let outcome)):
            return Transition(state: .idle(outcome))

        default:
            return Transition(state: state)
        }
    }

    /// A recording requested without pre-roll: check Accessibility, then ask for the microphone.
    private static func start(_ trigger: Trigger, _ facts: Facts) -> Transition {
        guard facts.accessibilityTrusted else {
            return Transition(state: .idle(.failed(accessibilityMessage)),
                              effects: [.requestAccessibility, .recordFailure(.accessibilityDenied)])
        }
        return Transition(state: .starting(trigger), effects: [.requestMicrophone])
    }
}

extension DictationMachine.State {
    var trigger: DictationMachine.Trigger? {
        switch self {
        case .starting(let t), .recording(let t), .finishing(let t): t
        case .idle, .armed: nil
        }
    }

    var isRecording: Bool {
        if case .recording = self { true } else { false }
    }
}
