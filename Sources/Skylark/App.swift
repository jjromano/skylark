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

        Divider()

        Button("Settings…") { controller.showSettings() }
        Button("Onboarding…") { controller.showOnboarding() }

        Divider()

        Button("Quit Skylark") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
