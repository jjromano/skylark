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

/// Cleaned text plus WHICH engine actually produced it — degrading wrappers
/// report the chain element that ran, so history rows can show real
/// provenance ("llama-3.3-70b" vs "local" vs "raw") instead of the tier the
/// user requested.
public struct CleanOutcome: Sendable, Equatable {
    public let text: String
    /// Stable engine label: "raw", "local", or a cloud model slug.
    public let engine: String

    public init(text: String, engine: String) {
        self.text = text
        self.engine = engine
    }
}

/// Transforms a raw transcript into clean text (ARCHITECTURE §2). Implementations:
/// `RawPassthrough`, `LocalCleaner` (FoundationModels), `OpenRouterCleaner`.
public protocol Cleaner: Sendable {
    var tier: CleanupTier { get }
    func clean(_ transcript: String, context: CleanupContext) async throws -> String
    /// `clean` plus engine provenance. Defaulted for simple cleaners (their
    /// engine IS their tier); `DegradingCleaner` overrides to report the chain
    /// element that actually produced the output.
    func cleanTracked(_ transcript: String, context: CleanupContext) async throws -> CleanOutcome
}

public extension Cleaner {
    /// Stable engine label derived from the tier.
    var engineID: String {
        switch tier {
        case .raw: return "raw"
        case .local: return "local"
        case .cloud(let slug): return slug
        }
    }

    func cleanTracked(_ transcript: String, context: CleanupContext) async throws -> CleanOutcome {
        CleanOutcome(text: try await clean(transcript, context: context), engine: engineID)
    }
}

public enum CleanerError: Error, Sendable {
    /// The engine can't run here (e.g. Apple Intelligence disabled) — the
    /// pipeline falls back to raw text, never blocks the paste.
    case unavailable(reason: String)
    /// The model responded but with unusable output; caller keeps the raw text.
    case unusableOutput
}
