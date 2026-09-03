import Foundation

/// Deterministic, conservative spoken-address formatting: joins spoken "dot",
/// "slash", and "at" into the punctuation they stand for, but ONLY when
/// surrounding context signals an actual address (a domain, URL, or email) —
/// never in ordinary prose ("connect the dot", "a slash in the price", "meet
/// me at the office"). Modelled on `SpokenNumbers.format`: pure, deterministic,
/// no I/O, idempotent, and conservative — when context doesn't clearly signal
/// an address, the words are left exactly as spoken.
///
/// The speech engine's own inverse-text-normalization already turns spoken
/// "dot" into a literal "." most of the time, which is why the live defect
/// (D12) showed "github.com slash jjromano slash skylark" — dot already
/// punctuated, slash and at still words. Rule 1 (dot) exists mainly as a
/// safety net for whenever that normalization doesn't fire; rules 2 and 3
/// (slash, at) are the actual fix.
///
/// Design contract (shared with `SpokenNumbers`):
///   - **Pure & deterministic:** no I/O, no shared mutable state, no clock.
///   - **Idempotent:** `format(format(x)) == format(x)` — a converted address
///     contains no more "dot"/"slash"/"at" WORDS to re-match.
///   - **Conservative:** context-gated on every rule; when a candidate doesn't
///     clearly read as part of an address, the words are left exactly as
///     spoken. Surrounding text, punctuation (including a sentence-final
///     period right after a converted address), capitalization, and spacing
///     are preserved verbatim outside the joined words.
public enum SpokenAddresses {
    /// Convert spoken "dot"/"slash"/"at" into the punctuation they represent
    /// wherever context marks the phrase as an address. Pure, deterministic,
    /// and idempotent. Order matters: dot runs first, so "slash"/"at" can see
    /// an already-dotted domain to their left/right.
    public static func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var toks = tokenize(text).map { $0.text }
        formatDots(&toks)
        formatSlashes(&toks)
        formatAts(&toks)
        return toks.joined()
    }

    // MARK: - Vocabulary

    private static let tldSet: Set<String> = [
        "com", "org", "net", "io", "dev", "ai", "co", "uk", "edu", "gov",
        "app", "me", "us", "de", "fr", "ca", "au",
    ]

    /// Left-side words that make "at" almost certainly a preposition, not an
    /// email separator ("meet me at example.com" stays prose despite the
    /// domain-like right side).
    private static let atStopwords: Set<String> = [
        "me", "you", "us", "them", "it", "him", "her", "at", "the", "a", "an",
    ]

    // MARK: - Rule 1: dot

    /// Join spoken "dot" between two words when the right word is a known TLD,
    /// or the left side already looks like part of an address ("." or "/" in
    /// it — chain continuation). Scans right-to-left so a chain resolves from
    /// its TLD tail inward: "www dot example dot co dot uk" merges "co"+"uk"
    /// first, then folds "example" and finally "www" into the growing domain.
    private static func formatDots(_ toks: inout [String]) {
        var i = toks.count - 1
        while i >= 0 {
            defer { i -= 1 }
            guard toks[i].lowercased() == "dot" else { continue }
            guard i >= 2, i + 2 < toks.count else { continue }
            guard isWhitespaceOnly(toks[i - 1]), isWhitespaceOnly(toks[i + 1]) else { continue }
            let left = toks[i - 2]
            let right = toks[i + 2]
            guard !left.isEmpty, !right.isEmpty else { continue }
            guard isTLDWord(right) || isDomainLike(right) || left.contains(".") || left.contains("/") else { continue }
            toks[i - 2] = left + "." + right
            toks[i - 1] = ""
            toks[i] = ""
            toks[i + 1] = ""
            toks[i + 2] = ""
        }
    }

    // MARK: - Rule 2: slash

    /// Join spoken "slash" (or "forward slash") into "/" when the left side —
    /// walked backward through any already-joined "." or "/" — is domain-like.
    /// Left-to-right so a later slash sees the growing path to its left
    /// ("github.com slash jjromano slash skylark" → the second slash's left
    /// chunk resolves all the way back to "github.com/jjromano").
    private static func formatSlashes(_ toks: inout [String]) {
        var i = 0
        while i < toks.count {
            defer { i += 1 }
            guard toks[i].lowercased() == "slash" else { continue }
            var delimStart = i
            if i >= 2, isWhitespaceOnly(toks[i - 1]), toks[i - 2].lowercased() == "forward" {
                delimStart = i - 2
            }
            guard delimStart >= 2, isWhitespaceOnly(toks[delimStart - 1]) else { continue }
            guard i + 2 < toks.count, isWhitespaceOnly(toks[i + 1]) else { continue }
            let right = toks[i + 2]
            guard !right.isEmpty else { continue }
            let (leftText, leftStart) = leftChunk(endingBefore: delimStart - 1, in: toks)
            guard !leftText.isEmpty, isDomainLike(hostPart(leftText)) else { continue }
            toks[leftStart] = leftText + "/" + right
            for k in (leftStart + 1) ... (i + 2) { toks[k] = "" }
        }
    }

    // MARK: - Rule 3: at

    /// Join spoken "at" into "@" when the right side — walked forward through
    /// any "." already in the text (an email domain often isn't a spoken-dot
    /// chain at all, just literal punctuation the STT already wrote) — is
    /// domain-like, and the left side is a plain handle that isn't a common
    /// preposition object.
    private static func formatAts(_ toks: inout [String]) {
        for i in 0 ..< toks.count {
            guard toks[i].lowercased() == "at" else { continue }
            guard i >= 2, i + 1 < toks.count else { continue }
            guard isWhitespaceOnly(toks[i - 1]), isWhitespaceOnly(toks[i + 1]) else { continue }
            let left = toks[i - 2]
            guard !left.isEmpty, isPlainHandle(left), !atStopwords.contains(left.lowercased()) else { continue }
            let (rightText, rightEnd) = rightChunk(startingAfter: i + 1, in: toks)
            guard !rightText.isEmpty, isDomainLike(rightText) else { continue }
            toks[i - 2] = left + "@" + rightText
            toks[i - 1] = ""
            toks[i] = ""
            for k in (i + 1) ... rightEnd { toks[k] = "" }
        }
    }

    // MARK: - Domain-likeness

    /// The right side of a spoken "dot" is a bare known TLD ("com", "uk"…).
    private static func isTLDWord(_ s: String) -> Bool {
        tldSet.contains(s.lowercased())
    }

    /// A token (or already-joined chunk) that reads as a domain: it starts
    /// with "http://"/"https://"/"www.", or it contains a "." whose final
    /// segment is a known TLD ("example.com", "co.uk", "example.com/path" —
    /// the last segment past the last "." is what's checked, so a path suffix
    /// after a "/" doesn't matter here; callers that need the bare host use
    /// `hostPart` first).
    private static func isDomainLike(_ s: String) -> Bool {
        let low = s.lowercased()
        guard !low.isEmpty else { return false }
        if low.hasPrefix("http://") || low.hasPrefix("https://") || low.hasPrefix("www.") { return true }
        if let dotIdx = low.lastIndex(of: ".") {
            let suffix = String(low[low.index(after: dotIdx)...])
            if !suffix.isEmpty, tldSet.contains(suffix) { return true }
        }
        return false
    }

    /// The part of a chunk before its first "/", i.e. the host ("github.com"
    /// out of "github.com/jjromano").
    private static func hostPart(_ chunk: String) -> String {
        guard let slashIdx = chunk.firstIndex(of: "/") else { return chunk }
        return String(chunk[chunk.startIndex ..< slashIdx])
    }

    /// A plain word/handle: letters, digits, dots, underscores, hyphens only —
    /// the character set an email local-part or bare word may use. Excludes
    /// anything already containing "/" or "@" (a path or a second address).
    private static func isPlainHandle(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// A gap made up entirely of "." and/or "/" — a domain/path connector,
    /// as opposed to a genuine word-boundary gap (whitespace) or unrelated
    /// punctuation (comma, colon…).
    private static func isConnectorOnly(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0 == "." || $0 == "/" }
    }

    private static func isWhitespaceOnly(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isWhitespace }
    }

    // MARK: - Chunk walking

    /// Walk backward from the whitespace gap at `gapIndex`, accumulating
    /// content through any connector-only gaps ("." or "/") so a
    /// multi-token domain/path already in the text ("github" "." "com") reads
    /// as one chunk. Stops at the first real word-boundary whitespace, and
    /// never crosses a DANGLING connector (one not followed by more content,
    /// e.g. the "." right before this gap turning out to be unrelated) —
    /// though in practice a dangling connector can only appear leading a
    /// chunk if the raw text itself is malformed, so this mainly guards the
    /// symmetric case on `rightChunk`. Returns the joined text and the index
    /// of its first (leftmost) token.
    private static func leftChunk(endingBefore gapIndex: Int, in toks: [String]) -> (text: String, start: Int) {
        guard gapIndex >= 0 else { return ("", gapIndex) }
        var idx = gapIndex - 1
        var text = ""
        var start = gapIndex
        while idx >= 0 {
            let s = toks[idx]
            if s.isEmpty { idx -= 1; continue }
            if isWhitespaceOnly(s) { break }
            if isConnectorOnly(s) {
                guard idx - 1 >= 0, !toks[idx - 1].isEmpty, !isWhitespaceOnly(toks[idx - 1]) else { break }
            }
            text = s + text
            start = idx
            idx -= 1
        }
        return (text, start)
    }

    /// The mirror of `leftChunk`: walk forward from just after `gapIndex`,
    /// accumulating content through connector-only gaps but stopping before a
    /// DANGLING one — a "." not followed by more content is a sentence-final
    /// period, not a domain separator, and must not be swallowed into the
    /// address. Returns the joined text and the index of its last token.
    private static func rightChunk(startingAfter gapIndex: Int, in toks: [String]) -> (text: String, end: Int) {
        var idx = gapIndex + 1
        var text = ""
        var end = gapIndex
        while idx < toks.count {
            let s = toks[idx]
            if s.isEmpty { idx += 1; continue }
            if isWhitespaceOnly(s) { break }
            if isConnectorOnly(s) {
                guard idx + 1 < toks.count, !toks[idx + 1].isEmpty, !isWhitespaceOnly(toks[idx + 1]) else { break }
            }
            text += s
            end = idx
            idx += 1
        }
        return (text, end)
    }

    // MARK: - Tokenization

    /// Split into maximal runs of letters (words) alternating with maximal
    /// runs of non-letters (gaps), preserving every character so the pieces
    /// rejoin into the exact original outside the rewritten spans. Identical
    /// scheme to `SpokenNumbers.tokenize`.
    private static func tokenize(_ s: String) -> [(text: String, isWord: Bool)] {
        var result: [(text: String, isWord: Bool)] = []
        var current = ""
        var currentIsWord = false
        for ch in s {
            let isWord = ch.isLetter
            if current.isEmpty {
                current.append(ch)
                currentIsWord = isWord
            } else if isWord == currentIsWord {
                current.append(ch)
            } else {
                result.append((current, currentIsWord))
                current = String(ch)
                currentIsWord = isWord
            }
        }
        if !current.isEmpty { result.append((current, currentIsWord)) }
        return result
    }
}
