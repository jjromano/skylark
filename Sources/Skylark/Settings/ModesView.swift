import AppKit
import SkylarkCore
import SwiftUI

/// Settings → Modes (phase-5a spec §4). List + create/edit/delete of app-aware
/// dictation modes. Deleting the default mode is blocked (`ModeStore` also
/// enforces this); exactly one default is kept via `setDefault(id:)`.
struct ModesView: View {
    let store: ModeStore
    let cleanupModels: [ModelRegistryEntry]

    @State private var modes: [ModeRecord] = []
    @State private var editorTarget: EditorTarget?

    private enum EditorTarget: Identifiable {
        case new
        case existing(ModeRecord)
        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let mode): return mode.id
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Modes").font(.title2.bold())
                Spacer()
                Button("New Mode…") { editorTarget = .new }
            }
            Text("A mode binds a target app to a cleanup tier + register hint. History rows keep their mode name even after the mode is deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(modes) { mode in
                    ModeRow(mode: mode, onEdit: { editorTarget = .existing(mode) }, onDelete: { delete(mode) })
                    if mode.id != modes.last?.id {
                        Divider()
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))

            Text("Suggested").font(.headline).padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(ModePresetCatalog.all) { preset in
                    PresetRow(preset: preset, isAdded: preset.isAdded(in: modes), onAdd: { add(preset) })
                    if preset.id != ModePresetCatalog.all.last?.id {
                        Divider()
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        }
        .task { await reload() }
        .sheet(item: $editorTarget) { target in
            ModeEditorSheet(
                existing: {
                    if case .existing(let mode) = target { return mode }
                    return nil
                }(),
                cleanupModels: cleanupModels,
                onSave: { record, makeDefault in
                    Task {
                        await save(record, makeDefault: makeDefault)
                        editorTarget = nil
                    }
                },
                onCancel: { editorTarget = nil }
            )
        }
    }

    private func reload() async {
        modes = ((try? await store.all()) ?? []).sorted { $0.name < $1.name }
    }

    private func save(_ record: ModeRecord, makeDefault: Bool) async {
        var toSave = record
        // Preserve the existing default flag; `setDefault` below is the sole
        // authority for flipping it on, so upsert never accidentally clears the
        // real default when saving an unrelated mode.
        toSave.isDefault = modes.first { $0.id == record.id }?.isDefault ?? false
        try? await store.upsert(toSave)
        if makeDefault {
            try? await store.setDefault(id: toSave.id)
        }
        await reload()
    }

    private func delete(_ mode: ModeRecord) {
        Task {
            try? await store.delete(id: mode.id)
            await reload()
        }
    }

    private func add(_ preset: ModePreset) {
        Task {
            try? await store.add(preset: preset)
            await reload()
        }
    }
}

/// One curated preset in the "Suggested" section: a one-line description plus
/// either an "Add" button (not yet added) or a checkmark (already added, per
/// name — see `ModePreset.isAdded(in:)`). Adding is explicit and one-click;
/// nothing auto-applies beyond what modes already do.
private struct PresetRow: View {
    let preset: ModePreset
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.system(size: 13, weight: .medium))
                Text(preset.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isAdded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("Already added")
            } else {
                Button("Add", action: onAdd)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ModeRow: View {
    let mode: ModeRecord
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mode.name).font(.system(size: 13, weight: .medium))
                    if mode.isDefault {
                        Text("default")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.blue.opacity(0.2)))
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
                .disabled(mode.isDefault)
                .help(mode.isDefault ? "Set another mode default first" : "")
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts: [String] = [tierLabel(mode.cleanupTier)]
        if let pattern = mode.bundleIDPattern, !pattern.isEmpty { parts.append(pattern) }
        if let hint = mode.registerHint, !hint.isEmpty { parts.append(hint) }
        if let whisperLabel = whisperOverrideLabel(mode.whisperModeOverride) { parts.append(whisperLabel) }
        return parts.joined(separator: " · ")
    }

    /// nil for the common case (follow global) so the row stays uncluttered;
    /// only an explicit override earns a subtitle chip.
    private func whisperOverrideLabel(_ override: WhisperModeOverride) -> String? {
        switch override {
        case .followGlobal: return nil
        case .on: return "Whisper Mode: always on"
        case .off: return "Whisper Mode: always off"
        }
    }

    private func tierLabel(_ tier: CleanupTier) -> String {
        switch tier {
        case .raw: return "Raw"
        case .local: return "Local"
        case .cloud(let slug): return "Cloud (\(slug))"
        }
    }
}

/// Menu labels for the per-mode Whisper Mode override picker (R3).
extension WhisperModeOverride {
    fileprivate var label: String {
        switch self {
        case .followGlobal: return "Follow global setting"
        case .on: return "Always on"
        case .off: return "Always off"
        }
    }
}

// MARK: - Editor sheet

private struct ModeEditorSheet: View {
    let existing: ModeRecord?
    let cleanupModels: [ModelRegistryEntry]
    let onSave: (ModeRecord, Bool) -> Void
    let onCancel: () -> Void

    private enum TierChoice: String, CaseIterable, Identifiable, Hashable {
        case raw, local, cloud
        var id: String { rawValue }
        var label: String {
            switch self {
            case .raw: return "Raw"
            case .local: return "Local"
            case .cloud: return "Cloud"
            }
        }
    }

    @State private var name: String
    @State private var bundlePattern: String
    @State private var tier: TierChoice
    @State private var cloudSlug: String
    @State private var registerHint: String
    @State private var whisperModeOverride: WhisperModeOverride
    @State private var customPrompt: String
    @State private var isDefault: Bool

    /// Live character budget. Mirrors `DictationMode.customPromptLimit` rather
    /// than restating the number, so the cap can only ever be changed in one
    /// place. Over-limit is a warning, not a block: `sanitizeCustomPrompt`
    /// truncates on save, and saying so beats silently dropping the tail.
    private var customPromptOverLimit: Bool {
        customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count
            > DictationMode.customPromptLimit
    }

    private var customPromptCaption: String {
        let used = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count
        let limit = DictationMode.customPromptLimit
        if customPromptOverLimit {
            return "Over the \(limit)-character limit — the extra \(used - limit) will be trimmed when you save."
        }
        return """
        Added to this mode's cleanup instructions on top of the standard rules, \
        never replacing them. Cleanup still has to keep your meaning, so an \
        instruction that rewrites too aggressively is rejected and the raw text \
        stands. Sent to the cloud model when this mode uses cloud cleanup. \
        \(used)/\(limit)
        """
    }

    init(
        existing: ModeRecord?,
        cleanupModels: [ModelRegistryEntry],
        onSave: @escaping (ModeRecord, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.existing = existing
        self.cleanupModels = cleanupModels
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: existing?.name ?? "")
        _bundlePattern = State(initialValue: existing?.bundleIDPattern ?? "")
        _registerHint = State(initialValue: existing?.registerHint ?? "")
        _whisperModeOverride = State(initialValue: existing?.whisperModeOverride ?? .followGlobal)
        _customPrompt = State(initialValue: existing?.customPrompt ?? "")
        _isDefault = State(initialValue: existing?.isDefault ?? false)
        switch existing?.cleanupTier {
        case .some(.raw):
            _tier = State(initialValue: .raw)
            _cloudSlug = State(initialValue: cleanupModels.first?.slug ?? "")
        case .some(.cloud(let slug)):
            _tier = State(initialValue: .cloud)
            _cloudSlug = State(initialValue: slug)
        case .some(.local), .none:
            _tier = State(initialValue: .local)
            _cloudSlug = State(initialValue: cleanupModels.first?.slug ?? "")
        }
    }

    var body: some View {
        Form {
            Section("Mode") {
                TextField("Name", text: $name)
                HStack {
                    TextField("Bundle ID pattern (e.g. com.apple.mail, com.microsoft.*)", text: $bundlePattern)
                    Menu {
                        ForEach(Self.runningAppBundleIDs(), id: \.self) { bundleID in
                            Button(bundleID) { bundlePattern = bundleID }
                        }
                    } label: {
                        Text("Pick…")
                    }
                    .frame(width: 70)
                }
            }

            Section("Cleanup") {
                Picker("Tier", selection: $tier) {
                    ForEach(TierChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                if tier == .cloud {
                    if cleanupModels.isEmpty {
                        TextField("Model slug", text: $cloudSlug)
                    } else {
                        Picker("Model", selection: $cloudSlug) {
                            ForEach(cleanupModels) { entry in
                                Text(entry.label).tag(entry.slug)
                            }
                        }
                    }
                }
                TextField("Register hint (optional, e.g. \"casual chat\")", text: $registerHint)
            }

            Section("Custom instruction") {
                TextField(
                    "Optional, e.g. \"keep bullet points on separate lines\"",
                    text: $customPrompt,
                    axis: .vertical
                )
                .lineLimit(3...6)
                Text(customPromptCaption)
                    .font(.caption)
                    .foregroundStyle(customPromptOverLimit ? .orange : .secondary)
            }

            Section("Whisper Mode") {
                Picker("Override", selection: $whisperModeOverride) {
                    ForEach(WhisperModeOverride.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                Text("Whether quiet-speech normalization runs for this mode's dictations, regardless of the menu-bar Whisper Mode toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Default mode", isOn: $isDefault)
                    .disabled(existing?.isDefault == true)
                if existing?.isDefault == true {
                    Text("Set another mode default to change this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        let id = existing?.id ?? UUID().uuidString
        let resolvedTier: CleanupTier
        switch tier {
        case .raw: resolvedTier = .raw
        case .local: resolvedTier = .local
        case .cloud: resolvedTier = .cloud(slug: cloudSlug.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let record = ModeRecord(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleIDPattern: bundlePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : bundlePattern.trimmingCharacters(in: .whitespacesAndNewlines),
            cleanupTier: resolvedTier,
            registerHint: registerHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : registerHint.trimmingCharacters(in: .whitespacesAndNewlines),
            whisperModeOverride: whisperModeOverride,
            // `ModeRecord.init` runs `sanitizeCustomPrompt`, so trimming and the
            // length cap are applied once, in the model, for every writer.
            customPrompt: customPrompt,
            isDefault: existing?.isDefault ?? false
        )
        onSave(record, isDefault)
    }

    /// Running, regular-activation-policy apps (excludes background/agent
    /// processes) — the "pick from running apps" convenience (phase-5a §4).
    private static func runningAppBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .sorted()
    }
}
