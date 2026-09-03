import AppKit
import SkylarkCore
import SwiftUI

@main
struct SkylarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Skylark's own mark, the same artwork the app icon is cut from, so
        // the Dock and the menu bar show one bird. It is a template image, so
        // macOS tints it for every menu-bar appearance the way the stock
        // symbol used to. `SkylarkMark` falls back to `bird.fill` if the asset
        // is ever missing — a label that fails to draw would look exactly like
        // a failed launch.
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            Image(nsImage: SkylarkMark.menuBar)
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

    /// MANDATORY: if a local Qwen cleanup engine is active, block (boundedly)
    /// until llama.cpp's context is freed — its Metal backend aborts in a
    /// static destructor if one is still alive at process exit. See
    /// `AppController.blockingUnloadLocalCleanupBackendBeforeQuit()`.
    func applicationWillTerminate(_ notification: Notification) {
        controller.blockingUnloadLocalCleanupBackendBeforeQuit()
    }

    /// `skylark://` deep links (registered via `CFBundleURLTypes`), delivered
    /// here whether the app is already running or just launched by the URL.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            controller.handleDeepLink(url)
        }
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
            Divider()
            Button {
                controller.selectSTT(.groqDirect)
            } label: {
                if controller.currentSTT == .groqDirect {
                    Label("Groq direct — Whisper large-v3-turbo", systemImage: "checkmark")
                } else {
                    Text("Groq direct — Whisper large-v3-turbo")
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
