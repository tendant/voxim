//
//  FocusContext.swift
//  voxim
//
//  Reads just enough about the focused field to format a transcript: the few characters
//  before the cursor and whether the app is a terminal. Never reads the whole field, and
//  the text is used only for formatting (never logged or stored).
//

import AppKit
import ApplicationServices

enum FocusContext {
    static let terminalBundleIDs: Set<String> = [
        "com.mitchellh.ghostty",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    private static let lookBehind = 3

    static func current() -> InsertionContext {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return InsertionContext(
            precedingText: AXAccess.isTrusted ? precedingText() : nil,
            isTerminal: terminalBundleIDs.contains(bundleID)
        )
    }

    private static func precedingText() -> String? {
        let system = AXUIElementCreateSystemWide()
        // A hung app must not stall dictation.
        AXUIElementSetMessagingTimeout(system, 0.25)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &selection) else { return nil }

        let start = max(0, selection.location - lookBehind)
        let length = selection.location - start
        if length == 0 { return "" }  // cursor at the start of the field

        var lookup = CFRange(location: start, length: length)
        guard let lookupValue = AXValueCreate(.cfRange, &lookup) else { return nil }
        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, lookupValue, &textRef
        ) == .success else { return nil }
        return textRef as? String
    }
}
