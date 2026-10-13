//
//  MenuView.swift
//  voxim
//

import SwiftUI

struct MenuView: View {
    @Bindable var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("voxim").font(.headline)
                Spacer()
                Text(controller.activeEngine).font(.caption).foregroundStyle(.secondary)
            }
            status


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
