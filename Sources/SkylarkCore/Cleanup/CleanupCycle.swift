import Foundation

/// One stop on the cleanup-selection ring walked by the optional cycle hotkey
/// (PRD §7: "a menu-bar dropdown AND an optional cycle hotkey to change the
/// active cleanup model on the fly").
///
/// The cases mirror exactly what the menu bar already offers — the Cleanup tier
/// submenu (Auto/Raw/Local/Cloud), the on-device engines in Settings → Models
/// ("Cleanup · on device"), and the cloud registry rows in the Cleanup Model
/// submenu — so the hotkey can never land the user somewhere the menus can't
/// show or undo.
public enum CleanupCycleOption: Sendable, Equatable, Hashable, Identifiable {
    /// Per-mode tier (the app's default): the resolved mode decides.
    case auto
    /// No cleanup — paste the raw transcript.
    case raw
    /// The local tier, pinned to a specific on-device engine.
    case local(LocalCleanupEngine)
    /// The cloud tier, pinned to a specific registry slug.
    case cloud(slug: String, label: String)

    public var id: String {
        switch self {
        case .auto: return "auto"
        case .raw: return "raw"
        case .local(let engine): return "local:\(engine.persistedValue)"
        case .cloud(let slug, _): return "cloud:\(slug)"
        }
    }

    /// The `cleanupTierOverride` raw value this option forces — the same strings
    /// the menu-bar Cleanup submenu and the Settings tier picker write.
    public var tierOverride: String {
        switch self {
        case .auto: return "auto"
        case .raw: return "raw"
        case .local: return "local"
        case .cloud: return "cloud"
        }
    }

    /// Name shown in the menu-bar note after a cycle press ("Cleanup: Qwen3 4B
    /// Instruct").
    public var displayName: String {
        switch self {
        case .auto: return "Auto (per-mode)"
        case .raw: return "Raw (no cleanup)"
        case .local(.appleFoundationModels): return "Apple Intelligence (local)"
        case .local(.llama(let modelID)):
            return LocalCleanupModel.model(id: modelID)?.displayName ?? modelID
        case .cloud(_, let label): return label
        }
    }
}

/// Pure ordering + advance logic for the cleanup cycle hotkey. Nothing here
/// touches UserDefaults or the orchestrator: the app layer asks for the options,
/// asks which one is current, asks for the next one, and applies it exactly as
/// the menus would.
public enum CleanupCycle {
    /// The ring, in menu order: Auto → Raw → Apple Intelligence → each Qwen model
    /// actually present on disk → each cloud cleanup model, but only when an API
    /// key is stored (a cloud stop with no key would degrade every dictation and
    /// is not a selection the user can act on).
    ///
    /// Auto leads because it is the app's default state and the menu's first row;
    /// including it keeps the ring lossless — whatever the hotkey does, another
    /// few presses return to where the user started.
    public static func options(
        localModels: [LocalCleanupModel] = LocalCleanupModel.installed,
        cloudModels: [ModelRegistryEntry],
        hasAPIKey: Bool
    ) -> [CleanupCycleOption] {
        var options: [CleanupCycleOption] = [.auto, .raw, .local(.appleFoundationModels)]
        options += localModels.map { .local(.llama(modelID: $0.id)) }
        if hasAPIKey {
            options += cloudModels
                .filter { $0.kind == .cleanup }
                .map { .cloud(slug: $0.slug, label: $0.label) }
        }
        return options
    }

    /// Which option the current settings correspond to, or nil when the live
    /// state isn't on the ring at all (e.g. the Cloud tier while no key is
    /// stored, or a local engine whose model was deleted) — in which case the
    /// next press restarts from the top rather than guessing.
    public static func current(
        tierOverride: String,
        localEngine: LocalCleanupEngine,
        cloudSlug: String,
        options: [CleanupCycleOption]
    ) -> CleanupCycleOption? {
        let wanted: CleanupCycleOption
        switch tierOverride {
        case "raw": wanted = .raw
        case "local": wanted = .local(localEngine)
        case "cloud": wanted = .cloud(slug: cloudSlug, label: cloudSlug)
        default: wanted = .auto
        }
        // Match on identity, not equality: a cloud option carries the registry
        // label, which the state above can't know.
        return options.first { $0.id == wanted.id }
    }

    /// The next option after `current`, wrapping at the end. An unknown (nil)
    /// current selection starts at the first option.
    public static func next(
        after current: CleanupCycleOption?,
        in options: [CleanupCycleOption]
    ) -> CleanupCycleOption? {
        guard let first = options.first else { return nil }
        guard let current, let index = options.firstIndex(where: { $0.id == current.id }) else {
            return first
        }
        return options[(index + 1) % options.count]
    }
}
