import Foundation

/// The canonical cleanup instruction set (PRD §6.3 default behavior spec).
/// Shared verbatim by `LocalCleaner` and `OpenRouterCleaner` so tier switches
/// change the model, not the task.
public enum CleanupPrompt {
    /// System/instruction text for a cleanup request.
    public static func instructions(context: CleanupContext) -> String {
        var text = """
        You clean up dictated speech transcripts. Apply ONLY these repairs:
        - Remove filler words (um, uh, er, "you know", and "like"/"I mean" when meaningless).
        - Resolve self-corrections, keeping only the final intent: "meet Tuesday, wait no, Friday" becomes "meet Friday".
        - Collapse accidentally repeated words ("the the" becomes "the").
        - Add punctuation, inferring sentence type — statements get periods, questions get question marks.
        - Fix capitalization (sentence starts, "I", proper nouns).
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
