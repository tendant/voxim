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
    private static let sentenceEnders: Set<Character> = [".", "!", "?", ":"]
    /// First words that stay capitalized mid-sentence.
    private static let alwaysCapitalized: Set<String> = ["I", "I'm", "I'll", "I've", "I'd"]

    static func format(_ raw: String, context: InsertionContext) -> String {
        var text = raw.split(whereSeparator: { $0 == " " }).joined(separator: " ").trimmed
        guard !text.isEmpty else { return text }

        let preceding = context.precedingText
        let lastVisible = preceding?.last { !$0.isWhitespace }
        let midSentence = lastVisible.map { !sentenceEnders.contains($0) } ?? false

        if context.isTerminal {
            text = droppingTrailingPeriod(text)
            text = lowercasingFirstWord(text)
        } else if midSentence {
            text = lowercasingFirstWord(text)
        }

        if let last = preceding?.last, !last.isWhitespace, !noSpaceAfter.contains(last) {
            text = " " + text
        }
        return text
    }

    /// "Git status." → "Git status"; keeps "…", "etc..", "?" and "!".
    static func droppingTrailingPeriod(_ text: String) -> String {
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
