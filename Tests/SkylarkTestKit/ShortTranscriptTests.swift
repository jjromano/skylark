import Testing
import SkylarkCore

/// WS7 — a one- or two-word utterance skips the cleanup model entirely. The
/// deterministic result has to be exactly what cleanup would legitimately have
/// done: capitalise the opening letter, terminate the sentence, change nothing
/// else.
@Suite("ShortTranscript — deterministic cleanup skip")
struct ShortTranscriptTests {
    @Test("One and two word transcripts are short; three is not")
    func threshold() {
        #expect(ShortTranscript.isShort("yes"))
        #expect(ShortTranscript.isShort("ok thanks"))
        #expect(!ShortTranscript.isShort("yes ship it"))
        #expect(!ShortTranscript.isShort("Skylark stub: end-to-end pipeline works."))
    }

    @Test("Empty and whitespace-only input is not 'short' — nothing is cleaned")
    func emptyIsNotShort() {
        #expect(!ShortTranscript.isShort(""))
        #expect(!ShortTranscript.isShort("   "))
    }

    @Test("Formatting capitalises and terminates")
    func formatting() {
        #expect(ShortTranscript.format("yes") == "Yes.")
        #expect(ShortTranscript.format("ok thanks") == "Ok thanks.")
        #expect(ShortTranscript.format("really?") == "Really?")
        #expect(ShortTranscript.format("Ship it!") == "Ship it!")
        #expect(ShortTranscript.format("done.") == "Done.")
    }

    @Test("Whitespace-only input is returned untouched")
    func whitespaceUntouched() {
        #expect(ShortTranscript.format("  ") == "  ")
        #expect(ShortTranscript.format("") == "")
    }

    @Test("Surrounding whitespace is trimmed, inner text is not rewritten")
    func trimming() {
        #expect(ShortTranscript.format("  yes  ") == "Yes.")
        #expect(ShortTranscript.format("API") == "API.")
    }

    @Test("The engine label is stable for history and diagnostics")
    func engineLabel() {
        #expect(ShortTranscript.engineLabel == "short")
    }
}
