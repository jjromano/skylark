import Foundation
import GRDB

/// Errors surfaced by the persistence layer that aren't naturally a GRDB error
/// (e.g. a raw-SQL upsert that somehow didn't leave a row behind).
public enum PersistenceError: Error, Sendable, Equatable {
    case upsertFailed
}

/// GRDB-backed database (ARCHITECTURE §5). Wraps one `DatabaseQueue`, applies
/// the "v1"/"v2" migrations, and hands the queue to the stores. `DatabaseQueue` is
/// GRDB's own thread-safe, `Sendable` serialized-access wrapper, so this type
/// is safe to share across actors.
public final class SkylarkDatabase: Sendable {
    public let dbQueue: DatabaseQueue

    /// - Parameter path: SQLite file location. Pass `nil` for an in-memory
    ///   database (tests).
    public init(path: URL?) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // No-op for `:memory:` databases (SQLite always uses "memory"
            // journal mode there); this is what gives us WAL on disk.
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }

        if let path {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            dbQueue = try DatabaseQueue(path: path.path, configuration: configuration)
        } else {
            dbQueue = try DatabaseQueue(configuration: configuration)
        }

        try Self.migrator.migrate(dbQueue)
    }

    /// `~/Library/Application Support/Skylark/skylark.sqlite` (ARCHITECTURE §5).
    public static func onDisk() throws -> SkylarkDatabase {
        try SkylarkDatabase(path: ModelPaths.appSupport.appendingPathComponent("skylark.sqlite"))
    }

    /// In-memory database — tests only.
    public static func inMemory() throws -> SkylarkDatabase {
        try SkylarkDatabase(path: nil)
    }

    /// The full "v1" -> "v3" migration chain. Exposed (rather than inlined in
    /// `init`) so tests can run it partially (`migrate(_:upTo:)`) to seed a
    /// pre-"v3" database, insert legacy-shaped rows, then run the rest of the
    /// chain and assert on the migration's own effects (e.g. the `word_count`
    /// backfill) — a fresh `SkylarkDatabase` always starts fully migrated,
    /// which otherwise leaves no way to observe an intermediate state.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull()
                t.column("raw_text", .text).notNull()
                t.column("clean_text", .text)
                t.column("mode_id", .text)
                t.column("engine", .text).notNull()
                t.column("duration_ms", .integer).notNull()
                t.column("latency_ms", .integer).notNull()
                t.column("audio_path", .text)
            }
            try db.create(table: "dictionary") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("phrase", .text).notNull().unique().collate(.nocase)
                t.column("replacement", .text)
                t.column("source", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(table: "modes") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("bundle_id_pattern", .text)
                t.column("engine", .text)
                t.column("cleanup_tier", .text).notNull()
                t.column("cloud_cleanup_slug", .text)
                t.column("register_hint", .text)
                t.column("is_default", .boolean).notNull()
            }
            try db.create(table: "model_registry") { t in
                t.column("slug", .text).primaryKey()
                t.column("label", .text).notNull()
                t.column("provider_pin", .text)
                t.column("kind", .text).notNull()
                t.column("sort", .integer).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            // Invert the dictionary model: `phrase` is now always the correct
            // spelling, and `misspellings` (JSON array TEXT) lists mistakes
            // that get rewritten to it, replacing the old `replacement` column.
            try db.create(table: "dictionary_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("phrase", .text).notNull().unique().collate(.nocase)
                t.column("misspellings", .text)
                t.column("source", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }

            let oldRows = try Row.fetchAll(db, sql: "SELECT phrase, replacement, source, created_at FROM dictionary")
            for row in oldRows {
                let phrase: String = row["phrase"]
                let replacement: String? = row["replacement"]
                let source: String = row["source"]
                let createdAt: Date = row["created_at"]

                let (correctWord, misspellings) = DictionaryRecord.migrateLegacyRow(phrase: phrase, replacement: replacement)
                let misspellingsJSON = DictionaryRecord.encodeMisspellings(misspellings)

                // Two old rows can map to the same correct word (e.g. two
                // distinct misspellings of it); tolerate that by keeping the
                // first and ignoring the rest rather than failing the migration.
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO dictionary_new (phrase, misspellings, source, created_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [correctWord, misspellingsJSON, source, createdAt]
                )
            }

            try db.drop(table: "dictionary")
            try db.rename(table: "dictionary_new", to: "dictionary")
        }

        migrator.registerMigration("v3") { db in
            // Usage-stats + per-app attribution columns (workstream B spec §1).
            try db.alter(table: "history") { t in
                t.add(column: "word_count", .integer).notNull().defaults(to: 0)
                t.add(column: "app_bundle_id", .text)
                t.add(column: "app_name", .text)
            }

            // Backfill word_count for existing rows from clean_text ?? raw_text.
            let rows = try Row.fetchAll(db, sql: "SELECT id, raw_text, clean_text FROM history")
            for row in rows {
                let id: Int64 = row["id"]
                let rawText: String = row["raw_text"]
                let cleanText: String? = row["clean_text"]
                let count = WordCount.count(cleanText ?? rawText)
                try db.execute(sql: "UPDATE history SET word_count = ? WHERE id = ?", arguments: [count, id])
            }

            // Stats queries (recent-days rollups, streaks) always filter/sort by
            // timestamp; index it now that the table can grow unbounded.
            try db.create(index: "history_on_timestamp", on: "history", columns: ["timestamp"], ifNotExists: true)

            // Whole-utterance text expansion (workstream B spec §4). `trigger`
            // is a SQL keyword; GRDB quotes every identifier it generates so
            // this is safe as a column name.
            try db.create(table: "snippets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trigger", .text).notNull().unique().collate(.nocase)
                t.column("replacement", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v4") { db in
            // Cleanup provenance: which engine ("raw", "local", or a cloud
            // model slug) actually produced clean_text — so History can show
            // real model usage vs. silent fallbacks. Nil for pre-v4 rows and
            // rows whose cleanup never landed.
            try db.alter(table: "history") { t in
                t.add(column: "cleanup_engine", .text)
            }
        }

        migrator.registerMigration("v5") { db in
            // Per-mode Whisper Mode override (R3): NULL = "follow the global
            // toggle" (`WhisperModeOverride.followGlobal`), "on"/"off" pin the
            // mode to always-on/always-off regardless of the global setting.
            // Purely additive — every pre-v5 row reads back as NULL, i.e.
            // follow-global, with no backfill needed.
            try db.alter(table: "modes") { t in
                t.add(column: "whisper_mode_override", .text)
            }
        }

        migrator.registerMigration("v6") { db in
            // Per-mode custom cleanup instruction (PRD Appendix A's last open
            // v1-backlog item, "user-defined custom mode prompts UI"). NULL =
            // no extra instruction, i.e. exactly the pre-v6 prompt. Purely
            // additive; every existing row reads back as NULL with no backfill.
            //
            // This ADDS to the standard cleanup contract, it never replaces it:
            // the faithfulness/hygiene guard still runs on the output, so an
            // over-aggressive user instruction gets rejected and raw stands.
            try db.alter(table: "modes") { t in
                t.add(column: "custom_prompt", .text)
            }
        }

        return migrator
    }
}
