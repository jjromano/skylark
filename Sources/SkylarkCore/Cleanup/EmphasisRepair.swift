import Foundation

/// Repairs the *emphasis* a cleanup model invents when the speaker stresses a
/// word. Stress is audible, not written: the model hears "this is **great**"
/// and renders the stress as an exclamation mark, ALL-CAPS, or markdown bold —
/// none of which the speaker dictated, and all of which change the register of
/// what gets pasted ("Ship it!" reads very differently from "Ship it.").
///
/// Design contract:
///   - **Repair, never reject.** Throwing away an otherwise-good cleanup over a
///     single `!` is worse than the mark. This pass runs *after* every
///     `CleanupHygiene` guard has already passed and only ever edits
///     punctuation and letter case.
///   - **Pure & deterministic:** no I/O, no shared state, no clock. Returns the
///     input unchanged (byte-identical) when no rule fires.
///   - **Never touches words.** No token is added, removed, reordered, or
///     respelled; only `!`/`?` marks, markdown emphasis markers, and the case
///     of letters already present can change.
///
/// The four rules run in this order (`repair` is the only entry point):
///   1. Strip markdown emphasis markers the raw doesn't have.
///   2. Collapse `!!` / `?!` / `!?` / `!!!` runs the raw doesn't have.
///   3. Cap the number of `!` at what the raw licenses.
///   4. Revert shouted ALL-CAPS words to the raw's casing.
public enum EmphasisRepair {
    /// Repair invented emphasis in `cleaned`, using `raw` (the speech-to-text
    /// transcript) as the authority for what the speaker actually dictated.
    public static func repair(_ cleaned: String, raw: String) -> String {
        let stripped = stripEmphasisMarkers(cleaned, raw: raw)
        let collapsed = collapseMarkRuns(stripped, raw: raw)
        let capped = capExclamations(collapsed, raw: raw)

        // The ALL-CAPS revert (rule 4) fires ONLY when one of the punctuation
        // rules already found invented emphasis in this output. Skylark's
        // recogniser emits an all-lowercase transcript ("i finished the api
        // then i deployed it"), so the raw's casing on its own cannot tell an
        // emphasized word ("GREAT") from an acronym the cleanup model correctly
        // uppercased ("API", "GPU") — both come from a lowercase raw token.
        // Requiring corroborating evidence (a downgraded `!`, a collapsed run,
        // or a stripped `**`) is what keeps the pass from lowercasing correct
        // acronyms in ordinary, unemphatic output. See `initialisms` for the
        // second line of defence.
        guard capped != cleaned else { return cleaned }
        return revertShouting(capped, raw: raw)
    }

    // MARK: - Rule 1: markdown emphasis markers

    /// Remove `**` / `__` emphasis markers when the raw contains none of that
    /// marker. Matched pairs and a lone unmatched marker are both removed (the
    /// model routinely opens a bold run and never closes it). An occurrence
    /// sitting *between* two alphanumerics is left alone, so removing it can
    /// never fuse two words into one (`snake__case` survives).
    static func stripEmphasisMarkers(_ text: String, raw: String) -> String {
        var out = text
        for marker in ["**", "__"] where !raw.contains(marker) && out.contains(marker) {
            out = removeMarker(marker, from: out)
        }
        return out
    }

    private static func removeMarker(_ marker: String, from text: String) -> String {
        let needle = Array(marker)
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if i + needle.count <= chars.count, Array(chars[i ..< i + needle.count]) == needle {
                let before = out.last
                let after = i + needle.count < chars.count ? chars[i + needle.count] : nil
                let wouldFuseWords = isAlphanumeric(before) && isAlphanumeric(after)
                if !wouldFuseWords {
                    i += needle.count
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }

    private static func isAlphanumeric(_ c: Character?) -> Bool {
        guard let c else { return false }
        return c.isLetter || c.isNumber
    }

    // MARK: - Rule 2: collapse mark runs

    /// Collapse a run of two or more `!`/`?` to a single mark, unless the raw
    /// contains that exact run (a speaker who dictated "!!" keeps it). A mixed
    /// run collapses to `?`: the question mark carries grammar, the `!` is the
    /// emphasis the model added ("what?!" → "what?").
    ///
    /// Runs collapse BEFORE the exclamation cap so the cap counts sentences,
    /// not marks — "Wow!! Great!!" costs two units of budget, not four.
    static func collapseMarkRuns(_ text: String, raw: String) -> String {
        guard text.contains("!") || text.contains("?") else { return text }
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            guard isMark(chars[i]) else {
                out.append(chars[i])
                i += 1
                continue
            }
            var j = i
            while j < chars.count, isMark(chars[j]) { j += 1 }
            let run = Array(chars[i ..< j])
            if run.count >= 2, !raw.contains(String(run)) {
                out.append(run.contains("?") ? "?" : "!")
            } else {
                out.append(contentsOf: run)
            }
            i = j
        }
        return String(out)
    }

    private static func isMark(_ c: Character) -> Bool { c == "!" || c == "?" }

    // MARK: - Rule 3: exclamation cap

    /// Downgrade `!` to `.` beyond the budget the raw licenses: the number of
    /// `!` the recogniser itself emitted, plus one per spoken exclamation
    /// command ("exclamation mark" / "exclamation point", which the model turns
    /// into a real mark — a legitimate conversion, not invented emphasis).
    ///
    /// **Which marks survive:** the earliest ones, left to right. Cleanup
    /// preserves word order, so the correspondence between raw and cleaned
    /// positions is monotone — the raw's first licensed mark lines up with the
    /// cleaned text's first mark. Keeping the earliest is therefore the
    /// positionally-aligned choice as well as the deterministic one (it does
    /// not depend on the length of the text or on where later edits land).
    static func capExclamations(_ text: String, raw: String) -> String {
        guard text.contains("!") else { return text }
        let budget = raw.filter { $0 == "!" }.count + spokenExclamationCount(in: raw)
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var kept = 0
        for (i, c) in chars.enumerated() {
            guard c == "!" else {
                out.append(c)
                continue
            }
            if kept < budget {
                kept += 1
                out.append(c)
            } else if i + 1 < chars.count, chars[i + 1] == "." {
                // A period already terminates here; dropping avoids an "!." pair.
                continue
            } else {
                out.append(".")
            }
        }
        return String(out)
    }

    /// Occurrences of a spoken exclamation command in the raw transcript. Each
    /// one licenses one `!` in the cleaned text.
    static func spokenExclamationCount(in raw: String) -> Int {
        let lower = raw.lowercased()
        var count = 0
        for phrase in ["exclamation mark", "exclamation point"] {
            var searchStart = lower.startIndex
            while let found = lower.range(of: phrase, range: searchStart ..< lower.endIndex) {
                count += 1
                searchStart = found.upperBound
            }
        }
        return count
    }

    // MARK: - Rule 4: ALL-CAPS revert

    /// Common initialisms, exempt from the revert. A cleanup model uppercasing
    /// one of these from a lowercase raw token ("api" → "API") is *correcting*
    /// the recogniser, not shouting, and lowercasing it back would be a visible
    /// corruption of good output. Stored uppercased, matched on the token's
    /// letters/digits only.
    private static let initialisms: Set<String> = [
        "API", "SQL", "GPU", "CPU", "RAM", "SSD", "URL", "URI", "HTTP", "HTTPS",
        "JSON", "XML", "HTML", "CSS", "JS", "TS", "SDK", "CLI", "GUI", "UI",
        "UX", "AI", "ML", "LLM", "NLP", "OCR", "PR", "CI", "CD", "QA", "DB",
        "ORM", "CRUD", "REST", "GRPC", "AWS", "GCP", "DNS", "SSH", "TLS", "SSL",
        "VPN", "JWT", "ID", "IDE", "OS", "PDF", "CSV", "TSV", "USB", "MVP",
        "KPI", "ROI", "ETA", "FAQ", "EOD", "SLA", "SLO", "NDA", "HR", "CEO",
        "CTO", "CFO", "COO", "VP", "PTO", "RFC", "TODO", "FYI", "ASAP", "IMO",
        "GDP", "USA", "UK", "EU", "US", "TV", "PC", "IOS", "MRI", "CRM", "SEO",
    ]

    /// Revert a shouted token (2+ letters, every letter uppercase) to the
    /// casing the raw used for that same word — the raw's FIRST occurrence.
    /// A token the raw itself has in caps is untouched (the recogniser emitted
    /// the acronym), as is a token absent from the raw entirely and any known
    /// initialism.
    static func revertShouting(_ text: String, raw: String) -> String {
        var chars = Array(text)
        let candidates = wordTokens(chars).filter {
            isShouted($0.chars) && !initialisms.contains(normalizedKey($0.chars).uppercased())
        }
        guard !candidates.isEmpty else { return text }

        var rawCasing: [String: [Character]] = [:]
        for token in wordTokens(Array(raw)) {
            let key = normalizedKey(token.chars)
            if !key.isEmpty, rawCasing[key] == nil { rawCasing[key] = token.chars }
        }

        var changed = false
        for token in candidates {
            guard let source = rawCasing[normalizedKey(token.chars)], !isShouted(source) else { continue }
            var replacement = applyCasing(of: source, to: token.chars)
            // The raw carries no internal capitals to respect, and the word
            // opens a sentence in the cleaned text: keep the sentence capital
            // rather than pasting a lowercase sentence start. (Skipped when the
            // raw has internal capitals — "iPhone" must stay "iPhone".)
            if isAllLowercase(source), startsSentence(at: token.start, in: chars),
               let first = replacement.firstIndex(where: { $0.isLetter }) {
                let upper = String(replacement[first]).uppercased()
                if upper.count == 1 { replacement[first] = Character(upper) }
            }
            guard replacement.count == token.chars.count, replacement != token.chars else { continue }
            for (offset, c) in replacement.enumerated() { chars[token.start + offset] = c }
            changed = true
        }
        return changed ? String(chars) : text
    }

    private struct WordToken {
        let chars: [Character]
        let start: Int
    }

    /// Maximal runs of letters, digits, and apostrophes, so a contraction
    /// ("DON'T") stays one token instead of splitting into "DON" + "T".
    private static func wordTokens(_ chars: [Character]) -> [WordToken] {
        var out: [WordToken] = []
        var i = 0
        while i < chars.count {
            guard isWordCharacter(chars[i]) else {
                i += 1
                continue
            }
            var j = i
            while j < chars.count, isWordCharacter(chars[j]) { j += 1 }
            out.append(WordToken(chars: Array(chars[i ..< j]), start: i))
            i = j
        }
        return out
    }

    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}"
    }

    /// Letters/digits only, lowercased — the identity of a word across the two
    /// texts, ignoring case and whichever apostrophe glyph each side used.
    private static func normalizedKey(_ token: [Character]) -> String {
        String(token.filter { $0.isLetter || $0.isNumber }).lowercased()
    }

    /// 2+ letters, all of them uppercase. A single capital ("Sarah") is a
    /// proper noun, not shouting; a case-less script is never shouting.
    private static func isShouted(_ token: [Character]) -> Bool {
        var letters = 0
        for c in token where c.isLetter {
            guard c.isUppercase else { return false }
            letters += 1
        }
        return letters >= 2
    }

    private static func isAllLowercase(_ token: [Character]) -> Bool {
        var sawLetter = false
        for c in token where c.isLetter {
            guard c.isLowercase else { return false }
            sawLetter = true
        }
        return sawLetter
    }

    /// Copy `source`'s per-letter casing onto `token`'s letters, in order. The
    /// two tokens have the same letters/digits by construction (equal keys), so
    /// this only ever changes case — `token`'s own digits and apostrophes are
    /// kept, and length is preserved.
    private static func applyCasing(of source: [Character], to token: [Character]) -> [Character] {
        var sourceLetters = source.filter { $0.isLetter }.makeIterator()
        var out: [Character] = []
        out.reserveCapacity(token.count)
        for c in token {
            guard c.isLetter, let s = sourceLetters.next() else {
                out.append(c)
                continue
            }
            let mapped = s.isUppercase ? String(c).uppercased() : String(c).lowercased()
            out.append(mapped.count == 1 ? Character(mapped) : c)
        }
        return out
    }

    /// True when nothing but whitespace and opening punctuation separates
    /// `index` from the start of the text or from a sentence terminator.
    private static func startsSentence(at index: Int, in chars: [Character]) -> Bool {
        var i = index - 1
        while i >= 0 {
            let c = chars[i]
            if c.isWhitespace || "\"'([{*_\u{201C}\u{2018}".contains(c) {
                i -= 1
                continue
            }
            return ".!?:;".contains(c)
        }
        return true
    }
}
