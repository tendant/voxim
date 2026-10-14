//
//  MenuView.swift
//  voxim
//

import SwiftUI

struct MenuView: View {
    @Bindable var controller: AppController
    /// The menu-bar panel hosting this view. It only auto-closes when voxim deactivates, so
    /// opening voxim's own Settings window must close it explicitly.
    @State private var menuWindow: NSWindow?

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

            // Setup only appears while something needs attention (re-checked every second).
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if SetupSection.needsAttention(controller.modelStatus, chinese: chineseStatus) {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        SetupSection(modelStatus: controller.modelStatus, chineseModelStatus: chineseStatus)
                    }
                }
            }

            Divider()
            Picker("Language", selection: $controller.languageMode) {
                ForEach(LanguageMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Hold fn to dictate · double-tap fn for hands-free")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            HStack {
                Button {
                    openSettings()
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
        .background(WindowReader { window in
            if menuWindow !== window { menuWindow = window }
        })
    }

    private var chineseStatus: ModelStatus? {
        controller.languageMode.needsChineseModel ? controller.chineseModelStatus : nil
    }

    private func openSettings(tab: SettingsTab? = nil) {
        menuWindow?.close()
        SettingsWindow.shared.show(controller, tab: tab)
    }

    private var typedStatus: String {
        switch controller.lastLanguage {
        case "zh": "Typed into the focused field · 中文"
        case "yue": "Typed into the focused field · 粵語"
        case "mixed": "Typed into the focused field · 中文 + English"
        case "en" where controller.languageMode != .english: "Typed into the focused field · English"
        default: "Typed into the focused field"
        }
    }

    private var todaySummary: String {
        let today = controller.metrics.summary(since: Calendar.current.startOfDay(for: .now))
        guard today.dictations > 0 else { return "No dictations today" }
        var parts = ["Today: \(today.dictations) dictation\(today.dictations == 1 ? "" : "s")", "\(today.words) words"]
        if let p50 = today.totalP50 { parts.append(String(format: "typical %.0f ms", p50)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        switch controller.phase {
        case .idle:
            Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .recording:
            Label(controller.isHandsFree ? "Recording (hands-free)" : "Recording",
                  systemImage: controller.isHandsFree ? "lock.fill" : "record.circle.fill").foregroundStyle(.red)
        case .transcribing:
            Label("Transcribing…", systemImage: "waveform")
        case .inserted:
            Label(typedStatus, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// Reports the NSWindow hosting a SwiftUI view, once it's attached (no per-render updates).
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}
}
