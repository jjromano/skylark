import Foundation

/// Shared output hygiene for every cleanup tier (local + cloud), so the
/// faithfulness rules live in exactly one place and the two tiers stay in
/// lockstep (per the `CleanupPrompt` design note).
///
/// A cleanup model is only ever allowed to *repair* the transcript. This turns
/// its raw response into trusted cleaned text, or throws
/// `CleanerError.unusableOutput` so the caller keeps the raw transcript, when
/// the model instead:
///   - returned nothing usable (empty / runaway length),
///   - stopped cleaning and started talking to the user (meta-commentary), or
///   - dropped a negation present in the raw text (meaning inversion — the
///     dangerous failure: "I can't see anything" → "I can see anything").
public enum CleanupHygiene {
    /// Trim surrounding whitespace, strip any echoed transcript fence tags, and
    /// remove a single layer of wrapping quotes the model sometimes adds.
    public static func sanitize(_ output: String) -> String {
        var s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        s = stripTranscriptTags(s)
        s = stripSurroundingQuotes(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanitize `output`, then reject it (throwing `.unusableOutput`, so the
    /// caller keeps the raw transcript) when it's empty, runaway-long, chatbot
    /// meta-commentary, or drops a negation present in `transcript`. Returns the
    /// trusted cleaned text otherwise.
    public static func validate(_ output: String, transcript: String) throws -> String {
        let cleaned = sanitize(output)
        guard !cleaned.isEmpty, cleaned.count <= transcript.count * 3 else {
            throw CleanerError.unusableOutput
        }
        if isMetaCommentary(cleaned, transcript: transcript) {
            throw CleanerError.unusableOutput
        }
        if dropsNegation(from: transcript, to: cleaned) {
            throw CleanerError.unusableOutput
        }
        if divergesFrom(transcript, cleaned: cleaned) {
            throw CleanerError.unusableOutput
        }
        return cleaned
    }

    // MARK: - Guards

    /// The model stopped cleaning and started addressing the user (answering,
    /// prefacing, or explaining). A tell only counts when it is NOT something
    /// the speaker themselves dictated — so a legitimately-spoken "here is a
    /// list…" (v0.2.0 list formatting) or "…should be rewritten as a class" is
    /// preserved, while an injected "Sure, here's the cleaned version:" is not.
    static func isMetaCommentary(_ cleaned: String, transcript: String) -> Bool {
        let lower = cleaned.lowercased()
        let rawLower = transcript.lowercased()

        let leadingTells = [
            "sure", "certainly", "of course", "here is", "here's",
            "i've cleaned", "i have cleaned", "okay, here", "the cleaned text",
        ]
        for tell in leadingTells where lower.hasPrefix(tell) && !rawLower.contains(tell) {
            return true
        }

        let anywhereTells = [
            "should be rewritten", "rewritten as", "cleaned version:",
            "cleaned transcript:", "corrected version:",
        ]
        for tell in anywhereTells where lower.contains(tell) && !rawLower.contains(tell) {
            return true
        }

        // Model echoed the transcript verbatim and appended commentary around
        // it (e.g. "<transcript> — this is already clean."). Cleaned output
        // normally differs from raw (fillers removed, punctuation/casing added),
        // so a verbatim copy plus a meaningful extra chunk is a tell.
        let rawTrimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTrimmed.count >= 4, cleaned.contains(rawTrimmed) {
            let extra = cleaned.replacingOccurrences(of: rawTrimmed, with: "")
            let signal = extra.filter { !$0.isWhitespace && !$0.isPunctuation }
            if signal.count >= 10 { return true }
        }
        return false
    }

    /// True when a sentential negation present in `raw` disappears in `cleaned`
    /// — cheap protection against meaning inversion ("I can't see" → "I can
    /// see"). Deliberately excludes bare "no", which is usually a self-
    /// correction marker ("meet Tuesday, no, Friday") the cleaner is SUPPOSED
    /// to drop, not a sentential negation. A genuine self-correction that drops
    /// "not"/"never" is rare and merely falls back to the (faithful) raw text.
    static func dropsNegation(from raw: String, to cleaned: String) -> Bool {
        negationCount(cleaned) < negationCount(raw)
    }

    private static let negationPatterns = [
        "\\bnot\\b", "\\bnever\\b", "\\bcannot\\b", "n't\\b",
    ]

    private static func negationCount(_ text: String) -> Int {
        // Normalize the unicode apostrophe STT sometimes emits so "can't"
        // matches the n't pattern regardless of which quote it used.
        let normalized = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let range = NSRange(normalized.startIndex..., in: normalized)
        var count = 0
        for pattern in negationPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            count += regex.numberOfMatches(in: normalized, range: range)
        }
        return count
    }

    /// True when the cleaned text shares too little vocabulary with the raw to
    /// plausibly be a cleanup of it. A tiny local model faced with input it
    /// can't "clean" (e.g. a bare imperative) sometimes regurgitates a prompt
    /// example instead — output that shares almost no words with what was
    /// spoken. Legitimate cleanup (filler/self-correction removal, punctuation,
    /// casing) keeps most content words, so a low retention ratio is a reliable
    /// tell. Skipped for very short transcripts, where the ratio is too noisy.
    static func divergesFrom(_ raw: String, cleaned: String) -> Bool {
        let rawWords = contentWords(raw)
        guard rawWords.count >= 4 else { return false }
        let cleanedSet = Set(contentWords(cleaned))
        let retained = rawWords.filter { cleanedSet.contains($0) }.count
        return Double(retained) / Double(rawWords.count) < 0.34
    }

    /// Filler + high-frequency function words carry no topical signal, so
    /// removing them focuses the retention ratio on meaningful vocabulary.
    private static let contentStopwords: Set<String> = [
        "um", "uh", "er", "an", "the", "of", "and", "or", "is", "are",
        "be", "this", "that", "it", "in", "on", "for", "my", "you", "your",
    ]

    private static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 1 && !contentStopwords.contains($0) }
    }

    /// Remove transcript fence delimiters the model sometimes echoes from the
    /// user message back into its output.
    private static func stripTranscriptTags(_ s: String) -> String {
        var t = s
        if t.lowercased().hasPrefix("<transcript>") { t = String(t.dropFirst("<transcript>".count)) }
        if t.lowercased().hasSuffix("</transcript>") { t = String(t.dropLast("</transcript>".count)) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripSurroundingQuotes(_ s: String) -> String {
        guard let first = s.first, let last = s.last, s.count >= 2 else { return s }
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"),
        ]
        for (open, close) in quotePairs where first == open && last == close {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
