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
        hosting.sizingOptions = [.preferredContentSize]
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let size = contentView?.fittingSize ?? self.frame.size
            setFrame(
                NSRect(x: frame.midX - size.width / 2, y: frame.minY + 120, width: size.width, height: size.height),
                display: true
            )
        }
        orderFrontRegardless()
    }
}

struct HUDView: View {
    @Bindable var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch controller.phase {
            case .recording:
                HStack {
                    Label("Listening…", systemImage: "mic.fill")
                        .foregroundStyle(.red)
                    Spacer()
                    Text("release fn to type · esc to cancel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        Button("Open Settings", action: AXAccess.openSettings)
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
        .frame(width: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
