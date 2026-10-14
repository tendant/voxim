//
//  MetricsTests.swift
//  voximTests
//

import Foundation
import Testing
@testable import voxim

@MainActor
struct MetricsTests {
    let fileURL = FileManager.default.temporaryDirectory
        .appending(path: "voxim-metrics-\(UUID().uuidString)")
        .appending(path: "metrics.jsonl")
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func inserted(_ transcribe: Double, _ type: Double, words: Int = 5, at date: Date? = nil) -> DictationEvent {
        DictationEvent(date: date ?? now, outcome: .inserted, engine: "Parakeet TDT v2",
                       audioSeconds: 2, transcribeMS: transcribe, typeMS: type, words: words)
    }

    @Test func summarizesOutcomesAndExcludesTapsFromDictations() {
        let events = [
            inserted(40, 10), inserted(60, 20),
            DictationEvent(date: now, outcome: .failed, reason: .focusChanged, audioSeconds: 1, transcribeMS: 50),
            DictationEvent(date: now, outcome: .failed, reason: .microphoneDenied),
            DictationEvent(date: now, outcome: .cancelled, audioSeconds: 1),
            DictationEvent(date: now, outcome: .tooShort, audioSeconds: 0.1),
        ]
        let s = MetricsSummary.summarize(events)
        #expect(s.dictations == 5)
        #expect(s.inserted == 2)
        #expect(s.failures == [.focusChanged: 1, .microphoneDenied: 1])
        #expect(s.cancelled == 1)
        #expect(s.tooShort == 1)
        #expect(s.successRate == 0.5)
        #expect(s.words == 10)
        #expect(s.totalP50 == 50)   // totals 50, 80
        #expect(s.totalP95 == 80)
        #expect(s.transcribeP50 == 50) // 40, 60, 50
    }

    @Test func periodFilter() {
        let old = inserted(40, 10, at: now.addingTimeInterval(-3 * 86_400))
        let s = MetricsSummary.summarize([old, inserted(40, 10)], since: now.addingTimeInterval(-86_400))
        #expect(s.dictations == 1)
    }

    @Test func nearestRankPercentile() {
        let values = (1...100).map(Double.init)
        #expect(MetricsSummary.percentile(values, 0.5) == 50)
        #expect(MetricsSummary.percentile(values, 0.95) == 95)
        #expect(MetricsSummary.percentile([7], 0.95) == 7)
        #expect(MetricsSummary.percentile([], 0.5) == nil)
    }

    @Test func persistsAcrossLaunches() {
        let store = MetricsStore(fileURL: fileURL, now: now)
        store.record(inserted(40, 10))
        store.record(DictationEvent(date: now, outcome: .cancelled))
        let reloaded = MetricsStore(fileURL: fileURL, now: now)
        #expect(reloaded.events == store.events)
    }

    @Test func prunesEventsOlderThanRetentionAndSkipsCorruptLines() throws {
        let store = MetricsStore(fileURL: fileURL, now: now)
        store.record(inserted(40, 10, at: now.addingTimeInterval(-100 * 86_400)))
        store.record(inserted(40, 10))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"date\":\"trunc".utf8))
        try handle.close()

        let reloaded = MetricsStore(fileURL: fileURL, now: now)
        #expect(reloaded.events.count == 1)
        // The pruned file holds exactly the surviving event.
        let lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
    }

    @Test func resetDeletesData() {
        let store = MetricsStore(fileURL: fileURL, now: now)
        store.record(inserted(40, 10))
        store.reset()
        #expect(store.events.isEmpty)
        #expect(MetricsStore(fileURL: fileURL, now: now).events.isEmpty)
    }

    @Test func storedRecordHasNoTextFields() throws {
        // Guard against someone adding transcript/selection text to the event later.
        let store = MetricsStore(fileURL: fileURL, now: now)
        store.record(DictationEvent(date: now, outcome: .failed, reason: .secureInput, engine: "Apple SpeechTranscriber",
                                    language: "zh", handsFree: true, pieces: 2, emptyPieces: 1,
                                    audioSeconds: 1, transcribeMS: 1, typeMS: 1, words: 3))
        let line = try Data(contentsOf: fileURL)
        let keys = Set(try #require(JSONSerialization.jsonObject(with: line) as? [String: Any]).keys)
        #expect(keys == ["date", "outcome", "reason", "engine", "language", "handsFree", "pieces", "emptyPieces",
                         "audioSeconds", "transcribeMS", "typeMS", "words"])
    }

    @Test func errorsMapToReasons() {
        #expect(DictationEvent.Reason(InsertionError.secureInput) == .secureInput)
        #expect(DictationEvent.Reason(InsertionError.focusChanged(from: "A", to: "B")) == .focusChanged)
        #expect(DictationEvent.Reason(AudioCaptureError.microphoneDenied) == .microphoneDenied)
        #expect(DictationEvent.Reason(TranscriberError.emptyAudio) == .recognitionFailed)
        #expect(DictationEvent.Reason(CocoaError(.fileNoSuchFile)) == .other)
    }
}
