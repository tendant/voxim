//
//  LoginItem.swift
//  voxim
//

import Foundation
import os
import ServiceManagement

/// "Launch at login" via SMAppService. Registration is tied to this app's bundle, so it
/// only makes sense for the installed copy in /Applications, not a build run from Xcode.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The user turned it off in System Settings › General › Login Items after voxim enabled it.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static var isInstalledCopy: Bool { Bundle.main.bundleURL.path.hasPrefix("/Applications/") }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("login item update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
