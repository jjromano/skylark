import Foundation

/// Decides which custom-dictionary terms are worth sending to a CLOUD cleanup
/// request for one utterance (P1-6).
///
/// The dictionary is a privacy surface: it holds colleagues' names, project
/// code names, client names, and internal jargon. Before this filter the whole
/// list went out with EVERY cloud cleanup — a measured 10.5 KB dictionary added
/// 4.9 KB to each request, with none of its terms anywhere in the transcript.
/// That is both a leak of terms the user never spoke and a per-request cost.
///
/// So: a term travels only when the transcript plausibly contains it — an exact
/// token, a listed misspelling, a shared prefix, or a small edit distance away
/// (the STT engine's own errors are what the "prefer these spellings" line
/// exists to repair, so approximate matches must count). Nothing matched ⇒ no
/// dictionary line in the prompt at all. LOCAL cleanup is unaffected and keeps
/// the full list: nothing leaves the machine there.
///
/// **This runs on the latency path** — it gates the cloud call, so it cannot be
/// deferred. Everything here is therefore pure, allocation-light, and bounded:
/// one pass to tokenize the transcript, then per surface form a length-bucketed
/// candidate lookup and a banded edit-distance check that bails on the first
/// row that exceeds the budget. No regex, no I/O, no locks.
public enum DictionaryRelevance {
    /// Hard ceiling on how many terms one request may carry. A user with a
    /// thousand-entry dictionary who dictates a long paragraph could otherwise
    /// still match a long tail of near-misses; the prompt line stays small and
    /// the cost stays predictable. Ordered by entry order, so the cap is stable.
    public static let maxTerms = 40

    /// Terms below this length must match a transcript token EXACTLY. Fuzzy
    /// matching two- and three-letter terms ("AI", "API", "CI") pulls in most of
    /// a dictionary from any sentence, which is exactly what we're fixing.
    private static let exactOnlyLength = 4

    /// The phrases from `entries` that `transcript` plausibly contains, in entry
    /// order, deduplicated, capped at `maxTerms`. Empty transcript or empty
    /// dictionary ⇒ empty (and the caller then emits no dictionary line).
    public static func relevantPhrases(entries: [DictionaryEntry], transcript: String) -> [String] {
        guard !entries.isEmpty else { return [] }
        let index = TranscriptIndex(transcript)
        guard !index.isEmpty else { return [] }

        var matched: [String] = []
        var seen = Set<String>()
        for entry in entries {
            guard !entry.phrase.isEmpty, !seen.contains(entry.phrase) else { continue }
            // The phrase itself first, then its listed misspellings — a
            // transcript that says the mistake still needs the right spelling.
            var forms = [entry.phrase]
            forms.append(contentsOf: entry.misspellings)
            guard forms.contains(where: { index.approximatelyContains($0) }) else { continue }
            seen.insert(entry.phrase)
            matched.append(entry.phrase)
            if matched.count == maxTerms { break }
        }
        return matched
    }

    // MARK: - Transcript index

    /// The transcript, tokenized once and bucketed by token length so a fuzzy
    /// lookup only ever compares candidates that could possibly be within the
    /// edit budget.
    struct TranscriptIndex {
        /// Lowercased alphanumeric tokens, in order.
        let tokens: [[Character]]
        /// Exact-match set.
        private let exact: Set<String>
        /// token length → indices into `tokens`.
        private let byLength: [Int: [Int]]
        /// Tokens joined by single spaces and padded with one, so a multi-word
        /// phrase can be found with a plain (token-boundary-safe) substring test.
        private let padded: String

        init(_ transcript: String) {
            let strings = DictionaryRelevance.tokenize(transcript)
            tokens = strings.map(Array.init)
            exact = Set(strings)
            var buckets: [Int: [Int]] = [:]
            for (offset, token) in tokens.enumerated() {
                buckets[token.count, default: []].append(offset)
            }
            byLength = buckets
            padded = strings.isEmpty ? "" : " " + strings.joined(separator: " ") + " "
        }

        var isEmpty: Bool { tokens.isEmpty }

        /// Does the transcript contain `surface`, exactly or approximately?
        func approximatelyContains(_ surface: String) -> Bool {
            let parts = DictionaryRelevance.tokenize(surface)
            guard let first = parts.first else { return false }
            if parts.count > 1 {
                // Multi-word term ("Skylark Dictation", "real-time"): the whole
                // phrase must appear, but each word may be individually fuzzy.
                if padded.contains(" " + parts.joined(separator: " ") + " ") { return true }
                return parts.allSatisfy { matchesSomeToken($0) }
            }
            if exact.contains(first) { return true }
            return matchesSomeToken(first)
        }

        /// Is some transcript token an approximate match for the single token
        /// `word` — same token, a shared prefix, or within the edit budget?
        private func matchesSomeToken(_ word: String) -> Bool {
            if exact.contains(word) { return true }
            let needle = Array(word)
            let budget = DictionaryRelevance.editBudget(forLength: needle.count)
            guard budget > 0 else { return false }
            // Only lengths within the budget (edit distance is at least the
            // length difference) — plus the prefix rule's wider window.
            let window = max(budget, DictionaryRelevance.prefixLengthWindow)
            for length in (needle.count - window)...(needle.count + window) {
                guard let indices = byLength[length] else { continue }
                for index in indices {
                    let candidate = tokens[index]
                    if DictionaryRelevance.sharesPrefix(needle, candidate) { return true }
                    if abs(candidate.count - needle.count) <= budget,
                       DictionaryRelevance.withinEditDistance(needle, candidate, budget: budget) {
                        return true
                    }
                }
            }
            return false
        }
    }

    // MARK: - Matching primitives

    /// Lowercased alphanumeric tokens. Punctuation, hyphens and apostrophes all
    /// split ("real-time" → ["real", "time"]) so the dictionary's spelling of a
    /// compound doesn't have to match the transcriber's.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(contentsOf: character.lowercased())
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// How many edits a token of this length may be away and still count as the
    /// same word. Short terms are exact-only (see `exactOnlyLength`).
    static func editBudget(forLength length: Int) -> Int {
        switch length {
        case ..<exactOnlyLength: return 0
        case exactOnlyLength...7: return 1
        default: return 2
        }
    }

    /// How much longer/shorter a token may be and still qualify under the
    /// prefix rule ("postgres" ↔ "postgresql").
    static let prefixLengthWindow = 3

    /// One token is a prefix of the other, the shorter one is long enough to be
    /// distinctive, and they don't differ by more than `prefixLengthWindow`.
    /// Catches the endings STT routinely drops or adds without paying for a
    /// wider edit budget.
    static func sharesPrefix(_ a: [Character], _ b: [Character]) -> Bool {
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        guard shorter.count >= exactOnlyLength,
              longer.count - shorter.count <= prefixLengthWindow,
              longer.count > shorter.count
        else { return false }
        for index in 0..<shorter.count where shorter[index] != longer[index] { return false }
        return true
    }

    /// Banded Levenshtein: is `a` within `budget` edits of `b`? Rows are
    /// computed only inside the diagonal band, and the whole thing bails the
    /// moment a row's minimum exceeds the budget, so a non-match costs O(n·k)
    /// with a tiny constant rather than a full O(n·m) table.
    static func withinEditDistance(_ a: [Character], _ b: [Character], budget: Int) -> Bool {
        if budget == 0 { return a == b }
        guard abs(a.count - b.count) <= budget else { return false }
        if a.isEmpty { return b.count <= budget }
        if b.isEmpty { return a.count <= budget }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            let low = max(1, i - budget)
            let high = min(b.count, i + budget)
            // Cells outside the band can never be reached within the budget.
            if low > 1 { current[low - 1] = budget + 1 }
            var rowMinimum = current[0]
            if low <= high {
                for j in low...high {
                    let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                    let deletion = previous[j] + 1
                    let insertion = current[j - 1] + 1
                    let best = min(substitution, min(deletion, insertion))
                    current[j] = best
                    rowMinimum = min(rowMinimum, best)
                }
            }
            if high < b.count { current[high + 1] = budget + 1 }
            guard rowMinimum <= budget else { return false }
            swap(&previous, &current)
        }
        return previous[b.count] <= budget
    }
}
