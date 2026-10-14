//
//  FnHoldDetector.swift
//  voxim
//
//  Push-to-talk on the fn key alone: hold past a threshold to start, release to stop.
//  fn used as a modifier (fn+arrow, fn+F-key, fn+E, …) or with other modifiers never starts
//  recording. Pure logic; the caller owns the timer and the event tap.
//

import Carbon.HIToolbox
import CoreGraphics

nonisolated struct FnHoldDetector {
    enum Event {
        case flagsChanged(CGEventFlags)
        /// A non-modifier key went down.
        case keyDown(keyCode: Int64)
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
        /// Esc while recording: discard the recording. The Esc must be swallowed.
        case cancel
        /// fn pressed and released alone, quicker than the hold threshold. Ends the arm like
        /// `.disarm`; two in a row make a double-tap (see `DoubleTapDetector`).
        case tap
        /// A double-tap of fn: lock recording on (hands-free). Emitted by `ShortcutManager`.
        case lock
    }

    /// Set while a hands-free recording runs: Esc then cancels even though fn isn't held.
    var handsFree = false

    static let escapeKey = Int64(kVK_Escape)

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
                return .tap
            }
            if !flags.intersection(Self.otherModifiers).isEmpty {
                state = .suppressed
                return .disarm
            }
            return nil

        case (.idle, .keyDown(let keyCode)) where keyCode == Self.escapeKey && handsFree:
            return .cancel

        case (.armed, .keyDown):
            state = .suppressed
            return .disarm

        case (.armed, .holdElapsed):
            state = .active
            return .press

        case (.active, .keyDown(let keyCode)) where keyCode == Self.escapeKey:
            // Wait for fn to come up before anything can start again.
            state = .suppressed
            return .cancel

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

/// Two fn taps whose releases are within `window` seconds make a double-tap.
nonisolated struct DoubleTapDetector {
    var window: TimeInterval = 0.45
    private var lastTap: TimeInterval?

    /// Records a tap at `time` (seconds, monotonic); true when it completes a double-tap.
    mutating func registerTap(at time: TimeInterval) -> Bool {
        if let lastTap, time - lastTap <= window {
            self.lastTap = nil
            return true
        }
        lastTap = time
        return false
    }

    mutating func reset() {
        lastTap = nil
    }
}
