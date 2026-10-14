//
//  Metrics.swift
//  voxim
//
//  Local, privacy-preserving usage metrics for dogfooding. One event per push-to-talk;
//  events carry counts and timings only — never transcript, selection or clipboard text.
//  Stored as JSON Lines in Application Support, pruned after 90 days.
//

import Foundation
import Observation
import os

nonisolated struct DictationEvent: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case inserted
        case failed
        case cancelled  // Esc while recording
        case tooShort   // released before the minimum hold
    }

    enum Reason: String, Codable, CaseIterable, Sendable {
        case microphoneDenied
        case accessibilityDenied
        case noInputDevice
        case recognitionFailed
        case nothingRecognized
        case secureInput
        case noFocusedField
        case focusChanged
        case other

        var label: String {
            switch self {
            case .microphoneDenied: "Microphone denied"
            case .accessibilityDenied: "Accessibility denied"
            case .noInputDevice: "No microphone"
            case .recognitionFailed: "Recognition error"
            case .nothingRecognized: "Nothing recognized"
            case .secureInput: "Secure input"
            case .noFocusedField: "No focused field"
            case .focusChanged: "Focus changed"
            case .other: "Other"
            }
        }

        init(_ error: any Error) {
            switch error {
            case InsertionError.accessibilityDenied: self = .accessibilityDenied
            case InsertionError.secureInput: self = .secureInput
            case InsertionError.noFocusedField: self = .noFocusedField
            case InsertionError.focusChanged: self = .focusChanged
            case AudioCaptureError.microphoneDenied: self = .microphoneDenied
            case AudioCaptureError.noInputDevice: self = .noInputDevice
            case is TranscriberError: self = .recognitionFailed
            default: self = .other
            }
        }
    }

    var date: Date
    var outcome: Outcome
    var reason: Reason?
    var engine: String?
    /// Recognized language code ("en", "zh", "yue"); never any text.
    var language: String?
    /// Recorded with double-tap fn (hands-free); nil for hold-to-talk.
    var handsFree: Bool?
    /// Pieces the dictation was split into, and how many came back with no words.
    var pieces: Int?
    var emptyPieces: Int?
    var audioSeconds: Double?
    /// Key release → transcript ready.
    var transcribeMS: Double?
    /// Transcript ready → ⌘V posted (vocabulary, formatting, focus checks).
    var typeMS: Double?
    var words: Int?

    /// Key release → text typed.
    var totalMS: Double? {
        guard let transcribeMS, let typeMS else { return nil }
        return transcribeMS + typeMS
    }
}

nonisolated struct MetricsSummary: Equatable {
    var dictations = 0
    var inserted = 0
    var failures: [DictationEvent.Reason: Int] = [:]
    var cancelled = 0
    var tooShort = 0
    var words = 0
    var audioSeconds = 0.0
    var transcribeP50: Double?
    var transcribeP95: Double?
    var totalP50: Double?
    var totalP95: Double?
    var engines: [String: Int] = [:]
    var languages: [String: Int] = [:]
    var handsFree = 0
    var pieces = 0
    var emptyPieces = 0

    var failed: Int { failures.values.reduce(0, +) }

    /// Share of attempts that reached a focused field; cancels and accidental taps excluded.
    var successRate: Double? {
        let attempts = inserted + failed
        return attempts == 0 ? nil : Double(inserted) / Double(attempts)
    }

    static func summarize(_ events: [DictationEvent], since start: Date? = nil) -> MetricsSummary {
        let events = start.map { start in events.filter { $0.date >= start } } ?? events
        var summary = MetricsSummary()
        var transcribe: [Double] = []
        var total: [Double] = []
        for event in events {
            switch event.outcome {
            case .inserted: summary.inserted += 1
            case .failed: summary.failures[event.reason ?? .other, default: 0] += 1
            case .cancelled: summary.cancelled += 1
            case .tooShort: summary.tooShort += 1
            }
            if event.outcome != .tooShort { summary.dictations += 1 }
            summary.words += event.words ?? 0
            summary.audioSeconds += event.audioSeconds ?? 0
            if let engine = event.engine { summary.engines[engine, default: 0] += 1 }
            if let language = event.language { summary.languages[language, default: 0] += 1 }
            if event.handsFree == true { summary.handsFree += 1 }
            summary.pieces += event.pieces ?? 0
            summary.emptyPieces += event.emptyPieces ?? 0
            if let ms = event.transcribeMS { transcribe.append(ms) }
            if event.outcome == .inserted, let ms = event.totalMS { total.append(ms) }
        }
        summary.transcribeP50 = percentile(transcribe, 0.50)
        summary.transcribeP95 = percentile(transcribe, 0.95)
        summary.totalP50 = percentile(total, 0.50)
        summary.totalP95 = percentile(total, 0.95)
        return summary
    }

    /// Nearest-rank percentile.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

@Observable
final class MetricsStore {
    static let retention: TimeInterval = 90 * 24 * 3600

    static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "voxim", directoryHint: .isDirectory)
            .appending(path: "metrics.jsonl")
    }

    private(set) var events: [DictationEvent] = []
    let fileURL: URL

    init(fileURL: URL = MetricsStore.defaultURL, now: Date = .now) {
        self.fileURL = fileURL
        load(now: now)
    }

    func record(_ event: DictationEvent) {
        events.append(event)
        do {
            var line = try Self.encoder.encode(event)
            line.append(0x0A)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL)
            }
        } catch {
            Log.app.error("metrics write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reset() {
        events = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    func summary(since start: Date? = nil) -> MetricsSummary {
        MetricsSummary.summarize(events, since: start)
    }

    private func load(now: Date) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let cutoff = now.addingTimeInterval(-Self.retention)
        let lines = data.split(separator: 0x0A)
        // Skip unreadable lines (e.g. a write interrupted mid-line) instead of failing the whole file.
        events = lines.compactMap { try? Self.decoder.decode(DictationEvent.self, from: Data($0)) }
        let kept = events.filter { $0.date >= cutoff }
        if kept.count != lines.count {
            events = kept
            rewrite()
        }
    }

    private func rewrite() {
        let body = events.compactMap { try? Self.encoder.encode($0) }
            .map { $0 + Data([0x0A]) }
            .reduce(Data(), +)
        try? body.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
