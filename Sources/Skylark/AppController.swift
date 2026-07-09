import AppKit
import ServiceManagement
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

    /// Play subtle start/stop sounds around each dictation — persisted, on by
    /// default. Built from macOS system sounds (`SoundEffects`), off the paste path.
    static let soundEffectsKey = "soundEffectsEnabled"
    static let soundStartKey = "soundStartID"
    static let soundStopKey = "soundStopID"
    static let soundVolumeKey = "soundVolume"
    private(set) var soundEffectsEnabled: Bool
    private(set) var soundStartID: String
    private(set) var soundStopID: String
    /// Cue volume 0…1 — Skylark's own cues only, never the system volume.
    private(set) var soundVolume: Double
    @ObservationIgnored private let sounds: SoundEffects

    // MARK: - Hotkey (Settings → General)

    /// The dictation trigger key (default Fn) and optional simultaneous mouse
    /// trigger. Persisted as `HotkeyBinding` raw strings; applied live.
    private(set) var hotkeyKeyboard: HotkeyBinding
    private(set) var hotkeyMouse: HotkeyBinding?

    func setHotkeyKeyboard(_ binding: HotkeyBinding) {
        hotkeyKeyboard = binding
        UserDefaults.standard.set(binding.rawValue, forKey: HotkeyBinding.defaultsKeyKeyboard)
        monitor.setBindings(keyboard: binding, mouse: hotkeyMouse)
    }

    /// Pause the global hotkey tap while the Settings shortcut recorder is
    /// active — the tap swallows bound keys at the HID level, so the recorder
    /// could never re-capture the current binding (and a stray press would
    /// start a dictation mid-recording).
    func pauseHotkeyMonitoring() {
        monitor.stop()
    }

    func resumeHotkeyMonitoring() {
        monitor.setBindings(keyboard: hotkeyKeyboard, mouse: hotkeyMouse)
        monitor.start()
    }

    /// nil = no mouse trigger.
    func setHotkeyMouse(_ binding: HotkeyBinding?) {
        hotkeyMouse = binding
        if let binding {
            UserDefaults.standard.set(binding.rawValue, forKey: HotkeyBinding.defaultsKeyMouse)
        } else {
            UserDefaults.standard.removeObject(forKey: HotkeyBinding.defaultsKeyMouse)
        }
        monitor.setBindings(keyboard: hotkeyKeyboard, mouse: binding)
    }

    // MARK: - Behavior toggles (Settings → General)

    /// Spoken "press enter" command (off by default).
    static let pressEnterKey = "pressEnterCommandEnabled"
    private(set) var pressEnterEnabled: Bool

    func setPressEnterEnabled(_ on: Bool) {
        pressEnterEnabled = on
        UserDefaults.standard.set(on, forKey: Self.pressEnterKey)
        Task { [orchestrator] in await orchestrator.setPressEnterEnabled(on) }
    }

    /// Pause Music/Spotify while dictating (off by default; needs an Automation
    /// permission grant the first time it fires).
    static let pauseMediaKey = "pauseMediaWhileDictating"
    private(set) var pauseMediaEnabled: Bool

    func setPauseMediaEnabled(_ on: Bool) {
        pauseMediaEnabled = on
        UserDefaults.standard.set(on, forKey: Self.pauseMediaKey)
    }

    /// Auto-learn dictionary corrections from history edits (off = confirm chips).
    static let dictionaryAutoLearnKey = "dictionary.autoLearn"
    var dictionaryAutoLearn: Bool {
        UserDefaults.standard.bool(forKey: Self.dictionaryAutoLearnKey)
    }

    func setDictionaryAutoLearn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.dictionaryAutoLearnKey)
    }

    // MARK: - HUD appearance (Settings → General)

    static let hudStyleKey = "hud.style"
    static let hudShowIdlePillKey = "hud.showIdlePill"

    func setHUDStyle(_ style: HUDStyle) {
        hud.style = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.hudStyleKey)
        applyHUDVisibility()
    }

    func setHUDShowIdlePill(_ show: Bool) {
        hud.showIdlePill = show
        UserDefaults.standard.set(show, forKey: Self.hudShowIdlePillKey)
        applyHUDVisibility()
    }

    private func applyHUDVisibility() {
        if hud.style == .hidden {
            hudPanel.hide()
        } else if permissions.allGranted {
            hudPanel.show()
        }
        hudPanel.refreshLayout()
    }

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

    // MARK: - History (Settings → History)

    /// Audio retention opt-in (default OFF — PRD §8, phase-5a spec §2).
    /// `nonisolated` so the `HistoryHub` retention closure (a plain `@Sendable`
    /// closure, not main-actor-isolated) can read it directly.
    nonisolated static let historyAudioRetentionKey = "history.audioRetentionEnabled"

    var audioRetentionEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.historyAudioRetentionKey)
    }

    func setAudioRetentionEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.historyAudioRetentionKey)
    }

    /// Deletes every retained audio file; the text history rows stay.
    func deleteAllStoredAudio() {
        Task { [historyHub] in await historyHub?.deleteAllAudio() }
    }

    /// History retention window in days (0 = keep forever). Prunes immediately
    /// on change and at every launch.
    var retentionDays: Int {
        UserDefaults.standard.integer(forKey: HistoryStore.retentionDefaultsKey)
    }

    func setRetentionDays(_ days: Int) {
        UserDefaults.standard.set(days, forKey: HistoryStore.retentionDefaultsKey)
        pruneHistory()
    }

    private func pruneHistory() {
        let days = retentionDays
        guard days > 0 else { return }
        Task { [historyStore] in _ = try? await historyStore?.prune(olderThanDays: days) }
    }

    // MARK: - Insights (Settings → Insights)

    /// Latest aggregate usage stats; refreshed at launch and after each
    /// dictation (cheap SQL, always off the paste path).
    private(set) var stats: StatsSummary?

    func refreshStats() {
        Task { [statsStore, weak self] in
            guard let summary = try? await statsStore?.summary() else { return }
            await MainActor.run { self?.stats = summary }
        }
    }

    // MARK: - Updates (Settings → Account)

    enum UpdateUIState: Equatable {
        case idle            // not checked yet
        case checking
        case upToDate
        case available(summary: String?)
        case failed(reason: String)
    }

    private(set) var updateState: UpdateUIState = .idle
    /// Build metadata stamped by bundle.sh; nil for unbundled dev runs.
    let buildInfo = BuildInfo.current()

    func checkForUpdates() {
        guard let buildInfo, let commit = buildInfo.commit, let remote = buildInfo.repoRemote else {
            updateState = .failed(reason: "Dev build — update by pulling the repo and re-running install.sh.")
            return
        }
        updateState = .checking
        Task { [weak self] in
            let status = await UpdateChecker().check(localCommit: commit, repoRemote: remote)
            await MainActor.run {
                switch status.state {
                case .upToDate:
                    self?.updateState = .upToDate
                case let .updateAvailable(_, summary, _):
                    self?.updateState = .available(summary: summary)
                case let .unknown(reason):
                    self?.updateState = .failed(reason: reason)
                }
            }
        }
    }

    /// Opens Terminal running `git pull --ff-only && Scripts/install.sh` from
    /// the repo this build was made from.
    func runUpdate() {
        guard let path = buildInfo?.repoPath else { return }
        do {
            let script = try UpdateCommandWriter.makeUpdateScript(repoPath: path)
            NSWorkspace.shared.open(script)
        } catch {
            showNote("Couldn't start the update: \(error.localizedDescription)")
        }
    }

    // MARK: - Launch at login (Settings → General)

    /// `SMAppService.mainApp` operates on the built, signed `.app` bundle; when
    /// run unbundled (`swift run`) its status reads `.notFound` — not an error,
    /// just "needs `make app` + a first launch from Finder" (surfaced in the UI).
    var launchAtLoginStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Human-readable reason `launchAtLoginStatus` isn't a plain on/off, or nil
    /// when it is.
    var launchAtLoginFootnote: String? {
        switch launchAtLoginStatus {
        case .notFound:
            return "Needs a bundled app (`make app`) and one launch from Finder before this works."
        case .requiresApproval:
            return "Approve Skylark in System Settings → General → Login Items."
        default:
            return nil
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showNote("Launch at Login failed: \(error.localizedDescription)")
        }
    }

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
    // history/persisted modes, on in-memory providers). Exposed (not private)
    // for the Settings → Dictionary/Modes/History views and the History window.
    private let registryStore: RegistryStore?
    let modeStore: ModeStore?
    let dictionaryStore: DictionaryStore?
    let historyStore: HistoryStore?
    let historyHub: HistoryHub?
    let snippetStore: SnippetStore?
    let statsStore: StatsStore?

    /// Pauses Music/Spotify around dictations when `pauseMediaEnabled`.
    @ObservationIgnored private let mediaPause = MediaPauseController()

    /// Bridges @Sendable notice callbacks built during init to `showNote`.
    @ObservationIgnored private let noticeRelay = NoticeRelay()

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
        // Sound effects default ON (register the default before the first read).
        if UserDefaults.standard.object(forKey: Self.soundEffectsKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.soundEffectsKey)
        }
        let soundsEnabled = UserDefaults.standard.bool(forKey: Self.soundEffectsKey)
        soundEffectsEnabled = soundsEnabled
        let startID = UserDefaults.standard.string(forKey: Self.soundStartKey) ?? SoundEffects.defaultStartID
        let stopID = UserDefaults.standard.string(forKey: Self.soundStopKey) ?? SoundEffects.defaultStopID
        soundStartID = startID
        soundStopID = stopID
        let volume = UserDefaults.standard.object(forKey: Self.soundVolumeKey) as? Double ?? SoundEffects.defaultVolume
        soundVolume = volume
        sounds = SoundEffects(enabled: soundsEnabled, startID: startID, stopID: stopID, volume: volume)
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.inputDeviceKey)

        // Hotkey bindings (default: Fn, no mouse trigger).
        hotkeyKeyboard = UserDefaults.standard.string(forKey: HotkeyBinding.defaultsKeyKeyboard)
            .flatMap(HotkeyBinding.init(rawValue:)) ?? .fn
        hotkeyMouse = UserDefaults.standard.string(forKey: HotkeyBinding.defaultsKeyMouse)
            .flatMap(HotkeyBinding.init(rawValue:))

        pressEnterEnabled = UserDefaults.standard.bool(forKey: Self.pressEnterKey)
        pauseMediaEnabled = UserDefaults.standard.bool(forKey: Self.pauseMediaKey)

        // Composition root: one on-disk database; fall back to in-memory
        // providers (no history/persisted modes) if it can't open.
        let modeProvider: any ModeProviding
        let dictionaryProvider: any DictionaryProviding
        var historyHub: HistoryHub?
        var snippetStore: SnippetStore?
        if let db = try? SkylarkDatabase.onDisk() {
            let modeStore = ModeStore(db: db)
            self.modeStore = modeStore
            self.registryStore = RegistryStore(db: db)
            modeProvider = ModeProviderAdapter(store: modeStore)
            let dictStore = DictionaryStore(db: db)
            self.dictionaryStore = dictStore
            dictionaryProvider = dictStore
            let histStore = HistoryStore(db: db)
            self.historyStore = histStore
            historyHub = HistoryHub(
                store: histStore,
                audioRetentionEnabled: { UserDefaults.standard.bool(forKey: Self.historyAudioRetentionKey) }
            )
            snippetStore = SnippetStore(db: db)
            self.snippetStore = snippetStore
            self.statsStore = StatsStore(db: db)
        } else {
            self.modeStore = nil
            self.registryStore = nil
            self.dictionaryStore = nil
            self.historyStore = nil
            self.snippetStore = nil
            self.statsStore = nil
            modeProvider = InMemoryModeProvider()
            dictionaryProvider = InMemoryDictionaryProvider()
            pendingStatusNote = "History disabled — storage unavailable"
        }
        self.historyHub = historyHub

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

        // Snippets load per session, off the paste path; nil store = feature off.
        let snippetsProvider: (@Sendable () async -> [SnippetRecord])?
        if let store = snippetStore {
            snippetsProvider = { (try? await store.all()) ?? [] }
        } else {
            snippetsProvider = nil
        }

        // Degrades (cloud cleanup falling back to local/raw) surface as
        // menu-bar notes — a tier the user picked failing must never be silent.
        // The relay exists because `self` can't be captured in an escaping
        // closure this early in init; `start()` points it back at us.
        let relay = noticeRelay
        let cleanupNotice: @Sendable (String) -> Void = { message in
            Task { @MainActor in relay.post(message) }
        }

        orchestrator = DictationOrchestrator(
            capture: capture,
            transcriber: parakeet,
            injector: injector,
            endpointer: endpointer,
            cleaners: CleanerRegistry(local: LocalCleaner(), cloudFactory: cloudFactory, notice: cleanupNotice),
            modeProvider: modeProvider,
            dictionary: dictionaryProvider,
            frontmostBundleID: frontmost.snapshot,
            snippets: snippetsProvider,
            historyRecord: historyHub?.recordSink(appInfo: frontmost.infoSnapshot),
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

        noticeRelay.controller = self
        permissions.refresh()

        // Restore persisted HUD appearance before the panel first shows.
        hud.style = UserDefaults.standard.string(forKey: Self.hudStyleKey)
            .flatMap(HUDStyle.init(rawValue:)) ?? .standard
        if UserDefaults.standard.object(forKey: Self.hudShowIdlePillKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.hudShowIdlePillKey)
        }
        hud.showIdlePill = UserDefaults.standard.bool(forKey: Self.hudShowIdlePillKey)

        // Forward HUD snapshots from the orchestrator to the UI; on the listening
        // edges play the start/stop cues and pause/resume media (both cue paths
        // are fire-and-forget — never on the audio/paste path). Leaving a session
        // (→ idle) also refreshes the Insights aggregates.
        Task { [orchestrator, hud, hudPanel, sounds, mediaPause, weak self] in
            var wasListening = false
            var wasIdle = true
            for await state in orchestrator.hudStates {
                hud.state = state
                let isListening: Bool = { if case .listening = state { return true } else { return false } }()
                let isIdle: Bool = { if case .idle = state { return true } else { return false } }()
                if isListening, !wasListening {
                    sounds.playStart()
                    if self?.pauseMediaEnabled == true {
                        Task { await mediaPause.pauseIfPlaying() }
                    }
                }
                if !isListening, wasListening {
                    sounds.playStop()
                    // Resume unconditionally: no-op unless we paused something.
                    Task { await mediaPause.resumeIfPaused() }
                }
                if isIdle, !wasIdle { self?.refreshStats() }
                wasListening = isListening
                wasIdle = isIdle
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

        // Warm the audio engine OFF the main thread. Binding the input device
        // (`AVAudioEngine.inputNode`) can stall for seconds — or hang forever
        // when coreaudiod is wedged — and blocking here keeps
        // `applicationDidFinishLaunching` from returning, which prevents the
        // MenuBarExtra scene from ever materializing (no menu-bar icon at all).
        // First-dictation capture start performs the same setup on demand, so
        // this stays purely a warm-up.
        Task.detached(priority: .userInitiated) { [capture] in
            capture.prepare()
        }

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

        // Orphaned audio files (no matching history row, e.g. left behind by a
        // crash) get swept once at launch. Detached; logs a count only.
        Task { [historyHub] in await historyHub?.sweepOrphans() }

        if let note = pendingStatusNote {
            showNote(note)
            pendingStatusNote = nil
        }

        // Apply the persisted press-enter opt-in, prune history to the retention
        // window, and warm the Insights aggregates.
        Task { [orchestrator, pressEnterEnabled] in await orchestrator.setPressEnterEnabled(pressEnterEnabled) }
        pruneHistory()
        refreshStats()

        // The monitor self-gates on Accessibility, so starting it is always safe.
        // Bindings are applied first so a non-default hotkey works from launch.
        monitor.setBindings(keyboard: hotkeyKeyboard, mouse: hotkeyMouse)
        monitor.start()

        if permissions.allGranted {
            applyHUDVisibility()
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
            // Insert-or-refresh the seed so registry additions reach existing
            // installs on their next update (never touches user-created rows).
            try? await registryStore.syncSeed()
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
                    self.applyHUDVisibility()
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
            setModelStatus("Preparing \(model.label)…")
        case let .downloading(progress):
            setModelStatus("Downloading \(model.label)… \(Int((progress * 100).rounded()))%")
        case .loading:
            setModelStatus("Loading \(model.label)…")
        case .ready:
            if isActiveEngine {
                setModelStatus(nil)
                Task { [orchestrator] in await orchestrator.setTranscriberReady(true) }
            } else if modelStatus?.contains(model.label) == true {
                setModelStatus(nil)
            }
        case .failed:
            setModelStatus("\(model.label) failed to load")
            if isActiveEngine {
                Task { [orchestrator] in await orchestrator.setTranscriberReady(false) }
            }
        }
        if isActiveEngine {
            hud.isPreparing = prep.isPreparing
        }
    }

    /// Assign `modelStatus` only when the displayed string actually changes.
    /// The download-progress stream fires many times per second and `@Observable`
    /// notifies on every set (no equality check), so writing the same string
    /// repeatedly rebuilds the menu-bar dropdown and makes it visibly flicker.
    private func setModelStatus(_ new: String?) {
        if modelStatus != new { modelStatus = new }
    }

    /// The model backing the active speech engine (the warm local engine, or the
    /// cloud fallback's local engine).
    private var activeSpeechModel: ManagedModel {
        activeLocal == .localWhisper ? .whisper : .parakeet
    }

    func showNote(_ note: String) {
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
    /// Choosing Cloud without a stored key warns immediately instead of
    /// letting every dictation degrade in silence.
    func setCleanupOverride(_ raw: String) {
        UserDefaults.standard.set(raw, forKey: Self.cleanupOverrideKey)
        applyCleanupOverride(raw)
        if raw == "cloud", !hasAPIKey {
            showNote("No API key — cloud cleanup will fall back to local. Add one in Settings → Account.")
        }
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
            // Read the key OFF the main actor: with a self-signed dev build,
            // `SecItemCopyMatching` can raise a keychain authorization prompt
            // and block until it's answered — on the main actor at launch that
            // froze the entire app (no menu-bar icon, no UI) until the dialog
            // was dismissed.
            Task.detached { [weak self] in
                let hasKey = KeychainStore().get() != nil
                await MainActor.run { self?.finishCloudRebuild(slug: slug, hasKey: hasKey) }
            }
        }
    }

    private func finishCloudRebuild(slug: String, hasKey: Bool) {
        guard hasKey else {
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

    /// Enable/disable the dictation start/stop sounds; persisted.
    func setSoundEffectsEnabled(_ on: Bool) {
        soundEffectsEnabled = on
        UserDefaults.standard.set(on, forKey: Self.soundEffectsKey)
        sounds.enabled = on
    }

    /// Select the recording-start cue; persisted, and auditioned immediately.
    func setSoundStart(_ id: String) {
        soundStartID = id
        UserDefaults.standard.set(id, forKey: Self.soundStartKey)
        sounds.setStart(id)
        sounds.preview(id)
    }

    /// Select the recording-stop cue; persisted, and auditioned immediately.
    func setSoundStop(_ id: String) {
        soundStopID = id
        UserDefaults.standard.set(id, forKey: Self.soundStopKey)
        sounds.setStop(id)
        sounds.preview(id)
    }

    /// Cue volume (0…1); persisted and applied to all cached players. Applies
    /// only to Skylark's cues — never the system output volume.
    func setSoundVolume(_ value: Double) {
        soundVolume = value
        UserDefaults.standard.set(value, forKey: Self.soundVolumeKey)
        sounds.setVolume(value)
    }

    /// Audition the start cue at the current volume (slider release).
    func previewSoundVolume() {
        sounds.preview(soundStartID)
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
        let view = OnboardingView(
            permissions: permissions,
            apiKeyClient: openRouterClient,
            hotkeyName: hotkeyKeyboard.displayName
        ) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let window = Self.makeWindow(title: "Welcome to Skylark", content: view, width: 460, height: 640)
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
            width: 560, height: 640
        )
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @ObservationIgnored private var historyWindow: NSWindow?

    func showHistory() {
        if let window = historyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let historyStore, let historyHub else {
            showNote("History unavailable — storage didn't open")
            return
        }
        let window = Self.makeWindow(
            title: "Skylark History",
            content: HistoryView(store: historyStore, hub: historyHub, modeStore: modeStore, dictionaryStore: dictionaryStore),
            width: 720, height: 480
        )
        historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Whether an OpenRouter key is currently stored (drives cloud warnings).
    var hasAPIKey: Bool { KeychainStore().exists() }

    /// Called when the stored API key changes (added/replaced/removed). The
    /// transcriber was built against the OLD key state — a cloud STT selection
    /// made while keyless silently ran local until now, so rebuild it.
    func apiKeyDidChange() {
        rebuildTranscriber()
        if case .cloud = modelSelection.sttChoice {
            showNote(hasAPIKey ? "Cloud speech engine active" : "Key removed — using local speech engine")
        }
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

/// Bridges @Sendable notice callbacks created during `AppController.init`
/// (before `self` is available to capture) back to `showNote`.
@MainActor
final class NoticeRelay {
    weak var controller: AppController?
    func post(_ message: String) { controller?.showNote(message) }
}
