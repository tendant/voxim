//
//  voximApp.swift
//  voxim
//
//  Created by Lei Wang on 10/12/26.
//

import SwiftUI

@main
struct voximApp: App {
    @State private var controller: AppController
    private let hud: StatusHUD
    private let shortcuts: ShortcutManager

    init() {
        let controller = AppController()
        let hud = StatusHUD(controller: controller)
        controller.onHUDVisibilityChange = { [weak hud] visible in
            if visible { hud?.show() } else { hud?.orderOut(nil) }
        }
        let shortcuts = ShortcutManager(onAction: controller.handle)
        // The fn shortcut needs an event tap, which needs Accessibility: ask up front, then
        // ShortcutManager keeps retrying until access is granted.
        // Unit tests host inside this app; don't prompt or intercept keys there.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        // `-voximSettingsPreview`: just open Settings, without taking over a running copy,
        // prompting for permissions or listening for fn. Used to check the window by hand.
        if CommandLine.arguments.contains("-voximSettingsPreview") {
            DispatchQueue.main.async { SettingsWindow.shared.show(controller) }
            _controller = State(initialValue: controller)
            self.hud = hud
            self.shortcuts = shortcuts
            return
        }
        #endif
        if !isTestHost {
            SingleInstance.takeOver()
            if !AXAccess.isTrusted { AXAccess.requestTrust() }
            shortcuts.start()
        }
        _controller = State(initialValue: controller)
        self.hud = hud
        self.shortcuts = shortcuts
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbol: String {
        switch controller.phase {
        case .recording: "mic.fill"
        case .failed: "mic.badge.xmark"
        default: "mic"
        }
    }
}
