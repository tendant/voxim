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
        controller.onHUDContentChange = { [weak hud] in
            // Let SwiftUI lay out the new text first, then re-fit the panel.
            DispatchQueue.main.async { if hud?.isVisible == true { hud?.fitToContent() } }
        }
        let shortcuts = ShortcutManager(onAction: controller.handle)
        shortcuts.isDoubleTapEnabled = { [weak controller] in controller?.isHandsFreeEnabled ?? false }
        controller.onHandsFreeChange = { [weak shortcuts] active in shortcuts?.setHandsFree(active) }
        // The fn shortcut needs an event tap, which needs Accessibility: ask up front, then
        // ShortcutManager keeps retrying until access is granted.
        // Unit tests host inside this app; don't prompt or intercept keys there.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        // `-voximSettingsPreview`: just open Settings, without taking over a running copy,
        // prompting for permissions or listening for fn. Used to check the window by hand.
        if CommandLine.arguments.contains("-voximMenuPreview") {
            // Debug-only: the menu-bar menu's content in a plain window, to check its size.
            DispatchQueue.main.async {
                let hosting = NSHostingView(rootView: MenuView(controller: controller))
                hosting.sizingOptions = [.intrinsicContentSize]
                let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = hosting
                window.setContentSize(hosting.fittingSize)
                window.center()
                window.orderFrontRegardless()
            }
            _controller = State(initialValue: controller)
            self.hud = hud
            self.shortcuts = shortcuts
            return
        }
        if CommandLine.arguments.contains("-voximHUDPreview") {
            controller.onHUDVisibilityChange = { [weak hud] visible in if visible { hud?.show() } }
            DispatchQueue.main.async {
                controller.debugShowPreview("")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    controller.debugShowPreview("Okay so here is what I want to do today. First, open the settings screen and move the vocabulary table into its own tab, because right now it is crowded and hard to read.")
                }
            }
            _controller = State(initialValue: controller)
            self.hud = hud
            self.shortcuts = shortcuts
            return
        }
        if CommandLine.arguments.contains("-voximSettingsPreview") {
            let tab: SettingsTab = switch UserDefaults.standard.string(forKey: "voximSettingsTab") {
            case "usage": .usage
            case "vocabulary": .vocabulary
            default: .general
            }
            DispatchQueue.main.async { SettingsWindow.shared.show(controller, tab: tab) }
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
