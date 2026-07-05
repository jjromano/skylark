import SkylarkCore
import SwiftUI

/// Settings window: API key, model manager (download/delete), and the input
/// device picker. Kept plain (Form) per the phase-4 spec; a later pass polishes.
struct SettingsView: View {
    @Bindable var controller: AppController
    let client: OpenRouterClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Settings")
                        .font(.title2.bold())
                }

                APIKeyCard(client: client, showRemove: true)

                ModelsSection(controller: controller)
                AudioSection(controller: controller)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }
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
