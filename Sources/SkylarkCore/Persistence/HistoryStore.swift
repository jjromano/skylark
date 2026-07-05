import Foundation
import GRDB

/// One recorded utterance, as persisted (ARCHITECTURE §5). Mirrors the
/// `history` table.
public struct HistoryRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: Int64?
    public var timestamp: Date
    public var rawText: String
    public var cleanText: String?
    public var modeID: String?
    public var engine: String
    public var durationMs: Int
    public var latencyMs: Int
    public var audioPath: String?

    public init(
        id: Int64? = nil,
        timestamp: Date = .init(),
        rawText: String,
        cleanText: String? = nil,
        modeID: String? = nil,
        engine: String,
        durationMs: Int,
        latencyMs: Int,
        audioPath: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.cleanText = cleanText
        self.modeID = modeID
        self.engine = engine
        self.durationMs = durationMs
        self.latencyMs = latencyMs
        self.audioPath = audioPath
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp
        case rawText = "raw_text"
        case cleanText = "clean_text"
        case modeID = "mode_id"
        case engine
        case durationMs = "duration_ms"
        case latencyMs = "latency_ms"
        case audioPath = "audio_path"
    }
}

extension HistoryRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "history"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// CRUD + search over `history` (ARCHITECTURE §5).
public actor HistoryStore {
    private let db: SkylarkDatabase

    public init(db: SkylarkDatabase) {
        self.db = db
    }

    @discardableResult
    public func append(_ record: HistoryRecord) async throws -> HistoryRecord {
        try await db.dbQueue.write { db in
            var toInsert = record
            try toInsert.insert(db)
            return toInsert
        }
    }

    /// Naive `LIKE` search over raw + clean text, newest first.
    public func search(text: String, limit: Int) async throws -> [HistoryRecord] {
        let pattern = "%\(text)%"
        return try await db.dbQueue.read { db in
            try HistoryRecord
                .filter(Column("raw_text").like(pattern) || Column("clean_text").like(pattern))
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func recent(limit: Int) async throws -> [HistoryRecord] {
        try await db.dbQueue.read { db in
            try HistoryRecord
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func updateEditedText(id: Int64, new text: String) async throws {
        try await db.dbQueue.write { db in
            try db.execute(sql: "UPDATE history SET clean_text = ? WHERE id = ?", arguments: [text, id])
        }
    }

    @discardableResult
    public func delete(id: Int64) async throws -> Bool {
        try await db.dbQueue.write { db in
            try HistoryRecord.deleteOne(db, key: id)
        }
    }

    public func purgeAll() async throws {
        _ = try await db.dbQueue.write { db in
            try HistoryRecord.deleteAll(db)
        }
    }
}
