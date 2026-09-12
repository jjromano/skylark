import Foundation

/// Applies the custom-dictionary correction map to a raw transcript (PRD §8).
/// One rewrite rule is compiled per `(misspelling → phrase)` pair. An entry
/// with no misspellings produces no rule, EXCEPT that a phrase whose casing is
/// the whole point ("CLAUDE.md", "GitHub", "iPhone") also rewrites its own
/// case-insensitive match to the exact spelling: the recognizer writes
/// "claude.md", and a dictionary that accepts the word but not its casing
/// looks broken (2026-09-08 human pass). Case-insensitive, word-boundary matching,
/// preserving the leading capitalization of the matched token when the
/// replacement (`phrase`) is lowercase ("Realtime" → "real-time" keeps
/// "Real-time" at a sentence start).
///
/// Regexes are compiled once per dictionary change (`update(entries:)`) so the
/// hot `apply` path stays inside the ≤5 ms correction budget (ARCHITECTURE §8).
public final class DictionaryCorrector: @unchecked Sendable {
    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String
        /// Case-enforcement rule: write `replacement` verbatim, never re-case it
        /// to the matched token (a sentence-initial "Iphone" must become
        /// "iPhone", not "IPhone").
        var exactCase = false
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

    /// Apply every rule to `text`, longest misspellings first.
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
        let pairs = entries.flatMap { entry in
            entry.misspellings.map { (misspelling: $0, phrase: entry.phrase, exactCase: false) }
        }
        let rewritten = Set(pairs.map { $0.misspelling.lowercased() })
        let casing = entries
            .filter { hasDistinctiveCasing($0.phrase) && !rewritten.contains($0.phrase.lowercased()) }
            .map { (misspelling: $0.phrase, phrase: $0.phrase, exactCase: true) }
        return (pairs + casing)
            // Longest misspelling first so multi-word entries win over their prefixes.
            .sorted { $0.misspelling.count > $1.misspelling.count }
            .compactMap { pair -> Rule? in
                guard !pair.misspelling.isEmpty, !pair.phrase.isEmpty else { return nil }
                let escaped = NSRegularExpression.escapedPattern(for: pair.misspelling)
                // Word-boundary anchors that also hold when the phrase starts or
                // ends with punctuation (".NET", "C++"), where `\b` would demand
                // a word character on the far side. Identical to `\b` for
                // phrases that start and end with a letter or digit.
                let pattern = "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    return nil
                }
                return Rule(regex: regex, replacement: pair.phrase, exactCase: pair.exactCase)
            }
    }

    /// True when a phrase's casing carries meaning a lowercase transcript would
    /// lose: an uppercase letter anywhere after the first character of a word
    /// ("GitHub", "iPhone", "CLAUDE.md", "JJ"). Plain Title Case ("Skylark",
    /// "New York") is not enough, since "Will" or "Mark" would then capitalize
    /// every ordinary use of the word. An all-caps entry that is also a common
    /// short word ("US", "IT", "OR") stays bias-only for the same reason.
    static func hasDistinctiveCasing(_ phrase: String) -> Bool {
        guard phrase.filter(\.isLetter).count >= 2 else { return false }
        let innerUpper = phrase.split(whereSeparator: { $0.isWhitespace })
            .contains { word in word.dropFirst().contains { $0.isUppercase } }
        guard innerUpper else { return false }
        return !commonShortWords.contains(phrase.lowercased())
    }

    private static let commonShortWords: Set<String> = [
        "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi", "id", "if", "in", "is", "it",
        "me", "my", "no", "of", "oh", "ok", "on", "or", "so", "to", "up", "us", "we",
        "all", "and", "are", "but", "can", "for", "had", "has", "her", "him", "his", "how",
        "may", "new", "not", "now", "one", "our", "out", "see", "she", "the", "two", "was",
        "who", "why", "yes", "you",
    ]

    private static func applyRule(_ rule: Rule, to text: String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = rule.regex.matches(in: text, options: [], range: full)
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        // Replace back-to-front so earlier ranges stay valid.
        for match in matches.reversed() {
            let matched = ns.substring(with: match.range)
            let replacement = rule.exactCase
                ? rule.replacement
                : capitalizationPreserved(matched: matched, replacement: rule.replacement)
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
