import Testing
import SkylarkCore

/// Emphasis the cleanup model invents from audible stress (`!`, ALL-CAPS,
/// markdown bold) is repaired down to what the raw transcript licenses — never
/// rejected. Each rule is pinned in both directions: it fires when the raw has
/// no such emphasis, and stays out of the way when the raw does.
@Suite("EmphasisRepair — invented emphasis is repaired, not rejected")
struct EmphasisRepairTests {
    // MARK: - Rule: exclamation cap

    @Test("An invented exclamation mark is downgraded to a period")
    func inventedExclamationDowngraded() {
        #expect(EmphasisRepair.repair("This is great!", raw: "this is great") == "This is great.")
        #expect(EmphasisRepair.repair("Ship it now!", raw: "ship it now") == "Ship it now.")
        // Only the excess is downgraded: budget 0 here, so both go.
        #expect(EmphasisRepair.repair("Wow! Ship it!", raw: "wow ship it") == "Wow. Ship it.")
    }

    @Test("An exclamation the raw itself carries is kept")
    func rawExclamationKept() {
        #expect(EmphasisRepair.repair("Wow, it worked!", raw: "wow it worked!") == "Wow, it worked!")
        // Budget is 1: the first mark survives, the second is downgraded.
        #expect(EmphasisRepair.repair("Wow! It worked!", raw: "wow! it worked") == "Wow! It worked.")
    }

    @Test("A spoken 'exclamation mark' / 'exclamation point' command licenses one mark")
    func spokenExclamationCommandLicensesMark() {
        #expect(EmphasisRepair.repair("I love that!", raw: "I love that exclamation mark") == "I love that!")
        #expect(EmphasisRepair.repair("Stop!", raw: "stop exclamation point") == "Stop!")
        // Two commands license two marks; a third mark is still downgraded.
        let raw = "hurry exclamation mark now exclamation mark go"
        #expect(EmphasisRepair.repair("Hurry! Now! Go!", raw: raw) == "Hurry! Now! Go.")
    }

    @Test("The earliest marks survive the cap (left-to-right budget)")
    func earliestMarksSurvive() {
        #expect(EmphasisRepair.repair("A! B! C!", raw: "a! b c") == "A! B. C.")
    }

    // MARK: - Rule: collapse mark runs

    @Test("Doubled and mixed mark runs collapse to a single mark")
    func markRunsCollapse() {
        #expect(EmphasisRepair.repair("Wow!!", raw: "wow!") == "Wow!")
        #expect(EmphasisRepair.repair("Really?!", raw: "really?") == "Really?")
        #expect(EmphasisRepair.repair("What!?", raw: "what?") == "What?")
        #expect(EmphasisRepair.repair("Stop!!!", raw: "stop exclamation mark") == "Stop!")
    }

    @Test("A mark run the raw itself contains is kept")
    func rawMarkRunKept() {
        #expect(EmphasisRepair.repair("Hey!!", raw: "hey!!") == "Hey!!")
        #expect(EmphasisRepair.repair("Really?!", raw: "really?!") == "Really?!")
    }

    // MARK: - Rule: markdown emphasis markers

    @Test("Markdown bold/underline markers the raw lacks are stripped")
    func markdownMarkersStripped() {
        #expect(EmphasisRepair.repair("Do it **now**.", raw: "do it now") == "Do it now.")
        #expect(EmphasisRepair.repair("Do it __now__.", raw: "do it now") == "Do it now.")
        // An unclosed marker goes too.
        #expect(EmphasisRepair.repair("Do it **now.", raw: "do it now") == "Do it now.")
    }

    @Test("Markers are kept when the raw has them, and never fuse two words")
    func markdownMarkersKept() {
        #expect(EmphasisRepair.repair("Wrap it in **bold**.", raw: "wrap it in ** bold **")
            == "Wrap it in **bold**.")
        // Intra-word underscores are an identifier, not emphasis: removing them
        // would fuse "snake" and "case" into one word.
        #expect(EmphasisRepair.repair("Use snake__case here.", raw: "use snake case here")
            == "Use snake__case here.")
    }

    // MARK: - Rule: ALL-CAPS revert

    @Test("A shouted word is reverted to the raw's casing")
    func shoutedWordReverted() {
        #expect(EmphasisRepair.repair("This is GREAT!!", raw: "this is great") == "This is great.")
        #expect(EmphasisRepair.repair("Do **NOT** merge this!", raw: "do not merge this")
            == "Do not merge this.")
    }

    @Test("A word the raw itself has in caps is untouched")
    func rawCapsUntouched() {
        #expect(EmphasisRepair.repair("The API is down!", raw: "the API is down") == "The API is down.")
        #expect(EmphasisRepair.repair("The SQL job FAILED!", raw: "the SQL job failed")
            == "The SQL job failed.")
    }

    @Test("A known initialism is never reverted, even from an all-lowercase raw")
    func initialismsProtected() {
        // The recogniser emits lowercase, so uppercasing "api"/"gpu" is the
        // model CORRECTING it — reverting would corrupt good output.
        #expect(EmphasisRepair.repair("The API is down!", raw: "the api is down") == "The API is down.")
        #expect(EmphasisRepair.repair("Reserve a GPU now!", raw: "reserve a gpu now") == "Reserve a GPU now.")
    }

    @Test("A word absent from the raw is left as the model wrote it")
    func unknownWordLeftAlone() {
        #expect(EmphasisRepair.repair("Check the KUBELET logs!", raw: "check the logs")
            == "Check the KUBELET logs.")
    }

    @Test("A proper-noun capital is not shouting")
    func properNounUntouched() {
        #expect(EmphasisRepair.repair("Send it to Sarah.", raw: "send it to sarah") == "Send it to Sarah.")
        #expect(EmphasisRepair.repair("Send it to Sarah!", raw: "send it to sarah") == "Send it to Sarah.")
    }

    @Test("A reverted word that opens a sentence keeps its sentence capital")
    func sentenceStartStaysCapitalized() {
        #expect(EmphasisRepair.repair("GREAT news, we shipped!", raw: "great news we shipped")
            == "Great news, we shipped.")
    }

    @Test("The revert needs corroborating emphasis: unemphatic caps are left alone")
    func revertNeedsEmphasisEvidence() {
        // No `!`, no run, no markers → nothing fired, so the casing the model
        // chose stands. This is what keeps ordinary output (acronyms outside
        // the known set) safe from a lowercase-raw false positive.
        let cleaned = "I finished the KUBERNETES migration."
        #expect(EmphasisRepair.repair(cleaned, raw: "i finished the kubernetes migration") == cleaned)
    }

    // MARK: - Identity

    @Test("Output is unchanged when no rule fires")
    func unchangedWhenNothingFires() {
        for (cleaned, raw) in [
            ("The migration ran cleanly on staging.", "the migration ran cleanly on staging"),
            ("I need to reserve an A10G GPU.", "i need to reserve an a ten g gpu"),
            ("Send it to Alice.", "send it to bob uh actually alice"),
            ("Wow!", "wow exclamation mark"),
        ] {
            #expect(EmphasisRepair.repair(cleaned, raw: raw) == cleaned)
        }
    }
}

/// The repair runs inside `CleanupHygiene.validate`, after every guard has
/// passed and before the spoken-number pass — and only outside translation
/// mode, like the other source-language comparisons.
@Suite("EmphasisRepair — wired into CleanupHygiene.validate")
struct EmphasisRepairHygieneTests {
    @Test("validate repairs invented emphasis instead of rejecting the cleanup")
    func validateRepairs() throws {
        #expect(try CleanupHygiene.validate("This is GREAT!!", transcript: "this is great")
            == "This is great.")
        #expect(try CleanupHygiene.validate("The API is down!", transcript: "the API is down")
            == "The API is down.")
        #expect(try CleanupHygiene.validate("Do it **now**!", transcript: "do it now")
            == "Do it now.")
    }

    @Test("A licensed exclamation survives validate")
    func validateKeepsLicensedMark() throws {
        #expect(try CleanupHygiene.validate("I love that!", transcript: "I love that exclamation mark")
            == "I love that!")
        #expect(try CleanupHygiene.validate("Send it to Sarah.", transcript: "send it to sarah")
            == "Send it to Sarah.")
    }

    @Test("Repair composes with the spoken-number pass, which still runs after it")
    func validateComposesWithNumbers() throws {
        #expect(try CleanupHygiene.validate(
            "We have twenty three open tickets!", transcript: "we have twenty three open tickets")
            == "We have 23 open tickets.")
    }

    @Test("Translation mode skips the repair (source-language comparison)")
    func translatedSkipsRepair() throws {
        // Same shape as the repaired case above, but translated → untouched.
        #expect(try CleanupHygiene.validate(
            "This is GREAT!!", transcript: "das ist toll", translated: true) == "This is GREAT!!")
        #expect(try CleanupHygiene.validate(
            "C'est **super**!", transcript: "this is great", translated: true) == "C'est **super**!")
    }
}
