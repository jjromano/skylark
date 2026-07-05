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

    /// Global Whisper Mode (quiet-speech) — persisted; drives capture gain, the
    /// clip-skip floor, VAD sensitivity, and the HUD cue (phase-4 spec §5).
    static let whisperModeKey = "whisperMode"
    private(set) var whisperModeOn: Bool

    // MARK: - Model manager (Settings → Models)

    /// A local model the settings model-manager can download/delete.
    enum ManagedModel: String, CaseIterable, Identifiable {
        case parakeet, whisper, vad
        var id: String { rawValue }
        var label: String {
            switch self {
            case .parakeet: return "Parakeet TDT v3"
            case .whisper: return "Whisper large-v3-turbo"
            case .vad: return "Silero VAD"
            }
        }
        var approxSize: String {
            switch self {
            case .parakeet: return "~483 MB"
            case .whisper: return "~626 MB"
            case .vad: return "few MB"
            }
        }
        var directory: URL {
            switch self {
            case .parakeet: return ModelPaths.parakeetModelDir
            case .whisper: return ModelPaths.whisperKitBase
            case .vad: return ModelPaths.vadModelDir
            }
        }
    }

    enum ManagedModelState: Equatable {
        case notDownloaded
        case downloading(Double)
        case preparing
        case ready(bytes: Int64)
    }

    /// Per-model download/on-disk state observed by the settings model manager.
    private(set) var modelStates: [ManagedModel: ManagedModelState] = [:]

    // MARK: - Audio devices (Settings → Audio)

    static let inputDeviceKey = "audio.inputDeviceUID"
    let audioDevices = AudioDeviceManager()
    private(set) var inputDevices: [AudioInputDevice] = []
    /// Selected input-device UID (nil = system default).
    private(set) var selectedDeviceUID: String?

    /// Global cleanup override backing the menu "Cleanup" submenu. "auto" = use
    /// the resolved mode's tier; "raw"/"local"/"cloud" force that tier.
    static let cleanupOverrideKey = "cleanupTierOverride"

    /// Live model selection (cleanup slug + STT engine), UserDefaults-backed.
    let modelSelection: ModelSelection
    /// Shared OpenRouter client (reads the key from Keychain per request, so a
    /// key dropped in later lights up cloud with no restart).
    let openRouterClient: OpenRouterClient

    private let capture = AudioCaptureService()
    private let parakeet: FluidAudioParakeet
    private let whisper: WhisperKitWhisper
    private let endpointer = FluidAudioVAD()
    private let injector = TextInjector()
    private let monitor = HotkeyMonitor()
    private let frontmost = FrontmostAppMonitor()
    private let orchestrator: DictationOrchestrator

    /// Which local engine is kept warm (memory policy: only the active local
    /// engine stays resident on 16 GB machines). Cloud STT's fallback is this
    /// engine. Updated on every local selection; cloud leaves it as the last local.
    private var activeLocal: STTChoice = .localParakeet

    // Persistence (nil when storage is unavailable — the app still runs, sans
    // history/persisted modes, on in-memory providers).
    private let registryStore: RegistryStore?
    private let modeStore: ModeStore?

    // Model-preparation states arrive on an arbitrary queue; funnel them through
    // a Sendable stream (tagged with which model) and apply them on the main
    // actor (see start()).
    @ObservationIgnored private let prepStream: AsyncStream<(ManagedModel, ModelPreparationState)>
    @ObservationIgnored private var noteClearTask: Task<Void, Never>?
    /// Deferred launch note (e.g. "history disabled") shown once start() runs.
    @ObservationIgnored private var pendingStatusNote: String?

    @ObservationIgnored private lazy var hudPanel = HUDPanelController(model: hud, controller: self)
    @ObservationIgnored private var onboardingWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var started = false

    init() {
        let (stream, cont) = AsyncStream<(ManagedModel, ModelPreparationState)>.makeStream(bufferingPolicy: .bufferingNewest(16))
        prepStream = stream
        parakeet = FluidAudioParakeet(progress: { state in cont.yield((.parakeet, state)) })
        whisper = WhisperKitWhisper(progress: { state in cont.yield((.whisper, state)) })
        whisperModeOn = UserDefaults.standard.bool(forKey: Self.whisperModeKey)
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.inputDeviceKey)

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
            transcriber: parakeet,
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
            for await (model, prep) in stream {
                self?.applyModelPrep(model, prep)
            }
        }

        capture.prepare()

        // Seed model-manager state from disk, then apply persisted whisper mode
        // (gain/floor/VAD/HUD) and the selected input device before first press.
        refreshModelStates()
        applyWhisperTuning()
        startAudioDevices()

        // The transcriber is not ready until its model finishes preparing.
        Task { [orchestrator] in await orchestrator.setTranscriberReady(false) }
        hud.isPreparing = true

        // Prepare Parakeet (default active local) + VAD concurrently at launch
        // (VAD degrades gracefully). Whisper stays cold until selected.
        Task { [parakeet] in try? await parakeet.warmUp() }
        Task { [endpointer, whisperModeOn] in
            await endpointer.prepare()
            await endpointer.setTuning(.forWhisperMode(whisperModeOn))
        }

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

    private func applyModelPrep(_ model: ManagedModel, _ prep: ModelPreparationState) {
        // Per-model manager state (all models).
        switch prep {
        case .checking, .loading:
            modelStates[model] = .preparing
        case let .downloading(progress):
            modelStates[model] = .downloading(progress)
        case .ready:
            modelStates[model] = .ready(bytes: ModelPaths.installedSize(at: model.directory))
        case .failed:
            modelStates[model] = ModelPaths.isPresent(at: model.directory)
                ? .ready(bytes: ModelPaths.installedSize(at: model.directory))
                : .notDownloaded
        }

        // Menu line reflects any in-flight preparation; the readiness gate and HUD
        // dot follow only the ACTIVE speech engine so a background model download
        // never blocks (or spins) dictation on the current engine.
        let isActiveEngine = (model == activeSpeechModel)
        switch prep {
        case .checking:
            modelStatus = "Preparing \(model.label)…"
        case let .downloading(progress):
            modelStatus = "Downloading \(model.label)… \(Int((progress * 100).rounded()))%"
        case .loading:
            modelStatus = "Loading \(model.label)…"
        case .ready:
            if isActiveEngine {
                modelStatus = nil
                Task { [orchestrator] in await orchestrator.setTranscriberReady(true) }
            } else if modelStatus?.contains(model.label) == true {
                modelStatus = nil
            }
        case .failed:
            modelStatus = "\(model.label) failed to load"
            if isActiveEngine {
                Task { [orchestrator] in await orchestrator.setTranscriberReady(false) }
            }
        }
        if isActiveEngine {
            hud.isPreparing = prep.isPreparing
        }
    }

    /// The model backing the active speech engine (the warm local engine, or the
    /// cloud fallback's local engine).
    private var activeSpeechModel: ManagedModel {
        activeLocal == .localWhisper ? .whisper : .parakeet
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
    /// orchestrator, honouring the memory policy: only the active local engine
    /// stays warm. Cloud wraps the active local engine in a `FallbackTranscriber`;
    /// a missing key falls straight back to local with a one-time notice.
    private func rebuildTranscriber() {
        switch modelSelection.sttChoice {
        case .localParakeet:
            switchLocalEngine(to: .localParakeet)
        case .localWhisper:
            switchLocalEngine(to: .localWhisper)
        case .cloud(let slug):
            guard KeychainStore().get() != nil else {
                showNote("No API key — using local engine")
                switchLocalEngine(to: activeLocal)
                return
            }
            let entry = sttModels.first { $0.slug == slug }
                ?? ModelRegistryEntry(slug: slug, label: slug, providerPin: nil, kind: .stt, sort: 0)
            let cloud = OpenRouterCloud(client: openRouterClient, entry: entry)
            let notice: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor in self?.showNote(message) }
            }
            // Fallback = whichever local engine is currently active (stays warm).
            let localFallback: any Transcriber = (activeLocal == .localWhisper) ? whisper : parakeet
            let idle: any Transcriber = (activeLocal == .localWhisper) ? parakeet : whisper
            let fallback = FallbackTranscriber(primary: cloud, fallback: localFallback, notice: notice)
            Task { [orchestrator] in
                try? await fallback.warmUp()
                await orchestrator.setTranscriber(fallback)
                await orchestrator.setTranscriberReady(true)
                await Self.shutdownEngine(idle) // free the non-fallback local engine
            }
        }
    }

    /// Switch the active local engine, warming the new one and (after the switch
    /// completes) shutting the other down to stay within the 16 GB memory budget.
    private func switchLocalEngine(to choice: STTChoice) {
        activeLocal = choice
        let keepWhisper = (choice == .localWhisper)
        let keep: any Transcriber = keepWhisper ? whisper : parakeet
        let drop: any Transcriber = keepWhisper ? parakeet : whisper
        Task { [orchestrator, weak self] in
            let ready = await Self.engineReady(keep)
            if !ready { await orchestrator.setTranscriberReady(false) }
            await orchestrator.setTranscriber(keep)
            try? await keep.warmUp()
            await orchestrator.setTranscriberReady(true)
            await Self.shutdownEngine(drop)
            self?.applyWhisperTuning()
        }
    }

    private static func engineReady(_ engine: any Transcriber) async -> Bool {
        if let p = engine as? FluidAudioParakeet { return await p.isReady }
        if let w = engine as? WhisperKitWhisper { return await w.isReady }
        return true
    }

    private static func shutdownEngine(_ engine: any Transcriber) async {
        if let p = engine as? FluidAudioParakeet { await p.shutdown() }
        else if let w = engine as? WhisperKitWhisper { await w.shutdown() }
    }

    // MARK: - Whisper Mode (menu bar)

    /// Toggle global Whisper Mode; persist and re-apply the tuning everywhere.
    func toggleWhisperMode() {
        whisperModeOn.toggle()
        UserDefaults.standard.set(whisperModeOn, forKey: Self.whisperModeKey)
        applyWhisperTuning()
        showNote(whisperModeOn ? "Whisper Mode on" : "Whisper Mode off")
    }

    /// Push the current whisper-mode tuning to capture (gain), the engines'
    /// clip-skip floor, the VAD, and the HUD cue.
    private func applyWhisperTuning() {
        let tuning = WhisperModeTuning.forWhisperMode(whisperModeOn)
        capture.setGain(tuning.captureGain)
        hud.isWhisperMode = whisperModeOn
        Task { [parakeet, whisper, endpointer] in
            await parakeet.setSilenceFloor(tuning.silenceFloor)
            await whisper.setSilenceFloor(tuning.silenceFloor)
            await endpointer.setTuning(tuning)
        }
    }

    // MARK: - Model manager (Settings → Models)

    /// Re-read on-disk model presence/size (skips models mid-download/prepare).
    func refreshModelStates() {
        for model in ManagedModel.allCases {
            switch modelStates[model] {
            case .downloading, .preparing: continue
            default: break
            }
            let size = ModelPaths.installedSize(at: model.directory)
            modelStates[model] = size > 0 ? .ready(bytes: size) : .notDownloaded
        }
    }

    /// Whether a model is the active speech engine (delete is blocked for it).
    func isModelInUse(_ model: ManagedModel) -> Bool {
        switch model {
        case .parakeet: return activeSpeechModel == .parakeet
        case .whisper: return activeSpeechModel == .whisper
        case .vad: return false
        }
    }

    /// Download a model to disk. Non-active engines are unloaded again afterward
    /// so only the active engine holds memory.
    func downloadModel(_ model: ManagedModel) {
        switch model {
        case .parakeet:
            Task { [parakeet, weak self] in
                try? await parakeet.warmUp()
                if self?.activeSpeechModel != .parakeet { await parakeet.shutdown() }
                self?.refreshModelStates()
            }
        case .whisper:
            Task { [whisper, weak self] in
                try? await whisper.warmUp()
                if self?.activeSpeechModel != .whisper { await whisper.shutdown() }
                self?.refreshModelStates()
            }
        case .vad:
            modelStates[.vad] = .preparing
            Task { [endpointer, weak self] in
                await endpointer.prepare()
                // refreshModelStates() skips `.preparing`, so set VAD explicitly.
                let size = ModelPaths.installedSize(at: ManagedModel.vad.directory)
                self?.modelStates[.vad] = size > 0 ? .ready(bytes: size) : .notDownloaded
            }
        }
    }

    /// Delete a model from disk (confirmed). Blocked for the in-use engine.
    func deleteModel(_ model: ManagedModel) {
        guard !isModelInUse(model) else {
            showNote("Can't delete the speech engine in use")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(model.label)?"
        alert.informativeText = "The model files will be removed from disk. It re-downloads the next time it's used."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [parakeet, whisper, weak self] in
            switch model {
            case .parakeet: await parakeet.shutdown()
            case .whisper: await whisper.shutdown()
            case .vad: break
            }
            try? ModelPaths.removeFromDisk(at: model.directory)
            self?.refreshModelStates()
        }
    }

    // MARK: - Audio devices (Settings → Audio)

    private func startAudioDevices() {
        audioDevices.onChange = { [weak self] in self?.handleDeviceListChanged() }
        audioDevices.start()
        inputDevices = audioDevices.devices
        applySelectedDevice(note: false)
    }

    private func handleDeviceListChanged() {
        inputDevices = audioDevices.devices
        applySelectedDevice(note: false)
    }

    /// Select an input device by UID (nil = system default). Persists and applies.
    func selectInputDevice(_ uid: String?) {
        selectedDeviceUID = uid
        if let uid {
            UserDefaults.standard.set(uid, forKey: Self.inputDeviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.inputDeviceKey)
        }
        applySelectedDevice(note: true)
    }

    private func applySelectedDevice(note: Bool) {
        guard let uid = selectedDeviceUID, !uid.isEmpty else {
            capture.setPreferredDeviceUID(nil)
            return
        }
        if let device = inputDevices.first(where: { $0.uid == uid }) {
            capture.setPreferredDeviceUID(uid)
            if note, device.isBluetooth {
                showNote("Bluetooth mics reduce recognition quality (HFP). Consider the built-in mic.")
            }
        } else {
            // Persisted device is gone — fall back to the system default.
            capture.setPreferredDeviceUID(nil)
            if note { showNote("Selected mic unavailable — using the system default") }
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
            content: SettingsView(controller: self, client: openRouterClient),
            width: 460, height: 620
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
