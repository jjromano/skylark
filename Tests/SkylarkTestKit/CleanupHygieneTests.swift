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

@Suite("CleanupPrompt — compact local prompt")
struct CompactPromptTests {
    @Test("Few-shot examples, fencing, data rule, and the no-rewrite anchor are present")
    func compactContent() {
        let text = CleanupPrompt.compactInstructions(context: CleanupContext())
        #expect(text.contains("<transcript>"))
        #expect(text.contains("DATA"))
        // At least three raw→cleaned few-shot pairs.
        #expect(text.components(separatedBy: "Raw:").count - 1 >= 3)
        #expect(text.components(separatedBy: "Cleaned:").count - 1 >= 3)
        // The explicit closing anchor against paraphrase.
        #expect(text.contains("Never drop, reorder, summarize, or reword"))
        #expect(text.lowercased().contains("if unsure"))
        // One example must be near-identical (models "do not rewrite").
        #expect(text.contains("The migration ran cleanly on staging."))
    }

    @Test("Keeps the dictionary-terms and register-hint suffixes")
    func compactSuffixes() {
        let ctx = CleanupContext(registerHint: "email", dictionaryTerms: ["Skylark", "Parakeet"])
        let text = CleanupPrompt.compactInstructions(context: ctx)
        #expect(text.contains("Skylark"))
        #expect(text.contains("Parakeet"))
        #expect(text.lowercased().contains("register"))
        #expect(text.contains("email"))
    }

    @Test("No suffixes when context is empty")
    func compactNoSuffixes() {
        let text = CleanupPrompt.compactInstructions(context: CleanupContext())
        #expect(!text.lowercased().contains("prefer these exact spellings"))
        #expect(!text.lowercased().contains("match this register"))
    }
}

/// The local tier dials `CleanupHygiene.validate` stricter than the cloud
/// default so the ~3B model's paraphrases fall back to raw. These fixtures pin
/// the tuned floors (`LocalCleaner.localRetentionFloor` = 0.55, vocabulary;
/// `localContentLossFloor` = 0.60, content-word count) in BOTH directions.
@Suite("CleanupHygiene — local-tier strictness")
struct LocalStrictnessTests {
    private let vocab = LocalCleaner.localRetentionFloor
    private let count = LocalCleaner.localContentLossFloor

    private func validateLocal(_ cleaned: String, _ raw: String) throws -> String {
        try CleanupHygiene.validate(cleaned, transcript: raw, retentionFloor: vocab, contentLossFloor: count)
    }

    @Test("Faithful cleanups pass the strict local floors")
    func faithfulPasses() throws {
        // Filler + self-correction resolved.
        #expect(try validateLocal("Send it to Alice.", "um send it to bob uh actually alice") == "Send it to Alice.")
        // Heavy filler removal only.
        #expect(try validateLocal(
            "I really think this feature is ready to ship.",
            "so um i really think this feature is uh basically ready to ship"
        ) == "I really think this feature is ready to ship.")
        // Near-identical (already clean).
        #expect(try validateLocal("The deploy finished without errors.", "the deploy finished without errors") ==
            "The deploy finished without errors.")
        // List formatting.
        let listClean = "Here is a list of three items:\n1. Bananas\n2. Apples\n3. Lemons"
        #expect(try validateLocal(listClean, "here is a list of three items one bananas two apples three lemons") == listClean)
    }

    @Test("Paraphrase / summarize / drop-a-clause are rejected at the strict floors")
    func unfaithfulRejected() {
        for (cleaned, raw) in [
            ("I purchased milk.", "i went to the store and i bought some milk and then i came back home"),      // summarize
            ("The tests pass on staging.", "the tests pass on staging but they fail on production"),            // drop clause
            ("Kindly restructure the auth component with tokens.", "please refactor the authentication module to use tokens"), // reword
        ] {
            #expect(throws: CleanerError.self) { try validateLocal(cleaned, raw) }
        }
    }

    @Test("The two guards are independent: vocab catches rewording, content-loss catches summarizing")
    func guardsAreIndependent() {
        // Reword keeps the word count high (content-loss alone would pass) but
        // shares almost no vocabulary → only the vocab floor catches it.
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate(
                "Kindly restructure the auth component with tokens.",
                transcript: "please refactor the authentication module to use tokens",
                retentionFloor: vocab, contentLossFloor: nil
            )
        }
        // Summarize shares its surviving words (vocab alone would pass with the
        // floor disabled) but slashes the word count → only content-loss catches.
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate(
                "I purchased milk.",
                transcript: "i went to the store and i bought some milk and then i came back home",
                retentionFloor: 0.0, contentLossFloor: count
            )
        }
    }

    @Test("Cloud defaults are more permissive: a dropped clause the local floor rejects passes at 0.34")
    func cloudDefaultStaysPermissive() throws {
        let cleaned = "The tests pass on staging."
        let raw = "the tests pass on staging but they fail on production"
        // Local rejects.
        #expect(throws: CleanerError.self) { try validateLocal(cleaned, raw) }
        // Cloud (default floor, no content-loss guard) accepts — unchanged behavior.
        #expect(try CleanupHygiene.validate(cleaned, transcript: raw) == cleaned)
    }
}
