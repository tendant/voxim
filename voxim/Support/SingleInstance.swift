//
//  SingleInstance.swift
//  voxim
//

import AppKit
import os

/// Two copies (e.g. the installed app and one run from Xcode) would both react to fn and
/// type twice. The most recently launched copy wins: it asks any older one to quit.
enum SingleInstance {
    /// Release and Debug builds use different bundle IDs (so each keeps its own
    /// Accessibility grant) but must still exclude each other.
    static let bundleIDs = ["ai.weilabs.voxim", "ai.weilabs.voxim.debug"]

    static func takeOver() {
        let me = NSRunningApplication.current
        let others = bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        for other in others where other.processIdentifier != me.processIdentifier {
            Log.app.info("asking older voxim (pid \(other.processIdentifier, privacy: .public)) to quit")
            other.terminate()
        }
    }
}
