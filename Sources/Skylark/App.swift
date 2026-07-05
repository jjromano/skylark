import AppKit
import SkylarkCore
import SwiftUI

@main
struct SkylarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Skylark", systemImage: "mic") {
            MenuContent(controller: appDelegate.controller)
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

        Divider()

        CleanupMenu(controller: controller)

        Divider()

        Button("Settings…") { controller.showSettings() }
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
