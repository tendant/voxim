//
//  ChineseText.swift
//  voxim
//
//  Chinese-aware text helpers: CJK detection, spacing between Chinese and Latin text,
//  Simplified ↔ Traditional output, and word counting for metrics.
//

import Foundation

nonisolated enum ChineseScript: String, CaseIterable, Identifiable, Sendable {
    case simplified
    case traditional

    var id: Self { self }
    var label: String { self == .simplified ? "简体" : "繁體" }
}

nonisolated enum ChineseText {
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF: true
        default: false
        }
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.first.map(isCJK) ?? false
    }

    /// Full-width CJK punctuation, which also never takes a space before or after.
    static func isCJKPunctuation(_ character: Character) -> Bool {
        "，。！？；：、（）《》〈〉「」『』【】…—～·".contains(character)
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJK)
    }

    /// Inserts a space between CJK characters and adjacent Latin letters or digits
    /// ("用npm安装" → "用 npm 安装"). Leaves everything else as is.
    static func spacingCJKAndLatin(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if let previous, needsSpace(between: previous, and: character) { result.append(" ") }
            result.append(character)
            previous = character
        }
        return result
    }

    private static func needsSpace(between a: Character, and b: Character) -> Bool {
        let latinA = a.isASCII && (a.isLetter || a.isNumber)
        let latinB = b.isASCII && (b.isLetter || b.isNumber)
        return (isCJK(a) && latinB) || (latinA && isCJK(b))
    }

    /// Joins two transcript parts: Chinese runs together, anything else gets a space.
    static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        let tight = (isCJK(last) || isCJKPunctuation(last)) && (isCJK(first) || isCJKPunctuation(first))
        return tight ? a + b : a + " " + b
    }

    static func converting(_ text: String, to script: ChineseScript) -> String {
        guard containsCJK(text) else { return text }
        let transform = StringTransform(script == .traditional ? "Hans-Hant" : "Hant-Hans")
        return text.applyingTransform(transform, reverse: false) ?? text
    }

    /// Words for metrics: each CJK character counts as one, Latin words as one.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                count += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inWord { count += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return count
    }
}
