//
//  TextInserter.swift
//  voxim
//

import AppKit
import ApplicationServices

nonisolated enum InsertionError: LocalizedError, Equatable {
    case accessibilityDenied
    case secureInput
    case noFocusedField
    case focusChanged(from: String, to: String)

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "voxim needs Accessibility access to type into other apps. Enable it in System Settings › Privacy & Security › Accessibility."
        case .secureInput:
            "A password field or secure input is active, so voxim won't type there."
        case .noFocusedField:
            "No text field has focus."
        case .focusChanged(let from, let to):
            "Focus moved from \(from) to \(to) while you were speaking, so nothing was typed."
        }
    }
}

/// Where dictated text goes. Implementations insert at the cursor and never press Return.
protocol DictationSink {
    func insert(_ text: String, expecting app: FocusedApp?) async throws
}

/// The app that had focus when recording started; insertion is refused if focus moved.
nonisolated struct FocusedApp: Equatable, Sendable {
    var pid: pid_t
    var name: String

    @MainActor static var current: FocusedApp? {
        NSWorkspace.shared.frontmostApplication.map {
            FocusedApp(pid: $0.processIdentifier, name: $0.localizedName ?? "another app")
        }
    }
}

enum AXAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt once; afterwards the user must toggle voxim in System Settings.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether some UI element in the frontmost app has keyboard focus.
    static var hasFocusedElement: Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        return AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success
            && focused != nil
    }
}
