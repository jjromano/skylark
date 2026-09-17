import Foundation
import NaturalLanguage

/// Deterministic leading-case fit for dictating into the middle of a sentence
/// (context-aware cleanup). The recognizer capitalizes every utterance as if it
/// starts a sentence, and the cleanup prompt's "continue in lowercase" rule is
/// not enough on its own: a model that returns the transcript unchanged, the
/// short-transcript bypass and the raw tier all paste that capital as-is. This
/// runs on the text about to be written, so every path gets the same answer.
///
/// Only the FIRST word is ever touched, and only when the on-screen text before
/// the caret ends mid-sentence. A capital that is genuine is kept: "I" and its
/// contractions, acronyms and mixed-case words, dictionary terms, a word the
/// surrounding text already capitalizes mid-sentence, and anything Apple's
/// on-device name tagger reads as a person, place or organization.
///
/// Pure, local, never logs text. Sub-millisecond once `warmUp()` has loaded the
/// tagger model (~80 ms cold), so it is safe on the paste path.
public enum ContinuationCasing {
    /// Load the name-tagger model off the paste path (first use is ~80 ms).
    public static func warmUp() {
        _ = namedEntity(preceding: "we met", text: "Sam today")
    }

    /// `text` with its first letter lowercased when it continues the sentence
    /// that `context.preceding` leaves open; otherwise `text` unchanged.
    public static func apply(_ text: String, context: FieldContext?, protectedTerms: [String] = []) -> String {
        guard let context, continuesSentence(context.preceding) else { return text }
        guard let first = text.first, first.isUppercase else { return text }

        let word = String(text.prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}" || $0 == "-" })
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return text }
        // A lone capital other than the article "A" is a label ("X", "B"), not a word.
        if letters.count == 1, letters != "A" { return text }
        // "I"/"I'm" and all-caps acronyms.
        if LocalCleaner.preservesContinuationCase(word) { return text }
        // Mixed case after the first letter ("GitHub", "McDonald").
        if word.dropFirst().contains(where: \.isUppercase) { return text }
        if isProtectedTerm(word, protectedTerms) { return text }
        // Nouns are capitalized mid-sentence in German; lowercasing would be wrong.
        if NLLanguageRecognizer.dominantLanguage(for: text) == .german { return text }
        let rest = String(text.dropFirst(word.count))
        if capitalizedMidSentence(word, in: context.preceding)
            || capitalizedMidSentence(word, in: context.following)
            || capitalizedMidSentence(word, in: rest) {
            return text
        }
        if namedEntity(preceding: context.preceding, text: text) { return text }

        return first.lowercased() + text.dropFirst()
    }

    /// True when the text before the caret leaves a sentence open: it ends
    /// (ignoring trailing spaces) in a letter, digit, or joining punctuation.
    /// Empty text, a line break, and sentence or clause enders (. ! ? … :) all
    /// mean the dictation starts fresh, so its capital stands.
    public static func continuesSentence(_ preceding: String) -> Bool {
        guard let last = preceding.last(where: { !($0 == " " || $0 == "\t" || $0 == "\u{00A0}") }) else {
            return false
        }
        if last.isLetter || last.isNumber { return true }
        return [",", ";", "-", "\u{2013}", "\u{2014}", "(", "&", "/"].contains(last)
    }

    private static func isProtectedTerm(_ word: String, _ terms: [String]) -> Bool {
        terms.contains { term in
            let head = term.prefix { !$0.isWhitespace }
            return head == word || (head.first?.isUppercase == true && head.lowercased() == word.lowercased())
        }
    }

    /// True when `word`, spelled exactly (case-sensitive, whole word), appears
    /// in `text` somewhere that is not the start of a sentence.
    private static func capitalizedMidSentence(_ word: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: word, range: searchStart..<text.endIndex) {
            searchStart = range.upperBound
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if let before, before.isLetter || before.isNumber { continue }
            if let after, after.isLetter || after.isNumber { continue }
            let prior = text[..<range.lowerBound].last { !$0.isWhitespace && !"\"'\u{201C}\u{2018}(".contains($0) }
            guard let prior else { continue }
            if prior.isNewline || ".!?\u{2026}:".contains(prior) { continue }
            return true
        }
        return false
    }

    /// Tag the first word of `text` in its on-screen position (after the tail
    /// of `preceding`), so the tagger sees a mid-sentence capital as it will read.
    private static func namedEntity(preceding: String, text: String) -> Bool {
        let tail = String(preceding.suffix(200)).trimmingCharacters(in: .whitespaces)
        let joined = tail.isEmpty ? String(text.prefix(200)) : tail + " " + String(text.prefix(200))
        let offset = tail.isEmpty ? 0 : tail.count + 1
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = joined
        let index = joined.index(joined.startIndex, offsetBy: offset)
        let (tag, _) = tagger.tag(at: index, unit: .word, scheme: .nameType)
        return tag == .personalName || tag == .placeName || tag == .organizationName
    }
}
