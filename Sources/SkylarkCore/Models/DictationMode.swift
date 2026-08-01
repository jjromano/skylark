import Foundation

/// Per-mode override of the global Whisper Mode (quiet-speech normalization)
/// toggle (R3). `followGlobal` is the default for every existing mode — it
/// must remain the zero-value/default case so pre-R3 modes (and the schema-v5
/// migration's NULL column) are silently equivalent to "no override".
public enum WhisperModeOverride: String, Sendable, Codable, Equatable, CaseIterable {
    /// Use whatever the menu-bar Whisper Mode toggle is currently set to.
    case followGlobal
    /// Whisper Mode is always on for dictations in this mode, regardless of
    /// the global toggle.
    case on
    /// Whisper Mode is always off for dictations in this mode, regardless of
    /// the global toggle.
    case off

    /// Effective whisper-mode-on state for one session: this override, or
    /// (`followGlobal`) the global toggle's current value. The one piece of
    /// resolution logic every pipeline seam should call — never re-derive it
    /// from the raw case values.
    public func effective(globalOn: Bool) -> Bool {
        switch self {
        case .followGlobal: return globalOn
        case .on: return true
        case .off: return false
        }
    }
}

/// An app-aware dictation mode (PRD §7, ARCHITECTURE §5 `modes` table). A mode
/// binds a target-app glob to a cleanup tier + register hint. Engine/model
/// fields arrive with Phase 3/4 integration; `cloudCleanupSlug` is added now so
/// the persisted shape is stable.
public struct DictationMode: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Glob over the frontmost bundle ID, e.g. "com.apple.mail" or
    /// "com.microsoft.*". nil = matches nothing (selectable, not auto-applied).
    public let bundleIDPattern: String?
    public let cleanupTier: CleanupTier
    /// OpenRouter slug when `cleanupTier == .cloud`; nil otherwise.
    public let cloudCleanupSlug: String?
    /// Tone hint fed to the cleaner (e.g. "casual chat", "email").
    public let registerHint: String?
    /// Per-mode Whisper Mode override (R3). Default `.followGlobal`.
    public let whisperModeOverride: WhisperModeOverride
    /// Free-text instruction the user writes for this mode (PRD Appendix A,
    /// "user-defined custom mode prompts"). ADDED to the standard cleanup
    /// contract, never a replacement for it, and truncated to
    /// `customPromptLimit` before it reaches a model. nil/empty = no extra
    /// instruction, which is byte-identical to the pre-v6 prompt.
    public let customPrompt: String?
    public let isDefault: Bool

    /// Hard ceiling on a custom instruction, in characters. Keeps a stray paste
    /// out of the token budget on every dictation (the prompt rides on the
    /// latency path for paste targets) and bounds what a cloud request carries.
    public static let customPromptLimit = 500

    /// The instruction as a cleaner should consume it: trimmed, nil when empty,
    /// and clamped to `customPromptLimit`. Every prompt builder must read this
    /// rather than `customPrompt` directly.
    public var sanitizedCustomPrompt: String? {
        Self.sanitizeCustomPrompt(customPrompt)
    }

    /// Shared sanitizer so the store, the UI, and the prompt builders cannot
    /// drift on what "empty" and "too long" mean.
    public static func sanitizeCustomPrompt(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > customPromptLimit else { return trimmed }
        return String(trimmed.prefix(customPromptLimit))
    }

    public init(
        id: String,
        name: String,
        bundleIDPattern: String?,
        cleanupTier: CleanupTier,
        cloudCleanupSlug: String? = nil,
        registerHint: String? = nil,
        whisperModeOverride: WhisperModeOverride = .followGlobal,
        customPrompt: String? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bundleIDPattern = bundleIDPattern
        self.cleanupTier = cleanupTier
        self.cloudCleanupSlug = cloudCleanupSlug
        self.registerHint = registerHint
        self.whisperModeOverride = whisperModeOverride
        self.customPrompt = customPrompt
        self.isDefault = isDefault
    }

    /// Last-resort mode if a mode list is empty (keeps resolution total).
    static let rawFallback = DictationMode(
        id: "raw", name: "Raw", bundleIDPattern: nil, cleanupTier: .raw, isDefault: true
    )
}

/// Read-side surface the pipeline consumes; the GRDB `ModeStore` conforms.
public protocol ModeProviding: Sendable {
    func modes() async throws -> [DictationMode]
}

/// In-memory default seed used until the GRDB store is wired in (integration
/// pass). "Default" (local tier, isDefault) + "Raw" (raw tier).
public struct InMemoryModeProvider: ModeProviding {
    private let seeded: [DictationMode]

    public init(modes: [DictationMode] = InMemoryModeProvider.defaults) {
        self.seeded = modes
    }

    public func modes() async throws -> [DictationMode] { seeded }

    public static let defaults: [DictationMode] = [
        DictationMode(id: "default", name: "Default", bundleIDPattern: nil, cleanupTier: .local, isDefault: true),
        DictationMode(id: "raw", name: "Raw", bundleIDPattern: nil, cleanupTier: .raw),
    ]
}

/// Pure most-specific-match resolver: exact > longest-literal-prefix glob >
/// default. Unit-tested (ARCHITECTURE §5).
public enum ModeResolver {
    public static func resolve(bundleID: String?, modes: [DictationMode]) -> DictationMode {
        let fallback = modes.first(where: { $0.isDefault }) ?? modes.first ?? DictationMode.rawFallback

        guard let bundleID, !bundleID.isEmpty else { return fallback }

        var best: (mode: DictationMode, score: Int)?
        for mode in modes {
            guard let pattern = mode.bundleIDPattern, !pattern.isEmpty else { continue }
            guard let score = matchScore(pattern: pattern, bundleID: bundleID) else { continue }
            if best == nil || score > best!.score {
                best = (mode, score)
            }
        }
        return best?.mode ?? fallback
    }

    /// Specificity score for a matching pattern, or nil when it doesn't match.
    /// Exact literal match ranks above any wildcard; wider literal prefixes win.
    static func matchScore(pattern: String, bundleID: String) -> Int? {
        if !pattern.contains("*") {
            return pattern == bundleID ? Int.max : nil
        }
        guard globMatches(pattern: pattern, string: bundleID) else { return nil }
        let literalPrefix = pattern.prefix(while: { $0 != "*" })
        return literalPrefix.count
    }

    /// Minimal glob matcher supporting only `*` (any run, incl. empty).
    static func globMatches(pattern: String, string: String) -> Bool {
        let segments = pattern.components(separatedBy: "*")
        // No wildcard → exact.
        if segments.count == 1 { return pattern == string }

        var index = string.startIndex
        let end = string.endIndex

        for (offset, segment) in segments.enumerated() {
            if segment.isEmpty { continue }
            if offset == 0 {
                // Leading segment must anchor at the start.
                guard string[index...].hasPrefix(segment) else { return false }
                index = string.index(index, offsetBy: segment.count)
            } else if offset == segments.count - 1 {
                // Trailing segment must anchor at the end.
                guard string[index...].hasSuffix(segment) else { return false }
            } else {
                // Middle segment: find next occurrence at or after `index`.
                guard let range = string.range(of: segment, range: index..<end) else { return false }
                index = range.upperBound
            }
        }
        return true
    }
}
