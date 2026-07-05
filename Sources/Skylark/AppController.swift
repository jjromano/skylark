import AppKit
import SkylarkCore
import SwiftUI

/// Owns and wires every runtime service, windows, and the HUD. The single
/// coordination point the app shell talks to.
@MainActor
@Observable
final class AppController {
    let permissions = PermissionsService()
    let hud = HUDModel()

    private let capture = AudioCaptureService()
    private let transcriber = StubTranscriber()
    private let injector = TextInjector()
    private let monitor = HotkeyMonitor()
    private let orchestrator: DictationOrchestrator

    @ObservationIgnored private lazy var hudPanel = HUDPanelController(model: hud, controller: self)
    @ObservationIgnored private var onboardingWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var started = false

    init() {
        orchestrator = DictationOrchestrator(
            capture: capture,
            transcriber: transcriber,
            injector: injector
        )
    }

    /// Human-readable HUD state for the menu.
    var statusLine: String {
        switch hud.state {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .processing: return "Processing"
        }
    }

    func start() {
        guard !started else { return }
        started = true

        permissions.refresh()

        // Forward HUD snapshots from the orchestrator to the UI.
        Task { [orchestrator, hud, hudPanel] in
            for await state in orchestrator.hudStates {
                hud.state = state
                hudPanel.refreshLayout()
            }
        }
        // Drive the pipeline from hotkey events.
        Task { [orchestrator, monitor] in
            await orchestrator.run(events: monitor.events)
        }

        capture.prepare()
        Task { [transcriber] in try? await transcriber.warmUp() }

        // The monitor self-gates on Accessibility, so starting it is always safe.
        monitor.start()

        if permissions.allGranted {
            hudPanel.show()
        } else {
            showOnboarding()
        }

        // Auto-advance from onboarding to the HUD once all grants land.
        permissions.startPolling()
        observeGrants()
    }

    private func observeGrants() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.permissions.allGranted {
                    self.onboardingWindow?.close()
                    self.onboardingWindow = nil
                    self.hudPanel.show()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - HUD-driven actions

    func toggleHandsFree() {
        Task { [orchestrator, hud] in
            switch hud.state {
            case .idle:
                await orchestrator.handle(.startRecording)
            case .listening:
                await orchestrator.handle(.stopRecording)
            case .processing:
                break
            }
        }
    }

    func cancelRecording() {
        Task { [orchestrator] in await orchestrator.handle(.cancel) }
    }

    // MARK: - Windows

    func showOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(permissions: permissions) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let window = Self.makeWindow(title: "Welcome to Skylark", content: view, width: 460, height: 420)
        onboardingWindow = window
        permissions.startPolling()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = Self.makeWindow(title: "Skylark Settings", content: SettingsView(), width: 420, height: 300)
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func makeWindow(title: String, content: some View, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
