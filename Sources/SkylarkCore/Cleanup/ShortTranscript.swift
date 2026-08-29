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

    /// True when `text` is short enough to skip the cleanup model. Empty text is
    /// NOT "short" — it is handled upstream (nothing is inserted at all).
    public static func isShort(_ text: String) -> Bool {
        let count = wordCount(text)
        return count > 0 && count < wordThreshold
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
