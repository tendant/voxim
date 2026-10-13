//
//  SetupSection.swift
//  voxim
//
//  First-run checklist in the menu: permissions and speech model. Re-evaluated every second
//  while the menu is open, since macOS doesn't notify apps when permissions change.
//

import AVFoundation
import SwiftUI

enum MicAccess {
    static var permission: AVAudioApplication.recordPermission { AVAudioApplication.shared.recordPermission }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct SetupSection: View {
    let modelStatus: ModelStatus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                microphone
                accessibility
                model
            }
            .font(.callout)
        }
    }

    @ViewBuilder private var microphone: some View {
        switch MicAccess.permission {
        case .granted:
            row("Microphone", ok: true)
        case .denied:
            row("Microphone", ok: false, detail: "Denied") {
                Button("Open Settings", action: MicAccess.openSettings)
            }
        default:
            row("Microphone", ok: false, detail: "Not yet allowed") {
                Button("Allow…") { Task { _ = await AudioCapture.requestPermission() } }
            }
        }
    }

    @ViewBuilder private var accessibility: some View {
        if AXAccess.isTrusted {
            row("Accessibility", ok: true)
        } else {
            row("Accessibility", ok: false, detail: "Needed for fn and typing") {
                Button("Open Settings", action: AXAccess.openSettings)
            }
        }
    }

    @ViewBuilder private var model: some View {
        switch modelStatus.state {
        case .starting:
            row("Speech model", ok: nil, detail: "Loading…")
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 2) {
                row("Speech model", ok: nil, detail: "Downloading \(Int(fraction * 100))%")
                ProgressView(value: fraction).controlSize(.small)
                Text("One-time ~450 MB download. Apple's built-in speech is used until it finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .compiling:
            row("Speech model", ok: nil, detail: "Preparing…")
        case .ready:
            row("Speech model", ok: true)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                row("Speech model", ok: false, detail: "Using Apple speech")
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func row(_ title: String, ok: Bool?, detail: String? = nil) -> some View {
        row(title, ok: ok, detail: detail) { EmptyView() }
    }

    private func row<Action: View>(
        _ title: String, ok: Bool?, detail: String? = nil, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 6) {
            switch ok {
            case true?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case false?: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case nil: ProgressView().controlSize(.mini)
            }
            Text(title)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
            action()
        }
    }
}
