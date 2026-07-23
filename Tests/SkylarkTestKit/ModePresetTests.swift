import Testing
import SkylarkCore

@Suite("ModePreset catalog integrity")
struct ModePresetCatalogTests {
    @Test("Preset ids are unique")
    func uniqueIDs() {
        let ids = ModePresetCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Preset names are unique")
    func uniqueNames() {
        let names = ModePresetCatalog.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("Every preset has at least one non-empty bundle-id pattern")
    func nonEmptyPatterns() {
        for preset in ModePresetCatalog.all {
            #expect(!preset.bundleIDPatterns.isEmpty, "\(preset.name) has no patterns")
            for pattern in preset.bundleIDPatterns {
                #expect(!pattern.trimmingCharacters(in: .whitespaces).isEmpty, "\(preset.name) has a blank pattern")
            }
        }
    }

    @Test("Every preset has a non-empty name and summary")
    func nonEmptyDescriptiveFields() {
        for preset in ModePresetCatalog.all {
            #expect(!preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!preset.summary.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @Test("Cleanup tiers are the curated set (no dangling cloud slugs)")
    func validTiers() {
        for preset in ModePresetCatalog.all {
            switch preset.cleanupTier {
            case .raw, .local:
                break
            case .cloud(let slug):
                Issue.record("\(preset.name) unexpectedly uses cloud tier (slug: \(slug))")
            }
        }
    }

    @Test("Catalog has roughly the ~8 curated presets")
    func catalogSize() {
        #expect(ModePresetCatalog.all.count >= 6)
    }

    @Test("makeRecords() produces one record per bundle-id pattern, all sharing the preset's name/tier/hint")
    func makeRecordsShapesMatchPreset() {
        for preset in ModePresetCatalog.all {
            let records = preset.makeRecords()
            #expect(records.count == preset.bundleIDPatterns.count)
            for record in records {
                #expect(record.name == preset.name)
                #expect(record.cleanupTier == preset.cleanupTier)
                #expect(record.registerHint == preset.registerHint)
                #expect(record.isDefault == false)
                #expect(preset.bundleIDPatterns.contains(record.bundleIDPattern ?? ""))
            }
        }
    }

    @Test("recordID(for:) is deterministic per preset+pattern")
    func recordIDsAreDeterministic() {
        let preset = ModePresetCatalog.all[0]
        let pattern = preset.bundleIDPatterns[0]
        #expect(preset.recordID(for: pattern) == preset.recordID(for: pattern))
        #expect(preset.recordID(for: pattern) != preset.recordID(for: pattern + "x"))
    }
}

@Suite("ModePreset ↔ ModeStore integration")
struct ModePresetStoreTests {
    @Test("Adding a preset inserts one row per bundle-id pattern")
    func addInsertsAllRows() async throws {
        let db = try SkylarkDatabase.inMemory()
        let store = ModeStore(db: db)
        try await store.seedIfEmpty()
        let preset = ModePresetCatalog.all.first { $0.bundleIDPatterns.count > 1 }!

        try await store.add(preset: preset)

        let all = try await store.all()
        let presetRows = all.filter { $0.name == preset.name }
        #expect(presetRows.count == preset.bundleIDPatterns.count)
    }

    @Test("Re-adding a preset does not duplicate rows (upsert-by-deterministic-id)")
    func reAddDoesNotDuplicate() async throws {
        let db = try SkylarkDatabase.inMemory()
        let store = ModeStore(db: db)
        try await store.seedIfEmpty()
        let preset = ModePresetCatalog.all.first!

        try await store.add(preset: preset)
        try await store.add(preset: preset)
        try await store.add(preset: preset)

        let all = try await store.all()
        let presetRows = all.filter { $0.name == preset.name }
        #expect(presetRows.count == preset.bundleIDPatterns.count)
    }

    @Test("isAdded(in:) reflects store state before and after adding")
    func isAddedTracksStoreState() async throws {
        let db = try SkylarkDatabase.inMemory()
        let store = ModeStore(db: db)
        try await store.seedIfEmpty()
        let preset = ModePresetCatalog.all.first!

        let before = try await store.all()
        #expect(preset.isAdded(in: before) == false)

        try await store.add(preset: preset)

        let after = try await store.all()
        #expect(preset.isAdded(in: after) == true)
    }

    @Test("A preset's rows round-trip through ModeProviderAdapter unchanged")
    func roundTripsThroughAdapter() async throws {
        let db = try SkylarkDatabase.inMemory()
        let store = ModeStore(db: db)
        try await store.seedIfEmpty()
        let preset = ModePresetCatalog.all.first { $0.cleanupTier == .raw }!

        try await store.add(preset: preset)

        let adapter = ModeProviderAdapter(store: store)
        let modes = try await adapter.modes()
        let matching = modes.filter { $0.name == preset.name }
        #expect(matching.count == preset.bundleIDPatterns.count)
        for mode in matching {
            #expect(mode.cleanupTier == preset.cleanupTier)
            #expect(mode.registerHint == preset.registerHint)
            #expect(preset.bundleIDPatterns.contains(mode.bundleIDPattern ?? ""))
            // Round-trip back to a record and confirm it matches what's stored.
            let record = ModeProviderAdapter.toRecord(mode)
            #expect(preset.makeRecords().contains(record))
        }
    }
}
