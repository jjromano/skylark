import Testing
import SkylarkCore

@Suite("DictionaryCorrector")
struct DictionaryCorrectorTests {
    private func entry(_ phrase: String, _ misspellings: [String] = []) -> DictionaryEntry {
        DictionaryEntry(phrase: phrase, misspellings: misspellings, source: .manual)
    }

    @Test("Case-insensitive match, word-boundary only")
    func caseInsensitiveBoundary() {
        let c = DictionaryCorrector(entries: [entry("GitHub", ["github"])])
        #expect(c.apply("push to github now") == "push to GitHub now")
        #expect(c.apply("PUSH TO GITHUB") == "PUSH TO GitHub")
        // Substring inside another word is NOT replaced.
        #expect(c.apply("githubbing") == "githubbing")
    }

    @Test("Preserves leading capitalization when replacement is lowercase")
    func preserveLeadingCap() {
        let c = DictionaryCorrector(entries: [entry("real-time", ["Realtime", "realtime"])])
        #expect(c.apply("Realtime updates") == "Real-time updates")
        #expect(c.apply("in realtime mode") == "in real-time mode")
    }

    @Test("Bias-only entries (no misspellings) do not rewrite")
    func biasOnlyNoRewrite() {
        let c = DictionaryCorrector(entries: [entry("Skylark")])
        #expect(c.apply("open skylark please") == "open skylark please")
    }

    @Test("Multi-word phrases match")
    func multiWord() {
        let c = DictionaryCorrector(entries: [entry("ML", ["machine learning"])])
        #expect(c.apply("I love machine learning") == "I love ML")
    }

    @Test("Multiple misspellings for one phrase all rewrite to it")
    func multipleMisspellingsSamePhrase() {
        let c = DictionaryCorrector(entries: [entry("GitHub", ["gitub", "guthub", "githb"])])
        #expect(c.apply("push to gitub now") == "push to GitHub now")
        #expect(c.apply("open guthub please") == "open GitHub please")
        #expect(c.apply("visit githb today") == "visit GitHub today")
    }

    @Test("Word-boundary safety: no mid-word rewrite")
    func wordBoundarySafety() {
        let c = DictionaryCorrector(entries: [entry("GitHub", ["hub"])])
        #expect(c.apply("githubbing") == "githubbing")
        #expect(c.apply("the hub of it") == "the GitHub of it")
    }

    @Test("update(entries:) rebuilds the rule set")
    func updateRebuilds() {
        let c = DictionaryCorrector(entries: [entry("bar", ["foo"])])
        #expect(c.apply("foo") == "bar")
        c.update(entries: [entry("baz", ["foo"])])
        #expect(c.apply("foo") == "baz")
    }

    @Test("Empty dictionary is identity")
    func emptyIdentity() {
        let c = DictionaryCorrector(entries: [])
        #expect(c.apply("nothing changes here") == "nothing changes here")
    }

    @Test("Application budget: 200 entries over a 100-word transcript is fast")
    func performanceBudget() {
        var entries: [DictionaryEntry] = []
        for i in 0..<200 { entries.append(entry("TERM\(i)", ["term\(i)"])) }
        let c = DictionaryCorrector(entries: entries)
        let transcript = (0..<100).map { "word\($0)" }.joined(separator: " ")

        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = c.apply(transcript) }
        // Budget ≤ 5 ms; assert < 50 ms to keep CI slack (spec).
        #expect(elapsed < .milliseconds(50))
    }
}
