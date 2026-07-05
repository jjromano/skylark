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
    public var isDefault: Bool

    public init(
        id: String,
        name: String,
        bundleIDPattern: String? = nil,
        engine: String? = nil,
        cleanupTier: CleanupTier,
        registerHint: String? = nil,
        isDefault: Bool
    ) {
        self.id = id
        self.name = name
        self.bundleIDPattern = bundleIDPattern
        self.engine = engine
        self.cleanupTier = cleanupTier
        self.registerHint = registerHint
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
        container["is_default"] = isDefault
    }
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

    public func delete(id: String) async throws {
        _ = try await db.dbQueue.write { db in
            try ModeRecord.deleteOne(db, key: id)
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
