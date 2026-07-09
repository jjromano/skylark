import Foundation

/// Detects and strips a terminal spoken "press enter" / "press return" command
/// from a finished transcript so the app layer can synthesize a Return keystroke
/// after injecting the remaining text.
///
/// Pure and stateless: all logic lives in `strip`, exercised by unit tests. The
/// command only fires when it is the *last* thing said — "press enter to
/// continue" (mid-text) and "press enter please" (non-terminal) are untouched.
public enum PressEnterCommand {
    /// Spoken forms that mean "hit Return". Compared case-insensitively.
    private static let commands = ["press enter", "press return"]

    /// Trailing characters the cleanup model may append after the command
    /// (punctuation it adds, plus whitespace). Trimmed before matching so
    /// "Press enter." still counts as the command.
    private static let trailingTrim: Set<Character> = [" ", "\t", "\n", "\r", ".", "!", "?", ","]

    /// Split a transcript into the text to inject and whether a Return should
    /// follow. When no terminal command is present the text is returned verbatim
    /// with `pressEnter == false`.
    ///
    /// - The command must sit at the very end (after trimming trailing
    ///   punctuation/whitespace). A word boundary is required before it so
    ///   "express enter" is not mistaken for "…press enter".
    /// - The command plus any orphaned whitespace immediately before it is
    ///   removed; a sentence boundary like ". " keeps its period with the
    ///   remaining text ("Ship it. Press enter." → "Ship it.").
    /// - If the whole utterance is only the command, the text is empty and the
    ///   app layer presses Return without injecting anything.
    public static func strip(_ text: String) -> (text: String, pressEnter: Bool) {
        let chars = Array(text)

        // Trim trailing whitespace/punctuation that cleanup may have appended
        // after the spoken command.
        var coreEnd = chars.count
        while coreEnd > 0, trailingTrim.contains(chars[coreEnd - 1]) {
            coreEnd -= 1
        }

        for command in commands {
            let cmd = Array(command)
            guard coreEnd >= cmd.count else { continue }
            let start = coreEnd - cmd.count

            // Compare the trailing run case-insensitively against the command.
            let suffix = String(chars[start..<coreEnd]).lowercased()
            guard suffix == command else { continue }

            // Whole (trimmed) utterance is the command → inject nothing, press Return.
            if start == 0 {
                return ("", true)
            }

            // Require a word boundary before the command so we don't slice a word
            // (e.g. "express enter", "reenter"). The preceding char must not be
            // alphanumeric.
            let boundary = chars[start - 1]
            guard !boundary.isLetter, !boundary.isNumber else { continue }

            // Drop the command plus any orphaned whitespace separator right before
            // it. A non-whitespace boundary (".", ",") stays with the text.
            var keepEnd = start
            while keepEnd > 0, chars[keepEnd - 1].isWhitespace {
                keepEnd -= 1
            }
            return (String(chars[0..<keepEnd]), true)
        }

        return (text, false)
    }
}
