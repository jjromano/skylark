import Testing
import SkylarkCore

@Suite("SpokenAddresses — the QA examples")
struct SpokenAddressesQATests {
    @Test("URL: dot already punctuated, slash left as words (D12 live repro)")
    func urlExample() {
        #expect(SpokenAddresses.format("github.com slash jjromano slash skylark")
            == "github.com/jjromano/skylark")
    }

    @Test("URL: dot never punctuated either — the safety-net path")
    func urlExampleAllSpoken() {
        #expect(SpokenAddresses.format("github dot com slash jjromano slash skylark")
            == "github.com/jjromano/skylark")
    }

    @Test("Email: dot already punctuated, at left as a word (D12 live repro)")
    func emailExample() {
        #expect(SpokenAddresses.format("jjromano at example.com") == "jjromano@example.com")
    }
}

@Suite("SpokenAddresses — dot chains")
struct SpokenAddressesDotChainTests {
    @Test("A single spoken dot before a known TLD joins")
    func simpleDot() {
        #expect(SpokenAddresses.format("visit example dot com") == "visit example.com")
        #expect(SpokenAddresses.format("get it from skylark dot app") == "get it from skylark.app")
    }

    @Test("A multi-hop dot chain resolves from its TLD tail inward")
    func chain() {
        #expect(SpokenAddresses.format("go to www dot example dot co dot uk")
            == "go to www.example.co.uk")
    }
}

@Suite("SpokenAddresses — slash chains")
struct SpokenAddressesSlashChainTests {
    @Test("Forward slash reads the same as slash")
    func forwardSlash() {
        #expect(SpokenAddresses.format("github.com forward slash jjromano")
            == "github.com/jjromano")
    }

    @Test("Backslash is a different word and is left alone")
    func backslashUntouched() {
        #expect(SpokenAddresses.format("use a backslash before the quote")
            == "use a backslash before the quote")
    }
}

@Suite("SpokenAddresses — prose is never touched")
struct SpokenAddressesProseTests {
    @Test("'dot' in ordinary prose stays a word")
    func dotProse() {
        #expect(SpokenAddresses.format("connect the dot") == "connect the dot")
    }

    @Test("'slash' in ordinary prose stays a word")
    func slashProse() {
        #expect(SpokenAddresses.format("a slash in the price") == "a slash in the price")
    }

    @Test("'at' with a stopword left side stays prose even without a domain")
    func atStopwordProse() {
        #expect(SpokenAddresses.format("meet me at the office") == "meet me at the office")
    }

    @Test("'at' with a non-domain right side stays prose")
    func atNoDomainProse() {
        #expect(SpokenAddresses.format("look at it") == "look at it")
    }

    @Test("A capitalised 'At' opening a sentence is left alone (no left word to join)")
    func capitalizedAtSentenceStart() {
        #expect(SpokenAddresses.format("At example.com you can find the docs.")
            == "At example.com you can find the docs.")
    }
}

@Suite("SpokenAddresses — idempotency and punctuation")
struct SpokenAddressesIdempotencyTests {
    @Test("Formatting an already-formatted address is a no-op")
    func idempotent() {
        let inputs = [
            "github.com slash jjromano slash skylark",
            "jjromano at example.com",
            "www dot example dot co dot uk",
            "connect the dot",
            "a slash in the price",
        ]
        for input in inputs {
            let once = SpokenAddresses.format(input)
            #expect(SpokenAddresses.format(once) == once)
        }
    }

    @Test("A sentence-final period after a converted address is preserved, not swallowed")
    func sentenceFinalPeriodPreserved() {
        #expect(SpokenAddresses.format("check out github.com slash jjromano slash skylark.")
            == "check out github.com/jjromano/skylark.")
        #expect(SpokenAddresses.format("email jjromano at example.com.")
            == "email jjromano@example.com.")
    }
}
