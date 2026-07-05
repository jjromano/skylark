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
        return parts.joined(separator: " · ")
    }

    private func tierLabel(_ tier: CleanupTier) -> String {
        switch tier {
        case .raw: return "Raw"
        case .local: return "Local"
        case .cloud(let slug): return "Cloud (\(slug))"
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
    @State private var isDefault: Bool

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
