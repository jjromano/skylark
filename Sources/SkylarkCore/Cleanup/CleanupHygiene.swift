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
    /// Trim, then peel off the scaffolding small local models leak even when told
    /// not to (observed on the on-device model): reasoning/thinking blocks, a
    /// wrapping markdown code fence, echoed transcript fence tags, a leading
    /// "Output:"-style label, and a single layer of wrapping quotes. Every strip
    /// is conservative — it only removes a recognized wrapper, never speaker
    /// content.
    ///
    /// Provenance, stated precisely because the previous wording was wrong: the
    /// only code here adapted from another project is the thinking-tag strip,
    /// which follows OpenWhispr's `stripThinkingTags` (MIT, adaptation
    /// permitted with attribution). VoiceInk was read for the IDEA that a local
    /// model's scaffolding needs filtering at all, and nothing else — it is
    /// **GPL-3.0**, so no line of it may be copied into this MIT repo, and an
    /// earlier version of this comment described it as "MIT-adjacent", which it
    /// is not. The strips below are ordinary string trimming written here.
    public static func sanitize(_ output: String) -> String {
        var s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        s = stripReasoningBlocks(s)
        s = stripCodeFence(s)
        s = stripTranscriptTags(s)
        s = stripLeadingLabel(s)
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
    ///   - translated: translation-mode output (Settings → General). A correct
    ///     translation legitimately shares NO source vocabulary and changes the
    ///     content-word count and negation count arbitrarily across languages, so
    ///     the retention, content-loss, and negation guards — all source-language
    ///     comparisons — would reject every correct translation. In this mode
    ///     they are skipped; the empty/runaway-length check and the
    ///     meta-commentary tells (still meaningful — a chatbot preface is a
    ///     failure in any language) are KEPT, plus translated-only rejections
    ///     for leaked fence tags and separator-repeated untranslated output.
    ///     The two source-language *repair* passes (`EmphasisRepair`,
    ///     `SpokenNumbers`) are skipped for the same reason.
    public static func validate(
        _ output: String,
        transcript: String,
        retentionFloor: Double = 0.34,
        contentLossFloor: Double? = nil,
        fieldContext: FieldContext? = nil,
        translated: Bool = false
    ) throws -> String {
        let cleaned = sanitize(output)
        guard !cleaned.isEmpty, cleaned.count <= transcript.count * 3 else {
            throw CleanerError.unusableOutput
        }
        if isMetaCommentary(cleaned, transcript: transcript) {
            throw CleanerError.unusableOutput
        }
        // The remaining guards all compare against the SOURCE-language transcript
        // (shared vocabulary, content-word count, negation count). A translation
        // shares none of that by design, so they only fire in non-translated mode.
        if !translated {
            if dropsNegation(from: transcript, to: cleaned) {
                throw CleanerError.unusableOutput
            }
            // Numbers are excluded from the vocabulary/count ratios (so spoken→
            // digit conversion isn't punished), which leaves a numbers-heavy
            // clause drop invisible to those floors ("transfer twenty three
            // thousand … dollars … to vendor now" → "Transfer to vendor now."
            // retains 100% of its non-number words). This dedicated guard closes
            // that gap by counting number *units*, not words — a dropped amount
            // deletes a whole unit even when every surviving word is kept.
            if dropsNumberUnit(from: transcript, to: cleaned) {
                throw CleanerError.unusableOutput
            }
            // A figure the raw doesn't license means the model CHANGED an amount
            // ("one dollar and ninety nine cents" → "$1.09"). Silently wrong
            // numbers are worse than an uncleaned transcript, so raw stands.
            if fabricatesFigure(in: cleaned, from: transcript) {
                throw CleanerError.unusableOutput
            }
            if divergesFrom(transcript, cleaned: cleaned, retentionFloor: retentionFloor) {
                throw CleanerError.unusableOutput
            }
            if let contentLossFloor, losesContent(transcript, cleaned: cleaned, floor: contentLossFloor) {
                throw CleanerError.unusableOutput
            }
        } else {
            // Translated-only rejections, from live CJK probes of the on-device
            // model: (a) leaked transcript fence tags mid-output (sanitize only
            // strips them at the edges), (b) the untranslated cleaned text
            // repeated with `---` separators. Both mean the model failed to
            // translate — the faithful raw transcript is the better outcome.
            if cleaned.contains("<transcript") || cleaned.contains("\n---\n") {
                throw CleanerError.unusableOutput
            }
        }
        if let fieldContext, echoesFieldContext(cleaned, transcript: transcript, fieldContext: fieldContext) {
            throw CleanerError.unusableOutput
        }
        // Everything below runs on already-trusted output and REPAIRS it —
        // nothing here can reject. Both passes compare against the source-
        // language transcript, so both are skipped for translations.
        guard !translated else { return cleaned }
        // Emphasis the model invented from audible stress (added `!`, ALL-CAPS,
        // markdown bold) is downgraded to what the raw licenses. Rejecting a
        // good cleanup over one `!` would be worse than the mark.
        let repaired = EmphasisRepair.repair(cleaned, raw: transcript)
        // Deterministic spoken-number → digit/currency/percent pass as a safety
        // net for anything the model left unformatted (small local models are
        // unreliable here). Runs only on already-trusted output, and is
        // idempotent, so digits the model formatted correctly are untouched.
        // (English number words don't appear in a translated result either.)
        // Same treatment for spoken URLs/emails ("slash", "at", and "dot" as a
        // safety net) — D12: models convert "dot" via their own ITN but leave
        // "slash"/"at" as words, producing a half-formatted address that looks
        // done and isn't. Runs after `SpokenNumbers` so an address containing
        // digits ("user2@example.com") is joined from already-trusted digits,
        // not re-examined by any guard above (guards run once, before both
        // repairs).
        return SpokenAddresses.format(SpokenNumbers.format(repaired))
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

    /// True when the raw had spoken numbers but the cleaned text has NONE left —
    /// a numbers-heavy clause was dropped wholesale ("transfer twenty three
    /// thousand dollars to vendor" → "Transfer to vendor"). Runs at every
    /// non-translated tier — it's what lets numbers be excluded from the
    /// vocabulary/count ratios without opening a hole.
    ///
    /// Deliberately fires only when the count reaches ZERO, not on any decrease:
    /// legitimate number FORMATTING routinely reduces the run count without
    /// losing information — currency collapses multiple spoken runs into one
    /// figure ("one dollar and ninety nine cents", 2 runs → "$1.99", 1), and a
    /// spoken number fused into a word ("A ten G" → "A10G") stays a single unit
    /// (see `isNumberToken`, which counts any digit-bearing token). An earlier
    /// strict `<` comparison rejected both of those, so the model's formatted
    /// output was thrown away and raw kept — the local-tier "A ten G"/"$1.99"
    /// regression.
    static func dropsNumberUnit(from raw: String, to cleaned: String) -> Bool {
        numberUnitCount(raw) > 0 && numberUnitCount(cleaned) == 0
    }

    /// Count maximal consecutive runs of number tokens as one unit each.
    private static func numberUnitCount(_ text: String) -> Int {
        let normalized = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        var units = 0
        var inRun = false
        for token in normalized.split(whereSeparator: { $0.isWhitespace }) {
            if isNumberToken(String(token)) {
                if !inRun { units += 1; inRun = true }
            } else {
                inRun = false
            }
        }
        return units
    }

    /// A whitespace-delimited token that reads as (part of) a number: any token
    /// carrying a digit ("23", "$20", "99.9%", "23,456", and a digit fused into a
    /// word like "A10G" or "v2" — whose letters would otherwise mask it, the
    /// "A ten G" → "A10G" case), or a spoken number word (`numberWords`,
    /// tolerating attached punctuation like a trailing comma). A purely
    /// alphabetic non-number word ("vendor") is not a number token, so it breaks
    /// a run.
    private static func isNumberToken(_ token: String) -> Bool {
        if token.contains(where: { $0.isNumber }) { return true }
        let letters = token.filter { $0.isLetter }
        return !letters.isEmpty && numberWords.contains(letters)
    }

    // MARK: - Numeric faithfulness

    /// True when the cleaned text states a figure the raw transcript does not
    /// license — the model silently CHANGED an amount rather than formatting it
    /// ("it costs one dollar and ninety nine cents" → "It costs $1.09.", observed
    /// on the on-device tier). The other guards can't see this: the words are all
    /// there, the number-unit count is unchanged, and numbers are excluded from
    /// the vocabulary/count ratios. A wrong figure is worse than an unformatted
    /// one, so a fabricated number sends the whole cleanup back to raw.
    ///
    /// Deliberately biased toward ACCEPTING: every digit-bearing literal in the
    /// cleaned text passes if it matches, verbatim or by value, something the raw
    /// licenses (a digit already written there, `SpokenNumbers.format(raw)`, any
    /// number the raw's spoken words parse to, or several consecutive such units
    /// read as one figure — "twenty twenty six" → "2026"). List markers at the
    /// start of a line are exempt, digits fused into words ("A10G", "3rd") and
    /// component-separated figures ("3:30") are checked component-by-component.
    static func fabricatesFigure(in cleaned: String, from raw: String) -> Bool {
        // No digits at all: nothing to check, and the common case — stay cheap.
        guard cleaned.contains(where: { $0.isASCII && $0.isNumber }) else { return false }
        let license = numericLicense(for: raw)
        for line in cleaned.split(separator: "\n", omittingEmptySubsequences: false) {
            let body = droppingListMarker(line)
            for literal in SpokenNumbers.digitLiterals(in: String(body)) where !license.allows(literal) {
                return true
            }
        }
        return false
    }

    /// The figures a transcript licenses: exact digit strings plus their numeric
    /// values (so "1250.30" also licenses "1,250.3").
    private struct NumericLicense {
        var strings: Set<String> = []
        var values: Set<Double> = []

        mutating func license(_ s: String) {
            guard !s.isEmpty else { return }
            strings.insert(s)
            if let v = Double(s) { values.insert(v) }
        }

        func allows(_ literal: String) -> Bool {
            if strings.contains(literal) { return true }
            if let value = Double(literal) { return values.contains(value) }
            // Not a single number ("1.2.3"): every component must be licensed.
            let parts = literal.split(separator: ".")
            guard parts.count > 1 else { return false }
            return parts.allSatisfy { part in
                strings.contains(String(part))
                    || (Double(part).map { values.contains($0) } ?? false)
            }
        }
    }

    /// Longest run of consecutive number units that may be read as one figure —
    /// covers a spoken phone number ("five five five one two one two").
    private static let maxLicensedUnitRun = 8

    private static func numericLicense(for raw: String) -> NumericLicense {
        var license = NumericLicense()
        // Units the raw's own words and digits license, in spoken order, plus the
        // figures the deterministic formatter would produce from the same raw.
        let spoken = SpokenNumbers.licensedNumberStrings(in: raw)
        let formatted = SpokenNumbers.digitLiterals(in: SpokenNumbers.format(raw))
        for s in spoken { license.license(s) }
        for s in formatted { license.license(s) }
        // Consecutive units read as one figure: "twenty twenty six" → "2026",
        // "five five five one two one two" → "5551212".
        for sequence in [spoken, formatted] {
            for i in sequence.indices where isPureDigits(sequence[i]) {
                var accumulated = sequence[i]
                var j = i + 1
                while j < sequence.count, j - i < maxLicensedUnitRun, isPureDigits(sequence[j]) {
                    accumulated += sequence[j]
                    license.license(accumulated)
                    j += 1
                }
            }
        }
        // A spoken scale word licenses the scaled figure too, since the model may
        // write it out in full ("one point five million" → "1,500,000").
        var multipliers: [Double] = []
        let lower = raw.lowercased()
        if lower.contains("thousand") { multipliers.append(1_000) }
        if lower.contains("million") { multipliers.append(1_000_000) }
        if lower.contains("billion") { multipliers.append(1_000_000_000) }
        if !multipliers.isEmpty {
            let base = license.values
            for value in base {
                for m in multipliers { license.values.insert(value * m) }
            }
        }
        return license
    }

    private static func isPureDigits(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Drop a leading list marker ("1. ", "2) ") so a model that legitimately
    /// numbers a spoken list isn't accused of inventing the numbers. Only a
    /// marker followed by whitespace or end-of-line counts, so "1.99 is the
    /// price" keeps its figure under the guard.
    private static func droppingListMarker(_ line: Substring) -> Substring {
        var start = line.startIndex
        while start < line.endIndex, line[start].isWhitespace { start = line.index(after: start) }
        var end = start
        while end < line.endIndex, line[end].isASCII, line[end].isNumber { end = line.index(after: end) }
        guard end > start, end < line.endIndex, line[end] == "." || line[end] == ")" else { return line }
        let after = line.index(after: end)
        guard after == line.endIndex || line[after].isWhitespace else { return line }
        return line[after...]
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

    /// Remove `<think>…</think>`, `<thinking>…</thinking>`, and
    /// `<reasoning>…</reasoning>` blocks a reasoning-capable local model emits
    /// before its answer. Case-insensitive, spans newlines, and tolerates the
    /// closing tag being absent (an unterminated block runs to end-of-string).
    static func stripReasoningBlocks(_ s: String) -> String {
        var out = s
        for tag in ["think", "thinking", "reasoning"] {
            let pattern = "(?is)<\(tag)\\b[^>]*>.*?(</\(tag)>|$)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Unwrap a single fenced code block when the ENTIRE output is one — a
    /// ```` ```lang … ``` ```` wrapper the model adds around the transcript.
    /// Leaves inline back-ticks and partial fences alone (speaker content).
    static func stripCodeFence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```"), t.hasSuffix("```"), t.count > 6 else { return s }
        var body = String(t.dropFirst(3).dropLast(3))
        // Drop an opening language tag / the newline after the opening fence.
        if let nl = body.firstIndex(of: "\n") {
            let firstLine = body[body.startIndex..<nl].trimmingCharacters(in: .whitespaces)
            if !firstLine.contains(" "), firstLine.count < 16 { body = String(body[body.index(after: nl)...]) }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Known label prefixes the model prepends. Removed ONLY when the label is
    /// the start of the output (its own line or immediately before the text), so
    /// a legitimately-dictated "Output: 3.4V" is untouched unless the whole
    /// thing begins with a bare label token.
    private static let leadingLabels = [
        "cleaned transcript:", "cleaned text:", "cleaned:", "output:",
        "here is the cleaned transcript:", "here's the cleaned transcript:",
        "here is the cleaned text:", "corrected transcript:",
    ]

    /// Strip one recognized leading label (e.g. "Output:") plus the whitespace
    /// after it. Case-insensitive; only the known set above, so it can't eat
    /// real content that merely contains a colon.
    static func stripLeadingLabel(_ s: String) -> String {
        let lower = s.lowercased()
        for label in leadingLabels where lower.hasPrefix(label) {
            return String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
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
