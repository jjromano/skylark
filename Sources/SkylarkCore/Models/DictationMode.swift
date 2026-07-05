import Foundation

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
    public let isDefault: Bool

    public init(
        id: String,
        name: String,
        bundleIDPattern: String?,
        cleanupTier: CleanupTier,
        cloudCleanupSlug: String? = nil,
        registerHint: String? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bundleIDPattern = bundleIDPattern
        self.cleanupTier = cleanupTier
        self.cloudCleanupSlug = cloudCleanupSlug
        self.registerHint = registerHint
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
