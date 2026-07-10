import Foundation

/// The canonical cleanup instruction set (PRD §6.3 default behavior spec).
/// Shared verbatim by `LocalCleaner` and `OpenRouterCleaner` so tier switches
/// change the model, not the task.
public enum CleanupPrompt {
    /// System/instruction text for a cleanup request.
    public static func instructions(context: CleanupContext) -> String {
        var text = """
        You clean up dictated speech transcripts. Apply ONLY these repairs:
        - Remove filler words (um, uh, er, "you know", and "like" when meaningless).
        - Resolve self-corrections, keeping ONLY the corrected version and deleting the abandoned words. Phrases like "I mean", "actually", "no wait", "sorry", "rather", or "scratch that" right after a word or phrase signal the speaker is replacing it:
          "I want to restructure uh I mean refactor the code" → "I want to refactor the code"
          "meet Tuesday, wait no, Friday" → "meet Friday"
          "send it to Bob, actually Alice" → "send it to Alice"
        - Collapse accidentally repeated words ("the the" becomes "the").
        - Add punctuation, inferring sentence type — statements get periods, questions get question marks.
        - Fix capitalization (sentence starts, "I", proper nouns).
        - Apply spoken layout commands, deleting the command words: "new line" → a line break, "new paragraph" → a blank line.
        - When the speaker clearly dictates a list — they announce one ("here is a list", "three items") or enumerate parallel items ("one, … two, … three, …", "first… second…", "bullet point …") — format it as a list: keep any intro sentence ending with a colon, then each item on its own line ("1. " numbering for spoken numbers, "- " for bullets), capitalized:
          "Here is a list of three items. One, bananas. Two, apples. Three, lemons" →
          "Here is a list of three items:
          1. Bananas
          2. Apples
          3. Lemons"
          Numbers inside an ordinary sentence are NOT a list ("I ate one banana and two apples" stays a sentence).
        Preserve the speaker's wording otherwise. Do not paraphrase, summarize, expand, or add content. Keep technical terms, names, numbers, and profanity exactly as spoken.
        Output ONLY the cleaned text — no commentary, no quotation marks around it.
        """
        if !context.dictionaryTerms.isEmpty {
            text += "\nPrefer these exact spellings when the transcript approximates them: "
                + context.dictionaryTerms.joined(separator: ", ") + "."
        }
        if let register = context.registerHint, !register.isEmpty {
            text += "\nLightly match this register without rewriting content: \(register)."
        }
        return text
    }

    /// User-message wrapper for the transcript.
    public static func userMessage(transcript: String) -> String {
        "Transcript:\n\(transcript)"
    }
}
