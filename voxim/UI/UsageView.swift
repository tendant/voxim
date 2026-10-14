//
//  UsageView.swift
//  voxim
//

import SwiftUI

struct UsageView: View {
    enum Period: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 days"
        case all = "90 days"

        var id: Self { self }

        var start: Date? {
            switch self {
            case .today: Calendar.current.startOfDay(for: .now)
            case .week: Calendar.current.date(byAdding: .day, value: -7, to: .now)
            case .all: nil
            }
        }
    }

    let store: MetricsStore
    @State private var period = Period.week
    @State private var confirmReset = false

    var body: some View {
        let summary = store.summary(since: period.start)
        Form {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Overview") {
                stat("Dictations", "\(summary.dictations)")
                stat("Typed successfully", rate(summary))
                stat("Words", "\(summary.words)")
                stat("Speaking time", String(format: "%.0f s", summary.audioSeconds))
                stat("Hands-free", "\(summary.handsFree)")
                stat("Cancelled (esc)", "\(summary.cancelled)")
                stat("Accidental taps", "\(summary.tooShort)")
            }

            Section("Speed") {
                stat("Release → text typed", latency(summary.totalP50, summary.totalP95))
                stat("Release → transcript", latency(summary.transcribeP50, summary.transcribeP95))
                if summary.pieces > 0 {
                    stat("Pieces with no words", "\(summary.emptyPieces) of \(summary.pieces)")
                }
            }

            if !summary.failures.isEmpty {
                Section("Failures") {
                    ForEach(summary.failures.sorted { $0.value > $1.value }, id: \.key) { reason, count in
                        stat(reason.label, "\(count)")
                    }
                }
            }

            if !summary.languages.isEmpty || summary.engines.count > 1 {
                Section("Languages & engines") {
                    ForEach(summary.languages.sorted { $0.value > $1.value }, id: \.key) { code, count in
                        stat(Self.languageName(code), "\(count)")
                    }
                    if summary.engines.count > 1 {
                        ForEach(summary.engines.sorted { $0.value > $1.value }, id: \.key) { engine, count in
                            stat(engine, "\(count)")
                        }
                    }
                }
            }

            Section {
                HStack {
                    Button("Show Data File") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                        .disabled(store.events.isEmpty)
                    Spacer()
                    Button("Reset…", role: .destructive) { confirmReset = true }
                        .disabled(store.events.isEmpty)
                }
            } header: {
                Text("Your data")
            } footer: {
                Text("Only counts and timings are stored on this Mac — never what you said. Kept for 90 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
        .frame(width: SettingsView.size.width, height: SettingsView.size.height)
        .confirmationDialog("Delete all usage statistics?", isPresented: $confirmReset) {
            Button("Delete", role: .destructive, action: store.reset)
        }
    }

    private static func languageName(_ code: String) -> String {
        switch code {
        case "en": "English"
        case "zh": "中文"
        case "yue": "粵語"
        case "mixed": "Mixed"
        default: code
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private func rate(_ summary: MetricsSummary) -> String {
        guard let rate = summary.successRate else { return "—" }
        return String(format: "%.0f%% (%d of %d)", rate * 100, summary.inserted, summary.inserted + summary.failed)
    }

    private func latency(_ p50: Double?, _ p95: Double?) -> String {
        guard let p50, let p95 else { return "—" }
        return String(format: "p50 %.0f ms · p95 %.0f ms", p50, p95)
    }
}
