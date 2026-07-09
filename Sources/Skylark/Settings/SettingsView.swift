import SkylarkCore
import SwiftUI

/// Settings window — a sidebar (`NavigationSplitView`) of sections with grouped
/// "cards" in the detail pane, matching the modern macOS System-Settings look.
/// Dictionary/Modes are absent (not disabled) when persistence couldn't open,
/// matching the graceful degradation the rest of the app uses for a missing DB.
struct SettingsView: View {
    @Bindable var controller: AppController
    let client: OpenRouterClient
    @State private var selection: Pane? = .general

    enum Pane: String, Hashable, Identifiable, CaseIterable {
        case general, models, audio, dictionary, modes, history, account
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .models: return "Models"
            case .audio: return "Audio"
            case .dictionary: return "Dictionary"
            case .modes: return "Modes"
            case .history: return "History"
            case .account: return "Account"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .models: return "cpu"
            case .audio: return "waveform"
            case .dictionary: return "character.book.closed"
            case .modes: return "switch.2"
            case .history: return "clock"
            case .account: return "person.crop.circle"
            }
        }
    }

    private var panes: [Pane] {
        Pane.allCases.filter { pane in
            switch pane {
            case .dictionary: return controller.dictionaryStore != nil
            case .modes: return controller.modeStore != nil
            default: return true
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(panes) { pane in
                    Label(pane.title, systemImage: pane.icon).tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 220)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            // The sidebar is fixed — there's no reason to collapse it, so drop
            // the automatic toggle button from the toolbar.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(for: selection ?? .general)
                .navigationTitle((selection ?? .general).title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 740, height: 560)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "bird.fill").foregroundStyle(.secondary)
            Text("Skylark \(Bundle.main.shortVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func detail(for pane: Pane) -> some View {
        switch pane {
        case .general:
            GeneralPane(controller: controller)
        case .models:
            ModelsPane(controller: controller)
        case .audio:
            AudioPane(controller: controller)
        case .dictionary:
            if let store = controller.dictionaryStore {
                ScrollView { DictionaryView(store: store).padding(20) }
            }
        case .modes:
            if let store = controller.modeStore {
                ScrollView { ModesView(store: store, cleanupModels: controller.cleanupModels).padding(20) }
            }
        case .history:
            HistoryPane(controller: controller)
        case .account:
            AccountPane(client: client)
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var controller: AppController

    /// Sentinel selection for the Cleanup-model picker's local option (maps to
    /// the "local" cleanup tier / Apple Intelligence). Won't collide with real
    /// registry slugs.
    private static let localCleanupTag = "skylark.local"

    var body: some View {
        Form {
            Section("Cleanup") {
                Picker("Default cleanup tier", selection: Binding(
                    get: { controller.cleanupOverride },
                    set: { controller.setCleanupOverride($0) }
                )) {
                    Text("Auto (per-mode)").tag("auto")
                    Text("Raw").tag("raw")
                    Text("Local").tag("local")
                    Text("Cloud").tag("cloud")
                }
            }

            Section("Speech & cleanup") {
                Picker("Speech engine", selection: Binding(
                    get: { controller.currentSTT },
                    set: { controller.selectSTT($0) }
                )) {
                    Text("Local — Parakeet").tag(STTChoice.localParakeet)
                    Text("Local — Whisper large-v3-turbo").tag(STTChoice.localWhisper)
                    ForEach(controller.sttModels) { entry in
                        Text(entry.label).tag(STTChoice.cloud(slug: entry.slug))
                    }
                }
                Picker("Cleanup model", selection: Binding(
                    get: { controller.cleanupOverride == "local" ? Self.localCleanupTag : controller.currentCleanupSlug },
                    set: { selection in
                        if selection == Self.localCleanupTag {
                            controller.setCleanupOverride("local")
                        } else {
                            // Picking a cloud model routes cleanup to the cloud so
                            // the choice actually takes effect.
                            controller.setCleanupOverride("cloud")
                            controller.selectCleanupSlug(selection)
                        }
                    }
                )) {
                    Text("Apple Intelligence (Local)").tag(Self.localCleanupTag)
                    ForEach(controller.cleanupModels) { entry in
                        Text(entry.label).tag(entry.slug)
                    }
                }
            }

            Section("Feedback") {
                Toggle("Play start/stop sounds", isOn: Binding(
                    get: { controller.soundEffectsEnabled },
                    set: { controller.setSoundEffectsEnabled($0) }
                ))
                Picker("Start sound", selection: Binding(
                    get: { controller.soundStartID },
                    set: { controller.setSoundStart($0) }
                )) {
                    ForEach(SoundEffects.catalog) { cue in Text(cue.label).tag(cue.id) }
                }
                .disabled(!controller.soundEffectsEnabled)
                Picker("Stop sound", selection: Binding(
                    get: { controller.soundStopID },
                    set: { controller.setSoundStop($0) }
                )) {
                    ForEach(SoundEffects.catalog) { cue in Text(cue.label).tag(cue.id) }
                }
                .disabled(!controller.soundEffectsEnabled)
            }

            Section("Launch") {
                Toggle("Launch Skylark at login", isOn: Binding(
                    get: { controller.launchAtLoginStatus == .enabled },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                if let footnote = controller.launchAtLoginFootnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History

private struct HistoryPane: View {
    @Bindable var controller: AppController
    @State private var confirmDeleteAudio = false

    var body: some View {
        Form {
            Section("Audio retention") {
                Toggle("Keep audio recordings (local only)", isOn: Binding(
                    get: { controller.audioRetentionEnabled },
                    set: { controller.setAudioRetentionEnabled($0) }
                ))
                Text("Off by default. When on, each dictation's audio is saved locally under Application Support/Skylark/Audio — never uploaded, and deleted when its history entry is deleted or history is cleared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete all stored audio…", role: .destructive) { confirmDeleteAudio = true }
                    .confirmationDialog(
                        "Delete all stored audio?",
                        isPresented: $confirmDeleteAudio,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) { controller.deleteAllStoredAudio() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("History entries stay; only the audio files are removed.")
                    }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Models

private struct ModelsPane: View {
    @Bindable var controller: AppController

    private static let costCaption = "Estimated cost assumes ~10 min of dictation/day (~5 hrs/month)."

    var body: some View {
        Form {
            Section {
                ModelRow(controller: controller, model: .parakeet)
                ModelRow(controller: controller, model: .whisper)
            } header: {
                Text("Speech engines · on device")
            } footer: {
                Text("Downloaded once and stored locally under Application Support/Skylark. Runs fully offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(Self.costCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(controller.sttModels) { entry in
                    InfoModelRow(label: entry.label, info: ModelInfo.cloudSTT[entry.slug], requiresAPIKey: true)
                }
            } header: {
                Text("Speech engines · cloud")
            } footer: {
                Text("Cloud speech runs on OpenRouter, not on this Mac. Add an API key in Account to use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                InfoModelRow(label: "Apple Intelligence", info: ModelInfo.appleIntelligence)
            } header: {
                Text("Cleanup · on device")
            }

            Section {
                Text(Self.costCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(controller.cleanupModels) { entry in
                    InfoModelRow(label: entry.label, info: ModelInfo.cloudCleanup[entry.slug], requiresAPIKey: true)
                }
            } header: {
                Text("Cleanup · cloud")
            } footer: {
                Text("Cloud cleanup runs on OpenRouter, not on this Mac. Add an API key in Account to use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ModelRow(controller: controller, model: .vad)
            } header: {
                Text("Utility")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelRow: View {
    @Bindable var controller: AppController
    let model: AppController.ManagedModel

    private var state: AppController.ManagedModelState {
        controller.modelStates[model] ?? .notDownloaded
    }

    private var info: ModelInfo.Entry? { ModelInfo.onDevice[model] }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.label).font(.system(size: 13, weight: .medium))
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if let info {
                    Text(info.description).font(.caption).foregroundStyle(.secondary)
                    ScoreRow(info: info)
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch state {
        case .notDownloaded:
            return "Not downloaded · \(model.approxSize)"
        case let .downloading(progress):
            return "Downloading \(Int((progress * 100).rounded()))%"
        case .preparing:
            return "Preparing…"
        case let .ready(bytes):
            // Some engines (FluidAudio Parakeet) install to a path we can't
            // measure precisely; fall back to the approximate size rather than
            // showing a misleading "Zero KB".
            return bytes > 0 ? "Ready · \(SettingsFormat.bytes(bytes))" : "Ready · \(model.approxSize)"
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .notDownloaded:
            Button("Download") { controller.downloadModel(model) }
        case .downloading, .preparing:
            ProgressView().controlSize(.small)
        case .ready:
            Button("Delete") { controller.deleteModel(model) }
                .disabled(controller.isModelInUse(model))
                .help(controller.isModelInUse(model) ? "In use by the current speech engine" : "")
        }
    }
}

/// Read-only informational row for a model that isn't downloadable/deletable
/// here — either a cloud (OpenRouter) model or an OS-provided one like Apple
/// Intelligence. No download/delete affordances.
private struct InfoModelRow: View {
    let label: String
    let info: ModelInfo.Entry?
    var requiresAPIKey: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13, weight: .medium))
                if let info {
                    Text(info.description).font(.caption).foregroundStyle(.secondary)
                    ScoreRow(info: info)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let cost = info?.costPerMonth {
                    Text(cost).font(.caption).foregroundStyle(.secondary)
                }
                if requiresAPIKey {
                    Text("Requires API key").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Compact "Label 4.5/5" pair for a model's two scores (Accuracy/Latency or
/// Quality/Speed), rendered as filled/half/empty dots.
private struct ScoreRow: View {
    let info: ModelInfo.Entry

    var body: some View {
        HStack(spacing: 14) {
            if let score = info.primaryScore {
                ScoreDots(label: info.primaryLabel, score: score)
            }
            if let score = info.secondaryScore {
                ScoreDots(label: info.secondaryLabel, score: score)
            }
        }
    }
}

private struct ScoreDots: View {
    let label: String
    let score: Double

    var body: some View {
        HStack(spacing: 3) {
            Text("\(label):")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: symbolName(forDotAt: index))
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }
            }
            Text(String(format: "%.1f", score))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func symbolName(forDotAt index: Int) -> String {
        let fill = score - Double(index)
        if fill >= 1 { return "circle.fill" }
        if fill >= 0.5 { return "circle.lefthalf.filled" }
        return "circle"
    }
}

// MARK: - Audio

private struct AudioPane: View {
    @Bindable var controller: AppController

    private var selectedDevice: AudioInputDevice? {
        controller.inputDevices.first { $0.uid == controller.selectedDeviceUID }
    }

    var body: some View {
        Form {
            Section("Input device") {
                Picker("Microphone", selection: Binding(
                    get: { controller.selectedDeviceUID ?? "" },
                    set: { controller.selectInputDevice($0.isEmpty ? nil : $0) }
                )) {
                    Text("System default").tag("")
                    ForEach(controller.inputDevices) { device in
                        Text(device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name)
                            .tag(device.uid)
                    }
                }

                if let device = selectedDevice, device.isBluetooth {
                    Label(
                        "Bluetooth mics reduce recognition quality (HFP). Consider the built-in mic.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Whisper Mode") {
                Toggle("Whisper Mode (boosts quiet speech)", isOn: Binding(
                    get: { controller.whisperModeOn },
                    set: { _ in controller.toggleWhisperMode() }
                ))
                Text("Boosts gain and tunes endpointing for quiet or whispered speech — useful in shared spaces where you don't want to talk at normal volume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Account

private struct AccountPane: View {
    let client: OpenRouterClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                APIKeyCard(client: client, showRemove: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(20)
        }
    }
}

// MARK: - Formatting

private enum SettingsFormat {
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
}
