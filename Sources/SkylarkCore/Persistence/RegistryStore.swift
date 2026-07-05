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

    enum CodingKeys: String, CodingKey {
        case slug, label
        case providerPin = "provider_pin"
        case kind, sort
    }
}

extension RegistryRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "model_registry"
}

extension RegistryRecord {
    init(entry: ModelRegistryEntry) {
        slug = entry.slug
        label = entry.label
        providerPin = entry.providerPin
        kind = entry.kind.rawValue
        sort = entry.sort
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

    public init(db: SkylarkDatabase) {
        self.db = db
    }

    public func all(kind: ModelRegistryEntry.Kind) async throws -> [ModelRegistryEntry] {
        try await db.dbQueue.read { db in
            try RegistryRecord
                .filter(Column("kind") == kind.rawValue)
                .order(Column("sort"))
                .fetchAll(db)
                .map(\.asEntry)
        }
    }

    /// Free-text slug upsert (insert-or-replace by primary key `slug`).
    public func upsert(entry: ModelRegistryEntry) async throws {
        try await db.dbQueue.write { db in
            try RegistryRecord(entry: entry).insert(db, onConflict: .replace)
        }
    }

    /// Seeds `ModelRegistryEntry.seed` iff the table is empty. Idempotent.
    public func seedIfEmpty() async throws {
        try await db.dbQueue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM model_registry") ?? 0
            guard count == 0 else { return }
            for entry in ModelRegistryEntry.seed {
                try RegistryRecord(entry: entry).insert(db)
            }
        }
    }
}
