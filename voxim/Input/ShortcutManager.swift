//
//  ShortcutManager.swift
//  voxim
//
//  Hold-fn push-to-talk via a session event tap. Carbon hotkeys can't express fn, so this
//  needs Accessibility access (the same grant used to type into other apps). Events are
//  observed only; nothing is swallowed, so fn keeps working as a modifier.
//

import CoreGraphics
import Foundation
import os

final class ShortcutManager {
    static let displayName = "Hold fn"
    /// fn must be held this long, alone, before recording starts.
    static let holdThreshold: Duration = .milliseconds(300)

    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var detector = FnHoldDetector()
    private var holdTimer: Task<Void, Never>?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
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
                MainActor.assumeIsolated { manager.handle(type, event) }
                return Unmanaged.passUnretained(event)
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

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables slow taps; re-enable and end any recording rather than leave it stuck.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            perform(detector.reset())
        case .flagsChanged:
            perform(detector.handle(.flagsChanged(event.flags)))
        case .keyDown:
            perform(detector.handle(.keyDown))
        default:
            break
        }
    }

    private func perform(_ action: FnHoldDetector.Action?) {
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
        case .press:
            holdTimer = nil
            onPress()
        case .release:
            onRelease()
        case nil:
            break
        }
    }
}

/// System Settings › Keyboard › "Press 🌐 key to". Anything but "Do Nothing" also fires
/// when fn is released, e.g. starting Apple Dictation alongside voxim.
enum GlobeKeySetting {
    static var conflictingAction: String? {
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
