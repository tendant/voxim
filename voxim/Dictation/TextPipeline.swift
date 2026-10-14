//
//  TextPipeline.swift
//  voxim
//
//  Transcript → text to type: vocabulary rules, Chinese script and spacing, then
//  context-aware formatting. Built from one dictation's settings snapshot.
//

import Foundation

nonisolated struct TextPipeline: Sendable {
    let rules: [Replacement]
    let preferences: Preferences

    /// Vocabulary rules, Chinese script and Chinese/English spacing. Shared by the live preview
    /// and the typed text so both read the same.
    func applyRules(_ text: String) -> String {
        var result = ReplacementEngine.apply(rules, to: text)
        if ChineseText.containsCJK(result) {
            result = ChineseText.converting(result, to: preferences.chineseScript)
            if preferences.cjkSpacing { result = ChineseText.spacingCJKAndLatin(result) }
        }
        return result
    }

    /// The whole transcript, typed once into the field described by `context`.
    func forTyping(_ text: String, context: InsertionContext) -> String {
        let result = applyRules(text)
        guard preferences.smartFormatting else { return result.trimmed }
        return TextFormatter.format(result, context: context, spaceBetweenCJKAndLatin: preferences.cjkSpacing)
    }

    /// One committed piece, continuing from what this dictation already typed. The first piece
    /// sees the real field (`context`, read by the caller); later ones continue from the text just typed.
    func piece(_ text: String, after typedSoFar: String, context: InsertionContext) -> String {
        let ruled = applyRules(text).trimmed
        guard !ruled.isEmpty else { return "" }
        guard preferences.smartFormatting else {
            return String(ChineseText.join(typedSoFar, ruled).dropFirst(typedSoFar.count))
        }
        let pieceContext = typedSoFar.isEmpty
            ? context
            : InsertionContext(precedingText: String(typedSoFar.suffix(3)), isTerminal: false)
        return TextFormatter.format(ruled, context: pieceContext, spaceBetweenCJKAndLatin: preferences.cjkSpacing)
    }
}
