//
//  DictationEngine.swift
//  voxim
//
//  Picks the speech engine per utterance from the user's language mode:
//    English  → Parakeet (Apple en fallback), as before.
//    Auto     → SenseVoice language ID; English without CJK goes to Parakeet, else SenseVoice text.
//    Chinese  → SenseVoice forced to zh (Apple zh_CN while SenseVoice downloads).
//

import Foundation
import os

enum LanguageMode: String, CaseIterable, Identifiable, Sendable {
    case english
    case auto
    case chinese

    var id: Self { self }

    var label: String {
        switch self {
        case .english: "English"
        case .auto: "Auto (EN + 中文)"
        case .chinese: "中文"
        }
    }

    var needsChineseModel: Bool { self != .english }
}

nonisolated struct Transcript: Equatable, Sendable {
    var text: String
    /// Language code of what was recognized ("en", "zh", "yue"); nil if unknown.
    var language: String?
    var engine: String
}

/// Pure routing rule for Auto mode, given SenseVoice's output.
nonisolated enum LanguageRouting {
    enum Route: Equatable { case chinese, english, nothing }

    /// Below this length a piece's own language tag isn't trusted over the dictation's language.
    static let decisiveSeconds: TimeInterval = 4

    /// - Parameters:
    ///   - hint: the language this dictation has settled on so far ("en", "zh", "yue"), if any.
    ///   - seconds: length of the audio, to judge how much the tag can be trusted.
    static func route(language: String?, text: String, hint: String? = nil, seconds: TimeInterval = .infinity) -> Route {
        if language == "nospeech" { return .nothing }
        // Chinese characters are decisive (also catches ja/ko misdetections of Mandarin).
        if ChineseText.containsCJK(text) { return .chinese }
        let short = seconds < decisiveSeconds
        switch hint {
        case "zh", "yue":
            // A short English-sounding stretch inside a Chinese dictation is usually an English
            // term; SenseVoice transcribes those well, so don't hop engines.
            if short { return .chinese }
        case "en":
            // A short stretch tagged Chinese but with no Chinese text stays English.
            if short { return .english }
        default:
            break
        }
        return language == "zh" || language == "yue" ? .chinese : .english
    }
}

protocol SpeechEngine: AnyObject, Sendable {
    func prepareEnglish() async throws
    /// Resolves when the English primary engine (Parakeet) has loaded; returns its error, if any.
    func waitForEnglishPrimary() async -> (any Error)?
    /// Starts loading the Chinese engine if needed; resolves when ready (returns its error, if any).
    func prepareChinese() async -> (any Error)?
    func englishEngineName() async -> String
    /// - Parameter languageHint: in Auto mode, the language this dictation has settled on, so
    ///   short pieces don't flip between engines.
    func transcribe(_ clip: AudioClip, mode: LanguageMode, languageHint: String?) async throws -> Transcript
}

extension SpeechEngine {
    func transcribe(_ clip: AudioClip, mode: LanguageMode) async throws -> Transcript {
        try await transcribe(clip, mode: mode, languageHint: nil)
    }
}

actor DictationEngine: SpeechEngine {
    private let english: FallbackTranscriber
    private let senseVoice: SenseVoiceTranscriber
    private let appleChinese: AppleSpeechTranscriber
    private var chineseLoad: Task<(any Error)?, Never>?

    init(english: FallbackTranscriber, senseVoice: SenseVoiceTranscriber) {
        self.english = english
        self.senseVoice = senseVoice
        self.appleChinese = AppleSpeechTranscriber(locale: Locale(identifier: "zh_CN"))
    }

    func prepareEnglish() async throws {
        try await english.prepare()
    }

    func waitForEnglishPrimary() async -> (any Error)? {
        await english.waitForPrimary()
    }

    func prepareChinese() async -> (any Error)? {
        if chineseLoad == nil {
            let senseVoice = self.senseVoice
            let apple = self.appleChinese
            chineseLoad = Task {
                // Apple zh_CN is installed with the OS and covers 中文 mode while SenseVoice downloads.
                try? await apple.prepare()
                do {
                    try await senseVoice.prepare()
                    return nil
                } catch {
                    Log.asr.error("SenseVoice failed to load: \(error.localizedDescription, privacy: .public)")
                    return error
                }
            }
        }
        return await chineseLoad!.value
    }

    func englishEngineName() async -> String {
        await english.activeName
    }

    func transcribe(_ clip: AudioClip, mode: LanguageMode, languageHint: String?) async throws -> Transcript {
        let senseVoiceReady = await senseVoice.isReady
        switch mode {
        case .english:
            return try await transcribeEnglish(clip)

        case .auto:
            // Until SenseVoice is downloaded, Auto behaves as English.
            guard senseVoiceReady else { return try await transcribeEnglish(clip) }
            let result = try await senseVoice.transcribe(clip, forceChinese: false)
            switch LanguageRouting.route(language: result.language, text: result.text,
                                         hint: languageHint, seconds: clip.duration) {
            case .nothing: return Transcript(text: "", language: nil, engine: senseVoice.name)
            case .english:
                if languageHint == "zh" || languageHint == "yue" {
                    // Leaving a Chinese dictation needs proof: if forcing Chinese still yields Chinese
                    // characters, it's Chinese with English terms that SenseVoice mis-tagged.
                    let chinese = try await senseVoice.transcribe(clip, forceChinese: true)
                    if ChineseText.containsCJK(chinese.text) {
                        return Transcript(text: chinese.text, language: "zh", engine: senseVoice.name)
                    }
                }
                return try await transcribeEnglish(clip)
            case .chinese:
                if result.language == "zh" || result.language == "yue" {
                    return Transcript(text: result.text, language: result.language, engine: senseVoice.name)
                }
                // Routed to Chinese against SenseVoice's own tag (e.g. a short "跑一下 tests" it heard
                // as English): its auto transcript is then English-ish gibberish, so redo it in Chinese.
                let chinese = try await senseVoice.transcribe(clip, forceChinese: true)
                return Transcript(text: chinese.text, language: "zh", engine: senseVoice.name)
            }

        case .chinese:
            if senseVoiceReady {
                let result = try await senseVoice.transcribe(clip, forceChinese: true)
                return Transcript(text: result.text, language: "zh", engine: senseVoice.name)
            }
            let text = try await appleChinese.transcribe(clip)
            return Transcript(text: text, language: "zh", engine: "Apple 中文")
        }
    }

    private func transcribeEnglish(_ clip: AudioClip) async throws -> Transcript {
        let text = try await english.transcribe(clip)
        return Transcript(text: text, language: "en", engine: await english.activeName)
    }
}
