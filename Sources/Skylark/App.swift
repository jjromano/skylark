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
        // The menu bar is live before `start()` runs (which can wait up to 5 s
        // below), so resolve what the pickers may offer right away.
        controller.refreshAppleIntelligenceAvailability()
        // Quit any older copy BEFORE starting: `start()` installs the hotkey
        // tap and shows the pill, and two of each is the bug this prevents.
        Task { @MainActor [controller] in
            await SingleInstanceGuard.replaceOlderInstances()
            controller.start()
        }
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

/// The single Cleanup picker: exactly one checkmark, one meaning.
///
/// Replaces a tier menu (Auto/Raw/Local/Cloud) that sat beside a model menu,
/// where choosing in one silently rewrote the other (Cloud tier + a local model
/// meant local). Offers only what can run: on-device models that are present
/// and enabled, cloud models only with an OpenRouter key. The same list drives
/// Settings and the cycle hotkey.
private struct CleanupMenu: View {
    let controller: AppController

    var body: some View {
        Menu("Cleanup") {
            let options = controller.cleanupPickerOptions
            row(.raw)
            row(.auto)
            Section("On this Mac") {
                ForEach(options.filter(\.isOnDevice)) { row($0) }
            }
            if controller.hasAPIKey {
                Section("Cloud · OpenRouter") {
                    ForEach(options.filter(\.isCloud)) { row($0) }
                }
                Divider()
                Button("Custom Slug…") { controller.promptCustomCleanupSlug() }
            } else {
                AddOpenRouterKeySection(controller: controller)
            }
        }
    }

    private func row(_ option: CleanupCycleOption) -> some View {
        MenuChoice(
            title: option.menuLabel,
            isSelected: controller.selectedCleanupOption.id == option.id
        ) {
            controller.selectCleanupOption(option)
        }
    }
}

/// Speech engine picker: on-device engines, then each cloud transport, each
/// shown only when it can actually run (see `SpeechEngineOptions`).
///
/// Every row is a `MenuChoice`, so the text edges line up whatever is selected
/// (a `Label` with a checkmark next to bare `Text` rows used to shift them).
private struct SpeechEngineMenu: View {
    let controller: AppController

    var body: some View {
        Menu("Speech Engine") {
            let options = controller.speechEngineOptions
            Section("On this Mac") {
                ForEach(options.onDevice, id: \.self) { choice in
                    self.choice(SpeechEngineOptions.onDeviceLabel(choice), choice)
                }
            }
            if options.groqDirect {
                Section("Cloud · Groq direct") {
                    choice("Whisper large-v3-turbo — Groq", .groqDirect)
                }
            }
            if options.needsOpenRouterKey {
                AddOpenRouterKeySection(controller: controller)
            } else {
                Section("Cloud · OpenRouter") {
                    ForEach(options.openRouter) { entry in
                        choice(entry.label, .cloud(slug: entry.slug))
                    }
                }
                Divider()
                Button("Custom Slug…") { controller.promptCustomSTTSlug() }
            }
        }
    }

    private func choice(_ title: String, _ value: STTChoice) -> some View {
        MenuChoice(title: title, isSelected: controller.currentSTT == value) {
            controller.selectSTT(value)
        }
    }
}

/// Stand-in for the OpenRouter models when no key is stored. The section header
/// is rendered gray by the system, which is what tells the user why no cloud
/// models are listed; the one row under it is the way to fix that.
private struct AddOpenRouterKeySection: View {
    let controller: AppController

    var body: some View {
        Section("Cloud · OpenRouter · no key added") {
            Button("Add OpenRouter Key…") { controller.showSettings(pane: "account") }
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
