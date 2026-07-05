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

    /// Registry entries for the menu-bar quick-switch (loaded at launch).
    private(set) var cleanupModels: [ModelRegistryEntry] = []
    private(set) var sttModels: [ModelRegistryEntry] = []

    /// Global cleanup override backing the menu "Cleanup" submenu. "auto" = use
    /// the resolved mode's tier; "raw"/"local"/"cloud" force that tier.
    static let cleanupOverrideKey = "cleanupTierOverride"

    /// Live model selection (cleanup slug + STT engine), UserDefaults-backed.
    let modelSelection: ModelSelection
    /// Shared OpenRouter client (reads the key from Keychain per request, so a
    /// key dropped in later lights up cloud with no restart).
    let openRouterClient: OpenRouterClient

    private let capture = AudioCaptureService()
    private let transcriber: FluidAudioParakeet
    private let endpointer = FluidAudioVAD()
    private let injector = TextInjector()
    private let monitor = HotkeyMonitor()
    private let frontmost = FrontmostAppMonitor()
    private let orchestrator: DictationOrchestrator

    // Persistence (nil when storage is unavailable — the app still runs, sans
    // history/persisted modes, on in-memory providers).
    private let registryStore: RegistryStore?
    private let modeStore: ModeStore?

    // Model-preparation states arrive on an arbitrary queue; funnel them through
    // a Sendable stream and apply them on the main actor (see start()).
    @ObservationIgnored private let prepStream: AsyncStream<ModelPreparationState>
    @ObservationIgnored private var noteClearTask: Task<Void, Never>?
    /// Deferred launch note (e.g. "history disabled") shown once start() runs.
    @ObservationIgnored private var pendingStatusNote: String?

    @ObservationIgnored private lazy var hudPanel = HUDPanelController(model: hud, controller: self)
    @ObservationIgnored private var onboardingWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var started = false

    init() {
        let (stream, cont) = AsyncStream<ModelPreparationState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        prepStream = stream
        transcriber = FluidAudioParakeet(progress: { state in cont.yield(state) })

        // Composition root: one on-disk database; fall back to in-memory
        // providers (no history/persisted modes) if it can't open.
        let modeProvider: any ModeProviding
        let dictionaryProvider: any DictionaryProviding
        var historyHub: HistoryHub?
        if let db = try? SkylarkDatabase.onDisk() {
            let modeStore = ModeStore(db: db)
            self.modeStore = modeStore
            self.registryStore = RegistryStore(db: db)
            modeProvider = ModeProviderAdapter(store: modeStore)
            dictionaryProvider = DictionaryStore(db: db)
            historyHub = HistoryHub(store: HistoryStore(db: db))
        } else {
            self.modeStore = nil
            self.registryStore = nil
            modeProvider = InMemoryModeProvider()
            dictionaryProvider = InMemoryDictionaryProvider()
            pendingStatusNote = "History disabled — storage unavailable"
        }

        let client = OpenRouterClient(keyProvider: { KeychainStore().get() })
        openRouterClient = client
        modelSelection = ModelSelection(registry: registryStore)

        // Cloud cleanup slot: build an OpenRouterCleaner per slug on demand. All
        // registry cleanup models are Groq-pinned, as are ad-hoc slugs we upsert.
        let cloudFactory: @Sendable (String) -> (any Cleaner)? = { slug in
            guard !slug.isEmpty else { return nil }
            return OpenRouterCleaner(
                client: client,
                entry: ModelRegistryEntry(slug: slug, label: slug, providerPin: "groq", kind: .cleanup, sort: 0)
            )
        }

        orchestrator = DictationOrchestrator(
            capture: capture,
            transcriber: transcriber,
            injector: injector,
            endpointer: endpointer,
            cleaners: CleanerRegistry(local: LocalCleaner(), cloudFactory: cloudFactory),
            modeProvider: modeProvider,
            dictionary: dictionaryProvider,
            frontmostBundleID: frontmost.snapshot,
            historyRecord: historyHub?.recordSink(),
            historyUpdate: historyHub?.updateSink()
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

        // Track the frontmost app so the orchestrator resolves modes at fn-down.
        frontmost.start()

        // Persistence + selection: seed defaults, load the quick-switch lists,
        // then apply the persisted cleanup override + STT choice.
        Task { [weak self] in await self?.bootstrapSelection() }

        if let note = pendingStatusNote {
            showNote(note)
            pendingStatusNote = nil
        }

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

    /// Seed the DB (idempotent), load registry lists, apply persisted selections.
    private func bootstrapSelection() async {
        if let registryStore {
            try? await registryStore.seedIfEmpty()
            cleanupModels = (try? await registryStore.all(kind: .cleanup)) ?? []
            sttModels = (try? await registryStore.all(kind: .stt)) ?? []
        } else {
            cleanupModels = ModelRegistryEntry.seed.filter { $0.kind == .cleanup }
            sttModels = ModelRegistryEntry.seed.filter { $0.kind == .stt }
        }
        try? await modeStore?.seedIfEmpty()

        applyCleanupOverride(cleanupOverride)
        rebuildTranscriber()
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

    // MARK: - Cleanup override (menu bar)

    /// The persisted override raw value ("auto"/"raw"/"local"/"cloud").
    var cleanupOverride: String {
        UserDefaults.standard.string(forKey: Self.cleanupOverrideKey) ?? "auto"
    }

    /// Set from the menu; persists and pushes the tier into mode resolution.
    func setCleanupOverride(_ raw: String) {
        UserDefaults.standard.set(raw, forKey: Self.cleanupOverrideKey)
        applyCleanupOverride(raw)
    }

    private func applyCleanupOverride(_ raw: String) {
        let tier: CleanupTier?
        switch raw {
        case "raw": tier = .raw
        case "local": tier = .local
        case "cloud": tier = .cloud(slug: modelSelection.cleanupSlug)
        default: tier = nil // auto
        }
        Task { [orchestrator] in await orchestrator.setTierOverride(tier) }
    }

    // MARK: - Quick-switch (menu bar)

    var currentCleanupSlug: String { modelSelection.cleanupSlug }
    var currentSTT: STTChoice { modelSelection.sttChoice }

    /// Select the global cleanup model slug (upserts an ad-hoc registry entry for
    /// a free-text slug). Takes effect next dictation.
    func selectCleanupSlug(_ slug: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.modelSelection.setCleanupSlug(slug, known: self.cleanupModels)
            await self.reloadRegistryLists()
            // If the override forces Cloud, re-apply so it picks up the new slug.
            if self.cleanupOverride == "cloud" { self.applyCleanupOverride("cloud") }
        }
    }

    /// Select the speech engine (upserts an ad-hoc stt registry entry for a
    /// free-text cloud slug), then rebuild/swap the orchestrator's transcriber.
    func selectSTT(_ choice: STTChoice) {
        Task { [weak self] in
            guard let self else { return }
            await self.modelSelection.setSTT(choice, known: self.sttModels)
            await self.reloadRegistryLists()
            self.rebuildTranscriber()
        }
    }

    private func reloadRegistryLists() async {
        guard let registryStore else { return }
        cleanupModels = (try? await registryStore.all(kind: .cleanup)) ?? cleanupModels
        sttModels = (try? await registryStore.all(kind: .stt)) ?? sttModels
    }

    /// Build the transcriber for the current STT choice and swap it into the
    /// orchestrator. Cloud wraps local in a `FallbackTranscriber`; a missing key
    /// falls straight back to local with a one-time notice.
    private func rebuildTranscriber() {
        switch modelSelection.sttChoice {
        case .localParakeet:
            Task { [orchestrator, transcriber] in await orchestrator.setTranscriber(transcriber) }
        case .cloud(let slug):
            guard KeychainStore().get() != nil else {
                showNote("No API key — using local engine")
                Task { [orchestrator, transcriber] in await orchestrator.setTranscriber(transcriber) }
                return
            }
            let entry = sttModels.first { $0.slug == slug }
                ?? ModelRegistryEntry(slug: slug, label: slug, providerPin: nil, kind: .stt, sort: 0)
            let cloud = OpenRouterCloud(client: openRouterClient, entry: entry)
            let notice: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor in self?.showNote(message) }
            }
            let fallback = FallbackTranscriber(primary: cloud, fallback: transcriber, notice: notice)
            Task { [orchestrator] in
                try? await fallback.warmUp()
                await orchestrator.setTranscriber(fallback)
            }
        }
    }

    /// Prompt for a custom cleanup model slug, then select it.
    func promptCustomCleanupSlug() {
        guard let slug = Self.promptForSlug(
            title: "Custom Cleanup Model",
            message: "Enter an OpenRouter model slug (e.g. meta-llama/llama-3.3-70b-instruct)."
        ) else { return }
        selectCleanupSlug(slug)
    }

    /// Prompt for a custom cloud STT model slug, then select it.
    func promptCustomSTTSlug() {
        guard let slug = Self.promptForSlug(
            title: "Custom Speech Model",
            message: "Enter an OpenRouter transcription model slug."
        ) else { return }
        selectSTT(.cloud(slug: slug))
    }

    private static func promptForSlug(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "provider/model-slug"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let slug = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return slug.isEmpty ? nil : slug
    }

    // MARK: - Windows

    func showOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(permissions: permissions, apiKeyClient: openRouterClient) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let window = Self.makeWindow(title: "Welcome to Skylark", content: view, width: 460, height: 560)
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
        let window = Self.makeWindow(
            title: "Skylark Settings",
            content: SettingsView(client: openRouterClient),
            width: 440, height: 300
        )
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
