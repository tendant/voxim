//
//  ASRDebugView.swift
//  voxim
//

import SwiftUI

struct ASRDebugView: View {
    @Bindable var model: ASRDebugModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("voxim").font(.headline)
                Spacer()
                Text(model.transcriber.name).font(.caption).foregroundStyle(.secondary)
            }

            status

            Button(action: model.toggleRecording) {
                Label(
                    model.phase == .recording ? "Stop & Transcribe" : "Start Test Recording",
                    systemImage: model.phase == .recording ? "stop.circle.fill" : "mic.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.phase == .preparing || model.phase == .transcribing)

            if !model.transcript.isEmpty {
                Text(model.transcript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Text(String(format: "Audio %.1fs · stop→text %.0f ms", model.clipDuration, model.latency * 1000))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()
            Button("Quit voxim") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .preparing:
            Label("Preparing on-device model…", systemImage: "hourglass")
        case .idle:
            Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .recording:
            Label("Recording", systemImage: "record.circle.fill").foregroundStyle(.red)
        case .transcribing:
            Label("Transcribing…", systemImage: "waveform")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
