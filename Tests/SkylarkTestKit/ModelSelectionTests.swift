import Testing
import Foundation
import SkylarkCore

@Suite("ModelSelection persistence + ad-hoc slug upsert")
@MainActor
struct ModelSelectionTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "modelselection-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("Defaults: gpt-oss-20b cleanup slug + local Parakeet STT")
    func defaults() {
        let selection = ModelSelection(defaults: freshDefaults())
        #expect(selection.cleanupSlug == "openai/gpt-oss-20b")
        #expect(selection.sttChoice == .localParakeet)
    }

    @Test("Selections persist across instances backed by the same UserDefaults")
    func persistsAcrossInstances() async {
        let defaults = freshDefaults()
        let first = ModelSelection(defaults: defaults)
        await first.setCleanupSlug("openai/gpt-oss-20b", known: [])
        await first.setSTT(.cloud(slug: "openai/whisper-large-v3-turbo"), known: [])

        let second = ModelSelection(defaults: defaults)
        #expect(second.cleanupSlug == "openai/gpt-oss-20b")
        #expect(second.sttChoice == .cloud(slug: "openai/whisper-large-v3-turbo"))
    }

    @Test("Free-text cleanup slug upserts an ad-hoc registry entry (NO pin)")
    func adHocCleanupUpsert() async throws {
        let db = try SkylarkDatabase.inMemory()
        let registry = RegistryStore(db: db)
        let selection = ModelSelection(defaults: freshDefaults(), registry: registry)

        await selection.setCleanupSlug("acme/custom-cleanup", known: [])

        let entries = try await registry.all(kind: .cleanup)
        let added = try #require(entries.first { $0.slug == "acme/custom-cleanup" })
        #expect(added.label == "acme/custom-cleanup")
        // An unknown slug is left UNPINNED so OpenRouter routes it. Pinning it to
        // Groq (as this used to) sends a model Groq may not serve to Groq first.
        #expect(added.providerPin == nil)
        #expect(selection.cleanupSlug == "acme/custom-cleanup")
    }

    @Test("Free-text cloud STT slug upserts an ad-hoc stt entry (no pin)")
    func adHocSTTUpsert() async throws {
        let db = try SkylarkDatabase.inMemory()
        let registry = RegistryStore(db: db)
        let selection = ModelSelection(defaults: freshDefaults(), registry: registry)

        await selection.setSTT(.cloud(slug: "acme/custom-stt"), known: [])

        let entries = try await registry.all(kind: .stt)
        let added = try #require(entries.first { $0.slug == "acme/custom-stt" })
        #expect(added.providerPin == nil)
        #expect(selection.sttChoice == .cloud(slug: "acme/custom-stt"))
    }

    @Test("A known slug is not re-upserted")
    func knownSlugNotUpserted() async throws {
        let db = try SkylarkDatabase.inMemory()
        let registry = RegistryStore(db: db)
        try await registry.seedIfEmpty()
        let known = try await registry.all(kind: .cleanup)
        let selection = ModelSelection(defaults: freshDefaults(), registry: registry)

        await selection.setCleanupSlug("meta-llama/llama-3.1-8b-instruct", known: known)

        let after = try await registry.all(kind: .cleanup)
        #expect(after.count == known.count)
    }
}
