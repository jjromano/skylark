import Foundation
import GRDB

/// GRDB row for the `model_registry` table; converts to/from the shared
/// `ModelRegistryEntry` (SkylarkCore/Models).
struct RegistryRecord: Sendable, Equatable, Codable {
    var slug: String
    var label: String
    var providerPin: String?
    var kind: String
    var sort: Int
    /// Was this row inserted by `RegistryStore.syncSeed()` from
    /// `ModelRegistryEntry.seed` (as opposed to a user/ad-hoc `upsert`)?
    /// Only seeded rows get their fields refreshed on a later `syncSeed()` —
    /// a user's own entry is never overwritten, even if its slug happens to
    /// collide with a seed slug. Added via an ad-hoc `ALTER TABLE` in
    /// `RegistryStore.ensureSeededColumn()` (see there for why this isn't a
    /// `SkylarkDatabase` migration).
    var seeded: Bool

    enum CodingKeys: String, CodingKey {
        case slug, label
        case providerPin = "provider_pin"
        case kind, sort, seeded
    }
}

extension RegistryRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "model_registry"
}

extension RegistryRecord {
    /// `seeded` defaults to `false`; callers that insert an actual seed entry
    /// flip it to `true` explicitly (see `RegistryStore.syncSeed()`).
    init(entry: ModelRegistryEntry) {
        slug = entry.slug
        label = entry.label
        providerPin = entry.providerPin
        kind = entry.kind.rawValue
        sort = entry.sort
        seeded = false
    }

    var asEntry: ModelRegistryEntry {
        ModelRegistryEntry(
            slug: slug,
            label: label,
            providerPin: providerPin,
            kind: ModelRegistryEntry.Kind(rawValue: kind) ?? .cleanup,
            sort: sort
        )
    }
}

/// CRUD over `model_registry`, seeded from `ModelRegistryEntry.seed`.
public actor RegistryStore {
    private let db: SkylarkDatabase
    private var didEnsureSeededColumn = false

    public init(db: SkylarkDatabase) {
        self.db = db
    }

    public func all(kind: ModelRegistryEntry.Kind) async throws -> [ModelRegistryEntry] {
        try await ensureSeededColumn()
        return try await db.dbQueue.read { db in
            try RegistryRecord
                .filter(Column("kind") == kind.rawValue)
                .order(Column("sort"))
                .fetchAll(db)
                .map(\.asEntry)
        }
    }

    /// Free-text slug upsert (insert-or-replace by primary key `slug`). Never
    /// marks the row `seeded` — this is how the UI/user adds or edits an
    /// entry, so it's exempt from `syncSeed()`'s refresh, even if it collides
    /// with a seed slug (see `RegistryRecord.seeded`).
    public func upsert(entry: ModelRegistryEntry) async throws {
        try await ensureSeededColumn()
        try await db.dbQueue.write { db in
            try RegistryRecord(entry: entry).insert(db, onConflict: .replace)
        }
    }

    /// Reconciles `model_registry` with `ModelRegistryEntry.seed`:
    /// - inserts any seed slug missing from the DB (this is how existing
    ///   installs pick up new catalog entries after `git pull` — the old
    ///   `seedIfEmpty` only ever ran once, on a brand-new empty table);
    /// - refreshes `label`/`providerPin`/`sort` for rows that were
    ///   themselves seeded, so a corrected label/pin in a newer seed reaches
    ///   existing installs too;
    /// - never updates a row the user created/edited by hand (`seeded ==
    ///   false`), even when its slug matches a seed slug;
    /// - retires rows IT previously seeded whose slug has dropped out of the
    ///   seed (a deprecated catalog entry disappears from menus on the next
    ///   launch after an update). A user-created row (`seeded == false`) is
    ///   never deleted, and a persisted selection keeps its slug string, so
    ///   an in-use retired model keeps working until the user picks another.
    public func syncSeed() async throws {
        try await ensureSeededColumn()
        try await db.dbQueue.write { db in
            for entry in ModelRegistryEntry.seed {
                var record = RegistryRecord(entry: entry)
                record.seeded = true
                if let existing = try RegistryRecord.fetchOne(db, key: entry.slug) {
                    guard existing.seeded else { continue }
                }
                try record.insert(db, onConflict: .replace)
            }
            let seedSlugs = ModelRegistryEntry.seed.map(\.slug)
            try RegistryRecord
                .filter(Column("seeded") == true && !seedSlugs.contains(Column("slug")))
                .deleteAll(db)
        }
    }

    /// Back-compat name for callers written against the original seed-once
    /// behavior. Now delegates to `syncSeed()`, which additionally picks up
    /// new/changed seed entries on later calls (e.g. subsequent app
    /// launches after a `git pull`) rather than only ever seeding once.
    public func seedIfEmpty() async throws {
        try await syncSeed()
    }

    /// Adds the `seeded` column to `model_registry` if it isn't there yet.
    ///
    /// This is a schema change scoped entirely to this table, applied with a
    /// plain, idempotent `ALTER TABLE` rather than a new entry in
    /// `SkylarkDatabase`'s shared `DatabaseMigrator` — `SkylarkDatabase.swift`
    /// is out of scope for this change (owned by another workstream), and
    /// `ALTER TABLE ADD COLUMN` on a tiny table is cheap enough to check on
    /// every fresh `RegistryStore` without a formal migration.
    private func ensureSeededColumn() async throws {
        guard !didEnsureSeededColumn else { return }
        try await db.dbQueue.write { db in
            let hasColumn = try db.columns(in: "model_registry").contains { $0.name == "seeded" }
            guard !hasColumn else { return }
            try db.execute(sql: "ALTER TABLE model_registry ADD COLUMN seeded BOOLEAN NOT NULL DEFAULT 0")
        }
        didEnsureSeededColumn = true
    }
}
