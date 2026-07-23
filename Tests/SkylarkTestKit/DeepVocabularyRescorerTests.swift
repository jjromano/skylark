import Testing
import Foundation
@testable import SkylarkCore

@Suite("Deep vocabulary term mapping")
struct DeepVocabularyMappingTests {
    private func entry(_ phrase: String, _ misspellings: [String] = []) -> DictionaryEntry {
        DictionaryEntry(phrase: phrase, misspellings: misspellings, source: .manual)
    }

    @Test("phrase maps to text, misspellings map to aliases")
    func mapsPhraseAndAliases() {
        let terms = DeepVocabularyMapping.terms(from: [
            entry("Skylark", ["sky lark", "skylock"]),
        ])
        #expect(terms == [VocabularyTerm(text: "Skylark", aliases: ["sky lark", "skylock"])])
    }

    @Test("entry with no misspellings yields a term with empty aliases")
    func noAliases() {
        let terms = DeepVocabularyMapping.terms(from: [entry("Parakeet")])
        #expect(terms == [VocabularyTerm(text: "Parakeet", aliases: [])])
    }

    @Test("blank phrase is dropped; blank aliases are trimmed out")
    func trimsAndDrops() {
        let terms = DeepVocabularyMapping.terms(from: [
            entry("   ", ["x"]),                    // dropped: empty phrase
            entry("  Nova  ", [" ", "novva ", ""]), // phrase + aliases trimmed/filtered
        ])
        #expect(terms == [VocabularyTerm(text: "Nova", aliases: ["novva"])])
    }

    @Test("order is preserved")
    func preservesOrder() {
        let terms = DeepVocabularyMapping.terms(from: [entry("A"), entry("B"), entry("C")])
        #expect(terms.map(\.text) == ["A", "B", "C"])
    }
}

@Suite("IdleTimer")
struct IdleTimerTests {
    /// Permit-based async latch used as the injected "sleep": each `signal`
    /// releases one pending (or future) `wait`. Permit counting removes the
    /// signal-before-wait race, so the timeout elapses exactly when the test says.
    private actor Latch {
        private var permits = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func signal() {
            if waiters.isEmpty { permits += 1 } else { waiters.removeFirst().resume() }
        }
        func wait() async {
            if permits > 0 { permits -= 1; return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private actor FireCount {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    private func spin(until predicate: @Sendable () async -> Bool) async {
        for _ in 0..<200 where await predicate() == false {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("fires onFire after the timeout elapses")
    func firesAfterTimeout() async {
        let latch = Latch()
        let count = FireCount()
        let timer = IdleTimer(timeout: .seconds(300), sleep: { _ in await latch.wait() })
        await timer.touch(onFire: { await count.bump() })
        #expect(await count.value == 0)   // still waiting
        await latch.signal()              // timeout "elapses"
        await spin { await count.value == 1 }
        #expect(await count.value == 1)
    }

    @Test("cancel before the timeout prevents the fire")
    func cancelPreventsFire() async {
        let latch = Latch()
        let count = FireCount()
        let timer = IdleTimer(timeout: .seconds(300), sleep: { _ in await latch.wait() })
        await timer.touch(onFire: { await count.bump() })
        await timer.cancel()
        await latch.signal()              // release the (now cancelled) sleep
        await spin { await count.value > 0 } // give any fire a chance to happen
        #expect(await count.value == 0)
    }

    @Test("a fresh touch restarts the countdown (only one fire)")
    func touchRestarts() async {
        let latch = Latch()
        let count = FireCount()
        let timer = IdleTimer(timeout: .seconds(300), sleep: { _ in await latch.wait() })
        await timer.touch(onFire: { await count.bump() })
        await timer.touch(onFire: { await count.bump() }) // cancels the first
        // Two signals cover both the cancelled first sleep and the live second one,
        // regardless of registration order; only the live one may fire.
        await latch.signal()
        await latch.signal()
        await spin { await count.value == 1 }
        #expect(await count.value == 1) // exactly one fire, not two
    }
}
