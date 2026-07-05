import Testing
import Foundation
@testable import SkylarkCore

@Suite("Persistence stores (in-memory GRDB)")
struct PersistenceTests {
    private func makeDB() throws -> SkylarkDatabase {
        try SkylarkDatabase.inMemory()
    }

    // MARK: - HistoryStore

    @Test("History append assigns an id and round-trips fields")
    func historyAppendRoundTrips() async throws {
        let store = HistoryStore(db: try makeDB())
        let record = HistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            rawText: "hello world",
            cleanText: "Hello world.",
            modeID: "default",
            engine: "parakeet",
            durationMs: 1200,
            latencyMs: 90
        )
        let inserted = try await store.append(record)
        #expect(inserted.id != nil)

        let recent = try await store.recent(limit: 10)
        #expect(recent.count == 1)
        #expect(recent.first?.rawText == "hello world")
        #expect(recent.first?.cleanText == "Hello world.")
    }

    @Test("History search matches raw and clean text, newest first")
    func historySearch() async throws {
        let store = HistoryStore(db: try makeDB())
        try await store.append(HistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1),
            rawText: "buy milk", engine: "parakeet", durationMs: 1, latencyMs: 1
        ))
        try await store.append(HistoryRecord(
            timestamp: Date(timeIntervalSince1970: 2),
            rawText: "call mom", cleanText: "Call Mom about milk.", engine: "parakeet", durationMs: 1, latencyMs: 1
        ))
        try await store.append(HistoryRecord(
            timestamp: Date(timeIntervalSince1970: 3),
            rawText: "unrelated entry", engine: "parakeet", durationMs: 1, latencyMs: 1
        ))

        let results = try await store.search(text: "milk", limit: 10)
        #expect(results.count == 2)
        // Newest first.
        #expect(results.first?.rawText == "call mom")
    }

    @Test("History updateEditedText and delete")
    func historyUpdateAndDelete() async throws {
        let store = HistoryStore(db: try makeDB())
        let inserted = try await store.append(HistoryRecord(
            rawText: "raw", engine: "parakeet", durationMs: 1, latencyMs: 1
        ))
        let id = try #require(inserted.id)

        try await store.updateEditedText(id: id, new: "edited")
        let afterUpdate = try await store.recent(limit: 1)
        #expect(afterUpdate.first?.cleanText == "edited")

        let deleted = try await store.delete(id: id)
        #expect(deleted)
        let afterDelete = try await store.recent(limit: 1)
        #expect(afterDelete.isEmpty)
    }

    @Test("History purgeAll clears every row")
    func historyPurgeAll() async throws {
        let store = HistoryStore(db: try makeDB())
        for i in 0..<3 {
            try await store.append(HistoryRecord(rawText: "entry \(i)", engine: "parakeet", durationMs: 1, latencyMs: 1))
        }
        try await store.purgeAll()
        let remaining = try await store.recent(limit: 10)
        #expect(remaining.isEmpty)
    }

    // MARK: - DictionaryStore

    @Test("Dictionary upsert inserts then updates the same phrase (case-insensitive)")
    func dictionaryUpsertByPhrase() async throws {
        let store = DictionaryStore(db: try makeDB())
        let first = try await store.upsert(DictionaryEntry(phrase: "Skylark", replacement: nil, source: .manual))
        #expect(first.id != nil)

        // Re-adding with different case + a replacement should update, not duplicate.
        let second = try await store.upsert(DictionaryEntry(phrase: "skylark", replacement: "Skylark™", source: .autoCorrection))
        #expect(second.id == first.id)

        let all = try await store.entries()
        #expect(all.count == 1)
        #expect(all.first?.replacement == "Skylark™")
        #expect(all.first?.source == .autoCorrection)
    }

    @Test("Dictionary delete removes the entry")
    func dictionaryDelete() async throws {
        let store = DictionaryStore(db: try makeDB())
        let entry = try await store.upsert(DictionaryEntry(phrase: "term", replacement: nil, source: .manual))
        let id = try #require(entry.id)
        try await store.delete(id: id)
        let all = try await store.entries()
        #expect(all.isEmpty)
    }

    // MARK: - RegistryStore

    @Test("Registry seedIfEmpty seeds once and is idempotent")
    func registrySeedIdempotent() async throws {
        let store = RegistryStore(db: try makeDB())
        try await store.seedIfEmpty()
        let sttFirst = try await store.all(kind: .stt)
        let cleanupFirst = try await store.all(kind: .cleanup)
        #expect(!sttFirst.isEmpty)
        #expect(!cleanupFirst.isEmpty)

        // Calling again must not duplicate rows.
        try await store.seedIfEmpty()
        let sttSecond = try await store.all(kind: .stt)
        #expect(sttSecond.count == sttFirst.count)
    }

    @Test("Registry upsert replaces an existing slug's fields")
    func registryUpsertReplaces() async throws {
        let store = RegistryStore(db: try makeDB())
        let entry = ModelRegistryEntry(slug: "test/model", label: "Test Model", providerPin: nil, kind: .cleanup, sort: 0)
        try await store.upsert(entry: entry)
        try await store.upsert(entry: ModelRegistryEntry(slug: "test/model", label: "Renamed", providerPin: "groq", kind: .cleanup, sort: 5))

        let all = try await store.all(kind: .cleanup)
        #expect(all.count == 1)
        #expect(all.first?.label == "Renamed")
        #expect(all.first?.providerPin == "groq")
    }

    // MARK: - ModeStore

    @Test("Mode seedIfEmpty seeds Default (local, isDefault) and Raw; idempotent")
    func modeSeedIdempotent() async throws {
        let store = ModeStore(db: try makeDB())
        try await store.seedIfEmpty()
        let modes = try await store.all()
        #expect(modes.count == 2)

        let defaultMode = try #require(modes.first { $0.id == "default" })
        #expect(defaultMode.cleanupTier == .local)
        #expect(defaultMode.isDefault)

        let rawMode = try #require(modes.first { $0.id == "raw" })
        #expect(rawMode.cleanupTier == .raw)
        #expect(!rawMode.isDefault)

        try await store.seedIfEmpty()
        let modesAgain = try await store.all()
        #expect(modesAgain.count == 2)
    }

    @Test("Mode CleanupTier round-trips through the cloud:<slug> serialization")
    func modeCloudTierRoundTrips() async throws {
        let store = ModeStore(db: try makeDB())
        try await store.upsert(ModeRecord(
            id: "work",
            name: "Work",
            bundleIDPattern: "com.microsoft.*",
            cleanupTier: .cloud(slug: "meta-llama/llama-3.1-8b-instruct"),
            registerHint: "professional",
            isDefault: false
        ))

        let modes = try await store.all()
        let work = try #require(modes.first { $0.id == "work" })
        #expect(work.cleanupTier == .cloud(slug: "meta-llama/llama-3.1-8b-instruct"))
        #expect(work.bundleIDPattern == "com.microsoft.*")
        #expect(work.registerHint == "professional")
    }

    @Test("Mode upsert replaces by id; delete removes it")
    func modeUpsertAndDelete() async throws {
        let store = ModeStore(db: try makeDB())
        try await store.upsert(ModeRecord(id: "custom", name: "Custom", cleanupTier: .raw, isDefault: false))
        try await store.upsert(ModeRecord(id: "custom", name: "Custom Renamed", cleanupTier: .local, isDefault: false))

        let modes = try await store.all()
        #expect(modes.count == 1)
        #expect(modes.first?.name == "Custom Renamed")
        #expect(modes.first?.cleanupTier == .local)

        try await store.delete(id: "custom")
        let afterDelete = try await store.all()
        #expect(afterDelete.isEmpty)
    }

    @Test("Mode setDefault(id:) flips exactly one default, atomically")
    func modeSetDefaultUniqueness() async throws {
        let store = ModeStore(db: try makeDB())
        try await store.seedIfEmpty() // "default" (isDefault) + "raw"
        try await store.upsert(ModeRecord(id: "work", name: "Work", cleanupTier: .local, isDefault: false))

        try await store.setDefault(id: "work")
        let afterFirst = try await store.all()
        #expect(afterFirst.filter(\.isDefault).count == 1)
        #expect(afterFirst.first { $0.id == "work" }?.isDefault == true)
        #expect(afterFirst.first { $0.id == "default" }?.isDefault == false)

        // Switching again keeps the invariant — never two defaults at once.
        try await store.setDefault(id: "raw")
        let afterSecond = try await store.all()
        #expect(afterSecond.filter(\.isDefault).count == 1)
        #expect(afterSecond.first { $0.id == "raw" }?.isDefault == true)
        #expect(afterSecond.first { $0.id == "work" }?.isDefault == false)
    }

    @Test("Mode delete is blocked for the default mode")
    func modeDeleteBlockedForDefault() async throws {
        let store = ModeStore(db: try makeDB())
        try await store.seedIfEmpty()

        await #expect(throws: ModeStoreError.self) {
            try await store.delete(id: "default")
        }
        let modes = try await store.all()
        #expect(modes.contains { $0.id == "default" })
    }
}
