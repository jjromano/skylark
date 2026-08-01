import Foundation
import GRDB

/// Serialization of `CleanupTier` (Cleanup/Cleaner.swift, shared type) into the
/// `modes.cleanup_tier` TEXT column: "raw" / "local" / "cloud:<slug>" (phase-3
/// spec). `cloud_cleanup_slug` additionally carries the slug redundantly so it
/// can be queried/indexed on its own per ARCHITECTURE §5's column list.
extension CleanupTier {
    var serialized: String {
        switch self {
        case .raw: return "raw"
        case .local: return "local"
        case .cloud(let slug): return "cloud:\(slug)"
        }
    }

    var cloudSlug: String? {
        if case .cloud(let slug) = self { return slug }
        return nil
    }

    init?(serialized: String) {
        switch serialized {
        case "raw": self = .raw
        case "local": self = .local
        default:
            guard serialized.hasPrefix("cloud:") else { return nil }
            self = .cloud(slug: String(serialized.dropFirst("cloud:".count)))
        }
    }
}

/// Serialization of `WhisperModeOverride` into the nullable
/// `modes.whisper_mode_override` TEXT column (schema v5, R3): NULL means
/// "follow global" (also the default for every pre-v5 row, via the additive
/// migration), "on"/"off" store the two explicit overrides. Mirrors
/// `CleanupTier`'s `serialized`/`init?(serialized:)` pair above — same
/// nullable/enum-coded column convention, just nil-able at the Swift side too
/// since `followGlobal` has no TEXT representation of its own.
extension WhisperModeOverride {
    var serialized: String? {
        switch self {
        case .followGlobal: return nil
        case .on: return "on"
        case .off: return "off"
        }
    }

    init(serialized: String?) {
        switch serialized {
        case "on": self = .on
        case "off": self = .off
        default: self = .followGlobal
        }
    }
}

/// A persisted dictation mode (ARCHITECTURE §5 `modes` table). Deliberately a
/// standalone record rather than the app-facing `DictationMode` type (owned by
/// the parallel Phase-2 worktree, out of scope here) — the integration pass
/// wires this row shape to whatever model type lands there.
public struct ModeRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var bundleIDPattern: String?
    public var engine: String?
    public var cleanupTier: CleanupTier
    public var registerHint: String?
    /// Per-mode Whisper Mode override (R3, schema v5). Default `.followGlobal`.
    public var whisperModeOverride: WhisperModeOverride
    /// Per-mode custom cleanup instruction (schema v6). Stored sanitized; see
    /// `DictationMode.sanitizeCustomPrompt`.
    public var customPrompt: String?
    public var isDefault: Bool

    public init(
        id: String,
        name: String,
        bundleIDPattern: String? = nil,
        engine: String? = nil,
        cleanupTier: CleanupTier,
        registerHint: String? = nil,
        whisperModeOverride: WhisperModeOverride = .followGlobal,
        customPrompt: String? = nil,
        isDefault: Bool
    ) {
        self.id = id
        self.name = name
        self.bundleIDPattern = bundleIDPattern
        self.engine = engine
        self.cleanupTier = cleanupTier
        self.registerHint = registerHint
        self.whisperModeOverride = whisperModeOverride
        self.customPrompt = DictationMode.sanitizeCustomPrompt(customPrompt)
        self.isDefault = isDefault
    }
}

extension ModeRecord: FetchableRecord {
    public init(row: Row) throws {
        id = row["id"]
        name = row["name"]
        bundleIDPattern = row["bundle_id_pattern"]
        engine = row["engine"]
        let tierText: String = row["cleanup_tier"]
        cleanupTier = CleanupTier(serialized: tierText) ?? .raw
        registerHint = row["register_hint"]
        whisperModeOverride = WhisperModeOverride(serialized: row["whisper_mode_override"])
        customPrompt = DictationMode.sanitizeCustomPrompt(row["custom_prompt"])
        isDefault = row["is_default"]
    }
}

extension ModeRecord: PersistableRecord {
    public static let databaseTableName = "modes"

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["name"] = name
        container["bundle_id_pattern"] = bundleIDPattern
        container["engine"] = engine
        container["cleanup_tier"] = cleanupTier.serialized
        container["cloud_cleanup_slug"] = cleanupTier.cloudSlug
        container["register_hint"] = registerHint
        container["whisper_mode_override"] = whisperModeOverride.serialized
        container["custom_prompt"] = customPrompt
        container["is_default"] = isDefault
    }
}

/// Errors surfaced by mode-management operations (phase-5a spec §4).
public enum ModeStoreError: Error, Sendable, Equatable {
    /// Every mode set must have exactly one default; deleting it is blocked
    /// (the UI should disable the delete action for the default mode too).
    case cannotDeleteDefault
}

/// CRUD over `modes`, seeded with the same two defaults the Phase-2 worktree's
/// `InMemoryModeProvider` uses: "Default" (local tier, is default) and "Raw"
/// (raw tier).
public actor ModeStore {
    private let db: SkylarkDatabase

    public init(db: SkylarkDatabase) {
        self.db = db
    }

    public func all() async throws -> [ModeRecord] {
        try await db.dbQueue.read { db in try ModeRecord.fetchAll(db) }
    }

    /// Insert-or-replace by primary key `id`.
    public func upsert(_ mode: ModeRecord) async throws {
        try await db.dbQueue.write { db in
            try mode.insert(db, onConflict: .replace)
        }
    }

    /// Deleting the default mode is blocked (there must always be exactly one
    /// default so mode resolution stays total); leaves history rows intact,
    /// `mode_id` there is informational only.
    public func delete(id: String) async throws {
        try await db.dbQueue.write { db in
            let isDefault = try Bool.fetchOne(
                db, sql: "SELECT is_default FROM modes WHERE id = ?", arguments: [id]
            ) ?? false
            guard !isDefault else { throw ModeStoreError.cannotDeleteDefault }
            try db.execute(sql: "DELETE FROM modes WHERE id = ?", arguments: [id])
        }
    }

    /// Make `id` the sole default, atomically. No-op (but still succeeds) if
    /// `id` doesn't exist — the caller already validated it from a fetched list.
    public func setDefault(id: String) async throws {
        try await db.dbQueue.write { db in
            try db.execute(sql: "UPDATE modes SET is_default = 0")
            try db.execute(sql: "UPDATE modes SET is_default = 1 WHERE id = ?", arguments: [id])
        }
    }

    /// Adds a curated `ModePreset` (Settings → Modes "Suggested" section).
    /// Upserts each of the preset's rows (one per bundle-id pattern); their
    /// ids are deterministic (`ModePreset.recordID(for:)`), so calling this
    /// again for the same preset replaces rather than duplicates them.
    public func add(preset: ModePreset) async throws {
        for record in preset.makeRecords() {
            try await upsert(record)
        }
    }

    /// Seeds the two defaults iff the table is empty. Idempotent.
    public func seedIfEmpty() async throws {
        try await db.dbQueue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM modes") ?? 0
            guard count == 0 else { return }
            let defaults: [ModeRecord] = [
                ModeRecord(id: "default", name: "Default", cleanupTier: .local, isDefault: true),
                ModeRecord(id: "raw", name: "Raw", cleanupTier: .raw, isDefault: false),
            ]
            for mode in defaults {
                try mode.insert(db)
            }
        }
    }
}
