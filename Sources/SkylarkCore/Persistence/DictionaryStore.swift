import Foundation
import GRDB

/// GRDB row for the `dictionary` table; converts to/from the shared
/// `DictionaryEntry` (SkylarkCore/Models).
struct DictionaryRecord: Sendable, Equatable, Codable {
    var id: Int64?
    var phrase: String
    var replacement: String?
    var source: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, phrase, replacement, source
        case createdAt = "created_at"
    }
}

extension DictionaryRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "dictionary"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension DictionaryRecord {
    init(entry: DictionaryEntry) {
        id = entry.id
        phrase = entry.phrase
        replacement = entry.replacement
        source = entry.source.rawValue
        createdAt = entry.createdAt
    }

    var asEntry: DictionaryEntry {
        DictionaryEntry(
            id: id,
            phrase: phrase,
            replacement: replacement,
            source: DictionaryEntry.Source(rawValue: source) ?? .manual,
            createdAt: createdAt
        )
    }
}

/// GRDB-backed `DictionaryProviding`. Upserts by `phrase` (case-insensitive,
/// enforced by the column's `COLLATE NOCASE`), so re-adding a known phrase
/// updates it in place rather than duplicating.
public actor DictionaryStore: DictionaryProviding {
    private let db: SkylarkDatabase

    public init(db: SkylarkDatabase) {
        self.db = db
    }

    public func entries() async throws -> [DictionaryEntry] {
        try await db.dbQueue.read { db in
            try DictionaryRecord.fetchAll(db).map(\.asEntry)
        }
    }

    @discardableResult
    public func upsert(_ entry: DictionaryEntry) async throws -> DictionaryEntry {
        try await db.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO dictionary (phrase, replacement, source, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(phrase) DO UPDATE SET
                    replacement = excluded.replacement,
                    source = excluded.source
                """,
                arguments: [entry.phrase, entry.replacement, entry.source.rawValue, entry.createdAt]
            )
            guard let record = try DictionaryRecord.filter(Column("phrase") == entry.phrase).fetchOne(db) else {
                throw PersistenceError.upsertFailed
            }
            return record.asEntry
        }
    }

    public func delete(id: Int64) async throws {
        _ = try await db.dbQueue.write { db in
            try DictionaryRecord.deleteOne(db, key: id)
        }
    }

    /// In-place update by id (phrase + replacement), for inline-editing an
    /// existing entry. Unlike `upsert`, this never inserts a new row, so
    /// renaming a phrase doesn't orphan the old one.
    public func update(id: Int64, phrase: String, replacement: String?) async throws {
        try await db.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE dictionary SET phrase = ?, replacement = ? WHERE id = ?",
                arguments: [phrase, replacement, id]
            )
        }
    }
}
