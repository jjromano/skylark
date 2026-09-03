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

    @Test("A dropped numbers-heavy clause is rejected even at the permissive cloud floor")
    func numberUnitClauseDropRejected() {
        // The regression: excluding numbers from the vocab/count ratios let a
        // dropped money clause retain 100% of its NON-number words. The number-
        // unit guard counts the two dropped amount runs and rejects it — at the
        // cloud default floor (0.34, no content-loss guard), where it used to pass.
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate(
                "Transfer to vendor now.",
                transcript: "transfer twenty three thousand four hundred fifty six dollars "
                    + "and ninety nine cents to vendor now"
            )
        }
    }

    @Test("Number formatting keeps its unit: spoken→digit conversion passes the number guard")
    func numberConversionPassesGuard() throws {
        // "twenty three" → "23" collapses one run into one token = same unit count.
        #expect(try CleanupHygiene.validate("We have 23 tickets.", transcript: "we have twenty three tickets")
            == "We have 23 tickets.")
        // Two separate number runs on both sides → equal units → passes.
        #expect(try CleanupHygiene.validate(
            "I ate 1 banana and 2 apples.",
            transcript: "i ate one banana and two apples"
        ) == "I ate 1 banana and 2 apples.")
    }

    // Regression (v0.7.x): legitimate number formatting that REDUCES the spoken
    // number-run count was wrongly rejected as a dropped number unit, so raw
    // (unformatted) text was kept — the local-tier "A ten G" / "one dollar and
    // ninety nine cents" bug. Formatting must pass at both the cloud (0.34) and
    // strict local (0.55/0.60) floors.
    @Test("Currency formatting (2 spoken runs → 1 figure) must not be rejected")
    func currencyFormattingPasses() throws {
        #expect(try CleanupHygiene.validate("$1.99", transcript: "one dollar and ninety nine cents") == "$1.99")
        #expect(try CleanupHygiene.validate(
            "$1.99", transcript: "one dollar and ninety nine cents",
            retentionFloor: 0.55, contentLossFloor: 0.60) == "$1.99")
    }

    // The mirror image of the test above, and the v0.20.x defect: the on-device
    // tier returned "$1.09" for "one dollar and ninety nine cents" — a DIFFERENT
    // amount, which no other guard can see (every word survives, the number-unit
    // count is unchanged, and numbers are excluded from the ratios). A changed
    // figure is worse than an unformatted one, so raw must stand. Full coverage
    // lives in `NumericFaithfulnessTests`.
    @Test("A changed figure is rejected (formatting is allowed, altering an amount is not)")
    func changedFigureRejected() {
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate("It costs $1.09.", transcript: "it costs one dollar and ninety nine cents")
        }
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate("The fee is $21.00.", transcript: "the fee is twenty dollars and ten cents")
        }
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate("We have 24 open tickets.", transcript: "we have twenty three open tickets")
        }
    }

    @Test("A spoken number fused into a word (A ten G → A10G) must not be rejected")
    func digitFusedIntoWordPasses() throws {
        let raw = "i need to reserve an a ten g gpu"
        let cleaned = "I need to reserve an A10G GPU."
        #expect(try CleanupHygiene.validate(cleaned, transcript: raw) == cleaned)
        #expect(try CleanupHygiene.validate(
            cleaned, transcript: raw, retentionFloor: 0.55, contentLossFloor: 0.60) == cleaned)
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

    @Test("Number formatting is invisible to the floors: numeral conversion passes, a numbered clause drop still fails")
    func numberAwareFloors() throws {
        // Spoken number → digits/symbol is a faithful repair. The words
        // "ninety/nine/point/nine/percent" vanish and become "99.9%", which
        // matches none of them — yet this must NOT read as content loss.
        #expect(try validateLocal(
            "The uptime last month was 99.9%, which is below our target.",
            "the uptime last month was ninety nine point nine percent which is below our target"
        ) == "The uptime last month was 99.9%, which is below our target.")
        #expect(try validateLocal("We have 23 open tickets.", "we have twenty three open tickets")
            == "We have 23 open tickets.")
        // Inviolable: a genuine clause drop is still rejected even when a number
        // is converted in the same sentence (non-number words carry the ratio).
        #expect(throws: CleanerError.self) {
            try validateLocal(
                "We shipped 3 features.",
                "we shipped three features but the deployment failed on production"
            )
        }
    }

    @Test("Content-loss boundary: exactly 6/10 content words (== the 0.60 floor) passes (strict <)")
    func contentLossBoundaryPasses() throws {
        // 10 content words in raw (fillers "um"/"the"/"and" don't count); the
        // cleanup keeps exactly 6 of them → ratio 0.60, which is NOT < 0.60, so
        // it passes. This pins the floor as a strict inequality at the boundary.
        let raw = "um the quarterly report covers revenue costs profit margins growth and risk factors"
        let cleaned6 = "The quarterly report covers revenue, costs, and profit." // 6 content words
        #expect(try validateLocal(cleaned6, raw) == cleaned6)
        // One content word fewer (5/10 = 0.50 < 0.60) tips over the floor → rejected.
        let cleaned5 = "The quarterly report covers revenue and costs."
        #expect(throws: CleanerError.self) { try validateLocal(cleaned5, raw) }
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

@Suite("CleanupHygiene — output scaffolding strips")
struct CleanupHygieneScaffoldingTests {
    @Test("Reasoning / thinking blocks are stripped")
    func stripsReasoning() {
        #expect(CleanupHygiene.sanitize("<think>the user said x</think>Send it Friday.") == "Send it Friday.")
        #expect(CleanupHygiene.sanitize("<reasoning>\nplan\n</reasoning>\nHello there.") == "Hello there.")
        #expect(CleanupHygiene.sanitize("<THINKING>upper</THINKING>Done.") == "Done.")
        // Unterminated block runs to end-of-string; earlier content survives.
        #expect(CleanupHygiene.sanitize("Done.\n<think>oops no close tag") == "Done.")
        // No tags → untouched (a bare "a < b" is not a reasoning block).
        #expect(CleanupHygiene.sanitize("a < b and c > d") == "a < b and c > d")
    }

    @Test("A whole-output markdown code fence is unwrapped; inline back-ticks are kept")
    func stripsCodeFence() {
        #expect(CleanupHygiene.sanitize("```\nHello there.\n```") == "Hello there.")
        #expect(CleanupHygiene.sanitize("```text\nHello there.\n```") == "Hello there.")
        #expect(CleanupHygiene.sanitize("Use the `git` command.") == "Use the `git` command.")
    }

    @Test("A recognized leading label is removed; a mid-sentence colon is not")
    func stripsLeadingLabel() {
        #expect(CleanupHygiene.sanitize("Output: Send it Friday.") == "Send it Friday.")
        #expect(CleanupHygiene.sanitize("Cleaned transcript:\nHello there.") == "Hello there.")
        #expect(CleanupHygiene.sanitize("Note to self: buy milk.") == "Note to self: buy milk.")
    }

    @Test("Strips compose: fence + reasoning + label together")
    func stripsCompose() {
        let raw = "```\n<think>hmm</think>\nOutput: Send it Friday.\n```"
        #expect(CleanupHygiene.sanitize(raw) == "Send it Friday.")
    }
}
