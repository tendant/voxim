//
//  Replacements.swift
//  voxim
//
//  User vocabulary as "when I say X, type Y" rules, applied to every transcript before
//  formatting. Engine-agnostic; fixes words the recognizer consistently garbles
//  ("T mux" → "tmux"). Cannot fix true homophones ("pain"/"pane").
//

import Foundation
import Observation

nonisolated struct Replacement: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// What the recognizer produces; matched case-insensitively as whole words.
    var spoken: String
    /// What gets typed instead, exactly as written.
    var written: String
}

nonisolated enum ReplacementEngine {
    static func apply(_ rules: [Replacement], to text: String) -> String {
        // Longest phrases first, so "t mux" wins over a separate "mux" rule.
        let ordered = rules
            .filter { !$0.spoken.trimmed.isEmpty }
            .sorted { $0.spoken.count > $1.spoken.count }
        return ordered.reduce(text) { result, rule in
            guard let regex = pattern(for: rule.spoken) else { return result }
            let range = NSRange(result.startIndex..., in: result)
            return regex.stringByReplacingMatches(
                in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: rule.written)
            )
        }
    }

    /// Whole-word, case-insensitive; any run of spaces/hyphens in the phrase matches any other
    /// ("t mux" matches "T-mux", "t  mux").
    static func pattern(for spoken: String) -> NSRegularExpression? {
        let words = spoken.trimmed
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let body = words.joined(separator: "[\\s-]+")
        return try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive]
        )
    }
}

/// Persisted rule list (UserDefaults, JSON). Shared by the menu, settings and the pipeline.
@Observable
final class ReplacementStore {
    private static let defaultsKey = "replacements"

    var rules: [Replacement] {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let rules = try? JSONDecoder().decode([Replacement].self, from: data) {
            self.rules = rules
        } else {
            rules = []
        }
    }

    func apply(to text: String) -> String {
        ReplacementEngine.apply(rules, to: text)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
