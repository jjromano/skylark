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
        MenuChoice(title: title, isSelected: override == value) {
            override = value
            controller.setCleanupOverride(value)
        }
    }
}

/// Global cleanup model picker, split into "On this Mac" and "Cloud" sections
/// so it is never ambiguous which one a row runs on.
private struct CleanupModelMenu: View {
    let controller: AppController

    var body: some View {
        Menu("Cleanup Model") {
            let options = controller.cleanupModelOptions
            Section("On this Mac") {
                ForEach(options.filter(\.isOnDevice)) { row($0) }
            }
            Section("Cloud · OpenRouter") {
                ForEach(options.filter { !$0.isOnDevice }) { row($0) }
            }
            Divider()
            Button("Custom Slug…") { controller.promptCustomCleanupSlug() }
        }
    }

    private func row(_ option: CleanupCycleOption) -> some View {
        MenuChoice(
            title: option.menuLabel,
            isSelected: controller.selectedCleanupModelOption.id == option.id
        ) {
            controller.selectCleanupModelOption(option)
        }
    }
}

/// Speech engine picker, grouped the same way as the cleanup menu and as the
/// Models pane: on-device engines, then each cloud transport.
///
/// The flat version of this menu read as if the local rows were indented
/// children of something: a selected row was `Label(…, systemImage:)` and an
/// unselected one a bare `Text`, so the two kinds of row started at different
/// x-positions inside one contiguous run. `MenuChoice` gives every row the same
/// shape, so the text edges line up whatever is selected.
private struct SpeechEngineMenu: View {
    let controller: AppController

    var body: some View {
        Menu("Speech Engine") {
            Section("On this Mac") {
                choice("Parakeet", .localParakeet)
                choice("Whisper large-v3-turbo", .localWhisper)
                choice("Apple Speech (macOS)", .localApple)
            }
            Section("Cloud · Groq direct") {
                choice("Whisper large-v3-turbo — Groq", .groqDirect)
            }
            Section("Cloud · OpenRouter") {
                ForEach(controller.sttModels) { entry in
                    choice(entry.label, .cloud(slug: entry.slug))
                }
            }
            Divider()
            Button("Custom Slug…") { controller.promptCustomSTTSlug() }
        }
    }

    private func choice(_ title: String, _ value: STTChoice) -> some View {
        MenuChoice(title: title, isSelected: controller.currentSTT == value) {
            controller.selectSTT(value)
        }
    }
}

/// One selectable row in a menu that behaves like a radio group.
///
/// A `Toggle` becomes a checkable `NSMenuItem`, which makes AppKit reserve the
/// state column for every row in the menu — including the unchecked ones. That
/// is what keeps the labels flush with each other; a `Button` whose label
/// switches between `Label(…, systemImage: "checkmark")` and `Text` does not,
/// and the rows visibly shift as the selection moves.
private struct MenuChoice: View {
    let title: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { isSelected },
            // Re-selecting the active row is a no-op rather than a deselect:
            // these are radio choices and there is no "nothing selected" state.
            set: { if $0 { select() } }
        ))
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
