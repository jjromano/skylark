import Foundation
import NaturalLanguage

/// Deterministic repair of sentence boundaries a speech recogniser invented
/// from *pause length* rather than grammar.
///
/// Every recogniser Skylark uses (Parakeet TDT, WhisperKit, Apple
/// `SpeechTranscriber`) emits punctuation, and its punctuation head keys on
/// acoustic silence: a 700 ms thinking pause is indistinguishable from a full
/// stop. So the transcript reaching cleanup already reads
/// `I want to. Draft the document.` — the period is an artifact, not the
/// speaker's intent. This pass removes those periods before the cleanup model
/// (or its chunker) ever sees them.
///
/// Design contract — same shape as `SpokenNumbers`:
///   - **Pure & deterministic:** no I/O, no shared mutable state, no clock.
///   - **Conservative:** a boundary is only merged when a closed word list says
///     the fragment on one side of it cannot stand alone. Anything ambiguous is
///     left exactly as dictated.
///   - **Byte-identical when nothing fires:** whitespace, casing and
///     punctuation outside a merged boundary are copied through verbatim, so a
///     transcript with no false boundary is returned unchanged.
///
/// Out of scope: `!` and `?` boundaries (a recogniser only guesses *periods*
/// from silence), and any merge across a newline (an explicit "new paragraph"
/// is the speaker's own structure).
public enum SentenceBoundaryRepair {
    // MARK: - Tuning

    /// A merge needs at least this many words before the boundary — below it the
    /// leading fragment is more likely a genuine short sentence ("Yes.") than a
    /// shredded clause.
    static let minimumPrecedingWords = 3
    /// Never build a sentence longer than this many words out of two fragments.
    static let maximumMergedWords = 60

    // MARK: - Word lists

    /// R1 — words a sentence cannot END on. A period after one of these is
    /// always a pause artifact: determiners, prepositions, coordinators,
    /// auxiliaries, intensifiers.
    private static let danglingTails: Set<String> = [
        // determiners
        "the", "a", "an", "my", "your", "our", "their", "its",
        "this", "that", "these", "those", "some", "any", "every",
        // prepositions
        "of", "to", "for", "with", "in", "on", "at", "by", "from", "into", "onto",
        "about", "over", "under", "after", "before", "during", "through", "between",
        // conjunctions
        "and", "but", "or", "so",
        // auxiliaries
        "is", "are", "was", "were", "be", "been", "am", "will", "would", "can",
        "could", "should", "shall", "may", "might", "must", "do", "does", "did",
        "has", "have", "had",
        // intensifiers
        "really", "very", "just", "kind", "sort",
    ]

    /// R2 — words that cannot OPEN a standalone sentence. A fragment starting
    /// with one of these is a subordinate clause cut off from its main clause.
    private static let illegalHeads: Set<String> = [
        "which", "whom", "whose", "than", "nor", "of",
    ]

    /// R3 — words that can open a *continuation* of the previous thought. Unlike
    /// R1/R2 this one is only advisory: the fragment after it is inspected for
    /// an independent clause before a comma is used.
    private static let coordinators: Set<String> = [
        "and", "but", "or", "so", "then", "plus", "because",
        "which", "while", "although", "though", "yet", "nor",
    ]

    /// Tokens whose trailing period is part of the token, never a sentence end.
    /// Single letters ("J."), dotted tokens ("e.g.", "foo.swift", "v0.15.0") and
    /// pure numbers ("1.", "3.5") are rejected structurally in `closesSentence`;
    /// this list covers the rest.
    private static let abbreviations: Set<String> = [
        "dr", "mr", "mrs", "ms", "mx", "prof", "sr", "jr", "st", "vs",
        "etc", "eg", "ie", "inc", "ltd", "dept", "fig", "vol", "approx", "cf", "al",
        "ave", "blvd", "rd", "mt", "gov", "sen", "rep", "capt", "lt", "sgt",
        "phd", "md", "am", "pm",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
    ]

    // MARK: - Entry point

    /// Rejoin fragments the recogniser split at a pause. Returns `text`
    /// byte-identical when no boundary qualifies.
    public static func repair(_ text: String) -> String {
        // No period, no pause artifact — the overwhelmingly common short case.
        guard text.contains(".") else { return text }

        let chars = Array(text)
        let boundaries = candidateBoundaries(chars)
        guard !boundaries.isEmpty else { return text }

        var out = ""
        out.reserveCapacity(text.count)
        // Start of the not-yet-emitted region.
        var cursor = 0
        // Words in the sentence currently being built, so R3's "at least 3 words
        // before" and "at most 60 after merging" see the ACCUMULATED sentence,
        // not just the fragment since the last period.
        var accumulatedWords = 0
        // Set when a merge lands: the next chunk opens mid-sentence, so its
        // leading capital (the recogniser's, not the speaker's) comes down.
        var lowercaseNextChunk = false

        for (index, boundary) in boundaries.enumerated() {
            var chunk = String(chars[cursor ..< boundary.dot])
            if lowercaseNextChunk {
                chunk = downcasingFirstCharacter(chunk)
                lowercaseNextChunk = false
            }
            out += chunk

            let tally = tailSentenceWords(chunk)
            accumulatedWords = tally.reset ? tally.count : accumulatedWords + tally.count

            let nextDot = index + 1 < boundaries.count ? boundaries[index + 1].dot : nil
            let followingEnd = fragmentEnd(from: boundary.continuationStart, chars: chars, limit: nextDot)
            let following = words(String(chars[boundary.continuationStart ..< followingEnd]))

            let tail = reduced(words(chunk).last ?? "")
            let head = reduced(following.first ?? "")

            switch decide(tail: tail, head: head, precedingWords: accumulatedWords, following: following) {
            case .keep:
                // Verbatim: the period and the exact whitespace that followed it.
                out.append(".")
                out += String(chars[(boundary.dot + 1) ..< boundary.continuationStart])
                accumulatedWords = 0
            case .space:
                out += " "
                lowercaseNextChunk = shouldDowncase(following.first)
            case .comma:
                out += ", "
                lowercaseNextChunk = shouldDowncase(following.first)
            }
            cursor = boundary.continuationStart
        }

        var remainder = String(chars[cursor...])
        if lowercaseNextChunk { remainder = downcasingFirstCharacter(remainder) }
        out += remainder
        return out
    }

    // MARK: - The decision

    private enum Merge {
        /// Leave the period (and its whitespace) exactly as dictated.
        case keep
        /// Drop the period, join with a single space.
        case space
        /// Drop the period, join with ", ".
        case comma
    }

    /// R1 → R2 → R3, in that precedence order. Anything else keeps the period.
    private static func decide(
        tail: String, head: String, precedingWords: Int, following: [String]
    ) -> Merge {
        // R1 — the fragment before the period cannot end there.
        if !tail.isEmpty, danglingTails.contains(tail) { return .space }
        // R2 — the fragment after the period cannot start there.
        if !head.isEmpty, illegalHeads.contains(head) { return .space }
        // R3 — a coordinator continuing a thought that was long enough to be one.
        guard !head.isEmpty, coordinators.contains(head),
              precedingWords >= minimumPrecedingWords,
              precedingWords + following.count <= maximumMergedWords
        else { return .keep }
        // A comma only reads correctly when what follows the coordinator is a
        // full clause of its own ("I shipped it, but I am tired"). When it is
        // not, the speaker paused mid-clause and wanted no punctuation at all
        // ("ship the feature and then tell the team").
        let rest = following.dropFirst().joined(separator: " ")
        return isIndependentClause(rest) ? .comma : .space
    }

    /// Does this clause carry BOTH an explicit nominal subject and a verb after
    /// it? Only then does a comma before the coordinator read correctly.
    /// (Ported from the measured prototype in the 0.16.0 handoff.)
    static func isIndependentClause(_ clause: String) -> Bool {
        guard !clause.isEmpty else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = clause
        var sawNominal = false
        var sawVerb = false
        tagger.enumerateTags(
            in: clause.startIndex ..< clause.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, _ in
            guard let tag else { return true }
            if tag == .verb {
                if sawNominal { sawVerb = true }
                return !sawVerb
            }
            if tag == .noun || tag == .pronoun { sawNominal = true }
            return true
        }
        return sawNominal && sawVerb
    }

    // MARK: - Boundary detection

    /// A period that MIGHT be a pause artifact: `dot` is its offset, and
    /// `continuationStart` the offset of the first character after the
    /// whitespace that follows it.
    private struct Boundary {
        let dot: Int
        let continuationStart: Int
    }

    /// Every period that could plausibly be a recogniser-inserted boundary.
    /// Ellipses, decimals, dotted tokens (file names, versions, hosts),
    /// abbreviations, initials, list markers, line breaks and end-of-text are
    /// all excluded here, so the merge rules never see them.
    private static func candidateBoundaries(_ chars: [Character]) -> [Boundary] {
        var result: [Boundary] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "." else { i += 1; continue }
            // Ellipsis — every dot of the run is left alone.
            if i > 0, chars[i - 1] == "." { i += 1; continue }
            if i + 1 < chars.count, chars[i + 1] == "." { i += 1; continue }
            // A boundary is a period, same-line whitespace, then more text.
            var j = i + 1
            var crossesLine = false
            while j < chars.count, chars[j].isWhitespace {
                if chars[j].isNewline { crossesLine = true }
                j += 1
            }
            guard j > i + 1, !crossesLine, j < chars.count, closesSentence(chars, dot: i) else {
                i += 1
                continue
            }
            result.append(Boundary(dot: i, continuationStart: j))
            i = j
        }
        return result
    }

    /// Whether the token this period closes looks like the end of a sentence.
    /// False for initials (`J.`), abbreviations (`Dr.`, `e.g.`), the tail of a
    /// dotted token (`foo.swift.`, `v0.15.0.`, `example.com.`) and bare numbers
    /// (`1.`, `3.5`) — in all of them the period belongs to the token.
    private static func closesSentence(_ chars: [Character], dot: Int) -> Bool {
        var start = dot
        while start > 0, isWordCharacter(chars[start - 1]) { start -= 1 }
        guard start < dot else { return false }
        // The token is itself dotted ("foo.swift", "v0.15.0", "e.g.").
        if start > 0, chars[start - 1] == "." { return false }
        let token = String(chars[start ..< dot])
        // A single letter is an initial; a token with no letters is a number.
        guard token.count > 1, token.contains(where: { $0.isLetter }) else { return false }
        return !abbreviations.contains(token.lowercased())
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}"
    }

    /// Where the fragment starting at `start` ends: the next hard break (`!`,
    /// `?` or a line break) or `limit` (the next candidate period), whichever
    /// comes first.
    private static func fragmentEnd(from start: Int, chars: [Character], limit: Int?) -> Int {
        let end = limit ?? chars.count
        var i = start
        while i < end {
            if chars[i].isNewline { return i }
            if chars[i] == "!" || chars[i] == "?" {
                if i + 1 >= chars.count || chars[i + 1].isWhitespace { return i }
            }
            i += 1
        }
        return end
    }

    /// Words in `chunk` since its last hard sentence break, and whether one was
    /// found. A `!`/`?`/newline inside the chunk resets the running sentence
    /// length; a period does not (every period still standing in the chunk was
    /// rejected as a boundary, i.e. it belongs to its token).
    private static func tailSentenceWords(_ chunk: String) -> (count: Int, reset: Bool) {
        let chars = Array(chunk)
        var breakAt: Int?
        var i = chars.count - 1
        while i >= 0 {
            if chars[i].isNewline { breakAt = i; break }
            if chars[i] == "!" || chars[i] == "?",
               i + 1 >= chars.count || chars[i + 1].isWhitespace {
                breakAt = i
                break
            }
            i -= 1
        }
        guard let breakAt else { return (words(chunk).count, false) }
        return (words(String(chars[(breakAt + 1)...])).count, true)
    }

    // MARK: - Small helpers

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Lowercase, letters/digits/apostrophe only — the form the word lists match.
    private static func reduced(_ word: String) -> String {
        String(word.lowercased().filter(isWordCharacter))
    }

    /// A merged continuation loses its recogniser-supplied capital, except for
    /// "I"/"I'…" and acronyms — the same rule `LocalCleaner` applies at a chunk
    /// seam, shared rather than duplicated.
    private static func shouldDowncase(_ firstWord: String?) -> Bool {
        guard let firstWord else { return false }
        return !LocalCleaner.preservesContinuationCase(firstWord)
    }

    private static func downcasingFirstCharacter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).lowercased() + text.dropFirst()
    }
}
