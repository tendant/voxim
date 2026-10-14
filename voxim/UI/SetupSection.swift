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

extension SetupSection {
    /// Something the user must act on (or is waiting for): the menu shows the checklist then.
    static func needsAttention(_ model: ModelStatus, chinese: ModelStatus?) -> Bool {
        MicAccess.permission != .granted || !AXAccess.isTrusted || GlobeKeySetting.conflictingAction != nil
            || model.state != .ready || (chinese.map { $0.state != .ready } ?? false)
    }
}

struct SetupSection: View {
    let modelStatus: ModelStatus
    /// Shown only when the language mode needs the Chinese model.
    var chineseModelStatus: ModelStatus? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 6) {
                microphone
                accessibility
                globeKey
                model(modelStatus, title: "Speech model", size: "~450 MB", fallback: "Apple's built-in speech")
                if let chineseModelStatus {
                    model(chineseModelStatus, title: "Chinese model", size: "~450 MB", fallback: "English (Auto) or Apple 中文")
                }
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
                Button("Open Settings") { MicAccess.openSettings() }
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
                Button("Open Settings") { AXAccess.openSettings() }
            }
        }
    }

    /// macOS's own 🌐/fn action must be off, or it runs alongside voxim (Apple Dictation types too).
    @ViewBuilder private var globeKey: some View {
        if let action = GlobeKeySetting.conflictingAction {
            VStack(alignment: .leading, spacing: 2) {
                row("🌐 key", ok: false, detail: action) {
                    Button("Open Settings") { GlobeKeySetting.openKeyboardSettings() }
                }
                Text(action == "Start Dictation"
                     ? "Apple Dictation would also type what you say. Set “Press 🌐 key to” to Do Nothing."
                     : "This also fires when you release fn. Set “Press 🌐 key to” to Do Nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            row("🌐 key", ok: true)
        }
    }

    @ViewBuilder private func model(_ status: ModelStatus, title: String, size: String, fallback: String) -> some View {
        switch status.state {
        case .starting:
            row(title, ok: nil, detail: "Loading…")
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 2) {
                row(title, ok: nil, detail: "Downloading \(Int(fraction * 100))%")
                ProgressView(value: fraction).controlSize(.small)
                Text("One-time \(size) download. \(fallback) is used until it finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .compiling:
            row(title, ok: nil, detail: "Preparing…")
        case .ready:
            row(title, ok: true)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                row(title, ok: false, detail: "Using \(fallback)")
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
