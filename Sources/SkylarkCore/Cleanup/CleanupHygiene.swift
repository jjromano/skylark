import Foundation

/// Shared output hygiene for every cleanup tier (local + cloud), so the
/// faithfulness rules live in exactly one place. The tiers use different
/// prompts (see the `CleanupPrompt` design note) but the same guards here —
/// the local tier just dials them stricter via `retentionFloor` /
/// `contentLossFloor`, because the small on-device model paraphrases more.
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
    /// meta-commentary, drops a negation present in `transcript`, or diverges
    /// too far from it. Returns the trusted cleaned text otherwise.
    ///
    /// - Parameters:
    ///   - retentionFloor: minimum share of the raw's content-word *vocabulary*
    ///     that must survive in the cleaned text. Default `0.34` (cloud); the
    ///     local tier passes a stricter value because the ~3B model paraphrases.
    ///   - contentLossFloor: when non-nil, also reject when the cleaned text's
    ///     content-word *count* falls below this fraction of the raw's — a
    ///     separate guard against dropped clauses (filler + short self-
    ///     corrections can't legitimately shrink the count this much). Cloud
    ///     passes nil (no count guard, unchanged behavior); local passes ~0.60.
    ///   - fieldContext: the on-screen context (opt-in) that was fed to the
    ///     prompt, if any. Non-nil enables the leak guard: a long verbatim run of
    ///     the surrounding field text that appears in the output but NOT in the
    ///     transcript means the model dumped context instead of just cleaning the
    ///     transcript — rejected so the raw transcript stands. The other guards
    ///     already compare only transcript vs output, so context can't otherwise
    ///     inflate the faithfulness ratios.
    public static func validate(
        _ output: String,
        transcript: String,
        retentionFloor: Double = 0.34,
        contentLossFloor: Double? = nil,
        fieldContext: FieldContext? = nil
    ) throws -> String {
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
        if divergesFrom(transcript, cleaned: cleaned, retentionFloor: retentionFloor) {
            throw CleanerError.unusableOutput
        }
        if let contentLossFloor, losesContent(transcript, cleaned: cleaned, floor: contentLossFloor) {
            throw CleanerError.unusableOutput
        }
        if let fieldContext, echoesFieldContext(cleaned, transcript: transcript, fieldContext: fieldContext) {
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
    static func divergesFrom(_ raw: String, cleaned: String, retentionFloor: Double) -> Bool {
        let rawWords = contentWords(raw)
        guard rawWords.count >= 4 else { return false }
        let cleanedSet = Set(contentWords(cleaned))
        let retained = rawWords.filter { cleanedSet.contains($0) }.count
        return Double(retained) / Double(rawWords.count) < retentionFloor
    }

    /// True when the cleaned text's content-word COUNT dropped below `floor` ×
    /// the raw's — a dropped-clause / summarization tell that `divergesFrom`
    /// (which measures shared *vocabulary*, not amount) can miss when the model
    /// keeps a few of the raw's words but throws most of the sentence away.
    /// Removing fillers and resolving one-to-two-word self-corrections shrinks
    /// the count only modestly, so a steep drop means content was lost.
    /// Skipped for very short transcripts, where the ratio is too noisy.
    static func losesContent(_ raw: String, cleaned: String, floor: Double) -> Bool {
        let rawCount = contentWords(raw).count
        guard rawCount >= 4 else { return false }
        let cleanedCount = contentWords(cleaned).count
        return Double(cleanedCount) / Double(rawCount) < floor
    }

    /// Length (UTF-16-agnostic Character count) of a verbatim run of surrounding
    /// field text that, if it shows up in the output but not the transcript,
    /// counts as leaked context. Long enough that a legitimately short
    /// continuation (matching a name's spelling, a few shared words) never trips
    /// it — only a wholesale echo of the field's existing prose does.
    static let fieldContextRunLength = 40

    /// True when the cleaned output contains a long verbatim run of the
    /// surrounding field context that is absent from the transcript — i.e. the
    /// model regurgitated on-screen text instead of only cleaning what was
    /// spoken. The other guards compare transcript vs output only, so this is the
    /// dedicated check that opt-in field context can't leak into the result.
    /// Runs absent from the transcript are the target: content the user genuinely
    /// re-dictated (so it IS in the transcript) is exempt.
    static func echoesFieldContext(_ cleaned: String, transcript: String, fieldContext: FieldContext) -> Bool {
        let runLength = fieldContextRunLength
        // Step by half a window so a leak that starts mid-window is still caught,
        // while keeping the scan cheap (context is bounded to ~1600 chars).
        let step = max(1, runLength / 2)
        for context in [fieldContext.preceding, fieldContext.following] {
            let chars = Array(context)
            guard chars.count >= runLength else { continue }
            var i = 0
            while i + runLength <= chars.count {
                let window = String(chars[i ..< i + runLength])
                if cleaned.contains(window), !transcript.contains(window) {
                    return true
                }
                i += step
            }
        }
        return false
    }

    /// Filler + high-frequency function words carry no topical signal, so
    /// removing them focuses the retention ratio on meaningful vocabulary.
    private static let contentStopwords: Set<String> = [
        "um", "uh", "er", "an", "the", "of", "and", "or", "is", "are",
        "be", "this", "that", "it", "in", "on", "for", "my", "you", "your",
    ]

    /// Self-correction markers ("send it to bob, actually alice"). Counting
    /// them as stopwords means that *resolving* a self-correction — deleting
    /// the marker and the word it replaces — doesn't itself dent the retention
    /// or content-loss ratios, so a legitimate correction isn't punished as
    /// "dropped content". The abandoned word ("bob") is still allowed to drop:
    /// the ratios stay high because that's a one-to-two-word delta, not a clause.
    private static let selfCorrectionMarkers: Set<String> = [
        "actually", "wait", "mean", "sorry", "rather", "scratch", "no",
    ]

    /// Spoken-number words. A faithful cleanup rewrites spoken numbers as digits
    /// and symbols ("ninety nine point nine percent" → "99.9%", "twenty three"
    /// → "23"), which deletes several *words* and emits a numeric token that
    /// matches none of them — so counting them would make a CORRECT conversion
    /// look like dropped content. Excluding both the spoken number words (here)
    /// and the numeric tokens they become (`isNumericToken`) from the ratios, the
    /// way stopwords/self-correction markers already are, makes number formatting
    /// invisible to the faithfulness floors. Non-number content words still carry
    /// the ratio, so dropping a real clause is still caught.
    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "thousand", "million", "billion", "trillion",
        "point", "percent", "dollar", "dollars", "cent", "cents",
    ]

    /// A token made only of digits — the numeric form a spoken number converts
    /// to (the surrounding "%", "$", "." are non-alphanumeric and already split
    /// away by `contentWords`, so "99.9%" arrives here as the tokens "99"/"9").
    private static func isNumericToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy { $0.isNumber }
    }

    private static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter {
                $0.count > 1
                    && !contentStopwords.contains($0)
                    && !selfCorrectionMarkers.contains($0)
                    && !numberWords.contains($0)
                    && !isNumericToken($0)
            }
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
