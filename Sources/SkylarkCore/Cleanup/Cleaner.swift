import Foundation

/// Which cleanup tier a cleaner implements (PRD §6.3).
public enum CleanupTier: Sendable, Equatable, Codable {
    /// Tier 0 — verbatim passthrough, zero added latency.
    case raw
    /// Tier 1 — on-device model (Apple Foundation Models).
    case local
    /// Tier 2 — cloud model via OpenRouter, identified by registry slug.
    case cloud(slug: String)
}

/// Context handed to a cleaner alongside the transcript.
public struct CleanupContext: Sendable {
    /// Bundle ID of the app the text is going into (register matching).
    public let targetAppBundleID: String?
    /// Optional tone hint from the active mode (e.g. "casual chat", "email").
    public let registerHint: String?
    /// Custom-dictionary spellings the cleaner must preserve/prefer.
    public let dictionaryTerms: [String]

    public init(targetAppBundleID: String? = nil, registerHint: String? = nil, dictionaryTerms: [String] = []) {
        self.targetAppBundleID = targetAppBundleID
        self.registerHint = registerHint
        self.dictionaryTerms = dictionaryTerms
    }
}

/// Transforms a raw transcript into clean text (ARCHITECTURE §2). Implementations:
/// `RawPassthrough`, `LocalCleaner` (FoundationModels), `OpenRouterCleaner`.
public protocol Cleaner: Sendable {
    var tier: CleanupTier { get }
    func clean(_ transcript: String, context: CleanupContext) async throws -> String
}

public enum CleanerError: Error, Sendable {
    /// The engine can't run here (e.g. Apple Intelligence disabled) — the
    /// pipeline falls back to raw text, never blocks the paste.
    case unavailable(reason: String)
    /// The model responded but with unusable output; caller keeps the raw text.
    case unusableOutput
}
