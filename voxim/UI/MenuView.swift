//
//  MenuView.swift
//  voxim
//

import SwiftUI

struct MenuView: View {
    @Bindable var controller: AppController
    @AppStorage(AppController.smartFormattingKey) private var smartFormatting = true
    @AppStorage(AppController.preRollKey) private var preRoll = true
    @State private var launchAtLoginEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("voxim").font(.headline)
                Spacer()
                Text(controller.activeEngine).font(.caption).foregroundStyle(.secondary)
            }
            status
            Text(todaySummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)


            Divider()
            SetupSection(modelStatus: controller.modelStatus)

            Divider()
            HStack {
                Text("Hold to dictate")
                Spacer()
                Text(ShortcutManager.displayName)
                    .font(.body.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            Text("Hold fn until the HUD appears, speak, then release. Text is typed where your cursor is; voxim never presses Return.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $smartFormatting) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart formatting")
                    Text("Adds a space and lowercases mid-sentence; terminal style (no trailing period, lowercase start) in terminal apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Toggle(isOn: $preRoll) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture from fn press")
                    Text("Starts the mic as soon as fn goes down so the first word isn't cut off. The mic indicator then flashes on every fn press, and Bluetooth headsets may briefly switch to call quality.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            HStack {
                Text(vocabularySummary).font(.callout)
                Spacer()
                Button("Edit…") { SettingsWindow.shared.show(controller, tab: .vocabulary) }
            }
            if let action = GlobeKeySetting.conflictingAction {
                Text("Your 🌐 key is set to “\(action)”, which also fires when you release fn. Set System Settings › Keyboard › “Press 🌐 key to” to Do Nothing.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            launchAtLogin
            HStack {
                Button {
                    SettingsWindow.shared.show(controller)
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                Spacer()
                Button("Quit voxim") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder private var launchAtLogin: some View {
        if LoginItem.isInstalledCopy {
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { enabled in
                    LoginItem.setEnabled(enabled)
                    launchAtLoginEnabled = LoginItem.isEnabled
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .onAppear { launchAtLoginEnabled = LoginItem.isEnabled }
            if LoginItem.needsApproval {
                Button("Allow in Login Items settings…") { LoginItem.openSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } else {
            Text("Launch at login is available once voxim is installed in /Applications (scripts/install.sh).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var todaySummary: String {
        let today = controller.metrics.summary(since: Calendar.current.startOfDay(for: .now))
        guard today.dictations > 0 else { return "No dictations today" }
        var parts = ["Today: \(today.dictations) dictation\(today.dictations == 1 ? "" : "s")", "\(today.words) words"]
        if let p50 = today.totalP50 { parts.append(String(format: "typical %.0f ms", p50)) }
        return parts.joined(separator: " · ")
    }

    private var vocabularySummary: String {
        switch controller.replacements.rules.count {
        case 0: "No custom words"
        case 1: "1 custom word"
        case let n: "\(n) custom words"
        }
    }

    @ViewBuilder private var status: some View {
        switch controller.phase {
        case .idle:
            Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .recording:
            Label("Recording", systemImage: "record.circle.fill").foregroundStyle(.red)
        case .transcribing:
            Label("Transcribing…", systemImage: "waveform")
        case .inserted:
            Label("Typed into the focused field", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
