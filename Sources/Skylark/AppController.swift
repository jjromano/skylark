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

    /// Menu-bar model-preparation line (nil once ready). E.g. "Downloading… 42%".
    private(set) var modelStatus: String?
    /// Last dictation latency, ms (menu "Last: 214 ms"). Nil until first paste.
    private(set) var lastLatencyMs: Int?
    /// Transient status note (e.g. model-not-ready discard).
    private(set) var statusNote: String?

    private let capture = AudioCaptureService()
    private let transcriber: FluidAudioParakeet
    private let endpointer = FluidAudioVAD()
    private let injector = TextInjector()
    private let monitor = HotkeyMonitor()
    private let orchestrator: DictationOrchestrator

    // Model-preparation states arrive on an arbitrary queue; funnel them through
    // a Sendable stream and apply them on the main actor (see start()).
    @ObservationIgnored private let prepStream: AsyncStream<ModelPreparationState>
    @ObservationIgnored private var noteClearTask: Task<Void, Never>?

    @ObservationIgnored private lazy var hudPanel = HUDPanelController(model: hud, controller: self)
    @ObservationIgnored private var onboardingWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var started = false

    init() {
        let (stream, cont) = AsyncStream<ModelPreparationState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        prepStream = stream
        transcriber = FluidAudioParakeet(progress: { state in cont.yield(state) })
        orchestrator = DictationOrchestrator(
            capture: capture,
            transcriber: transcriber,
            injector: injector,
            endpointer: endpointer
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
                if case let .listening(level) = state {
                    hud.pushLevel(level)
                } else if case .idle = state {
                    hud.resetWaveform()
                }
                hudPanel.refreshLayout()
            }
        }
        // Drive the pipeline from hotkey events.
        Task { [orchestrator, monitor] in
            await orchestrator.run(events: monitor.events)
        }
        // Menu-bar latency line.
        Task { [orchestrator, weak self] in
            for await summary in orchestrator.latencies {
                self?.lastLatencyMs = Int(summary.totalMs.rounded())
            }
        }
        // Transient status notes.
        Task { [orchestrator, weak self] in
            for await note in orchestrator.statusNotes {
                self?.showNote(note)
            }
        }
        // Model-preparation progress → menu line, HUD dot, readiness gate.
        Task { [weak self] in
            guard let stream = self?.prepStream else { return }
            for await prep in stream {
                self?.applyModelPrep(prep)
            }
        }

        capture.prepare()

        // The transcriber is not ready until its model finishes preparing.
        Task { [orchestrator] in await orchestrator.setTranscriberReady(false) }
        hud.isPreparing = true

        // Prepare Parakeet + VAD concurrently at launch (VAD degrades gracefully).
        Task { [transcriber] in try? await transcriber.warmUp() }
        Task { [endpointer] in await endpointer.prepare() }

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

    // MARK: - Model preparation + notes

    private func applyModelPrep(_ prep: ModelPreparationState) {
        hud.isPreparing = prep.isPreparing
        switch prep {
        case .checking:
            modelStatus = "Preparing speech model…"
        case let .downloading(progress):
            modelStatus = "Downloading speech model… \(Int((progress * 100).rounded()))%"
        case .loading:
            modelStatus = "Loading speech model…"
        case .ready:
            modelStatus = nil
            Task { [orchestrator] in await orchestrator.setTranscriberReady(true) }
        case .failed:
            modelStatus = "Speech model failed to load"
            Task { [orchestrator] in await orchestrator.setTranscriberReady(false) }
        }
    }

    private func showNote(_ note: String) {
        statusNote = note
        noteClearTask?.cancel()
        noteClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.statusNote = nil }
        }
    }

    // MARK: - HUD-driven actions

    func toggleHandsFree() {
        Task { [orchestrator, hud] in
            switch hud.state {
            case .idle:
                // The HUD record button starts a hands-free session (no key to
                // hold), so arm VAD endpointing right after starting.
                await orchestrator.handle(.startRecording)
                await orchestrator.handle(.engageHandsFree)
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
