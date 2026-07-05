import Foundation

/// Applies the custom-dictionary correction map to a raw transcript (PRD §8).
/// Only entries with a non-nil `replacement` rewrite text; case-insensitive,
/// word-boundary matching, preserving the leading capitalization of the matched
/// token when the replacement is lowercase ("Realtime" → "real-time" keeps
/// "Real-time" at a sentence start).
///
/// Regexes are compiled once per dictionary change (`update(entries:)`) so the
/// hot `apply` path stays inside the ≤5 ms correction budget (ARCHITECTURE §8).
public final class DictionaryCorrector: @unchecked Sendable {
    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String
    }

    private let lock = NSLock()
    private var rules: [Rule]

    public init(entries: [DictionaryEntry]) {
        rules = Self.compile(entries)
    }

    /// Rebuild the precompiled rules for a changed dictionary.
    public func update(entries: [DictionaryEntry]) {
        let compiled = Self.compile(entries)
        lock.lock()
        rules = compiled
        lock.unlock()
    }

    /// Apply every rule to `text`, longest phrases first.
    public func apply(_ text: String) -> String {
        lock.lock()
        let rules = self.rules
        lock.unlock()
        guard !rules.isEmpty else { return text }

        var result = text
        for rule in rules {
            result = Self.applyRule(rule, to: result)
        }
        return result
    }

    // MARK: - Compilation

    private static func compile(_ entries: [DictionaryEntry]) -> [Rule] {
        entries
            // Longest phrase first so multi-word entries win over their prefixes.
            .sorted { $0.phrase.count > $1.phrase.count }
            .compactMap { entry -> Rule? in
                guard let replacement = entry.replacement,
                      !entry.phrase.isEmpty else { return nil }
                let escaped = NSRegularExpression.escapedPattern(for: entry.phrase)
                // \b anchors on word boundaries; phrases may span multiple words.
                let pattern = "\\b\(escaped)\\b"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    return nil
                }
                return Rule(regex: regex, replacement: replacement)
            }
    }

    private static func applyRule(_ rule: Rule, to text: String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = rule.regex.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        // Replace back-to-front so earlier ranges stay valid.
        for match in matches.reversed() {
            let matched = ns.substring(with: match.range)
            let replacement = capitalizationPreserved(matched: matched, replacement: rule.replacement)
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    /// When the matched token starts uppercase and the replacement starts with a
    /// lowercase letter, uppercase the replacement's first character.
    static func capitalizationPreserved(matched: String, replacement: String) -> String {
        guard let matchedFirst = matched.first, matchedFirst.isUppercase,
              let repFirst = replacement.first, repFirst.isLowercase else {
            return replacement
        }
        return repFirst.uppercased() + replacement.dropFirst()
    }
}
