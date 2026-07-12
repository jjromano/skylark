import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

/// One local-model cleanup generation, abstracted so the logic (prompt assembly,
/// token budgeting, output hygiene, the unavailable path) is unit-testable
/// without Apple Intelligence. The live conformer talks to Apple
/// `FoundationModels`; tests supply a fake.
public protocol LocalCleanupBackend: Sendable {
    /// nil when the model can run here; otherwise a human-readable reason the app
    /// can surface (e.g. "Apple Intelligence is not enabled").
    func unavailability() async -> String?
    /// Run one cleanup generation with a fresh session and a plain-string response.
    func generate(instructions: String, userMessage: String, maximumResponseTokens: Int) async throws -> String
    /// Warm the next session so a subsequent request is low-latency. Called off
    /// the paste path after each use.
    func prewarm(instructions: String) async
}

/// Tier 1 cleaner — Apple on-device Foundation Models (ARCHITECTURE §0).
///
/// Availability is a supported runtime state, not an error: this build box
/// reports `appleIntelligenceNotEnabled`, so the pipeline must fall back to raw
/// text rather than crash. Generation is structured behind `LocalCleanupBackend`
/// so prompt/hygiene/unavailable paths are testable without real generation.
public struct LocalCleaner: Cleaner {
    public let tier: CleanupTier = .local

    private let backend: any LocalCleanupBackend

    /// Rough token estimate — 4 chars/token (ARCHITECTURE §1 heuristic).
    static let charsPerToken = 4
    /// Skip cleanup entirely above this many transcript tokens (~4096 ctx budget
    /// minus instructions/response headroom).
    static let contextTokenBudget = 3000
    /// Hard cap on requested response tokens regardless of input size.
    static let responseTokenCap = 1024
    /// Floor so very short transcripts still get room to breathe.
    static let responseTokenFloor = 64

    /// Testing seam — inject a fake backend (real generation isn't runnable on
    /// the CLT-only box).
    public init(backend: any LocalCleanupBackend) {
        self.backend = backend
    }

    public init() {
        #if canImport(FoundationModels)
        self.backend = FoundationModelBackend()
        #else
        self.backend = UnavailableBackend(reason: "on-device model framework unavailable in this build")
        #endif
    }

    public func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        // Truncation guard: skip cleanup for transcripts too long for the context.
        let estimatedTokens = Self.estimatedTokens(transcript)
        guard estimatedTokens <= Self.contextTokenBudget else {
            throw CleanerError.unavailable(reason: "transcript too long for local cleanup")
        }

        if let reason = await backend.unavailability() {
            throw CleanerError.unavailable(reason: reason)
        }

        let instructions = CleanupPrompt.instructions(context: context)
        let userMessage = CleanupPrompt.userMessage(transcript: transcript)
        let maxTokens = Self.maximumResponseTokens(forTranscriptTokens: estimatedTokens)

        let raw = try await backend.generate(
            instructions: instructions,
            userMessage: userMessage,
            maximumResponseTokens: maxTokens
        )

        // Prewarm the next session off the paste path (this whole call already
        // runs detached from the HUD state), then apply the shared output
        // hygiene (empty/runaway/meta-commentary/negation-drop → keep raw).
        await backend.prewarm(instructions: instructions)

        return try CleanupHygiene.validate(raw, transcript: transcript)
    }

    // MARK: - Pure helpers (unit-tested)

    public static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / charsPerToken)
    }

    /// ~2× transcript tokens, clamped to [floor, cap].
    public static func maximumResponseTokens(forTranscriptTokens transcriptTokens: Int) -> Int {
        min(responseTokenCap, max(responseTokenFloor, transcriptTokens * 2))
    }

    /// Trim surrounding whitespace and a single layer of wrapping quotes.
    /// Delegates to the shared `CleanupHygiene` so local and cloud tiers share
    /// one implementation.
    public static func sanitize(_ output: String) -> String {
        CleanupHygiene.sanitize(output)
    }
}

/// Backend used when `FoundationModels` can't be imported at all.
struct UnavailableBackend: LocalCleanupBackend {
    let reason: String
    func unavailability() async -> String? { reason }
    func generate(instructions: String, userMessage: String, maximumResponseTokens: Int) async throws -> String {
        throw CleanerError.unavailable(reason: reason)
    }
    func prewarm(instructions: String) async {}
}

#if canImport(FoundationModels)
/// Live Apple Foundation Models backend. Holds one prewarmed session for the
/// common (repeat-context) case; a session that has already responded is never
/// reused (fresh 4096-token context, no accumulation).
actor FoundationModelBackend: LocalCleanupBackend {
    private var prewarmed: (instructions: String, session: LanguageModelSession)?

    func unavailability() async -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return Self.describe(reason)
        @unknown default:
            return "the on-device model is unavailable"
        }
    }

    func generate(instructions: String, userMessage: String, maximumResponseTokens: Int) async throws -> String {
        let session: LanguageModelSession
        if let prewarmed, prewarmed.instructions == instructions {
            session = prewarmed.session
            self.prewarmed = nil
        } else {
            session = LanguageModelSession(instructions: { instructions })
        }
        let options = GenerationOptions(temperature: 0.1, maximumResponseTokens: maximumResponseTokens)
        let response = try await session.respond(to: userMessage, options: options)
        return response.content
    }

    func prewarm(instructions: String) async {
        let session = LanguageModelSession(instructions: { instructions })
        session.prewarm()
        prewarmed = (instructions, session)
    }

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled"
        case .deviceNotEligible:
            return "this device does not support Apple Intelligence"
        case .modelNotReady:
            return "the on-device model is still preparing"
        @unknown default:
            return "the on-device model is unavailable"
        }
    }
}
#endif
