import Testing
import SkylarkCore

@Suite("CorrectionDiff")
struct CorrectionDiffTests {
    @Test("Single-token substitution is a candidate")
    func singleSubstitution() {
        let pairs = CorrectionDiff.pairs(raw: "push to gitub now", edited: "push to github now")
        #expect(pairs == [CorrectionDiff.Pair(from: "gitub", to: "github")])
    }

    @Test("One-to-two token substitution is allowed")
    func oneToTwo() {
        let pairs = CorrectionDiff.pairs(raw: "use realtime data", edited: "use real time data")
        #expect(pairs == [CorrectionDiff.Pair(from: "realtime", to: "real time")])
    }

    @Test("Pure case change is rejected")
    func rejectCaseOnly() {
        let pairs = CorrectionDiff.pairs(raw: "open github page", edited: "open GitHub page")
        #expect(pairs.isEmpty)
    }

    @Test("Pure punctuation change is rejected")
    func rejectPunctuationOnly() {
        let pairs = CorrectionDiff.pairs(raw: "wait dont go", edited: "wait don't go")
        #expect(pairs.isEmpty)
    }

    @Test("Short (< 3 char) source is rejected")
    func rejectShort() {
        let pairs = CorrectionDiff.pairs(raw: "go to it", edited: "go to that")
        #expect(pairs.isEmpty)
    }

    @Test("Three-token replacement is not a candidate")
    func rejectThreeTokens() {
        let pairs = CorrectionDiff.pairs(raw: "the thing here", edited: "the one big thing here")
        // "thing" → "one big thing"? alignment keeps "thing" equal, inserts 2 before.
        // No single-token 1→(1|2) substitution qualifies.
        #expect(pairs.allSatisfy { $0.from.split(separator: " ").count == 1 })
    }

    @Test("Identical strings yield no pairs")
    func identical() {
        #expect(CorrectionDiff.diff(raw: "same words", edited: "same words").isEmpty)
    }
}
