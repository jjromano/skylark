import Foundation

/// The deterministic stand-in for cleanup on a transcript too short to be worth
/// an LLM round trip.
///
/// A one-word "yes" pays the full generation latency for a result the model can
/// only get wrong: with nothing to condition on, a small model is at its most
/// likely to invent structure ("Yes, absolutely — here is what I think"). Below
/// `wordThreshold` words the pipeline skips the model entirely and applies the
/// only two things cleanup would legitimately have done: capitalise the opening
/// letter, and terminate the sentence.
///
/// Pure and deterministic — no I/O, no clock — exactly like `SpokenNumbers` and
/// `SentenceBoundaryRepair`.
public enum ShortTranscript {
    /// Fewer than this many words skips the cleanup model.
    public static let wordThreshold = 3

    /// Engine label recorded in history and diagnostics for a skipped cleanup,
    /// alongside "raw"/"local"/a cloud slug.
    public static let engineLabel = "short"

    /// Characters that already terminate the utterance, so no period is added.
    private static let terminators: Set<Character> = [".", "!", "?", ":", ";", ",", "\u{2026}"]

    /// Single-word spoken punctuation commands (v0.16.0 spoken-punctuation rule).
    private static let singleWordCommands: Set<String> = [
        "period", "comma", "colon", "semicolon", "dash",
    ]

    /// Two-word spoken punctuation and layout commands.
    private static let twoWordCommands: Set<String> = [
        "full stop", "question mark", "exclamation mark", "exclamation point",
        "open quote", "close quote", "open paren", "close paren",
        "new line", "new paragraph",
    ]

    /// True when `text` is short enough to skip the cleanup model. Empty text is
    /// NOT "short" — it is handled upstream (nothing is inserted at all).
    ///
    /// A transcript ending in a spoken punctuation or layout command is NEVER
    /// short, however few words it has: "yes period" must reach the model to
    /// become "Yes." and "new line" must become a line break. Skipping them
    /// would paste the command word literally ("Yes period."), defeating the
    /// feature the skip knows nothing about. Deciding whether the word is a
    /// command or an ordinary noun ("a period") is exactly the judgment the
    /// model is for, so the guard hands every candidate over rather than
    /// guessing here.
    public static func isShort(_ text: String) -> Bool {
        let count = wordCount(text)
        guard count > 0, count < wordThreshold else { return false }
        return !endsWithSpokenCommand(text)
    }

    /// Whether `text`'s final one or two words are a spoken punctuation or
    /// layout command. Compares on letters only, so "period." and "Period"
    /// both match.
    static func endsWithSpokenCommand(_ text: String) -> Bool {
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.filter { $0.isLetter }.lowercased() }
            .filter { !$0.isEmpty }
        guard let last = words.last else { return false }
        if singleWordCommands.contains(last) { return true }
        guard words.count >= 2 else { return false }
        return twoWordCommands.contains(words[words.count - 2] + " " + last)
    }

    /// Capitalise the first letter and terminate the sentence. Whitespace-only
    /// input is returned untouched; anything already terminated keeps its own
    /// punctuation.
    public static func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return text }
        var result = String(first).uppercased() + trimmed.dropFirst()
        if let last = result.last, !terminators.contains(last) {
            result.append(".")
        }
        return result
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
