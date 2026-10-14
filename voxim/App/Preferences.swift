//
//  Preferences.swift
//  voxim
//
//  Every user setting in one typed value, read from UserDefaults. A dictation takes one
//  snapshot when it starts, so changing a setting mid-dictation can't change it halfway.
//

import Foundation

nonisolated struct Preferences: Equatable, Sendable {
    /// UserDefaults keys (also used by `@AppStorage` in the settings UI).
    enum Key {
        static let smartFormatting = "smartFormatting"
        static let preRoll = "preRoll"
        static let languageMode = "languageMode"
        static let chineseScript = "chineseScript"
        static let cjkSpacing = "cjkLatinSpacing"
        static let livePreview = "livePreview"
        static let typeAsYouSpeak = "typeAsYouSpeak"
        static let handsFree = "handsFree"
        static let handsFreeSilence = "handsFreeSilence"
        static let handsFreeMaximum = "handsFreeMaximum"
    }

    static let defaultHandsFreeSilence: TimeInterval = 300
    static let defaultHandsFreeMaximum: TimeInterval = 3600

    /// Context-aware cleanup: spacing, mid-sentence case, terminal style.
    var smartFormatting = true
    /// Start the microphone when fn goes down, not when the hold qualifies.
    var preRoll = true
    /// Show what's been recognized so far while recording.
    var livePreview = true
    /// Type each sentence as soon as it's finished.
    var typeAsYouSpeak = true
    /// Double-tap fn locks recording on.
    var handsFree = true
    var chineseScript = ChineseScript.simplified
    /// Space between Chinese and English ("用 npm 安装").
    var cjkSpacing = true
    /// Hands-free auto-finish after this much silence, and maximum length (`.infinity` = never).
    var handsFreeSilence: TimeInterval = defaultHandsFreeSilence
    var handsFreeMaximum: TimeInterval = defaultHandsFreeMaximum

    init() {}

    init(_ defaults: UserDefaults) {
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        // Stored as seconds; 0 means "never".
        func limit(_ key: String, _ fallback: TimeInterval) -> TimeInterval {
            let value = defaults.object(forKey: key) as? Double ?? fallback
            return value > 0 ? value : .infinity
        }
        smartFormatting = bool(Key.smartFormatting, true)
        preRoll = bool(Key.preRoll, true)
        livePreview = bool(Key.livePreview, true)
        typeAsYouSpeak = bool(Key.typeAsYouSpeak, true)
        handsFree = bool(Key.handsFree, true)
        chineseScript = ChineseScript(rawValue: defaults.string(forKey: Key.chineseScript) ?? "") ?? .simplified
        cjkSpacing = bool(Key.cjkSpacing, true)
        handsFreeSilence = limit(Key.handsFreeSilence, Self.defaultHandsFreeSilence)
        handsFreeMaximum = limit(Key.handsFreeMaximum, Self.defaultHandsFreeMaximum)
    }
}
