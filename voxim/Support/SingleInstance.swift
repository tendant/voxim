//
//  SingleInstance.swift
//  voxim
//

import AppKit
import os

/// Two copies (e.g. the installed app and one run from Xcode) would both react to fn and
/// type twice. The most recently launched copy wins: it asks any older one to quit.
enum SingleInstance {
    static func takeOver() {
        let me = NSRunningApplication.current
        guard let bundleID = me.bundleIdentifier else { return }
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where other.processIdentifier != me.processIdentifier {
            Log.app.info("asking older voxim (pid \(other.processIdentifier, privacy: .public)) to quit")
            other.terminate()
        }
    }
}
