import Testing
import SkylarkCore

/// The 15 regression cases measured against the prototype in the 0.16.0
/// handoff (§3.3), ported verbatim. They are the contract: a recogniser splits
/// a sentence wherever the speaker paused, and only these merges are safe.
@Suite("SentenceBoundaryRepair — handoff regression set")
struct SentenceBoundaryRepairRegressionTests {
    private struct Case {
        let raw: String
        let expected: String
        let note: String
    }

    private static let cases: [Case] = [
        .init(raw: "I want to. Draft the document.",
              expected: "I want to draft the document.",
              note: "R1 dangling 'to' — JJ's own example, no comma"),
        .init(raw: "I think we should ship the feature. And then tell the team on Friday.",
              expected: "I think we should ship the feature and then tell the team on Friday.",
              note: "R3 'and' with no independent clause after — space, not comma"),
        .init(raw: "I shipped it. But I am tired.",
              expected: "I shipped it, but I am tired.",
              note: "R3 'but' + independent clause — comma"),
        .init(raw: "I want to talk about the migration. Because it keeps failing on staging.",
              expected: "I want to talk about the migration, because it keeps failing on staging.",
              note: "R3 'because' + independent clause — comma"),
        .init(raw: "Send the draft to Bob. Then loop in Alice.",
              expected: "Send the draft to Bob then loop in Alice.",
              note: "R3 'then' with an imperative after — space"),
        .init(raw: "We need to rewrite the parser. Which is going to take a week.",
              expected: "We need to rewrite the parser which is going to take a week.",
              note: "R2 illegal head 'which'"),
        .init(raw: "We should move the deadline to. Next Friday at the earliest.",
              expected: "We should move the deadline to next Friday at the earliest.",
              note: "R1 dangling preposition"),
        .init(raw: "It costs about. Twenty three dollars.",
              expected: "It costs about twenty three dollars.",
              note: "R1 dangling 'about', continuation down-cased"),
        .init(raw: "I was thinking we could. Really just ship it today.",
              expected: "I was thinking we could really just ship it today.",
              note: "R1 dangling auxiliary"),
        .init(raw: "Can you look at the. Auth bug before standup?",
              expected: "Can you look at the auth bug before standup?",
              note: "R1 dangling determiner, question mark preserved"),
        .init(raw: "I need to check the logs. And the metrics dashboard.",
              expected: "I need to check the logs and the metrics dashboard.",
              note: "R3 'and' over a noun phrase — space"),
        .init(raw: "The deploy went out at noon. I am going to bed.",
              expected: "The deploy went out at noon. I am going to bed.",
              note: "two genuine sentences — untouched"),
        .init(raw: "Let us review the metrics on Tuesday. Sarah will bring the deck.",
              expected: "Let us review the metrics on Tuesday. Sarah will bring the deck.",
              note: "proper-noun head — untouched"),
        .init(raw: "Yes. Ship it.",
              expected: "Yes. Ship it.",
              note: "short verbless fragment stays split (the rejected 4th rule)"),
        .init(raw: "That is the whole plan. Any questions?",
              expected: "That is the whole plan. Any questions?",
              note: "'any' is a dangling TAIL, never an illegal head"),
    ]

    @Test("All 15 handoff cases")
    func handoffCases() {
        for c in Self.cases {
            #expect(SentenceBoundaryRepair.repair(c.raw) == c.expected, "\(c.note)")
        }
    }
}

@Suite("SentenceBoundaryRepair — adversarial input")
struct SentenceBoundaryRepairAdversarialTests {
    @Test("A transcript with no period is returned byte-identical")
    func noPeriods() {
        let raw = "just a quick note about the meeting tomorrow"
        #expect(SentenceBoundaryRepair.repair(raw) == raw)
    }

    @Test("A transcript where no rule fires keeps its exact whitespace")
    func whitespacePreserved() {
        let raw = "Ship it.  Sarah will review it.\nThanks."
        #expect(SentenceBoundaryRepair.repair(raw) == raw)
    }

    @Test("Empty and whitespace-only input pass through")
    func emptyInput() {
        #expect(SentenceBoundaryRepair.repair("") == "")
        #expect(SentenceBoundaryRepair.repair("   ") == "   ")
    }

    @Test("An abbreviation's period is never a boundary")
    func abbreviations() {
        let repaired = SentenceBoundaryRepair.repair("Dr. Smith called. And he left the office.")
        #expect(repaired.hasPrefix("Dr. Smith called"))
        #expect(!repaired.contains("Dr Smith"))
        // "e.g." / "vs." / initials are structurally rejected too.
        #expect(SentenceBoundaryRepair.repair("Use a queue, e.g. the one in the parser.")
            == "Use a queue, e.g. the one in the parser.")
        #expect(SentenceBoundaryRepair.repair("J. R. Romano signed off. And then left.")
            .hasPrefix("J. R. Romano signed off"))
    }

    @Test("A decimal is not a sentence boundary")
    func decimals() {
        let repaired = SentenceBoundaryRepair.repair("It cost 3.5 million. And we paid cash.")
        #expect(repaired.contains("3.5 million"))
        #expect(!repaired.contains("3 5"))
    }

    @Test("File names, hosts and version numbers keep their periods")
    func dottedTokens() {
        let raw = "Check foo.swift and example.com. Then ship v0.15.0."
        #expect(SentenceBoundaryRepair.repair(raw) == raw)
        let path = "Open Sources/SkylarkCore/Cleanup/LocalCleaner.swift. And read it."
        #expect(SentenceBoundaryRepair.repair(path) == path)
    }

    @Test("An ellipsis is left alone")
    func ellipsis() {
        let raw = "I was thinking... maybe we should wait."
        #expect(SentenceBoundaryRepair.repair(raw) == raw)
        let trailing = "I want to... draft the document."
        #expect(SentenceBoundaryRepair.repair(trailing) == trailing)
    }

    @Test("Never merge across a newline")
    func newlines() {
        let raw = "I want to.\nDraft the document."
        #expect(SentenceBoundaryRepair.repair(raw) == raw)
        let spaced = "I want to. \n Draft the document."
        #expect(SentenceBoundaryRepair.repair(spaced) == spaced)
    }

    @Test("Never merge when the terminator is ! or ?")
    func strongTerminators() {
        let bang = "Ship it! And tell the team."
        #expect(SentenceBoundaryRepair.repair(bang) == bang)
        let question = "Did you ship it? And then what."
        #expect(SentenceBoundaryRepair.repair(question) == question)
    }

    @Test("A continuation keeps 'I' and acronym casing")
    func casingGuards() {
        #expect(SentenceBoundaryRepair.repair("We need to update the. API documentation today.")
            == "We need to update the API documentation today.")
        #expect(SentenceBoundaryRepair.repair("I talked to him about the. Migration plan.")
            == "I talked to him about the migration plan.")
        let merged = SentenceBoundaryRepair.repair("I talked to him about the migration. And I am tired.")
        #expect(merged.contains("and I am tired"))
    }

    @Test("R3 needs at least 3 words before the boundary")
    func shortLeadingFragment() {
        let raw = "Yes. And we shipped it."
        #expect(SentenceBoundaryRepair.repair(raw) == raw)
    }

    @Test("R3 refuses to build a sentence longer than 60 words")
    func mergedLengthCap() {
        let long = Array(repeating: "word", count: 58).joined(separator: " ")
        let raw = "\(long). And the team shipped it."
        #expect(SentenceBoundaryRepair.repair(raw) == raw)
    }

    @Test("Several boundaries in one transcript are repaired independently")
    func multipleBoundaries() {
        let raw = "I want to. Draft the document for the team. "
            + "We should move the deadline to. Next Friday at the earliest."
        #expect(SentenceBoundaryRepair.repair(raw)
            == "I want to draft the document for the team. "
            + "We should move the deadline to next Friday at the earliest.")
    }

    @Test("The repair is stable under a second application")
    func idempotentOnRepairedText() {
        for raw in ["I want to. Draft the document.",
                    "I shipped it. But I am tired.",
                    "The deploy went out at noon. I am going to bed."] {
            let once = SentenceBoundaryRepair.repair(raw)
            #expect(SentenceBoundaryRepair.repair(once) == once)
        }
    }
}

@Suite("SentenceBoundaryRepair — cost")
struct SentenceBoundaryRepairPerformanceTests {
    /// 192 words, shredded at eight false boundaries — the handoff's measured
    /// shape. The repair sits on the paste path, so it has to be free.
    private static func transcript() -> String {
        let block = "I want to. Draft the migration document for the whole team before Friday "
            + "so that everyone knows what is changing and nobody is surprised on the day. "
            + "We should move the deadline to. Next Friday at the earliest because the "
            + "staging cluster keeps falling over every single night and nobody has had "
            + "time to look at it properly. I need to check the logs. And the metrics "
            + "dashboard as well before we make any promises to the wider team. "
            + "The deploy went out at noon. I am going to bed now after a very long day."
        return Array(repeating: block, count: 2).joined(separator: " ")
    }

    @Test("A 192-word transcript repairs well inside the paste budget")
    func fastEnough() {
        let text = Self.transcript()
        #expect(text.split(whereSeparator: { $0.isWhitespace }).count >= 192)
        // Warm the tagger once so the measurement is steady-state, not first-use.
        _ = SentenceBoundaryRepair.repair(text)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = SentenceBoundaryRepair.repair(text) }
        #expect(elapsed < .milliseconds(50), "repair took \(elapsed)")
    }
}
