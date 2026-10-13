//
//  MenuView.swift
//  voxim
//

import SwiftUI

struct MenuView: View {
    @Bindable var controller: AppController
    @AppStorage(AppController.smartFormattingKey) private var smartFormatting = true
    @Environment(\.openSettings) private var openSettings

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
            HStack {
                Text(vocabularySummary).font(.callout)
                Spacer()
                Button("Vocabulary…") {
                    // Menu-bar apps must activate first, or the window opens behind others.
                    NSApplication.shared.activate()
                    openSettings()
                }
            }
            if let action = GlobeKeySetting.conflictingAction {
                Text("Your 🌐 key is set to “\(action)”, which also fires when you release fn. Set System Settings › Keyboard › “Press 🌐 key to” to Do Nothing.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button("Quit voxim") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 320)
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
