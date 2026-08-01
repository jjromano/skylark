import Foundation

/// Which speech-to-text engine the user has selected.
public enum STTChoice: Sendable, Equatable, Hashable {
    /// Local Parakeet (default, fully offline).
    case localParakeet
    /// Local WhisperKit large-v3-turbo (offline fallback engine, phase-4).
    case localWhisper
    /// Local Apple Speech (macOS 26 SpeechAnalyzer/SpeechTranscriber, offline).
    case localApple
    /// Cloud STT via OpenRouter, identified by registry slug.
    case cloud(slug: String)

    /// UserDefaults serialization ("local" | "localWhisper" | "localApple" |
    /// "cloud:<slug>"); non-secret.
    var serialized: String {
        switch self {
        case .localParakeet: return "local"
        case .localWhisper: return "localWhisper"
        case .localApple: return "localApple"
        case .cloud(let slug): return "cloud:\(slug)"
        }
    }

    init(serialized: String?) {
        guard let value = serialized else { self = .localParakeet; return }
        if value.hasPrefix("cloud:") {
            self = .cloud(slug: String(value.dropFirst("cloud:".count)))
        } else if value == "localWhisper" {
            self = .localWhisper
        } else if value == "localApple" {
            self = .localApple
        } else {
            self = .localParakeet
        }
    }

    /// Whether this is one of the local (offline) engines.
    public var isLocal: Bool {
        switch self {
        case .localParakeet, .localWhisper, .localApple: return true
        case .cloud: return false
        }
    }
}

/// Live, UserDefaults-backed model selection surfaced by the menu-bar
/// quick-switcher (phase-3 spec §2). Non-secret, so it lives in plain
/// UserDefaults keys. When the user picks a free-text slug that isn't already in
/// the registry it's upserted as an ad-hoc entry (with the registry-resolved
/// provider pin — none for an unknown slug) so it shows up in the menus
/// thereafter.
@MainActor
@Observable
public final class ModelSelection {
    public static let defaultCleanupSlug = "openai/gpt-oss-20b"

    private enum Key {
        static let cleanupSlug = "modelSelection.cleanupSlug"
        static let sttChoice = "modelSelection.sttChoice"
    }

    public var cleanupSlug: String {
        didSet { defaults.set(cleanupSlug, forKey: Key.cleanupSlug) }
    }

    public var sttChoice: STTChoice {
        didSet { defaults.set(sttChoice.serialized, forKey: Key.sttChoice) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let registry: RegistryStore?

    public init(defaults: UserDefaults = .standard, registry: RegistryStore? = nil) {
        self.defaults = defaults
        self.registry = registry
        // Assignments in init don't fire `didSet`, so loading defaults here never
        // writes them back.
        self.cleanupSlug = defaults.string(forKey: Key.cleanupSlug) ?? Self.defaultCleanupSlug
        self.sttChoice = STTChoice(serialized: defaults.string(forKey: Key.sttChoice))
    }

    /// Set the global cleanup slug; upsert an ad-hoc registry entry when the slug
    /// isn't already known so it appears in menus thereafter.
    ///
    /// The pin is RESOLVED, never assumed: a slug the registry knows keeps its
    /// curated pin, and an unknown free-text slug is stored with NO pin so
    /// OpenRouter routes it. Pinning an arbitrary slug to Groq (which this used
    /// to do) is worse than not pinning at all — Groq may not serve that model,
    /// so the user's deliberate switch silently lands somewhere else.
    public func setCleanupSlug(_ slug: String, known: [ModelRegistryEntry]) async {
        cleanupSlug = slug
        guard !slug.isEmpty, !known.contains(where: { $0.slug == slug }) else { return }
        try? await registry?.upsert(entry: ModelRegistryEntry(
            slug: slug,
            label: slug,
            providerPin: CleanupProviderPins.providerPin(for: slug, known: known),
            kind: .cleanup,
            sort: 999
        ))
    }

    /// Set the STT choice; for a free-text cloud slug not in the registry, upsert
    /// an ad-hoc stt entry (no provider pin) so it appears in menus thereafter.
    public func setSTT(_ choice: STTChoice, known: [ModelRegistryEntry]) async {
        sttChoice = choice
        guard case .cloud(let slug) = choice, !slug.isEmpty,
              !known.contains(where: { $0.slug == slug }) else { return }
        try? await registry?.upsert(entry: ModelRegistryEntry(
            slug: slug, label: slug, providerPin: nil, kind: .stt, sort: 999
        ))
    }
}
