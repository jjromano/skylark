import Foundation
import GRDB

/// One text-expansion snippet, as persisted (workstream B spec §4). Mirrors
/// the `snippets` table. `trigger` is unique, case-insensitive (`COLLATE
/// NOCASE`, enforced by the "v3" migration).
public struct SnippetRecord: Sendable, Equatable, Codable, Identifiable {
    public var id: Int64?
    public var trigger: String
    public var replacement: String
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        trigger: String,
        replacement: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.trigger = trigger
        self.replacement = replacement
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, trigger, replacement
        case createdAt = "created_at"
    }
}

extension SnippetRecord: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "snippets"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Errors surfaced by snippet-management operations.
public enum SnippetStoreError: Error, Sendable, Equatable {
    /// `trigger` (case-insensitively, after trimming) already names another
    /// snippet.
    case duplicateTrigger(String)
}

/// CRUD over `snippets` (workstream B spec §4).
public actor SnippetStore {
    private let db: SkylarkDatabase

    public init(db: SkylarkDatabase) {
        self.db = db
    }

    public func all() async throws -> [SnippetRecord] {
        try await db.dbQueue.read { db in
            try SnippetRecord.order(Column("trigger")).fetchAll(db)
        }
    }

    /// Inserts a new snippet. `trigger`/`replacement` are trimmed of leading/
    /// trailing whitespace before comparison and storage. Throws
    /// `SnippetStoreError.duplicateTrigger` if another snippet already has the
    /// same trigger (case-insensitively) — checked and inserted atomically in
    /// one write transaction, so this is race-free against other calls on the
    /// same `SnippetStore` actor.
    @discardableResult
    public func add(trigger: String, replacement: String) async throws -> SnippetRecord {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await db.dbQueue.write { db in
            guard try !Self.triggerExists(trimmedTrigger, excluding: nil, db) else {
                throw SnippetStoreError.duplicateTrigger(trimmedTrigger)
            }
            var record = SnippetRecord(trigger: trimmedTrigger, replacement: trimmedReplacement, createdAt: Date())
            try record.insert(db)
            return record
        }
    }

    /// In-place update by id. Throws `SnippetStoreError.duplicateTrigger` if
    /// the new trigger collides with a *different* existing snippet.
    public func update(id: Int64, trigger: String, replacement: String) async throws {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        try await db.dbQueue.write { db in
            guard try !Self.triggerExists(trimmedTrigger, excluding: id, db) else {
                throw SnippetStoreError.duplicateTrigger(trimmedTrigger)
            }
            try db.execute(
                sql: "UPDATE snippets SET \"trigger\" = ?, replacement = ? WHERE id = ?",
                arguments: [trimmedTrigger, trimmedReplacement, id]
            )
        }
    }

    public func delete(id: Int64) async throws {
        _ = try await db.dbQueue.write { db in
            try SnippetRecord.deleteOne(db, key: id)
        }
    }

    private static func triggerExists(_ trigger: String, excluding id: Int64?, _ db: Database) throws -> Bool {
        if let id {
            return try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM snippets WHERE \"trigger\" = ? AND id != ?)",
                arguments: [trigger, id]
            ) ?? false
        }
        return try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM snippets WHERE \"trigger\" = ?)",
            arguments: [trigger]
        ) ?? false
    }
}

/// Pure whole-utterance snippet matcher (workstream B spec §4) — no DB
/// access, so it can run inline on the paste path without an actor hop.
/// Matches only when the *entire* normalized utterance equals a normalized
/// trigger; there is no mid-text expansion.
public enum SnippetMatcher {
    private static let edgePunctuation: Set<Character> = [".", ",", "!", "?", ";", ":"]

    /// Returns the replacement for the snippet whose trigger exactly matches
    /// `text` once both are normalized (lowercased, trimmed, stripped of
    /// leading/trailing punctuation, internal whitespace collapsed), or `nil`
    /// if none match.
    public static func match(text: String, snippets: [SnippetRecord]) -> String? {
        let normalizedText = normalize(text)
        guard !normalizedText.isEmpty else { return nil }
        return snippets.first { normalize($0.trigger) == normalizedText }?.replacement
    }

    private static func normalize(_ text: String) -> String {
        var chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        while let first = chars.first, edgePunctuation.contains(first) {
            chars.removeFirst()
        }
        while let last = chars.last, edgePunctuation.contains(last) {
            chars.removeLast()
        }
        let trimmedAgain = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAgain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
