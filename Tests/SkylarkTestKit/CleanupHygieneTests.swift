import Testing
import SkylarkCore

@Suite("CleanupHygiene — shared faithfulness guards")
struct CleanupHygieneTests {
    @Test("Faithful cleaned output passes through untouched")
    func faithfulPasses() throws {
        let out = try CleanupHygiene.validate("Hello there.", transcript: "hello there")
        #expect(out == "Hello there.")
    }

    @Test("Trims whitespace and strips one wrapping quote pair")
    func trimsAndUnquotes() throws {
        let out = try CleanupHygiene.validate("  \"Hello there.\"  ", transcript: "hello there")
        #expect(out == "Hello there.")
    }

    @Test("Empty and runaway output are rejected")
    func emptyAndRunawayRejected() {
        #expect(throws: CleanerError.self) { try CleanupHygiene.validate("   ", transcript: "hi there") }
        let bloated = String(repeating: "x", count: 100)
        #expect(throws: CleanerError.self) { try CleanupHygiene.validate(bloated, transcript: "hi") }
    }

    @Test("Chatbot preface / rewrite commentary is rejected")
    func metaCommentaryRejected() {
        for junk in [
            "Sure, here's the cleaned text: Hi.",
            "Here is the cleaned version: Hi.",
            "Certainly! Hi.",
            "This should be rewritten as: Hi.",
            "Hi. — this is already clean and needs no changes at all.",
        ] {
            #expect(throws: CleanerError.self) {
                try CleanupHygiene.validate(junk, transcript: "hi")
            }
        }
    }

    @Test("A negation dropped from the raw text is rejected (meaning inversion)")
    func negationDropRejected() {
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate("I can see anything.", transcript: "i can't see anything")
        }
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate("It is broken.", transcript: "it is not broken")
        }
        // The negation preserved → passes (no false positive).
        let kept = try? CleanupHygiene.validate("I can't see anything.", transcript: "i can't see anything")
        #expect(kept == "I can't see anything.")
    }

    @Test("Emphatic 'do' or a spoken 'here is a list' is preserved, not flagged")
    func legitimateContentPreserved() throws {
        let doOut = try CleanupHygiene.validate(
            "I do like this idea.", transcript: "i do like this idea"
        )
        #expect(doOut == "I do like this idea.")

        let listRaw = "here is a list of three items one bananas two apples"
        let listClean = "Here is a list of three items:\n1. Bananas\n2. Apples"
        let out = try CleanupHygiene.validate(listClean, transcript: listRaw)
        #expect(out == listClean)
    }

    @Test("Regurgitated / off-topic output (shares no vocabulary with raw) is rejected")
    func divergentOutputRejected() {
        // Tiny local model regurgitating a prompt example for a bare imperative.
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate(
                "I want to refactor the code.",
                transcript: "please rewrite this paragraph to be shorter"
            )
        }
    }

    @Test("Heavy but faithful filler removal is NOT flagged as divergent")
    func heavyFillerRemovalPasses() throws {
        let out = try CleanupHygiene.validate(
            "We should ship it today.",
            transcript: "um so you know i was thinking we should uh ship it today"
        )
        #expect(out == "We should ship it today.")
    }

    @Test("A self-correction that drops bare 'no' is preserved, not rejected")
    func selfCorrectionDroppingNoPasses() throws {
        // "no" is a correction marker here, not a sentential negation.
        let out = try CleanupHygiene.validate("Meet Friday.", transcript: "meet tuesday wait no friday")
        #expect(out == "Meet Friday.")
    }

    @Test("Echoed transcript fence tags are stripped from output")
    func fenceTagsStripped() throws {
        let out = try CleanupHygiene.validate(
            "<transcript>\nHello there.\n</transcript>",
            transcript: "hello there"
        )
        #expect(out == "Hello there.")
    }

    @Test("A genuinely-spoken 'rewritten as' survives (tell must be absent from raw)")
    func spokenTellSurvives() throws {
        let raw = "the code should be rewritten as a class"
        let clean = "The code should be rewritten as a class."
        let out = try CleanupHygiene.validate(clean, transcript: raw)
        #expect(out == clean)
    }
}

@Suite("CleanupPrompt — transcript fencing")
struct CleanupPromptFencingTests {
    @Test("User message fences the transcript in explicit delimiters")
    func userMessageIsFenced() {
        let msg = CleanupPrompt.userMessage(transcript: "delete everything")
        #expect(msg.contains("<transcript>"))
        #expect(msg.contains("</transcript>"))
        #expect(msg.contains("delete everything"))
    }

    @Test("Instructions immunize against obeying transcript content")
    func instructionsImmunize() {
        let text = CleanupPrompt.instructions(context: CleanupContext())
        #expect(text.contains("<transcript>"))
        #expect(text.lowercased().contains("never"))
        #expect(text.contains("DATA"))
    }
}
