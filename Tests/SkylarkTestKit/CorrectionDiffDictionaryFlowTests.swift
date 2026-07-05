import Testing
import Foundation
import SkylarkCore

/// The History window's edit → auto-learn loop (phase-5a spec §1): editing a
/// history entry's final text runs `CorrectionDiff.diff(raw:edited:)` and the
/// UI upserts accepted pairs as `.autoCorrection` dictionary entries. This
/// exercises that pipeline end-to-end against a real (in-memory) `DictionaryStore`.
@Suite("CorrectionDiff -> dictionary auto-learn flow")
struct CorrectionDiffDictionaryFlowTests {
    private func makeStore() throws -> DictionaryStore {
        DictionaryStore(db: try SkylarkDatabase.inMemory())
    }

    @Test("Edited history text produces the expected dictionary upsert")
    func editProducesUpsert() async throws {
        let store = try makeStore()
        let pairs = CorrectionDiff.pairs(raw: "push to gitub now", edited: "push to github now")
        #expect(pairs == [CorrectionDiff.Pair(from: "gitub", to: "github")])

        for pair in pairs {
            _ = try await store.upsert(DictionaryEntry(phrase: pair.from, replacement: pair.to, source: .autoCorrection))
        }

        let entries = try await store.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.phrase == "gitub")
        #expect(entries.first?.replacement == "github")
        #expect(entries.first?.source == .autoCorrection)
    }

    @Test("Two independent edits upsert two distinct entries")
    func independentEditsUpsertSeparately() async throws {
        let store = try makeStore()
        let editA = CorrectionDiff.pairs(raw: "use realtime data", edited: "use real time data")
        let editB = CorrectionDiff.pairs(raw: "push to gitub now", edited: "push to github now")

        for pair in editA + editB {
            _ = try await store.upsert(DictionaryEntry(phrase: pair.from, replacement: pair.to, source: .autoCorrection))
        }

        let entries = try await store.entries()
        #expect(entries.count == 2)
        #expect(entries.contains { $0.phrase == "realtime" && $0.replacement == "real time" })
        #expect(entries.contains { $0.phrase == "gitub" && $0.replacement == "github" })
    }

    @Test("Re-editing the same phrase upserts in place rather than duplicating")
    func repeatedEditUpsertsInPlace() async throws {
        let store = try makeStore()
        _ = try await store.upsert(DictionaryEntry(phrase: "realtime", replacement: "real time", source: .autoCorrection))
        _ = try await store.upsert(DictionaryEntry(phrase: "realtime", replacement: "real-time", source: .autoCorrection))

        let entries = try await store.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.replacement == "real-time")
    }

    @Test("A candidate toggled off by the user is never upserted")
    func rejectedCandidateSkipsUpsert() async throws {
        let store = try makeStore()
        let pairs = CorrectionDiff.pairs(raw: "push to gitub now", edited: "push to github now")
        // Simulate the History window's chip UI: default ON, but the user
        // toggles this one off before confirming — the caller filters it out.
        let accepted = pairs.filter { _ in false }
        for pair in accepted {
            _ = try await store.upsert(DictionaryEntry(phrase: pair.from, replacement: pair.to, source: .autoCorrection))
        }

        let entries = try await store.entries()
        #expect(entries.isEmpty)
    }

    @Test("A no-op edit (identical text) proposes nothing to upsert")
    func noOpEditProposesNothing() async throws {
        let store = try makeStore()
        let pairs = CorrectionDiff.pairs(raw: "same words here", edited: "same words here")
        #expect(pairs.isEmpty)
        let entries = try await store.entries()
        #expect(entries.isEmpty)
    }
}
