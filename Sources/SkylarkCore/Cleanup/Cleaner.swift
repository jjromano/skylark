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

/// On-screen text surrounding the caret at dictation start, captured via
/// Accessibility (opt-in, "context-aware cleanup"). Handed to the cleaner as
/// reference DATA so a continuation gets the right capitalization/leading
/// punctuation ("…finish the sentence" stays lowercase after a comma) and
/// names/jargon already in the field are spelled consistently.
///
/// Both strings are already truncated at capture (the reader bounds them by
/// `precedingLimit`/`followingLimit`) — the prompt builder never re-truncates.
/// Privacy: this value lives only for the single cleanup call that consumes it;
/// it is never logged, never persisted.
public struct FieldContext: Sendable, Equatable {
    /// Text immediately BEFORE the caret (up to `precedingLimit` UTF-16 units).
    public let preceding: String
    /// Text immediately AFTER the caret (up to `followingLimit` UTF-16 units).
    public let following: String

    /// Capture bounds (UTF-16 units). ~1200 before the caret gives the cleaner
    /// enough of the sentence/paragraph to continue it; ~400 after is enough to
    /// see the following word/sentence without pulling in a whole document.
    public static let precedingLimit = 1200
    public static let followingLimit = 400

    public init(preceding: String, following: String) {
        self.preceding = preceding
        self.following = following
    }

    /// No usable context on either side (empty field / caret with nothing
    /// around it) — treated as "no context" so nothing is added to the prompt.
    public var isEmpty: Bool {
        preceding.isEmpty && following.isEmpty
    }
}

/// Context handed to a cleaner alongside the transcript.
public struct CleanupContext: Sendable {
    /// Bundle ID of the app the text is going into (register matching).
    public let targetAppBundleID: String?
    /// Optional tone hint from the active mode (e.g. "casual chat", "email").
    public let registerHint: String?
    /// Custom-dictionary spellings the cleaner must preserve/prefer.
    public let dictionaryTerms: [String]
    /// How aggressively the cleaner may edit (Settings → General). Defaulted
    /// so existing call sites compile unchanged.
    public let intensity: CleanupIntensity
    /// On-screen text around the caret (opt-in context-aware cleanup). nil when
    /// the toggle is off, the field isn't AX-readable, or the read hadn't
    /// finished by cleanup time — the cleaner then behaves exactly as before.
    public let fieldContext: FieldContext?
    /// BCP-47 target language for translation mode (Settings → General; OFF by
    /// default). `nil` = translate off. When set, the cleanup prompt appends a
    /// final "translate the result into <language>" instruction, and the
    /// faithfulness guards run in translated mode (retention/content-loss/
    /// negation checks — all source-language comparisons — are bypassed; see
    /// `CleanupHygiene.validate`). Ignored by `RawPassthrough` (Tier 0 needs a
    /// cleanup model to translate, so raw dictation is never translated).
    public let translateTo: String?
    /// Free-text instruction from the active mode (PRD Appendix A's
    /// "user-defined custom mode prompts"). Already sanitized and length-capped
    /// by `DictationMode.sanitizeCustomPrompt`. Appended to the standard
    /// instructions, never replacing them; the hygiene/faithfulness guard still
    /// judges the result, so an over-aggressive instruction degrades to raw
    /// rather than shipping a mangled transcript. nil = no extra instruction.
    public let customInstruction: String?

    public init(
        targetAppBundleID: String? = nil,
        registerHint: String? = nil,
        dictionaryTerms: [String] = [],
        intensity: CleanupIntensity = .standard,
        fieldContext: FieldContext? = nil,
        translateTo: String? = nil,
        customInstruction: String? = nil
    ) {
        self.targetAppBundleID = targetAppBundleID
        self.registerHint = registerHint
        self.dictionaryTerms = dictionaryTerms
        self.intensity = intensity
        self.fieldContext = fieldContext
        self.translateTo = translateTo
        self.customInstruction = customInstruction
    }

    /// Copy carrying a different dictionary term list. The orchestrator narrows
    /// the list to the terms the current transcript plausibly contains before a
    /// CLOUD request (`DictionaryRelevance`), so a private dictionary isn't
    /// uploaded wholesale on every cleanup; local cleanup keeps the full list.
    public func withDictionaryTerms(_ terms: [String]) -> CleanupContext {
        CleanupContext(
            targetAppBundleID: targetAppBundleID,
            registerHint: registerHint,
            dictionaryTerms: terms,
            intensity: intensity,
            fieldContext: fieldContext,
            translateTo: translateTo,
            customInstruction: customInstruction
        )
    }

    /// Copy carrying `fieldContext` — the orchestrator merges the (late,
    /// off-path) AX read into the setup-built context at cleanup time. A nil or
    /// empty context clears it, so an absent read leaves a plain context.
    public func withFieldContext(_ fieldContext: FieldContext?) -> CleanupContext {
        let resolved = (fieldContext?.isEmpty ?? true) ? nil : fieldContext
        return CleanupContext(
            targetAppBundleID: targetAppBundleID,
            registerHint: registerHint,
            dictionaryTerms: dictionaryTerms,
            intensity: intensity,
            fieldContext: resolved,
            translateTo: translateTo,
            customInstruction: customInstruction
        )
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
