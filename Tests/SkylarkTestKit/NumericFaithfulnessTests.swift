import Testing
import SkylarkCore

/// The numeric-faithfulness guard: a cleanup may FORMAT a figure but never
/// change it. The defect it exists for — the on-device tier turning "it costs
/// one dollar and ninety nine cents" into "It costs $1.09." — is invisible to
/// every other guard: no word is dropped, the number-unit count is unchanged,
/// and numbers are excluded from the vocabulary/content-loss ratios. A silently
/// wrong amount is worse than an unformatted one, so an unlicensed figure sends
/// the whole cleanup back to the raw transcript.
///
/// The accept half of this suite is the load-bearing half: the guard must never
/// reject legitimate formatting (that failure mode silently pastes raw, the
/// v0.7.x "A ten G"/"$1.99" regression). Every case is checked at the cloud
/// defaults and at the strict local floors (0.55 / 0.60), which is what the
/// on-device tier runs.
@Suite("Numeric faithfulness — a cleanup may format a figure, never change it")
struct NumericFaithfulnessTests {
    private func accepts(_ cleaned: String, _ raw: String, _ label: Comment) throws {
        #expect(try CleanupHygiene.validate(cleaned, transcript: raw) == cleaned, label)
        #expect(try CleanupHygiene.validate(
            cleaned, transcript: raw, retentionFloor: 0.55, contentLossFloor: 0.60) == cleaned, label)
    }

    private func rejects(_ cleaned: String, _ raw: String, _ label: Comment) {
        #expect(throws: CleanerError.self, label) {
            try CleanupHygiene.validate(cleaned, transcript: raw)
        }
        #expect(throws: CleanerError.self, label) {
            try CleanupHygiene.validate(
                cleaned, transcript: raw, retentionFloor: 0.55, contentLossFloor: 0.60)
        }
    }

    // MARK: - Rejected: the figure changed

    @Test("The reported defect: $1.09 from 'one dollar and ninety nine cents' is rejected")
    func changedCentsRejected() throws {
        let raw = "it costs one dollar and ninety nine cents"
        // The correct formatting passes...
        try accepts("It costs $1.99.", raw, "correct cents formatting must survive")
        // ...the wrong amounts do not, including the "1" + "99" digits reshuffled
        // into a different value.
        rejects("It costs $1.09.", raw, "1.09 is not the spoken amount")
        rejects("It costs $2.99.", raw, "2.99 is not the spoken amount")
        rejects("It costs $1.90.", raw, "1.90 is not the spoken amount")
    }

    @Test("A changed dollars-and-cents amount is rejected")
    func changedDollarsRejected() throws {
        let raw = "the fee is twenty dollars and ten cents"
        try accepts("The fee is $20.10.", raw, "correct formatting must survive")
        rejects("The fee is $21.00.", raw, "21.00 is not the spoken amount")
        rejects("The fee is $20.01.", raw, "20.01 is not the spoken amount")
    }

    @Test("A changed count is rejected")
    func changedCountRejected() throws {
        let raw = "we have twenty three open tickets"
        try accepts("We have 23 open tickets.", raw, "correct formatting must survive")
        rejects("We have 24 open tickets.", raw, "24 is not the spoken count")
    }

    @Test("A figure invented out of nothing is rejected")
    func inventedFigureRejected() {
        rejects("The migration ran cleanly on 3 staging hosts.",
                "the migration ran cleanly on staging",
                "the raw licenses no figure at all")
    }

    // MARK: - Accepted: legitimate formatting of a licensed figure

    @Test("Currency, percent, and counts formatted from spoken words are accepted")
    func spokenNumberFormattingAccepted() throws {
        try accepts("It costs $1.99.", "it costs one dollar and ninety nine cents", "cents")
        try accepts("It cost $1250.30.",
                    "it cost one thousand two hundred and fifty dollars and thirty cents",
                    "thousands + cents")
        try accepts("We ran 42 builds across 17 days.",
                    "we ran forty two builds across seventeen days",
                    "two independent counts")
        try accepts("Uptime last month was 99.9%.",
                    "uptime last month was ninety nine point nine percent",
                    "decimal percent")
        try accepts("It costs about $23.", "it costs about twenty three dollars", "whole dollars")
    }

    @Test("Digits read as one figure across consecutive spoken units are accepted")
    func concatenatedUnitsAccepted() throws {
        try accepts("The plan lands in 2026.", "the plan lands in twenty twenty six", "year")
        try accepts("March 5, 2026 is the date.", "march fifth twenty twenty six is the date",
                    "ordinal date + year")
        try accepts("Call me at 555-1212 today.",
                    "call me at five five five one two one two today",
                    "spoken digit string")
    }

    @Test("Times, ordinals, and digits fused into words are accepted")
    func componentFiguresAccepted() throws {
        try accepts("We meet at 3:30 tomorrow.", "we meet at three thirty tomorrow", "time")
        try accepts("Let us do it at half past 2.", "let us do it at half past two", "half past")
        try accepts("Take the 3rd option instead.", "take the third option instead", "ordinal suffix")
        try accepts("I need to reserve an A10G GPU.", "i need to reserve an a ten g gpu", "alphanumeric")
    }

    @Test("A spoken list numbered by the model is accepted (list markers are not figures)")
    func listMarkersAccepted() throws {
        try accepts("Here are three things:\n1. Buy milk\n2. Walk the dog\n3. Call mom",
                    "here are three things one buy milk two walk the dog three call mom",
                    "spoken ordinals become list markers")
    }

    @Test("Digits already in the raw transcript pass through unchanged")
    func rawDigitsAccepted() throws {
        try accepts("Please look at ticket 4521 today.",
                    "please look at ticket 4521 today",
                    "STT emitted digits")
        try accepts("The build is at 1,250 tests.",
                    "the build is at 1250 tests",
                    "thousands separator added by the cleanup")
    }

    @Test("A cleanup with no digits at all is untouched by the guard")
    func noDigitsIsANoOp() throws {
        try accepts("So I really think this is basically ready to ship.",
                    "um so i really think this is uh basically ready to ship you know",
                    "no figure to check")
    }

    // MARK: - The corpus stays green

    /// The corpus gate (`CleanupCorpusTests.expectedOutputsAreNeverRejected`)
    /// covers this too; asserting it here as well keeps the numeric guard's own
    /// suite self-contained when tuning it.
    @Test("Numbers on either side of a sentence boundary never merge into a licensed figure")
    func clauseBoundaryEndsTheRun() {
        let raw = "the queue is down to twenty. one item just failed"
        #expect(throws: CleanerError.self) {
            try CleanupHygiene.validate("The queue is down to 21. One item just failed.", transcript: raw)
        }
        #expect(throws: Never.self) {
            try CleanupHygiene.validate("The queue is down to 20. One item just failed.", transcript: raw)
        }
    }

    @Test("Every canonical corpus cleanup survives the numeric guard at both floors")
    func corpusSurvives() throws {
        for example in CleanupCorpus.examples {
            #expect(throws: Never.self, "[\(example.category)] rejected at the cloud floor") {
                try CleanupHygiene.validate(example.expected, transcript: example.raw)
            }
            #expect(throws: Never.self, "[\(example.category)] rejected at the local floor") {
                try CleanupHygiene.validate(
                    example.expected, transcript: example.raw,
                    retentionFloor: 0.55, contentLossFloor: 0.60)
            }
        }
    }
}
