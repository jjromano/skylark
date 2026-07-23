import Foundation
import GRDB

/// GRDB row for the `dictionary` table; converts to/from the shared
/// `DictionaryEntry` (SkylarkCore/Models). `misspellings` is stored as a
/// JSON-encoded array of strings in a single TEXT column.
struct DictionaryRecord: Sendable, Equatable, Codable {
    var id: Int64?
    var phrase: String
    var misspellings: String
    var source: String
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, phrase, misspellings, source
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
    /// Encode a misspellings list as the JSON TEXT stored in the column.
    static func encodeMisspellings(_ misspellings: [String]) -> String {
        guard let data = try? JSONEncoder().encode(misspellings),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Decode the JSON TEXT column back into a misspellings list.
    static func decodeMisspellings(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    /// The "v2" migration's row mapping (SkylarkDatabase): OLD schema had
    /// `phrase` = mistake and `replacement` = correction (or nil to just bias).
    /// NEW schema has `phrase` = correction and `misspellings` = [mistake].
    /// Factored out so the migration and its tests share one source of truth.
    static func migrateLegacyRow(phrase: String, replacement: String?) -> (phrase: String, misspellings: [String]) {
        let correctWord = replacement ?? phrase
        let misspellings = replacement != nil ? [phrase] : []
        return (correctWord, misspellings)
    }

    init(entry: DictionaryEntry) {
        id = entry.id
        phrase = entry.phrase
        misspellings = Self.encodeMisspellings(entry.misspellings)
        source = entry.source.rawValue
        createdAt = entry.createdAt
    }

    var asEntry: DictionaryEntry {
        DictionaryEntry(
            id: id,
            phrase: phrase,
            misspellings: Self.decodeMisspellings(misspellings),
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
            let misspellingsJSON = DictionaryRecord.encodeMisspellings(entry.misspellings)
            try db.execute(
                sql: """
                INSERT INTO dictionary (phrase, misspellings, source, created_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(phrase) DO UPDATE SET
                    misspellings = excluded.misspellings,
                    source = excluded.source
                """,
                arguments: [entry.phrase, misspellingsJSON, entry.source.rawValue, entry.createdAt]
            )
            guard let record = try DictionaryRecord.filter(Column("phrase") == entry.phrase).fetchOne(db) else {
                throw PersistenceError.upsertFailed
            }
            return record.asEntry
        }
    }

    /// Returns whether a row actually existed to delete — the learned-banner
    /// Undo (AppController) uses this to tell "deleted" from "already gone"
    /// (e.g. the user removed it in Settings while the banner was showing).
    @discardableResult
    public func delete(id: Int64) async throws -> Bool {
        try await db.dbQueue.write { db in
            try DictionaryRecord.deleteOne(db, key: id)
        }
    }

    /// In-place update by id (phrase + misspellings), for inline-editing an
    /// existing entry. Unlike `upsert`, this never inserts a new row, so
    /// renaming a phrase doesn't orphan the old one.
    public func update(id: Int64, phrase: String, misspellings: [String]) async throws {
        try await db.dbQueue.write { db in
            let misspellingsJSON = DictionaryRecord.encodeMisspellings(misspellings)
            try db.execute(
                sql: "UPDATE dictionary SET phrase = ?, misspellings = ? WHERE id = ?",
                arguments: [phrase, misspellingsJSON, id]
            )
        }
    }
}
