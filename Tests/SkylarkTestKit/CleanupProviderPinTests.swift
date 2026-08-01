import Testing
import Foundation
import SkylarkCore

/// Provider pinning for CLOUD CLEANUP slugs. The app used to pin every
/// user-entered slug to Groq, which is the opposite of what PRD §7 asks pinning
/// to do: a model Groq doesn't serve is routed by `allow_fallbacks` to whatever
/// is left, so the user's deliberate switch means nothing.
@Suite("Cleanup provider-pin resolution")
struct CleanupProviderPinTests {
    @Test("A registry slug uses the registry's pin")
    func knownSlugKeepsItsPin() {
        let known: [ModelRegistryEntry] = [
            .init(slug: "openai/gpt-oss-20b", label: "GPT-OSS 20B (Groq)", providerPin: "groq", kind: .cleanup, sort: 1)
        ]
        #expect(CleanupProviderPins.providerPin(for: "openai/gpt-oss-20b", known: known) == "groq")
    }

    @Test("An unknown slug gets NO pin — OpenRouter routes it")
    func unknownSlugIsUnpinned() {
        #expect(CleanupProviderPins.providerPin(for: "acme/custom-cleanup", known: []) == nil)
    }

    @Test("A registry row with no pin stays unpinned (nil is a decision, not a miss)")
    func explicitNilPinIsHonoured() {
        let known: [ModelRegistryEntry] = [
            .init(slug: "acme/single-provider", label: "Acme", providerPin: nil, kind: .cleanup, sort: 0)
        ]
        #expect(CleanupProviderPins.providerPin(for: "acme/single-provider", known: known) == nil)
        #expect(CleanupProviderPins.isKnown(slug: "acme/single-provider", known: known))
    }

    @Test("An stt row never answers for a cleanup slug")
    func kindIsRespected() {
        let known: [ModelRegistryEntry] = [
            .init(slug: "openai/whisper-large-v3-turbo", label: "Groq Fast Whisper", providerPin: "groq", kind: .stt, sort: 0)
        ]
        #expect(CleanupProviderPins.providerPin(for: "openai/whisper-large-v3-turbo", known: known) == nil)
        #expect(!CleanupProviderPins.isKnown(slug: "openai/whisper-large-v3-turbo", known: known))
    }

    @Test("The shipped seed answers when the caller's rows don't (pre-load, no DB)")
    func seedIsTheFloor() {
        let seeded = ModelRegistryEntry.seed.first { $0.kind == .cleanup }!
        #expect(CleanupProviderPins.providerPin(for: seeded.slug, known: []) == seeded.providerPin)
        #expect(CleanupProviderPins.isKnown(slug: seeded.slug, known: []))
    }

    @Test("The published snapshot resolves seed rows before any publish, then live rows")
    func snapshotPublish() {
        let pins = CleanupProviderPins()
        let seeded = ModelRegistryEntry.seed.first { $0.kind == .cleanup }!
        // Fresh instance: the seed already answers (the cloud-cleanup factory can
        // run before the registry finishes loading).
        #expect(pins.providerPin(for: seeded.slug) == seeded.providerPin)
        #expect(pins.providerPin(for: "acme/custom-cleanup") == nil)

        // A user-added row (upserted with no pin) resolves as itself, and an
        // install-specific pin overrides the seed.
        pins.publish([
            .init(slug: "acme/custom-cleanup", label: "acme/custom-cleanup", providerPin: nil, kind: .cleanup, sort: 999),
            .init(slug: seeded.slug, label: seeded.label, providerPin: "cerebras", kind: .cleanup, sort: seeded.sort),
        ])
        #expect(pins.providerPin(for: "acme/custom-cleanup") == nil)
        #expect(pins.providerPin(for: seeded.slug) == "cerebras")
        // Seed rows the publish didn't mention still resolve.
        let otherSeed = ModelRegistryEntry.seed.last { $0.kind == .cleanup && $0.slug != seeded.slug }!
        #expect(pins.providerPin(for: otherSeed.slug) == otherSeed.providerPin)
    }
}
