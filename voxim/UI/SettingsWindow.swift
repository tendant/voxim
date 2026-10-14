//
//  SettingsWindow.swift
//  voxim
//
//  A self-managed settings window. SwiftUI's `Settings` scene is unreliable in a menu-bar-only
//  (LSUIElement) app: `openSettings()` can silently do nothing or open behind other windows.
//  While this window is open the app becomes a regular app (Dock icon, ⌘-Tab) so it can take
//  focus, then returns to menu-bar-only when it closes.
//

import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case vocabulary
    case usage
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private let selection = SettingsSelection()

    /// Opens (or brings forward) the window; `tab` nil keeps the last-selected tab.
    func show(_ controller: AppController, tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller, selection: selection))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "voxim Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only; no Dock icon once settings are closed.
        NSApp.setActivationPolicy(.accessory)
    }
}

@Observable
final class SettingsSelection {
    var tab: SettingsTab = .general
}

struct SettingsView: View {
    let controller: AppController
    @Bindable var selection: SettingsSelection

    /// Every tab uses this size, so the window doesn't jump when switching tabs.
    static let size = CGSize(width: 520, height: 560)

    var body: some View {
        TabView(selection: $selection.tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView(controller: controller, selection: selection)
            }
            Tab("Vocabulary", systemImage: "character.book.closed", value: SettingsTab.vocabulary) {
                VocabularySettingsView(store: controller.replacements)
            }
            Tab("Usage", systemImage: "chart.bar", value: SettingsTab.usage) {
                UsageView(store: controller.metrics)
            }
        }
        .padding(.top, 8)
    }
}
