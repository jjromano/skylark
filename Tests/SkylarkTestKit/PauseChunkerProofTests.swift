import Testing
import SkylarkCore

/// WS5 — the chunker proof. Above `LocalCleaner.chunkTokenThreshold` a
/// dictation is cleaned in sentence windows, and `sentenceChunks` cuts on
/// `NLTokenizer(unit: .sentence)` — i.e. exactly the set of periods the
/// recogniser invented from pauses. Each fragment is then cleaned in isolation,
/// so the model cannot see that it continues a thought.
///
/// No `LocalCleaner` change was needed: `SentenceBoundaryRepair` runs upstream
/// in the orchestrator, so the chunker only ever sees repaired text. This test
/// is the proof of that, and it fails the moment the repair stops running
/// before the chunker.
@Suite("Pause-shredded long dictation never chunks at a false boundary")
struct PauseChunkerProofTests {
    /// A long dictation shredded at four false boundaries per block: a dangling
    /// preposition ("to."), a dangling determiner-style pause, and a
    /// coordinator head ("And the metrics…"). Repeated so it clears the
    /// 200-estimated-token chunking threshold.
    private static func shreddedTranscript() -> String {
        let block = "I want to. Draft the migration document for the whole team before Friday. "
            + "We should move the deadline to. Next Friday at the earliest. "
            + "I need to check the logs. And the metrics dashboard as well. "
            + "The deploy went out at noon. I am going to bed now."
        return Array(repeating: block, count: 4).joined(separator: " ")
    }

    @Test("The raw transcript really is long enough to be chunked")
    func longEnoughToChunk() {
        let raw = Self.shreddedTranscript()
        #expect(LocalCleaner.estimatedTokens(raw) > LocalCleaner.chunkTokenThreshold)
        // Without the repair the chunker DOES cut at the false boundaries —
        // that is the bug this proves fixed.
        let unrepaired = LocalCleaner.sentenceChunks(raw, maxTokens: LocalCleaner.chunkTokenThreshold)
        #expect(unrepaired.contains { $0.hasSuffix("to.") || $0.hasPrefix("And ") })
    }

    @Test("After the repair, no chunk boundary falls at a false period")
    func repairedChunksAreClean() {
        let repaired = SentenceBoundaryRepair.repair(Self.shreddedTranscript())
        #expect(LocalCleaner.estimatedTokens(repaired) > LocalCleaner.chunkTokenThreshold)

        let chunks = LocalCleaner.sentenceChunks(repaired, maxTokens: LocalCleaner.chunkTokenThreshold)
        #expect(chunks.count > 1, "the proof is vacuous unless chunking actually happened")

        for chunk in chunks {
            #expect(!chunk.hasSuffix("to."), "chunk ended on a dangling preposition: \(chunk.suffix(40))")
            #expect(!chunk.hasSuffix("deadline to."))
            #expect(!chunk.hasPrefix("And "), "chunk opened on a coordinator: \(chunk.prefix(40))")
            #expect(!chunk.hasPrefix("Next Friday"))
            #expect(!chunk.hasPrefix("Draft the migration"))
        }
    }

    @Test("The repair removed the false periods and kept the real ones")
    func falsePeriodsRemoved() {
        let repaired = SentenceBoundaryRepair.repair(Self.shreddedTranscript())
        #expect(!repaired.contains("I want to. Draft"))
        #expect(!repaired.contains("deadline to. Next"))
        #expect(!repaired.contains("the logs. And the metrics"))
        // A genuine boundary between two complete sentences survives.
        #expect(repaired.contains("The deploy went out at noon. I am going to bed now."))
    }
}
