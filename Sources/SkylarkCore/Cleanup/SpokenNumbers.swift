import Foundation

/// Deterministic spoken-number → written/digit conversion for cleaned dictation
/// text. Small on-device LLMs are unreliable at this (they drop, invert, or
/// hallucinate digits), so a pure, testable pass owns it instead. The algorithm
/// (left-to-right run detection + a classic hundreds/scales accumulator) is a
/// clean-room reimplementation inspired by the *approach* nerd-dictation takes;
/// no GPL code was copied.
///
/// Design contract:
///   - **Pure & deterministic:** no I/O, no shared mutable state, no clock.
///   - **Idempotent:** `format(format(x)) == format(x)`. Text that is already in
///     digit form ("23", "$1.99", "99.9%") passes through untouched — the
///     converter only ever matches *spoken* number words, never digits.
///   - **Conservative:** when a run doesn't cleanly parse as a number, decimal,
///     currency, or percent, the words are left exactly as spoken. Surrounding
///     text, punctuation, capitalization, and spacing are preserved verbatim;
///     only the matched number words are rewritten.
///
/// Out of scope (left unchanged): ordinals ("third"), dates, times, and
/// alphanumeric fusion ("a ten g" → "A10G").
public enum SpokenNumbers {
    /// Convert spoken cardinal numbers, decimals, currency, and percent in
    /// `text` to written form. Pure, deterministic, and idempotent.
    public static func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let tokens = tokenize(text)

        // Project the word tokens (maximal letter runs) into a parse array,
        // recording each word's index in `tokens` and whether the gap separating
        // it from the previous word is a pure connector (whitespace and/or
        // hyphens) — the only thing that may sit *between* two words of one
        // spoken number. Any other separator (comma, period, digit, symbol)
        // breaks the run.
        var words: [(lower: String, tokenIndex: Int, connectorBefore: Bool)] = []
        for (ti, tok) in tokens.enumerated() where tok.isWord {
            let connector: Bool
            if let last = words.last {
                let between = tokens[(last.tokenIndex + 1) ..< ti]
                connector = !between.isEmpty && between.allSatisfy { isConnectorGap($0.text) }
            } else {
                connector = false
            }
            words.append((tok.text.lowercased(), ti, connector))
        }

        // Mutable copy of the raw token strings; number runs overwrite the first
        // token of the run with the rewritten value and blank the interior gaps.
        var output = tokens.map { $0.text }

        var wi = 0
        while wi < words.count {
            if isAnchor(words[wi].lower) {
                // The maximal connector-contiguous segment starting here — the
                // parser may look this far ahead but no further.
                var segEnd = wi
                while segEnd + 1 < words.count, words[segEnd + 1].connectorBefore {
                    segEnd += 1
                }
                let segment = words[wi ... segEnd].map { $0.lower }
                if let (consumed, replacement) = parseExpression(Array(segment)), consumed >= 1 {
                    let t0 = words[wi].tokenIndex
                    let t1 = words[wi + consumed - 1].tokenIndex
                    output[t0] = replacement
                    if t1 > t0 {
                        for t in (t0 + 1) ... t1 { output[t] = "" }
                    }
                    wi += consumed
                    continue
                }
            }
            wi += 1
        }

        return output.joined()
    }

    // MARK: - Tuning

    /// A STANDALONE cardinal word whose value is `<=` this is left as a word
    /// (prose carve-out): "I have three apples" stays "three apples". A number
    /// that is multi-word ("twenty three"), scaled ("one hundred"), decimal,
    /// currency, or percent always converts regardless. Tune here.
    private static let smallNumberMax = 10

    // MARK: - Expression parser

    /// Parse one number expression from the front of a connector-contiguous word
    /// segment. Returns the number of leading words consumed and their written
    /// replacement, or `nil` to leave the words unchanged (a bare small number,
    /// or no number at all).
    private static func parseExpression(_ w: [String]) -> (consumed: Int, replacement: String)? {
        guard let (intVal, cardinalWords) = parseCardinal(w, 0) else { return nil }
        var idx = cardinalWords
        var numberStr = String(intVal)
        var hasDecimal = false

        // Decimal: "point" followed by one or more single-digit words, each read
        // individually ("three point one four" → "3.14"). A "point" with no
        // digit word after it is left as prose (not consumed).
        if idx < w.count, w[idx] == "point" {
            var digits = ""
            var k = idx + 1
            while k < w.count, let d = singleDigit(w[k]) {
                digits += d
                k += 1
            }
            if !digits.isEmpty {
                numberStr += "." + digits
                idx = k
                hasDecimal = true
            }
        }

        // Percent modifier.
        if idx < w.count, w[idx] == "percent" {
            return (idx + 1, numberStr + "%")
        }

        // Currency modifier — only ever introduces "$" when "dollar"/"dollars"
        // is actually spoken.
        if idx < w.count, w[idx] == "dollar" || w[idx] == "dollars" {
            var result = "$" + numberStr
            var consumed = idx + 1
            // Optional "[and] <cardinal> cent[s]" tail, zero-padded to 2 digits.
            // Only for whole-dollar amounts (no decimal already present).
            if !hasDecimal {
                var k = consumed
                if k < w.count, w[k] == "and" { k += 1 }
                if let (centVal, centWords) = parseCardinal(w, k), centVal >= 0, centVal <= 99 {
                    let after = k + centWords
                    if after < w.count, w[after] == "cent" || w[after] == "cents" {
                        result = "$" + numberStr + "." + pad2(centVal)
                        consumed = after + 1
                    }
                }
            }
            return (consumed, result)
        }

        // No decimal and no modifier: honor the standalone-small-number carve-out
        // so ordinary prose ("three apples") is left alone. Multi-word / scaled /
        // larger values still convert.
        if !hasDecimal, cardinalWords == 1, intVal <= smallNumberMax {
            return nil
        }
        return (idx, numberStr)
    }

    /// Parse a cardinal integer (0…billions) from `w[start...]`. Returns the
    /// value and the word count consumed, or `nil` if `w[start]` doesn't begin a
    /// number. Tolerates "and" between a hundreds group and its remainder and
    /// between scale groups ("one hundred and five", "three thousand and five").
    private static func parseCardinal(_ w: [String], _ start: Int) -> (value: Int, consumed: Int)? {
        var idx = start
        var total = 0
        var any = false
        var lastRank = Int.max // scales must strictly descend (billion→million→thousand)

        while idx < w.count {
            guard let (grp, gc) = parseHundreds(w, idx) else { break }
            let j = idx + gc
            if j < w.count, let scale = scaleMap[w[j]] {
                if scale.rank >= lastRank { break }
                total += grp * scale.value
                lastRank = scale.rank
                idx = j + 1
                any = true
                if idx < w.count, w[idx] == "and", idx + 1 < w.count, isTwoDigitStart(w[idx + 1]) {
                    idx += 1 // swallow a connecting "and" before the next group
                }
            } else {
                total += grp
                idx = j
                any = true
                break
            }
        }
        return any ? (total, idx - start) : nil
    }

    /// Parse a value in 0…999 (`[1-99] "hundred" [["and"] 1-99]`, or a bare
    /// hundred, or a plain 0-99) from `w[start...]`.
    private static func parseHundreds(_ w: [String], _ start: Int) -> (value: Int, consumed: Int)? {
        // [1-99] "hundred" [...]
        if let (h, c) = parseTwoDigit(w, start), start + c < w.count, w[start + c] == "hundred" {
            return finishHundreds(w, hundredsValue: h * 100, afterHundred: start + c + 1, start: start)
        }
        // bare "hundred" → 100
        if w[start] == "hundred" {
            return finishHundreds(w, hundredsValue: 100, afterHundred: start + 1, start: start)
        }
        // plain 0-99
        if let (t, c) = parseTwoDigit(w, start) {
            return (t, c)
        }
        return nil
    }

    /// Shared tail for a hundreds group: optional connecting "and", then an
    /// optional trailing 0-99 remainder.
    private static func finishHundreds(_ w: [String], hundredsValue: Int, afterHundred: Int, start: Int) -> (value: Int, consumed: Int) {
        var value = hundredsValue
        var idx = afterHundred
        if idx < w.count, w[idx] == "and", idx + 1 < w.count, isTwoDigitStart(w[idx + 1]) {
            idx += 1
        }
        if let (t, c) = parseTwoDigit(w, idx) {
            value += t
            idx += c
        }
        return (value, idx - start)
    }

    /// Parse a value in 0…99: a single unit word (zero…nineteen) or a tens word
    /// (twenty…ninety) optionally followed by a unit 1-9.
    private static func parseTwoDigit(_ w: [String], _ start: Int) -> (value: Int, consumed: Int)? {
        guard start < w.count else { return nil }
        let word = w[start]
        if let tens = tensMap[word] {
            if start + 1 < w.count, let unit = unitsMap[w[start + 1]], unit >= 1, unit <= 9 {
                return (tens + unit, 2)
            }
            return (tens, 1)
        }
        if let unit = unitsMap[word] {
            return (unit, 1)
        }
        return nil
    }

    // MARK: - Word tables

    private static let unitsMap: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tensMap: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Scale words and their strictly-descending rank (used to reject nonsense
    /// like "thousand million").
    private static let scaleMap: [String: (value: Int, rank: Int)] = [
        "thousand": (1_000, 1),
        "million": (1_000_000, 2),
        "billion": (1_000_000_000, 3),
    ]

    /// A word may begin a spoken number only if it's a unit or a tens word;
    /// scale words ("hundred", "thousand") never anchor a run on their own.
    private static func isAnchor(_ word: String) -> Bool {
        unitsMap[word] != nil || tensMap[word] != nil
    }

    private static func isTwoDigitStart(_ word: String) -> Bool {
        unitsMap[word] != nil || tensMap[word] != nil
    }

    /// The single digit "0"…"9" for a unit word, else nil (used for reading
    /// post-"point" decimal digits individually).
    private static func singleDigit(_ word: String) -> String? {
        guard let v = unitsMap[word], v >= 0, v <= 9 else { return nil }
        return String(v)
    }

    // MARK: - Licensing (numeric-faithfulness guard)

    /// Every figure the *content* of `text` licenses, as digit strings, in the
    /// order they appear: one entry per spoken cardinal ("twenty three" → "23"),
    /// one per spoken ordinal ("fifth" → "5", "twenty first" → "21"), and one per
    /// digit literal already written in the text ("4521"). A run of number words
    /// contributes each unit it parses as, so "one dollar and ninety nine cents"
    /// yields ["1", "99"] — the pieces a cleanup may legitimately recombine into
    /// "$1.99".
    ///
    /// Read by `CleanupHygiene`'s numeric-faithfulness guard only, and
    /// deliberately GENEROUS (it ignores the connector-gap rule `format` obeys and
    /// treats ordinals as numbers): over-licensing merely lets an odd-but-honest
    /// formatting through, while under-licensing would throw a good cleanup away.
    /// `format` is untouched by any of this.
    static func licensedNumberStrings(in text: String) -> [String] {
        var out: [String] = []
        var run: [String] = []
        func flushWords() {
            guard !run.isEmpty else { return }
            out.append(contentsOf: numberStrings(inWordRun: run))
            run.removeAll(keepingCapacity: true)
        }
        for token in tokenize(text) {
            if token.isWord {
                run.append(token.text.lowercased())
            } else {
                let literals = digitLiterals(in: token.text)
                if !literals.isEmpty {
                    flushWords()
                    out.append(contentsOf: literals)
                } else if token.text.contains(where: { Self.clauseBreak.contains($0) }) {
                    // A sentence or clause boundary ends the number run, so
                    // "down to twenty. One item failed" licenses 20 and 1, never
                    // 21 — otherwise a hallucinated figure could be licensed by
                    // words that were never spoken together.
                    flushWords()
                }
            }
        }
        flushWords()
        return out
    }

    /// Punctuation that separates clauses for `licensedNumberStrings`. Commas
    /// are deliberately absent: STT occasionally drops one inside a spoken
    /// figure, and under-licensing throws a correct cleanup away.
    private static let clauseBreak: Set<Character> = [".", "?", "!", ";", ":", "\n"]

    /// The numeric literals written in `text`, as normalized digit strings:
    /// maximal digit runs, keeping a decimal point that sits between digits and
    /// dropping thousands commas ("$1,250.30." → ["1250.30"], "3:30" → ["3",
    /// "30"], "A10G" → ["10"], "v1.2.3" → ["1.2.3"]).
    static func digitLiterals(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var pendingDot = false
        for ch in text {
            if ch.isASCII, ch.isNumber {
                if pendingDot { current.append("."); pendingDot = false }
                current.append(ch)
            } else if ch == ",", !current.isEmpty, !pendingDot {
                continue // thousands separator between digits: join across it
            } else if ch == ".", !current.isEmpty, !pendingDot {
                pendingDot = true // decimal point, but only if a digit follows
            } else {
                if !current.isEmpty { out.append(current); current = "" }
                pendingDot = false
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Parse a whole run of words left to right, emitting one digit string per
    /// number (cardinal or ordinal) found and skipping everything else.
    private static func numberStrings(inWordRun words: [String]) -> [String] {
        var out: [String] = []
        var k = 0
        while k < words.count {
            // Ordinals first, so "twenty first" reads as 21 rather than 20 + 1.
            if let (value, consumed) = parseOrdinal(words, k), consumed > 0 {
                out.append(String(value))
                k += consumed
            } else if let (value, consumed) = parseCardinal(words, k), consumed > 0 {
                out.append(String(value))
                k += consumed
            } else {
                k += 1
            }
        }
        return out
    }

    /// Parse a spoken ordinal ("third", "twenty first") from `w[start...]`.
    private static func parseOrdinal(_ w: [String], _ start: Int) -> (value: Int, consumed: Int)? {
        guard start < w.count else { return nil }
        if let tens = tensMap[w[start]], start + 1 < w.count,
           let unit = ordinalsMap[w[start + 1]], unit >= 1, unit <= 9 {
            return (tens + unit, 2)
        }
        if let value = ordinalsMap[w[start]] { return (value, 1) }
        return nil
    }

    /// Spoken ordinals. Licensing-only: `format` never rewrites an ordinal.
    private static let ordinalsMap: [String: Int] = [
        "zeroth": 0, "first": 1, "second": 2, "third": 3, "fourth": 4,
        "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
        "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17,
        "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
        "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
        "eightieth": 80, "ninetieth": 90, "hundredth": 100, "thousandth": 1_000,
    ]

    // MARK: - Tokenization helpers

    /// Split into maximal runs of letters (words) alternating with maximal runs
    /// of non-letters (gaps), preserving every character so the pieces rejoin
    /// into the exact original outside the rewritten runs.
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

    /// A gap that may sit between two words of a single spoken number: only
    /// whitespace and/or hyphens ("twenty-three" is one number). Anything else
    /// (comma, period, digit, symbol) ends the run.
    private static func isConnectorGap(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isWhitespace || $0 == "-" }
    }

    private static func pad2(_ n: Int) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }
}
