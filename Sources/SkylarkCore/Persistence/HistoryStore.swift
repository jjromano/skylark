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
    public var wordCount: Int
    public var appBundleID: String?
    public var appName: String?
    /// Which cleanup engine produced `cleanText` ("raw", "local", or a cloud
    /// model slug); nil when cleanup never landed or for pre-v4 rows.
    public var cleanupEngine: String?
    /// Per-stage latency (ms) for this utterance; nil for pre-0.17.0 rows.
    /// `cleanupMs` is the PASTE-path cleanup wait only — 0 when cleanup ran
    /// detached after an AX insert, because the user was not waiting on it.
    public var transcribeMs: Int?
    public var cleanupMs: Int?
    public var injectMs: Int?

    public init(
        id: Int64? = nil,
        timestamp: Date = .init(),
        rawText: String,
        cleanText: String? = nil,
        modeID: String? = nil,
        engine: String,
        durationMs: Int,
        latencyMs: Int,
        audioPath: String? = nil,
        wordCount: Int = 0,
        appBundleID: String? = nil,
        appName: String? = nil,
        cleanupEngine: String? = nil,
        transcribeMs: Int? = nil,
        cleanupMs: Int? = nil,
        injectMs: Int? = nil
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
        self.wordCount = wordCount
        self.appBundleID = appBundleID
        self.appName = appName
        self.cleanupEngine = cleanupEngine
        self.transcribeMs = transcribeMs
        self.cleanupMs = cleanupMs
        self.injectMs = injectMs
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
        case wordCount = "word_count"
        case appBundleID = "app_bundle_id"
        case appName = "app_name"
        case cleanupEngine = "cleanup_engine"
        case transcribeMs = "transcribe_ms"
        case cleanupMs = "cleanup_ms"
        case injectMs = "inject_ms"
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

    public func fetch(id: Int64) async throws -> HistoryRecord? {
        try await db.dbQueue.read { db in
            try HistoryRecord.fetchOne(db, key: id)
        }
    }

    /// Updates the clean text and refreshes `word_count` from it (correlated
    /// clean-text arrives after the raw-text append; the word count should
    /// reflect whichever text is now "final").
    public func updateEditedText(id: Int64, new text: String, cleanupEngine: String? = nil) async throws {
        let count = WordCount.count(text)
        try await db.dbQueue.write { db in
            if let cleanupEngine {
                try db.execute(
                    sql: "UPDATE history SET clean_text = ?, word_count = ?, cleanup_engine = ? WHERE id = ?",
                    arguments: [text, count, cleanupEngine, id]
                )
            } else {
                try db.execute(
                    sql: "UPDATE history SET clean_text = ?, word_count = ? WHERE id = ?",
                    arguments: [text, count, id]
                )
            }
        }
    }

    /// Replace a row's transcription in place (History → Re-transcribe): the new
    /// engine's raw text overwrites `raw_text`, `clean_text` and `cleanup_engine`
    /// are cleared (no re-cleanup happens on this path), the `engine` column is
    /// stamped, and `word_count` is recomputed from the new raw text. Off any
    /// latency path.
    public func replaceTranscription(id: Int64, rawText: String, engine: String) async throws {
        let count = WordCount.count(rawText)
        try await db.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE history
                SET raw_text = ?, clean_text = NULL, cleanup_engine = NULL, engine = ?, word_count = ?
                WHERE id = ?
                """,
                arguments: [rawText, engine, count, id]
            )
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

    /// Every non-null `audio_path`, for the retained-audio delete/purge/orphan
    /// sweep (phase-5a spec §2). Off any latency path.
    public func allAudioPaths() async throws -> [String] {
        try await db.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT audio_path FROM history WHERE audio_path IS NOT NULL")
        }
    }

    /// Null out every row's `audio_path` without touching the row itself — used
    /// by "Delete all stored audio" (the text history stays; only audio goes).
    public func clearAllAudioPaths() async throws {
        try await db.dbQueue.write { db in
            try db.execute(sql: "UPDATE history SET audio_path = NULL WHERE audio_path IS NOT NULL")
        }
    }

    /// UserDefaults key for the retention window (whole days; 0 = keep forever).
    /// Read/write lives in the app layer — this constant just gives both sides
    /// one spelling to agree on.
    public static let retentionDefaultsKey = "history.retentionDays"

    /// UserDefaults key for the AUDIO retention window (whole days; default 7).
    /// Distinct from `retentionDefaultsKey`: this one prunes retained *audio
    /// files* only (see `pruneAudio`), never the text rows. Read/write lives in
    /// the app layer.
    public static let audioRetentionDefaultsKey = "history.audioRetentionDays"

    /// Interpret the stored audio-retention-days default: unset (`UserDefaults`
    /// returns 0 for a missing integer) means the 7-day default. There is no
    /// "keep forever" for audio, so 0 is never a valid stored value.
    public static func audioRetentionDays(stored: Int) -> Int {
        stored == 0 ? 7 : stored
    }

    /// Delete retained audio *files* older than `days` and null their
    /// `audio_path` column, keeping the text rows (opt-in audio retention,
    /// phase-5a spec §2). Returns the number of files removed. Off any latency
    /// path — called from the launch/periodic sweep and when the setting
    /// changes.
    @discardableResult
    public func pruneAudio(olderThanDays days: Int) async throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return try await db.dbQueue.write { db in
            let paths = try String.fetchAll(
                db,
                sql: "SELECT audio_path FROM history WHERE timestamp < ? AND audio_path IS NOT NULL",
                arguments: [cutoff]
            )
            for path in paths {
                try? FileManager.default.removeItem(atPath: path)
            }
            try db.execute(
                sql: "UPDATE history SET audio_path = NULL WHERE timestamp < ? AND audio_path IS NOT NULL",
                arguments: [cutoff]
            )
            return paths.count
        }
    }

    /// Deletes every row older than `days` (by `timestamp`), removing each
    /// row's retained audio file first (same pattern as `deleteEntry`/
    /// `purgeAll` in `HistoryHub`, just batched). Returns the number of rows
    /// deleted. Off any latency path — called from a launch/periodic sweep.
    @discardableResult
    public func prune(olderThanDays days: Int) async throws -> Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        return try await db.dbQueue.write { db in
            let paths = try String.fetchAll(
                db,
                sql: "SELECT audio_path FROM history WHERE timestamp < ? AND audio_path IS NOT NULL",
                arguments: [cutoff]
            )
            for path in paths {
                try? FileManager.default.removeItem(atPath: path)
            }
            try db.execute(sql: "DELETE FROM history WHERE timestamp < ?", arguments: [cutoff])
            return db.changesCount
        }
    }
}
