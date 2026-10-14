//
//  StatusHUD.swift
//  voxim
//
//  Small floating indicator. It never becomes key, so keyboard focus stays in the
//  app being dictated into.
//

import AppKit
import SwiftUI

final class StatusHUD: NSPanel {
    init(controller: AppController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 60),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: HUDView(controller: controller))
        // Intrinsic size, so `fittingSize` follows the content (live-preview text, error details).
        // `.preferredContentSize` alone reports 0×0 and the panel never grows.
        hosting.sizingOptions = [.intrinsicContentSize]
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        fitToContent()
        orderFrontRegardless()
    }

    /// Sizes the panel to its content, centered horizontally and anchored near the bottom of
    /// the screen, so it grows upward as live-preview text is added.
    func fitToContent() {
        guard let screen = NSScreen.main else { return }
        contentView?.layoutSubtreeIfNeeded()
        let visible = screen.visibleFrame
        let size = contentView?.fittingSize ?? frame.size
        setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.minY + 120, width: size.width, height: size.height),
            display: true
        )
    }
}

struct HUDView: View {
    @Bindable var controller: AppController

    private var isCompact: Bool {
        controller.phase == .recording && controller.isHandsFree && controller.isListeningIdle
            && controller.livePreview.isEmpty && controller.typingPausedFor == nil
    }

    /// Hands-free with nobody speaking: a small but always-visible "mic is on" indicator.
    private var idlePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").foregroundStyle(.red)
            Text("Hands-free · listening")
            if let started = controller.recordingStartedAt {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(Duration.seconds(context.date.timeIntervalSince(started))
                        .formatted(.time(pattern: .minuteSecond)))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption.monospacedDigit())
    }

    /// Locked recording: unmistakable mic state, elapsed time, how to stop, and the cap countdown.
    private var handsFreeHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Hands-free", systemImage: "lock.fill")
                    .foregroundStyle(.red)
                if let started = controller.recordingStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Duration.seconds(context.date.timeIntervalSince(started))
                            .formatted(.time(pattern: .minuteSecond)))
                            .monospacedDigit()
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                Text("tap fn to finish · esc to cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notice = controller.handsFreeNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch controller.phase {
            case .recording where isCompact:
                idlePill
            case .recording:
                if controller.isHandsFree {
                    handsFreeHeader
                } else {
                    HStack {
                        Label("Listening…", systemImage: "mic.fill")
                            .foregroundStyle(.red)
                        Spacer()
                        Text("release fn to type · esc to cancel")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let app = controller.typingPausedFor {
                    Label("Paused — return to \(app) to keep typing", systemImage: "pause.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if GlobeKeySetting.startsAppleDictation {
                    Label("Apple Dictation is also listening, so text may appear twice. Set Keyboard › “Press 🌐 key to” to Do Nothing.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !controller.livePreview.isEmpty {
                    // Show the end of long dictations: that's where new words appear.
                    Text(controller.livePreview)
                        .lineLimit(3)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(nil, value: controller.livePreview)
                }
            case .transcribing:
                Label("Transcribing…", systemImage: "waveform")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if !controller.undelivered.isEmpty {
                    Text(controller.undelivered)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    if controller.phase == .failed(InsertionError.accessibilityDenied.localizedDescription) {
                        Button("Open Settings") { AXAccess.openSettings() }
                    }
                    Spacer()
                    if !controller.undelivered.isEmpty {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(controller.undelivered, forType: .string)
                            controller.dismiss()
                        }
                    }
                    Button("Dismiss", action: controller.dismiss)
                }
            case .idle, .inserted:
                EmptyView()
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: isCompact ? nil : 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
