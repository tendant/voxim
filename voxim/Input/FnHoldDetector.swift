//
//  FnHoldDetector.swift
//  voxim
//
//  Push-to-talk on the fn key alone: hold past a threshold to start, release to stop.
//  fn used as a modifier (fn+arrow, fn+F-key, fn+E, …) or with other modifiers never starts
//  recording. Pure logic; the caller owns the timer and the event tap.
//

import CoreGraphics

nonisolated struct FnHoldDetector {
    enum Event {
        case flagsChanged(CGEventFlags)
        /// Any non-modifier key went down.
        case keyDown
        /// The hold timer scheduled on `.arm` fired.
        case holdElapsed
    }

    enum Action: Equatable {
        /// Start the hold timer; report `.holdElapsed` when it fires.
        case arm
        /// Cancel the hold timer.
        case disarm
        case press
        case release
    }

    private enum State {
        case idle
        case armed       // fn down alone, waiting for the threshold
        case active      // recording
        case suppressed  // fn is being used as a modifier; wait for it to come up
    }

    private static let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    private var state = State.idle

    var isActive: Bool { state == .active }

    mutating func handle(_ event: Event) -> Action? {
        switch (state, event) {
        case (.idle, .flagsChanged(let flags)):
            guard flags.contains(.maskSecondaryFn) else { return nil }
            if flags.intersection(Self.otherModifiers).isEmpty {
                state = .armed
                return .arm
            }
            state = .suppressed
            return nil

        case (.armed, .flagsChanged(let flags)):
            if !flags.contains(.maskSecondaryFn) {
                state = .idle  // a tap, not a hold
                return .disarm
            }
            if !flags.intersection(Self.otherModifiers).isEmpty {
                state = .suppressed
                return .disarm
            }
            return nil

        case (.armed, .keyDown):
            state = .suppressed
            return .disarm

        case (.armed, .holdElapsed):
            state = .active
            return .press

        case (.active, .flagsChanged(let flags)):
            // Other modifiers or keys while recording are ignored; only fn-up ends it.
            guard !flags.contains(.maskSecondaryFn) else { return nil }
            state = .idle
            return .release

        case (.suppressed, .flagsChanged(let flags)):
            if !flags.contains(.maskSecondaryFn) { state = .idle }
            return nil

        default:
            return nil
        }
    }

    /// The event tap was disabled or restarted; forget any in-flight press.
    mutating func reset() -> Action? {
        defer { state = .idle }
        switch state {
        case .active: return .release
        case .armed: return .disarm
        case .idle, .suppressed: return nil
        }
    }
}
