import Foundation

/// How aggressively the cleanup stage may edit a transcript (Settings →
/// General, Cleanup section). Independent of `CleanupTier` (which engine
/// runs) — this controls how much that engine is asked to change. The
/// existing `.raw` tier already covers "no cleanup at all", so there is no
/// `.none` level here.
public enum CleanupIntensity: String, CaseIterable, Sendable, Codable, Equatable {
    /// Punctuation, capitalization, spoken-number formatting, and collapsing
    /// accidental word repeats only — every other spoken word is kept.
    case light
    /// Today's default behavior: filler/self-correction removal, punctuation,
    /// capitalization, spoken layout + list formatting (+ number/politeness
    /// formatting on the local tier's compact prompt).
    case standard
    /// Everything `standard` does, plus light grammatical smoothing (tense/
    /// number agreement, dropping false starts and abandoned fragments,
    /// tightening obvious redundancy) — never summarizing, reordering, or
    /// dropping content.
    case high

    /// One-line description for the Settings footer caption.
    public var caption: String {
        switch self {
        case .light:
            return "Only punctuation, capitalization, and repeated-word cleanup — every other spoken word is kept."
        case .standard:
            return "Removes filler words and false starts, resolves self-corrections, and formats numbers and lists (default)."
        case .high:
            return "Also smooths tense and agreement and tightens obvious redundancy, without changing your meaning."
        }
    }

    /// Persisted UserDefaults key (Settings → General, Cleanup section).
    public static let defaultsKey = "cleanup.intensity"

    /// Read the persisted value, defaulting to `.standard`.
    public static func persisted(in defaults: UserDefaults = .standard) -> CleanupIntensity {
        defaults.string(forKey: defaultsKey).flatMap(CleanupIntensity.init(rawValue:)) ?? .standard
    }
}
