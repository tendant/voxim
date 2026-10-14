//
//  TextFormatter.swift
//  voxim
//
//  Adapts a raw transcript to where it will be typed. Pure and conservative: when the
//  context is unknown, the transcript is only trimmed.
//

import Foundation

nonisolated struct InsertionContext: Equatable, Sendable {
    /// A few characters immediately before the cursor; "" at the start of a field; nil if unreadable.
    var precedingText: String?
    /// The focused app is a terminal emulator.
    var isTerminal: Bool

    static let unknown = InsertionContext(precedingText: nil, isTerminal: false)
}

nonisolated enum TextFormatter {
    /// No space is added after these (opening brackets/quotes, path and handle prefixes).
    private static let noSpaceAfter: Set<Character> = ["(", "[", "{", "<", "\"", "'", "`", "/", "@", "#", "-", "_", "$", "~"]
    /// Text after these starts a new sentence, so capitalization is kept.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", ":", "。", "！", "？", "："]
    /// First words that stay capitalized mid-sentence.
    private static let alwaysCapitalized: Set<String> = ["I", "I'm", "I'll", "I've", "I'd"]

    /// - Parameter spaceBetweenCJKAndLatin: whether Chinese and English text get a space between
    ///   them ("用 npm 安装"); applied at the boundary with the preceding text too.
    static func format(_ raw: String, context: InsertionContext, spaceBetweenCJKAndLatin: Bool = true) -> String {
        var text = raw.split(whereSeparator: { $0 == " " }).joined(separator: " ").trimmed
        guard !text.isEmpty else { return text }

        let preceding = context.precedingText
        let lastVisible = preceding?.last { !$0.isWhitespace }
        let midSentence = lastVisible.map { !sentenceEnders.contains($0) } ?? false
        // After Chinese, an English word is a term ("用 React"), not a sentence continuation.
        let afterChinese = lastVisible.map { ChineseText.isCJK($0) || ChineseText.isCJKPunctuation($0) } ?? false

        if context.isTerminal {
            text = droppingTrailingPeriod(text)
            text = lowercasingFirstWord(text)
        } else if midSentence && !afterChinese {
            text = lowercasingFirstWord(text)
        }

        if let last = preceding?.last, let first = text.first, needsLeadingSpace(after: last, before: first, spaceBetweenCJKAndLatin) {
            text = " " + text
        }
        return text
    }

    private static func needsLeadingSpace(after last: Character, before first: Character, _ spaceBetweenCJKAndLatin: Bool) -> Bool {
        if last.isWhitespace || noSpaceAfter.contains(last) { return false }
        // Chinese punctuation is full-width and carries its own spacing.
        if ChineseText.isCJKPunctuation(last) || ChineseText.isCJKPunctuation(first) { return false }
        let lastIsCJK = ChineseText.isCJK(last), firstIsCJK = ChineseText.isCJK(first)
        if lastIsCJK && firstIsCJK { return false }  // Chinese runs together
        if lastIsCJK || firstIsCJK { return spaceBetweenCJKAndLatin }
        return true
    }

    /// "Git status." → "Git status", "构建失败了。" → "构建失败了"; keeps "…", "etc..", "?" and "!".
    static func droppingTrailingPeriod(_ text: String) -> String {
        if text.hasSuffix("。") { return String(text.dropLast()) }
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        return String(text.dropLast())
    }

    /// Lowercases the first word only if it looks like an ordinary capitalized word
    /// ("The" → "the"), leaving "I", acronyms ("API") and mixed case ("iPhone", "McDonald") alone.
    static func lowercasingFirstWord(_ text: String) -> String {
        let firstWord = text.prefix { !$0.isWhitespace && $0 != "," && $0 != "." }
        guard let first = firstWord.first, first.isUppercase,
              !alwaysCapitalized.contains(String(firstWord)),
              firstWord.dropFirst().allSatisfy({ !$0.isUppercase })
        else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
