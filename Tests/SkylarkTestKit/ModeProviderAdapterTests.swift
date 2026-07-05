import Testing
import SkylarkCore

@Suite("ModeProviderAdapter mapping")
struct ModeProviderAdapterTests {
    @Test("ModeRecord → DictationMode → ModeRecord round-trips (incl. cloud slug)")
    func roundTripsCloudTier() {
        let record = ModeRecord(
            id: "work",
            name: "Work",
            bundleIDPattern: "com.microsoft.*",
            engine: nil,
            cleanupTier: .cloud(slug: "meta-llama/llama-3.1-8b-instruct"),
            registerHint: "professional",
            isDefault: false
        )

        let mode = ModeProviderAdapter.toDictationMode(record)
        #expect(mode.id == "work")
        #expect(mode.name == "Work")
        #expect(mode.bundleIDPattern == "com.microsoft.*")
        #expect(mode.cleanupTier == .cloud(slug: "meta-llama/llama-3.1-8b-instruct"))
        #expect(mode.cloudCleanupSlug == "meta-llama/llama-3.1-8b-instruct")
        #expect(mode.registerHint == "professional")
        #expect(mode.isDefault == false)

        let back = ModeProviderAdapter.toRecord(mode)
        #expect(back == record)
    }

    @Test("Local/raw tiers round-trip with a nil cloud slug")
    func roundTripsLocalTier() {
        let record = ModeRecord(id: "default", name: "Default", cleanupTier: .local, isDefault: true)
        let mode = ModeProviderAdapter.toDictationMode(record)
        #expect(mode.cleanupTier == .local)
        #expect(mode.cloudCleanupSlug == nil)
        #expect(mode.isDefault)
        #expect(ModeProviderAdapter.toRecord(mode) == record)
    }

    @Test("Adapter reads modes from the backing ModeStore")
    func readsFromStore() async throws {
        let db = try SkylarkDatabase.inMemory()
        let store = ModeStore(db: db)
        try await store.seedIfEmpty()
        let adapter = ModeProviderAdapter(store: store)

        let modes = try await adapter.modes()
        #expect(modes.count == 2)
        #expect(modes.contains { $0.id == "default" && $0.cleanupTier == .local })
        #expect(modes.contains { $0.id == "raw" && $0.cleanupTier == .raw })
    }
}
