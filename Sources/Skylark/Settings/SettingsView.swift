import SkylarkCore
import SwiftUI

/// Settings window (phase-5a spec §5): a plain, native `TabView` — General,
/// Models, Audio, Dictionary, Modes, History, Account. Dictionary/Modes tabs
/// are omitted (not hidden-and-disabled — just absent) when persistence
/// couldn't open, matching the same graceful degradation the rest of the app
/// uses for a missing on-disk database.
struct SettingsView: View {
    @Bindable var controller: AppController
    let client: OpenRouterClient

    var body: some View {
        TabView {
            GeneralTab(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ModelsSection(controller: controller)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            }
            .tabItem { Label("Models", systemImage: "cpu") }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AudioSection(controller: controller)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            }
            .tabItem { Label("Audio", systemImage: "waveform") }

            if let dictionaryStore = controller.dictionaryStore {
                ScrollView {
                    DictionaryView(store: dictionaryStore)
                        .padding(20)
                }
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            }

            if let modeStore = controller.modeStore {
                ScrollView {
                    ModesView(store: modeStore, cleanupModels: controller.cleanupModels)
                        .padding(20)
                }
                .tabItem { Label("Modes", systemImage: "switch.2") }
            }

            HistorySettingsTab(controller: controller)
                .tabItem { Label("History", systemImage: "clock") }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    APIKeyCard(client: client, showRemove: true)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(20)
            }
            .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 560, height: 640)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var controller: AppController

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
                Toggle("Whisper Mode (boosts quiet speech)", isOn: Binding(
                    get: { controller.whisperModeOn },
                    set: { _ in controller.toggleWhisperMode() }
                ))
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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - History

private struct HistorySettingsTab: View {
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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Models

private struct ModelsSection: View {
    @Bindable var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models")
                .font(.headline)
            ForEach(AppController.ManagedModel.allCases) { model in
                ModelRow(controller: controller, model: model)
                if model != AppController.ManagedModel.allCases.last {
                    Divider()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }
}

private struct ModelRow: View {
    @Bindable var controller: AppController
    let model: AppController.ManagedModel

    private var state: AppController.ManagedModelState {
        controller.modelStates[model] ?? .notDownloaded
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.label).font(.system(size: 13, weight: .medium))
                Text(statusText).font(.caption).foregroundStyle(.secondary)
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
            return "Ready · \(SettingsFormat.bytes(bytes))"
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

// MARK: - Audio

private struct AudioSection: View {
    @Bindable var controller: AppController

    private var selectedDevice: AudioInputDevice? {
        controller.inputDevices.first { $0.uid == controller.selectedDeviceUID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio")
                .font(.headline)

            Picker("Input device", selection: Binding(
                get: { controller.selectedDeviceUID ?? "" },
                set: { controller.selectInputDevice($0.isEmpty ? nil : $0) }
            )) {
                Text("System default").tag("")
                ForEach(controller.inputDevices) { device in
                    Text(device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name)
                        .tag(device.uid)
                }
            }
            .pickerStyle(.menu)

            if let device = selectedDevice, device.isBluetooth {
                Label(
                    "Bluetooth mics reduce recognition quality (HFP). Consider the built-in mic.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
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
