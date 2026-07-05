import Foundation
import GRDB

/// Errors surfaced by the persistence layer that aren't naturally a GRDB error
/// (e.g. a raw-SQL upsert that somehow didn't leave a row behind).
public enum PersistenceError: Error, Sendable, Equatable {
    case upsertFailed
}

/// GRDB-backed database (ARCHITECTURE §5). Wraps one `DatabaseQueue`, applies
/// the "v1" migration, and hands the queue to the stores. `DatabaseQueue` is
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
        try migrator.migrate(dbQueue)
    }

    /// `~/Library/Application Support/Skylark/skylark.sqlite` (ARCHITECTURE §5).
    public static func onDisk() throws -> SkylarkDatabase {
        try SkylarkDatabase(path: ModelPaths.appSupport.appendingPathComponent("skylark.sqlite"))
    }

    /// In-memory database — tests only.
    public static func inMemory() throws -> SkylarkDatabase {
        try SkylarkDatabase(path: nil)
    }
}
