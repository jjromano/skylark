import Testing
import Foundation
import GRDB
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

    @Test("History updateEditedText refreshes word_count from the new text")
    func historyUpdateRefreshesWordCount() async throws {
        let store = HistoryStore(db: try makeDB())
        let inserted = try await store.append(HistoryRecord(
            rawText: "one two three", engine: "parakeet", durationMs: 1, latencyMs: 1, wordCount: 3
        ))
        let id = try #require(inserted.id)

        try await store.updateEditedText(id: id, new: "Cleaned up sentence here.")
        let row = try #require(try await store.recent(limit: 1).first)
        #expect(row.cleanText == "Cleaned up sentence here.")
        #expect(row.wordCount == 4)
    }

    @Test("prune deletes rows older than the cutoff and their audio files, keeps recent rows")
    func historyPruneDeletesOldRowsAndAudio() async throws {
        let store = HistoryStore(db: try makeDB())
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let oldAudioURL = tempDir.appendingPathComponent("old.wav")
        try Data([0x00]).write(to: oldAudioURL)

        let calendar = Calendar.current
        let oldDate = try #require(calendar.date(byAdding: .day, value: -40, to: Date()))
        let recentDate = try #require(calendar.date(byAdding: .day, value: -5, to: Date()))

        try await store.append(HistoryRecord(
            timestamp: oldDate, rawText: "old", engine: "parakeet", durationMs: 1, latencyMs: 1,
            audioPath: oldAudioURL.path
        ))
        try await store.append(HistoryRecord(
            timestamp: recentDate, rawText: "recent", engine: "parakeet", durationMs: 1, latencyMs: 1
        ))

        let deletedCount = try await store.prune(olderThanDays: 30)
        #expect(deletedCount == 1)

        let remaining = try await store.recent(limit: 10)
        #expect(remaining.count == 1)
        #expect(remaining.first?.rawText == "recent")
        #expect(!FileManager.default.fileExists(atPath: oldAudioURL.path))
    }

    @Test("prune is a no-op when nothing is older than the cutoff")
    func historyPruneNoOpWhenNothingOld() async throws {
        let store = HistoryStore(db: try makeDB())
        try await store.append(HistoryRecord(rawText: "now", engine: "parakeet", durationMs: 1, latencyMs: 1))

        let deletedCount = try await store.prune(olderThanDays: 30)
        #expect(deletedCount == 0)
        let remaining = try await store.recent(limit: 10)
        #expect(remaining.count == 1)
    }

    // MARK: - Migration v3 (word_count backfill, app columns, snippets table)

    @Test("v3 migration backfills word_count from clean_text ?? raw_text on pre-existing rows")
    func v3MigrationBackfillsWordCount() throws {
        // `SkylarkDatabase.inMemory()` always ends up fully migrated (v1 through
        // v3 run in one shot on an empty `history` table), so — same reasoning
        // as the v2 dictionary migration test above — there's no way to observe
        // the backfill's effect through that entry point. Drive the shared
        // `migrator` directly: apply up through "v2", insert rows in that
        // pre-"v3" shape, then run the rest of the chain and inspect what it did.
        let dbQueue = try DatabaseQueue()
        try SkylarkDatabase.migrator.migrate(dbQueue, upTo: "v2")

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO history (timestamp, raw_text, clean_text, engine, duration_ms, latency_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [Date(), "hello world", nil, "parakeet", 100, 10]
            )
            try db.execute(
                sql: """
                INSERT INTO history (timestamp, raw_text, clean_text, engine, duration_ms, latency_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [Date(), "raw text is ignored here", "Cleaned  text   here.", "parakeet", 100, 10]
            )
        }

        try SkylarkDatabase.migrator.migrate(dbQueue)

        let counts = try dbQueue.read { db in
            try Int.fetchAll(db, sql: "SELECT word_count FROM history ORDER BY id")
        }
        #expect(counts == [2, 3])

        let historyColumns = try dbQueue.read { db in try db.columns(in: "history").map(\.name) }
        #expect(historyColumns.contains("app_bundle_id"))
        #expect(historyColumns.contains("app_name"))

        let snippetColumns = try dbQueue.read { db in try db.columns(in: "snippets").map(\.name) }
        #expect(snippetColumns.contains("trigger"))
        #expect(snippetColumns.contains("replacement"))
    }

    @Test("Freshly migrated database already has the v3 history/snippets schema")
    func freshDatabaseHasV3Schema() async throws {
        let db = try makeDB()
        let historyColumns = try await db.dbQueue.read { conn in
            try conn.columns(in: "history").map(\.name)
        }
        #expect(historyColumns.contains("word_count"))
        #expect(historyColumns.contains("app_bundle_id"))
        #expect(historyColumns.contains("app_name"))

        let snippetColumns = try await db.dbQueue.read { conn in
            try conn.columns(in: "snippets").map(\.name)
        }
        #expect(snippetColumns.contains("id"))
        #expect(snippetColumns.contains("trigger"))
        #expect(snippetColumns.contains("replacement"))
        #expect(snippetColumns.contains("created_at"))
    }

    // MARK: - DictionaryStore

    @Test("Dictionary upsert inserts then updates the same phrase (case-insensitive)")
    func dictionaryUpsertByPhrase() async throws {
        let store = DictionaryStore(db: try makeDB())
        let first = try await store.upsert(DictionaryEntry(phrase: "Skylark", source: .manual))
        #expect(first.id != nil)

        // Re-adding with different case + misspellings should update, not duplicate.
        let second = try await store.upsert(DictionaryEntry(phrase: "skylark", misspellings: ["Skylerk"], source: .autoCorrection))
        #expect(second.id == first.id)

        let all = try await store.entries()
        #expect(all.count == 1)
        #expect(all.first?.misspellings == ["Skylerk"])
        #expect(all.first?.source == .autoCorrection)
    }

    @Test("Dictionary upsert/round-trip preserves multiple misspellings")
    func dictionaryUpsertRoundTripsMisspellings() async throws {
        let store = DictionaryStore(db: try makeDB())
        _ = try await store.upsert(DictionaryEntry(phrase: "GitHub", misspellings: ["gitub", "guthub"], source: .manual))

        let all = try await store.entries()
        #expect(all.count == 1)
        #expect(all.first?.phrase == "GitHub")
        #expect(all.first?.misspellings == ["gitub", "guthub"])
    }

    @Test("Dictionary delete removes the entry and reports it existed")
    func dictionaryDelete() async throws {
        let store = DictionaryStore(db: try makeDB())
        let entry = try await store.upsert(DictionaryEntry(phrase: "term", source: .manual))
        let id = try #require(entry.id)
        let deleted = try await store.delete(id: id)
        #expect(deleted)
        let all = try await store.entries()
        #expect(all.isEmpty)
    }

    @Test("Dictionary delete of an already-gone id reports false (no throw)")
    func dictionaryDeleteAlreadyGone() async throws {
        let store = DictionaryStore(db: try makeDB())
        let entry = try await store.upsert(DictionaryEntry(phrase: "term", source: .manual))
        let id = try #require(entry.id)
        try await store.delete(id: id) // first delete succeeds
        let deletedAgain = try await store.delete(id: id) // already gone
        #expect(!deletedAgain)
    }

    @Test("v2 migration maps an old (phrase, replacement) row to (correctWord, [misspelling])")
    func v2MigrationMapsOldRowsToNewSchema() throws {
        // SkylarkDatabase's "v2" migration uses this exact helper to convert
        // each legacy `dictionary` row (phrase = mistake, replacement =
        // correction or nil) into the new shape (phrase = correction,
        // misspellings = [mistake]). Exercise it directly since a fresh
        // `SkylarkDatabase` always starts fully migrated (v1 -> v2 in one
        // shot), leaving no way to observe an intermediate v1-only state.
        let withReplacement = DictionaryRecord.migrateLegacyRow(phrase: "gitub", replacement: "github")
        #expect(withReplacement.phrase == "github")
        #expect(withReplacement.misspellings == ["gitub"])

        // A bias-only row (replacement == nil) keeps its phrase as the
        // correct word and has no misspellings to learn.
        let biasOnly = DictionaryRecord.migrateLegacyRow(phrase: "Skylark", replacement: nil)
        #expect(biasOnly.phrase == "Skylark")
        #expect(biasOnly.misspellings.isEmpty)
    }

    @Test("Freshly migrated database has the v2 dictionary schema (misspellings, no replacement)")
    func freshDatabaseHasV2Schema() async throws {
        let db = try makeDB()
        let columns = try await db.dbQueue.read { conn in
            try conn.columns(in: "dictionary").map(\.name)
        }
        #expect(columns.contains("misspellings"))
        #expect(!columns.contains("replacement"))
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

    @Test("Registry syncSeed inserts every seed entry and is idempotent")
    func registrySyncSeedInsertsMissing() async throws {
        let store = RegistryStore(db: try makeDB())
        try await store.syncSeed()

        let stt = try await store.all(kind: .stt)
        let cleanup = try await store.all(kind: .cleanup)
        #expect(stt.count == ModelRegistryEntry.seed.filter { $0.kind == .stt }.count)
        #expect(cleanup.count == ModelRegistryEntry.seed.filter { $0.kind == .cleanup }.count)

        // Calling again must not duplicate rows.
        try await store.syncSeed()
        let sttAgain = try await store.all(kind: .stt)
        #expect(sttAgain.count == stt.count)
    }

    @Test("Registry syncSeed never deletes rows outside the seed list")
    func registrySyncSeedNeverDeletes() async throws {
        let store = RegistryStore(db: try makeDB())
        try await store.upsert(entry: ModelRegistryEntry(
            slug: "custom/not-in-seed", label: "Mine", providerPin: nil, kind: .stt, sort: 50
        ))

        try await store.syncSeed()

        let stt = try await store.all(kind: .stt)
        #expect(stt.contains { $0.slug == "custom/not-in-seed" })
    }

    @Test("Registry syncSeed retires a seeded row whose slug left the seed, keeping user rows")
    func registrySyncSeedRetiresStaleSeededRow() async throws {
        let db = try makeDB()
        let store = RegistryStore(db: db)
        try await store.syncSeed()

        // Simulate a row an OLDER seed inserted (seeded=1) that the current
        // seed no longer contains — e.g. a deprecated cloud model.
        try await db.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO model_registry (slug, label, provider_pin, kind, sort, seeded)
                VALUES ('legacy/deprecated-model', 'Old Model', 'groq', 'cleanup', 9, 1)
                """
            )
        }
        // And a user-created row also absent from the seed (must survive).
        try await store.upsert(entry: ModelRegistryEntry(
            slug: "custom/kept-model", label: "Mine", providerPin: nil, kind: .cleanup, sort: 60
        ))

        try await store.syncSeed()

        let cleanup = try await store.all(kind: .cleanup)
        #expect(!cleanup.contains { $0.slug == "legacy/deprecated-model" })
        #expect(cleanup.contains { $0.slug == "custom/kept-model" })
        #expect(cleanup.count == ModelRegistryEntry.seed.filter { $0.kind == .cleanup }.count + 1)
    }

    @Test("Registry syncSeed leaves a user's own row alone even if its slug collides with a seed slug")
    func registrySyncSeedPreservesUserOwnedRow() async throws {
        let store = RegistryStore(db: try makeDB())
        let seedSlug = try #require(ModelRegistryEntry.seed.first { $0.kind == .cleanup }).slug

        // A user hand-adds (or edits) an entry that happens to share a seed
        // slug. `upsert` never marks a row `seeded`, so `syncSeed()` must
        // leave it exactly as the user set it rather than overwriting it
        // back to the catalog's label.
        try await store.upsert(entry: ModelRegistryEntry(
            slug: seedSlug, label: "My Custom Label", providerPin: "custom-pin", kind: .cleanup, sort: 99
        ))

        try await store.syncSeed()

        let afterSync = try await store.all(kind: .cleanup)
        let userRow = try #require(afterSync.first { $0.slug == seedSlug })
        #expect(userRow.label == "My Custom Label")
        #expect(userRow.providerPin == "custom-pin")
    }

    @Test("Registry syncSeed refreshes a stale row that it seeded itself")
    func registrySyncSeedRefreshesStaleSeededRow() async throws {
        let db = try makeDB()
        let store = RegistryStore(db: db)
        let seedEntry = try #require(ModelRegistryEntry.seed.first { $0.kind == .cleanup })

        // First sync seeds the row for real (marks it `seeded`).
        try await store.syncSeed()

        // Simulate an older app version having seeded this row with
        // different metadata (e.g. the catalog's label/pin changed since).
        try await db.dbQueue.write { conn in
            try conn.execute(
                sql: "UPDATE model_registry SET label = ?, provider_pin = ? WHERE slug = ?",
                arguments: ["Stale Seeded Label", "stale-pin", seedEntry.slug]
            )
        }

        try await store.syncSeed()

        let refreshed = try await store.all(kind: .cleanup)
        let refreshedRow = try #require(refreshed.first { $0.slug == seedEntry.slug })
        #expect(refreshedRow.label == seedEntry.label)
        #expect(refreshedRow.providerPin == seedEntry.providerPin)
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

    // MARK: - Migration v5 (whisper_mode_override column, R3)

    @Test("v5 migration adds whisper_mode_override as a nullable column; pre-existing rows read back as follow-global")
    func v5MigrationAddsWhisperModeOverrideColumn() throws {
        // Same reasoning as the v3 test above: a fresh `SkylarkDatabase` always
        // starts fully migrated, so there's no way to observe the pre-v5 shape
        // through that entry point. Drive the shared `migrator` directly: apply
        // up through "v4", insert a row in that pre-"v5" shape (no
        // whisper_mode_override column exists yet), then run the rest of the
        // chain and confirm the column exists and the old row decodes as
        // `.followGlobal` (the additive migration's whole point — no backfill
        // needed because NULL already means "no override").
        let dbQueue = try DatabaseQueue()
        try SkylarkDatabase.migrator.migrate(dbQueue, upTo: "v4")

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO modes (id, name, bundle_id_pattern, engine, cleanup_tier, cloud_cleanup_slug, register_hint, is_default)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["default", "Default", nil, nil, "local", nil, nil, true]
            )
        }

        try SkylarkDatabase.migrator.migrate(dbQueue)

        let columns = try dbQueue.read { db in try db.columns(in: "modes").map(\.name) }
        #expect(columns.contains("whisper_mode_override"))

        let modes = try dbQueue.read { db in try ModeRecord.fetchAll(db) }
        let preExisting = try #require(modes.first { $0.id == "default" })
        #expect(preExisting.whisperModeOverride == .followGlobal)
    }

    @Test("Freshly migrated database already has the v5 modes schema")
    func freshDatabaseHasV5Schema() async throws {
        let db = try makeDB()
        let columns = try await db.dbQueue.read { conn in try conn.columns(in: "modes").map(\.name) }
        #expect(columns.contains("whisper_mode_override"))
    }

    // MARK: - Migration v6 (custom_prompt column, PRD Appendix A)

    @Test("v6 migration adds custom_prompt as a nullable column; pre-existing rows read back as nil")
    func v6MigrationAddsCustomPromptColumn() throws {
        // Same technique as the v5 test above: migrate up through "v5", write a
        // row in that pre-"v6" shape, then finish the chain. The additive
        // migration's point is that NULL already means "no custom instruction",
        // so an existing mode must survive with no backfill and produce a prompt
        // byte-identical to the pre-v6 one.
        let dbQueue = try DatabaseQueue()
        try SkylarkDatabase.migrator.migrate(dbQueue, upTo: "v5")

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO modes (id, name, bundle_id_pattern, engine, cleanup_tier, cloud_cleanup_slug, register_hint, is_default)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["default", "Default", nil, nil, "local", nil, nil, true]
            )
        }

        try SkylarkDatabase.migrator.migrate(dbQueue)

        let columns = try dbQueue.read { db in try db.columns(in: "modes").map(\.name) }
        #expect(columns.contains("custom_prompt"))

        let modes = try dbQueue.read { db in try ModeRecord.fetchAll(db) }
        let preExisting = try #require(modes.first { $0.id == "default" })
        #expect(preExisting.customPrompt == nil)
    }

    @Test("Mode custom_prompt round-trips through the store, sanitized")
    func modeCustomPromptRoundTrips() async throws {
        let store = ModeStore(db: try makeDB())
        try await store.upsert(ModeRecord(
            id: "mail", name: "Mail", cleanupTier: .local,
            customPrompt: "  sign off with 'Thanks, JJ'  ", isDefault: false
        ))
        try await store.upsert(ModeRecord(
            id: "plain", name: "Plain", cleanupTier: .raw, isDefault: false
        ))

        let modes = try await store.all()
        // Stored trimmed, not as typed.
        #expect(modes.first { $0.id == "mail" }?.customPrompt == "sign off with 'Thanks, JJ'")
        // Unspecified stays NULL rather than becoming an empty string.
        #expect(modes.first { $0.id == "plain" }?.customPrompt == nil)
    }

    // MARK: - Whisper Mode override (R3)

    @Test("Mode whisper_mode_override round-trips through the store (on/off/follow-global)")
    func modeWhisperModeOverrideRoundTrips() async throws {
        let store = ModeStore(db: try makeDB())
        try await store.upsert(ModeRecord(
            id: "loud", name: "Loud", cleanupTier: .raw, whisperModeOverride: .off, isDefault: false
        ))
        try await store.upsert(ModeRecord(
            id: "quiet", name: "Quiet", cleanupTier: .raw, whisperModeOverride: .on, isDefault: false
        ))
        try await store.upsert(ModeRecord(
            id: "neutral", name: "Neutral", cleanupTier: .raw, isDefault: false
        ))

        let modes = try await store.all()
        #expect(modes.first { $0.id == "loud" }?.whisperModeOverride == .off)
        #expect(modes.first { $0.id == "quiet" }?.whisperModeOverride == .on)
        // Default (unspecified at construction) is `.followGlobal`, stored NULL.
        #expect(modes.first { $0.id == "neutral" }?.whisperModeOverride == .followGlobal)
    }

    @Test("Mode seedIfEmpty defaults are follow-global")
    func modeSeedDefaultsFollowGlobal() async throws {
        let store = ModeStore(db: try makeDB())
        try await store.seedIfEmpty()
        let modes = try await store.all()
        #expect(modes.allSatisfy { $0.whisperModeOverride == .followGlobal })
    }
}
