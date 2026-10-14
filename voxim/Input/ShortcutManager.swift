//
//  ShortcutManager.swift
//  voxim
//
//  Hold-fn push-to-talk via a session event tap. Carbon hotkeys can't express fn, so this
//  needs Accessibility access (the same grant used to type into other apps). Events pass
//  through untouched, so fn keeps working as a modifier; the one exception is Esc pressed
//  while recording, which cancels and is swallowed.
//

import AppKit
import CoreGraphics
import Foundation
import os

final class ShortcutManager {
    static let displayName = "Hold fn"
    /// fn must be held this long, alone, before recording starts.
    static let holdThreshold: Duration = .milliseconds(300)

    /// Receives every push-to-talk action: `.arm` the moment fn goes down alone (pre-roll can
    /// start), `.disarm` if it turns out to be a tap or a modifier, then `.press`/`.release`/`.cancel`.
    private let onAction: (FnHoldDetector.Action) -> Void
    private var detector = FnHoldDetector()
    private var doubleTap = DoubleTapDetector()
    /// Whether a double-tap of fn should lock recording on (menu setting).
    var isDoubleTapEnabled: () -> Bool = { true }

    /// Tells the detector a hands-free recording is running (Esc cancels without fn held).
    func setHandsFree(_ active: Bool) {
        detector.handsFree = active
        doubleTap.reset()
    }
    private var holdTimer: Task<Void, Never>?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?

    init(onAction: @escaping (FnHoldDetector.Action) -> Void) {
        self.onAction = onAction
    }

    var isRunning: Bool { tap != nil }

    /// Installs the tap now if Accessibility is granted, otherwise retries until it is.
    func start() {
        guard tap == nil else { return }
        if installTap() { return }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if self.installTap() { timer.invalidate() }
            }
        }
    }

    private func installTap() -> Bool {
        guard AXAccess.isTrusted else { return false }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Active tap (allowed by the Accessibility grant alone; listen-only can also require
            // Input Monitoring). Every event is still passed through unchanged.
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let manager = Unmanaged<ShortcutManager>.fromOpaque(refcon!).takeUnretainedValue()
                let swallow = MainActor.assumeIsolated { manager.handle(type, event) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.app.error("could not create fn event tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        Log.app.info("fn event tap installed")
        return true
    }

    /// Returns true when the event must not reach the focused app (only Esc that cancels a recording).
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let action: FnHoldDetector.Action?
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables slow taps; re-enable and end any recording rather than leave it stuck.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            action = detector.reset()
        case .flagsChanged:
            action = detector.handle(.flagsChanged(event.flags))
        case .keyDown:
            action = detector.handle(.keyDown(keyCode: event.getIntegerValueField(.keyboardEventKeycode)))
        default:
            action = nil
        }
        perform(action)
        return action == .cancel
    }

    private func perform(_ action: FnHoldDetector.Action?) {
        guard let action else { return }
        switch action {
        case .arm:
            holdTimer?.cancel()
            holdTimer = Task { [weak self] in
                try? await Task.sleep(for: Self.holdThreshold)
                guard !Task.isCancelled, let self else { return }
                self.perform(self.detector.handle(.holdElapsed))
            }
        case .disarm:
            holdTimer?.cancel()
            holdTimer = nil
        case .tap:
            holdTimer?.cancel()
            holdTimer = nil
            if !detector.handsFree, isDoubleTapEnabled(),
               doubleTap.registerTap(at: ProcessInfo.processInfo.systemUptime) {
                onAction(.lock)
                return
            }
        case .press:
            holdTimer = nil
            doubleTap.reset()
        case .release, .cancel, .lock:
            break
        }
        onAction(action)
    }
}

/// System Settings › Keyboard › "Press 🌐 key to". Anything but "Do Nothing" also fires
/// when fn is released, e.g. starting Apple Dictation alongside voxim.
enum GlobeKeySetting {
    /// Apple Dictation also listens and types when fn is pressed, so text appears twice.
    static var startsAppleDictation: Bool { conflictingAction == "Start Dictation" }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    static var conflictingAction: String? {
        // Re-read from disk: the user may have just changed it in System Settings.
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        switch value {
        case 0: return nil
        case 1: return "Change Input Source"
        case 2: return "Show Emoji & Symbols"
        case 3: return "Start Dictation"
        default: return nil
        }
    }
}
