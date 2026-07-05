import Testing
import SkylarkCore

@Suite("DictionaryCorrector")
struct DictionaryCorrectorTests {
    private func entry(_ phrase: String, _ replacement: String?) -> DictionaryEntry {
        DictionaryEntry(phrase: phrase, replacement: replacement, source: .manual)
    }

    @Test("Case-insensitive match, word-boundary only")
    func caseInsensitiveBoundary() {
        let c = DictionaryCorrector(entries: [entry("github", "GitHub")])
        #expect(c.apply("push to github now") == "push to GitHub now")
        #expect(c.apply("PUSH TO GITHUB") == "PUSH TO GitHub")
        // Substring inside another word is NOT replaced.
        #expect(c.apply("githubbing") == "githubbing")
    }

    @Test("Preserves leading capitalization when replacement is lowercase")
    func preserveLeadingCap() {
        let c = DictionaryCorrector(entries: [entry("Realtime", "real-time")])
        #expect(c.apply("Realtime updates") == "Real-time updates")
        #expect(c.apply("in realtime mode") == "in real-time mode")
    }

    @Test("Bias-only entries (replacement == nil) do not rewrite")
    func biasOnlyNoRewrite() {
        let c = DictionaryCorrector(entries: [entry("Skylark", nil)])
        #expect(c.apply("open skylark please") == "open skylark please")
    }

    @Test("Multi-word phrases match")
    func multiWord() {
        let c = DictionaryCorrector(entries: [entry("machine learning", "ML")])
        #expect(c.apply("I love machine learning") == "I love ML")
    }

    @Test("update(entries:) rebuilds the rule set")
    func updateRebuilds() {
        let c = DictionaryCorrector(entries: [entry("foo", "bar")])
        #expect(c.apply("foo") == "bar")
        c.update(entries: [entry("foo", "baz")])
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
        for i in 0..<200 { entries.append(entry("term\(i)", "TERM\(i)")) }
        let c = DictionaryCorrector(entries: entries)
        let transcript = (0..<100).map { "word\($0)" }.joined(separator: " ")

        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = c.apply(transcript) }
        // Budget ≤ 5 ms; assert < 50 ms to keep CI slack (spec).
        #expect(elapsed < .milliseconds(50))
    }
}
