import Testing
import SkylarkCore

// P1-6: only the dictionary terms a transcript plausibly contains may travel to
// a cloud cleanup request. These cover the pure filter; the orchestrator wiring
// (cloud filtered / local full) is covered in DictationOrchestratorTests.

private func entry(_ phrase: String, _ misspellings: String...) -> DictionaryEntry {
    DictionaryEntry(phrase: phrase, misspellings: misspellings, source: .manual)
}

@Suite("Dictionary relevance filter")
struct DictionaryRelevanceTests {
    private let dictionary = [
        entry("Kubernetes", "kubernetties"),
        entry("Anthropic"),
        entry("Skylark"),
        entry("Priya Raghunathan", "preeya ragunathan"),
        entry("real-time"),
        entry("PostgreSQL", "postgres"),
        entry("API"),
    ]

    // MARK: Exact

    @Test("An exact term in the transcript is sent")
    func exactMatch() {
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "we should redeploy the kubernetes cluster tonight"
        )
        #expect(terms == ["Kubernetes"])
    }

    @Test("Matching is case- and punctuation-insensitive")
    func caseAndPunctuation() {
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "Ask ANTHROPIC, then ship it."
        )
        #expect(terms == ["Anthropic"])
    }

    @Test("A multi-word term is sent when the whole phrase is spoken")
    func multiWordPhrase() {
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "loop in priya raghunathan before friday"
        )
        #expect(terms == ["Priya Raghunathan"])
    }

    @Test("A hyphenated term matches the spaced transcript form")
    func hyphenFolding() {
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "we need real time updates on the dashboard"
        )
        #expect(terms == ["real-time"])
    }

    // MARK: Misspellings

    @Test("A listed misspelling in the transcript sends the correct spelling")
    func listedMisspelling() {
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "the kubernetties nodes are flapping"
        )
        #expect(terms == ["Kubernetes"])
    }

    @Test("A listed multi-word misspelling also sends the phrase")
    func listedMultiWordMisspelling() {
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "preeya ragunathan owns that service"
        )
        #expect(terms == ["Priya Raghunathan"])
    }

    // MARK: Fuzzy

    @Test("An unlisted near-miss from the transcriber still matches")
    func fuzzyNearMiss() {
        // "kubernets" is one deletion from "kubernetes" and is in no misspelling list.
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "restart the kubernets scheduler"
        )
        #expect(terms == ["Kubernetes"])
    }

    @Test("A dropped/added suffix matches via the prefix rule")
    func prefixRule() {
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "dump the postgres tables"
        )
        #expect(terms == ["PostgreSQL"])
    }

    @Test("A two-edit miss on a long term matches")
    func twoEditsOnLongTerm() {
        // "anthropik" → "anthropic" is 1 substitution; "anthropics" adds one more.
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "ping anthropiks about the quota"
        )
        #expect(terms == ["Anthropic"])
    }

    // MARK: Negative

    @Test("Unrelated speech sends nothing at all")
    func unrelatedTranscriptSendsNothing() {
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "remind me to buy milk and walk the dog"
        )
        #expect(terms.isEmpty)
    }

    @Test("A different word of similar length is not a match")
    func similarLengthNonMatch() {
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "the skylight in the kitchen leaks"
        )
        // "skylight" vs "Skylark" is 3 edits — beyond the budget.
        #expect(terms.isEmpty)
    }

    @Test("Short terms require an exact match, so they never flood the prompt")
    func shortTermsAreExactOnly() {
        // "apt", "app", "ape" are all 1 edit from "API" and would otherwise pull
        // it into every request.
        let near = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "install the app and open it"
        )
        #expect(near.isEmpty)
        let exact = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "the api returned a 500"
        )
        #expect(exact == ["API"])
    }

    @Test("Empty transcript and empty dictionary both yield nothing")
    func emptyInputs() {
        #expect(DictionaryRelevance.relevantPhrases(entries: dictionary, transcript: "").isEmpty)
        #expect(DictionaryRelevance.relevantPhrases(entries: dictionary, transcript: "   ...  ").isEmpty)
        #expect(DictionaryRelevance.relevantPhrases(entries: [], transcript: "kubernetes").isEmpty)
    }

    @Test("Only the matching terms travel, not the neighbours")
    func onlyMatchingTermsTravel() {
        let terms = DictionaryRelevance.relevantPhrases(
            entries: dictionary, transcript: "skylark should call the api on kubernetes"
        )
        #expect(Set(terms) == ["Skylark", "API", "Kubernetes"])
    }

    // MARK: Bounds

    @Test("The per-request term cap is enforced")
    func termCapEnforced() {
        // Every entry matches its own token, so the transcript names them all.
        let many = (0..<(DictionaryRelevance.maxTerms + 10)).map { entry("Zephyrine\($0)") }
        let transcript = many.map(\.phrase).joined(separator: " ")
        let terms = DictionaryRelevance.relevantPhrases(entries: many, transcript: transcript)
        #expect(terms.count == DictionaryRelevance.maxTerms)
        #expect(terms.first == "Zephyrine0")
    }

    @Test("Duplicate phrases are sent once")
    func duplicatesDeduped() {
        let terms = DictionaryRelevance.relevantPhrases(
            entries: [entry("Skylark"), entry("Skylark", "sky lark")], transcript: "open skylark"
        )
        #expect(terms == ["Skylark"])
    }

    @Test("Filtering a large dictionary stays well inside the latency budget")
    func filterIsFast() {
        // It gates the cloud request, so it is ON the latency path.
        let big = (0..<1_000).map { entry("Term\($0)pheric", "termm\($0)pheric") }
        let transcript = String(
            repeating: "the quick brown fox jumps over the lazy dog and then ", count: 10
        )
        let started = ContinuousClock.now
        let terms = DictionaryRelevance.relevantPhrases(entries: big, transcript: transcript)
        let elapsed = started.duration(to: .now)
        #expect(terms.isEmpty)
        #expect(elapsed < .milliseconds(50))
    }
}
