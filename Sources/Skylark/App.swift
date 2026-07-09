import AppKit
import SkylarkCore
import SwiftUI

@main
struct SkylarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar accessory app (also LSUIElement in Info.plist).
        NSApp.setActivationPolicy(.accessory)
        controller.start()
    }
}

/// The menu-bar dropdown.
struct MenuContent: View {
    let controller: AppController

    var body: some View {
        Text("Status: \(controller.statusLine)")
            .font(.caption)

        if let modelStatus = controller.modelStatus {
            Text(modelStatus).font(.caption)
        }
        if let note = controller.statusNote {
            Text(note).font(.caption)
        }
        if let last = controller.lastLatencyMs {
            Text("Last: \(last) ms").font(.caption)
        }
        if let stats = controller.stats, stats.wordsToday > 0 {
            Text("\(stats.wordsToday.formatted()) words today").font(.caption)
        }

        Divider()

        CleanupMenu(controller: controller)
        CleanupModelMenu(controller: controller)
        SpeechEngineMenu(controller: controller)
        WhisperModeToggle(controller: controller)

        Divider()

        Button("Settings…") { controller.showSettings() }
        Button("History…") { controller.showHistory() }
        Button("Onboarding…") { controller.showOnboarding() }

        Divider()

        Button("Quit Skylark") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Temporary global cleanup-tier override (real Settings UI lands later).
/// Auto = use the app-resolved mode's tier; Raw/Local force a tier.
private struct CleanupMenu: View {
    let controller: AppController
    @AppStorage(AppController.cleanupOverrideKey) private var override = "auto"

    var body: some View {
        Menu("Cleanup") {
            item("Auto", value: "auto")
            item("Raw", value: "raw")
            item("Local", value: "local")
            item("Cloud", value: "cloud")
        }
    }

    private func item(_ title: String, value: String) -> some View {
        Button {
            override = value
            controller.setCleanupOverride(value)
        } label: {
            if override == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// Global cloud cleanup model picker (registry `.cleanup` entries + custom slug).
private struct CleanupModelMenu: View {
    let controller: AppController

    var body: some View {
        Menu("Cleanup Model") {
            ForEach(controller.cleanupModels) { entry in
                Button {
                    controller.selectCleanupSlug(entry.slug)
                } label: {
                    if controller.currentCleanupSlug == entry.slug {
                        Label(entry.label, systemImage: "checkmark")
                    } else {
                        Text(entry.label)
                    }
                }
            }
            Divider()
            Button("Custom Slug…") { controller.promptCustomCleanupSlug() }
        }
    }
}

/// Speech engine picker: local Parakeet + registry `.stt` entries + custom slug.
private struct SpeechEngineMenu: View {
    let controller: AppController

    var body: some View {
        Menu("Speech Engine") {
            Button {
                controller.selectSTT(.localParakeet)
            } label: {
                if controller.currentSTT == .localParakeet {
                    Label("Local (Parakeet)", systemImage: "checkmark")
                } else {
                    Text("Local (Parakeet)")
                }
            }
            Button {
                controller.selectSTT(.localWhisper)
            } label: {
                if controller.currentSTT == .localWhisper {
                    Label("Local (Whisper large-v3-turbo)", systemImage: "checkmark")
                } else {
                    Text("Local (Whisper large-v3-turbo)")
                }
            }
            ForEach(controller.sttModels) { entry in
                Button {
                    controller.selectSTT(.cloud(slug: entry.slug))
                } label: {
                    if controller.currentSTT == .cloud(slug: entry.slug) {
                        Label(entry.label, systemImage: "checkmark")
                    } else {
                        Text(entry.label)
                    }
                }
            }
            Divider()
            Button("Custom Slug…") { controller.promptCustomSTTSlug() }
        }
    }
}

/// Global Whisper Mode (quiet-speech) toggle.
private struct WhisperModeToggle: View {
    let controller: AppController

    var body: some View {
        Button {
            controller.toggleWhisperMode()
        } label: {
            if controller.whisperModeOn {
                Label("Whisper Mode", systemImage: "checkmark")
            } else {
                Text("Whisper Mode")
            }
        }
    }
}
