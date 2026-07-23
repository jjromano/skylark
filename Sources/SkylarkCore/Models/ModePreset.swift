import Foundation

/// Curated, one-click "style presets" for common apps — pure content layered
/// on the existing modes machinery (`DictationMode`/`ModeStore`/
/// `ModeResolver` already do app matching + register-hint/cleanup-tier
/// resolution; this type adds no new pipeline behavior).
///
/// `DictationMode`/`ModeRecord` bind exactly one bundle-id glob per mode
/// (`ModeResolver.matchScore` scores a single `pattern`), so a preset that
/// covers several apps under one curated name expands to one `ModeRecord`
/// per pattern when added — see `makeRecords()`. All rows from the same
/// preset share its name, register hint, and cleanup tier, and are
/// independently user-editable/deletable afterward like any other mode.
public struct ModePreset: Sendable, Equatable, Identifiable {
    /// Stable catalog identifier (not shown in the UI) — combined with each
    /// bundle-id pattern to derive deterministic `ModeRecord` ids so
    /// re-adding a preset replaces rather than duplicates its rows.
    public let id: String
    public let name: String
    /// One-line description shown next to the "Add" button in Settings.
    public let summary: String
    /// One glob per matched app (see `ModeResolver.globMatches` for the
    /// supported `*` syntax — no OR/alternation, hence one row per pattern).
    public let bundleIDPatterns: [String]
    public let cleanupTier: CleanupTier
    public let registerHint: String?

    public init(
        id: String,
        name: String,
        summary: String,
        bundleIDPatterns: [String],
        cleanupTier: CleanupTier,
        registerHint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.bundleIDPatterns = bundleIDPatterns
        self.cleanupTier = cleanupTier
        self.registerHint = registerHint
    }

    /// Deterministic per-pattern `ModeRecord` id: `"preset:<presetID>:<pattern>"`.
    public func recordID(for pattern: String) -> String {
        "preset:\(id):\(pattern)"
    }

    /// Whether `existing` already contains a row added by this preset.
    /// Matched by mode name (spec'd contract for the Settings "Suggested"
    /// list) — every row a preset creates shares its `name`, so a single
    /// name check covers the whole group regardless of how many bundle-id
    /// rows it expanded into.
    public func isAdded(in existing: [ModeRecord]) -> Bool {
        existing.contains { $0.name == name }
    }

    /// Expands this preset into one `ModeRecord` per bundle-id pattern, none
    /// of them a default mode. IDs are deterministic (see `recordID(for:)`),
    /// so passing these to `ModeStore.upsert` (insert-or-replace by primary
    /// key) is idempotent — re-adding a preset never creates duplicate rows.
    public func makeRecords() -> [ModeRecord] {
        bundleIDPatterns.map { pattern in
            ModeRecord(
                id: recordID(for: pattern),
                name: name,
                bundleIDPattern: pattern,
                engine: nil,
                cleanupTier: cleanupTier,
                registerHint: registerHint,
                isDefault: false
            )
        }
    }
}

/// The curated preset catalog (~8 entries). Bundle IDs were verified against
/// vendor docs/known conventions at authoring time; see the per-preset
/// comments. `.local` stands in for "auto" cleanup (no such tier exists yet);
/// `.raw` is used where reworded text would be actively harmful (shell
/// commands, cell values).
public enum ModePresetCatalog {
    public static let all: [ModePreset] = [
        ModePreset(
            id: "messages-chat-casual",
            name: "Messages & chat — casual",
            summary: "Messages, Slack, Discord, Signal — relaxed tone, contractions fine.",
            bundleIDPatterns: [
                "com.apple.MobileSMS",
                "com.tinyspeck.slackmacgap",
                "com.hnc.Discord",
                "org.whispersystems.signal-desktop",
            ],
            cleanupTier: .local,
            registerHint: "casual chat: relaxed tone, contractions fine, lowercase-after-comma style, emoji left as spoken"
        ),
        ModePreset(
            id: "mail-documents-polished",
            name: "Mail & documents — polished",
            summary: "Mail, Outlook, Pages, Word — complete sentences, proper punctuation.",
            bundleIDPatterns: [
                "com.apple.mail",
                "com.microsoft.Outlook",
                "com.apple.iWork.Pages",
                "com.microsoft.Word",
            ],
            cleanupTier: .local,
            registerHint: "professional writing: complete sentences, proper punctuation"
        ),
        ModePreset(
            id: "terminals-editors-verbatim",
            name: "Terminals & editors — verbatim",
            summary: "iTerm2, Terminal, Warp, VS Code, Cursor — never reworded.",
            bundleIDPatterns: [
                "com.googlecode.iterm2",
                "com.apple.Terminal",
                "dev.warp.Warp-Stable",
                "com.microsoft.VSCode",
                // Cursor: TeamID-derived bundle id (Electron/todesktop shell),
                // confirmed via Cursor's own community forum.
                "com.todesktop.230313mzl4w4u92",
            ],
            cleanupTier: .raw
        ),
        ModePreset(
            id: "notes-structured",
            name: "Notes — structured",
            summary: "Apple Notes, Obsidian, Notion — concise, lists welcome.",
            bundleIDPatterns: [
                "com.apple.Notes",
                // Obsidian's app id is documented as "md.obsidian" (and
                // "md.obsidian.Obsidian" on its Linux/Flatpak build); the
                // trailing glob covers either macOS variant.
                "md.obsidian*",
                "notion.id",
            ],
            cleanupTier: .local,
            registerHint: "notes: concise, lists welcome"
        ),
        ModePreset(
            id: "ai-chat-natural",
            name: "AI chat & assistants — natural",
            summary: "ChatGPT, Claude desktop — conversational, thinking-out-loud is fine.",
            bundleIDPatterns: [
                "com.openai.chat",
                "com.anthropic.claudefordesktop",
            ],
            cleanupTier: .local,
            registerHint: "conversational: natural phrasing, thinking-out-loud is fine, no need for perfect grammar"
        ),
        ModePreset(
            id: "tasks-trackers-structured",
            name: "Tasks & trackers — structured",
            summary: "Things, Todoist, OmniFocus — short, imperative task text.",
            bundleIDPatterns: [
                "com.culturedcode.ThingsMac",
                "com.todoist.mac.Todoist",
                // Covers both the direct-download and Mac App Store variants
                // (com.omnigroup.OmniFocus3 / com.omnigroup.OmniFocus3.MacAppStore).
                "com.omnigroup.OmniFocus3*",
            ],
            cleanupTier: .local,
            registerHint: "task text: short, imperative, no filler"
        ),
        ModePreset(
            id: "spreadsheets-verbatim",
            name: "Spreadsheets — verbatim",
            summary: "Excel, Numbers — cell values and formulas, never reworded.",
            bundleIDPatterns: [
                "com.microsoft.Excel",
                "com.apple.iWork.Numbers",
            ],
            cleanupTier: .raw
        ),
        ModePreset(
            id: "calendar-concise",
            name: "Calendar & scheduling — concise",
            summary: "Calendar — concise event text, times and locations kept exact.",
            bundleIDPatterns: [
                // "iCal" is Calendar.app's legacy-but-still-current bundle id.
                "com.apple.iCal",
            ],
            cleanupTier: .local,
            registerHint: "calendar event text: concise, keep times and locations exact"
        ),
    ]
}
