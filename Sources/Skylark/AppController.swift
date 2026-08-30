import AppKit
import os
import ServiceManagement
import SkylarkCore
import SwiftUI

/// An engine option offered by History → Re-transcribe. Cloud cases carry their
/// slug + label so the factory can build an `OpenRouterCloud` without reading
/// any main-actor state; the picker keys on `id`.
enum RetranscribeEngine: Identifiable, Hashable {
    case parakeet
    case whisper
    case appleSpeech
    case cloud(slug: String, label: String)

    var id: String {
        switch self {
        case .parakeet: return "parakeet"
        case .whisper: return "whisper"
        case .appleSpeech: return "appleSpeech"
        case .cloud(let slug, _): return "cloud:\(slug)"
        }
    }

    var label: String {
        switch self {
        case .parakeet: return "Parakeet — local"
        case .whisper: return "Whisper — local"
        case .appleSpeech: return "Apple Speech — local"
        case .cloud(_, let label): return "\(label) — cloud"
        }
    }
}

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
    /// Optional Voice Command Mode trigger (keyboard only; default UNBOUND).
    /// While held, the user speaks an instruction that rewrites the selection or
    /// generates text at the cursor. Persisted under `hotkey.command`.
    private(set) var hotkeyCommand: HotkeyBinding?
    /// Optional "cycle cleanup model" trigger (keyboard only; default UNBOUND —
    /// PRD §7 makes it optional). Each press advances the active cleanup
    /// selection one step through the options the menu bar offers and names the
    /// new one in a menu-bar note. Persisted under `hotkey.cycleCleanup`.
    private(set) var hotkeyCycleCleanup: HotkeyBinding?

    func setHotkeyKeyboard(_ binding: HotkeyBinding) {
        hotkeyKeyboard = binding
        UserDefaults.standard.set(binding.rawValue, forKey: HotkeyBinding.defaultsKeyKeyboard)
        monitor.setBindings(keyboard: binding, mouse: hotkeyMouse)
    }

    /// Set (or clear, nil) the Voice Command Mode trigger. Applied live.
    func setHotkeyCommand(_ binding: HotkeyBinding?) {
        hotkeyCommand = binding
        if let binding {
            UserDefaults.standard.set(binding.rawValue, forKey: HotkeyBinding.defaultsKeyCommand)
        } else {
            UserDefaults.standard.removeObject(forKey: HotkeyBinding.defaultsKeyCommand)
        }
        monitor.setCommandBinding(binding)
    }

    /// Set (or clear, nil) the cleanup-cycle trigger. Applied live.
    func setHotkeyCycleCleanup(_ binding: HotkeyBinding?) {
        hotkeyCycleCleanup = binding
        if let binding {
            UserDefaults.standard.set(binding.rawValue, forKey: HotkeyBinding.defaultsKeyCycleCleanup)
        } else {
            UserDefaults.standard.removeObject(forKey: HotkeyBinding.defaultsKeyCycleCleanup)
        }
        monitor.setCleanupCycleBinding(binding)
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
        monitor.setCommandBinding(hotkeyCommand)
        monitor.setCleanupCycleBinding(hotkeyCycleCleanup)
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

    /// Context-aware cleanup: read the on-screen text around the caret (via
    /// Accessibility) at dictation start and feed it to the cleanup model, so
    /// continuations and spellings match what's already in the field. Off by
    /// default — it reads the focused field, so it's opt-in.
    static let contextAwareCleanupKey = "cleanup.useOnScreenContext"
    private(set) var contextAwareCleanupEnabled: Bool

    func setContextAwareCleanupEnabled(_ on: Bool) {
        contextAwareCleanupEnabled = on
        UserDefaults.standard.set(on, forKey: Self.contextAwareCleanupKey)
        Task { [orchestrator] in await orchestrator.setContextAwareCleanupEnabled(on) }
    }

    /// Live transcription preview (prototype): show interim words in the
    /// recording pill while speaking. Off by default; only renders for the local
    /// Parakeet engine. The pasted text is always the batch decode — unaffected.
    static let livePreviewKey = "recording.livePreview"
    private(set) var livePreviewEnabled: Bool

    func setLivePreviewEnabled(_ on: Bool) {
        livePreviewEnabled = on
        UserDefaults.standard.set(on, forKey: Self.livePreviewKey)
        Task { [orchestrator] in await orchestrator.setLivePreviewEnabled(on) }
    }

    /// Pause Music/Spotify while dictating (off by default; needs an Automation
    /// permission grant the first time it fires).
    static let pauseMediaKey = "pauseMediaWhileDictating"
    private(set) var pauseMediaEnabled: Bool

    func setPauseMediaEnabled(_ on: Bool) {
        pauseMediaEnabled = on
        UserDefaults.standard.set(on, forKey: Self.pauseMediaKey)
    }

    /// Translation mode (Settings → General; OFF by default). When on, cleanup
    /// also translates the text into `translateTargetLanguage` (a BCP-47 code)
    /// before typing. Requires a cleanup tier — raw dictation proceeds untranslated.
    static let translateEnabledKey = "translation.enabled"
    static let translateLanguageKey = "translation.targetLanguage"
    /// Default target when the user first enables translation (English).
    static let translateDefaultLanguage = "en"
    private(set) var translateEnabled: Bool
    private(set) var translateTargetLanguage: String

    func setTranslateEnabled(_ on: Bool) {
        translateEnabled = on
        UserDefaults.standard.set(on, forKey: Self.translateEnabledKey)
        applyTranslationSetting()
    }

    func setTranslateTargetLanguage(_ code: String) {
        translateTargetLanguage = code
        UserDefaults.standard.set(code, forKey: Self.translateLanguageKey)
        applyTranslationSetting()
    }

    /// Push the resolved translation target (nil when off) to the orchestrator.
    private func applyTranslationSetting() {
        let target = translateEnabled ? translateTargetLanguage : nil
        Task { [orchestrator] in await orchestrator.setTranslateTo(target) }
    }

    /// Auto-learn dictionary corrections from history edits (off = confirm chips).
    static let dictionaryAutoLearnKey = "dictionary.autoLearn"
    /// Stored (not computed) so `@Observable` tracks it — a computed property
    /// reading UserDefaults never triggers SwiftUI re-renders, leaving the
    /// toggle visually stuck (the v0.2.2 cleanupOverride bug class).
    private(set) var dictionaryAutoLearn: Bool

    func setDictionaryAutoLearn(_ on: Bool) {
        dictionaryAutoLearn = on
        UserDefaults.standard.set(on, forKey: Self.dictionaryAutoLearnKey)
    }

    /// Learn words from in-place corrections after a dictation (Settings →
    /// Dictionary). Off by default — watching a field via Accessibility is
    /// opt-in. `nonisolated` so the orchestrator settle handler can read it off
    /// the main actor without hopping.
    nonisolated static let learnFromCorrectionsKey = "dictionary.learnFromCorrections"
    /// Stored (not computed) so `@Observable` tracks it (v0.2.2 bug class);
    /// off-main-actor readers use the UserDefaults key directly.
    private(set) var learnFromCorrectionsEnabled: Bool

    func setLearnFromCorrections(_ on: Bool) {
        learnFromCorrectionsEnabled = on
        UserDefaults.standard.set(on, forKey: Self.learnFromCorrectionsKey)
    }

    /// Deep vocabulary matching (Settings → Dictionary, default ON since the
    /// spotter-rescue corruption fix). Runs a second on-device acoustic pass
    /// against the dictionary so names/terms are recognised as spoken. Needs
    /// the ~98 MB CTC helper model (downloaded on first launch/enable).
    static let deepVocabKey = "dictionary.deepVocabMatching"
    /// One-shot marker for the v0.12.2 forced disable (see start()).
    static let deepVocabKillSwitchKey = "dictionary.deepVocabMatching.v0122KillSwitch"
    /// One-shot marker for the post-fix re-enable (see start()).
    static let deepVocabReEnableKey = "dictionary.deepVocabMatching.v0123ReEnable"
    private(set) var deepVocabEnabled: Bool =
        UserDefaults.standard.object(forKey: AppController.deepVocabKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: AppController.deepVocabKey)

    /// Enable/disable deep vocabulary matching. On first enable, downloads the CTC
    /// helper model (progress shows in Models); once present, the rescorer is wired
    /// into the pipeline. Disabling clears it and unloads the model.
    func setDeepVocabEnabled(_ on: Bool) {
        deepVocabEnabled = on
        UserDefaults.standard.set(on, forKey: Self.deepVocabKey)
        if on {
            enableDeepVocab()
        } else {
            Task { [orchestrator, deepVocabRescorer] in
                await orchestrator.setRescorer(nil)
                await deepVocabRescorer.unload()
            }
        }
    }

    /// Ensure the CTC model is present (downloading with progress if needed), then
    /// wire the rescorer into the orchestrator. No-op parts are cheap when already
    /// prepared. Any failure surfaces as a note and leaves the stage unwired.
    private func enableDeepVocab() {
        if !deepVocabRescorer.isModelDownloaded {
            modelStates[.deepVocab] = .preparing
            showNote("Downloading the deep-vocabulary model (~98 MB)…")
        }
        Task { [orchestrator, deepVocabRescorer, weak self] in
            do {
                try await deepVocabRescorer.prepareModel()
                await orchestrator.setRescorer(deepVocabRescorer)
                self?.refreshModelStates()
            } catch {
                await MainActor.run {
                    self?.deepVocabEnabled = false
                    UserDefaults.standard.set(false, forKey: Self.deepVocabKey)
                    self?.showNote("Deep vocabulary model failed to download — feature stays off.")
                    self?.refreshModelStates()
                }
            }
        }
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
        case parakeet, whisper, appleSpeech, vad, deepVocab
        var id: String { rawValue }
        var label: String {
            switch self {
            case .parakeet: return "Parakeet TDT v3"
            case .whisper: return "Whisper large-v3-turbo"
            case .appleSpeech: return "Apple Speech"
            case .vad: return "Silero VAD"
            case .deepVocab: return "Deep Vocabulary (CTC 110M)"
            }
        }
        var approxSize: String {
            switch self {
            case .parakeet: return "~483 MB"
            case .whisper: return "~626 MB"
            case .appleSpeech: return "system-managed"
            case .vad: return "few MB"
            case .deepVocab: return "~98 MB"
            }
        }
        var directory: URL {
            switch self {
            case .parakeet: return ModelPaths.parakeetModelDir
            case .whisper: return ModelPaths.whisperKitBase
            // System-managed (assets live in the OS's Speech asset store, not
            // under our Models dir). Placeholder — never measured for size.
            case .appleSpeech: return ModelPaths.appSupport
            case .vad: return ModelPaths.vadModelDir
            case .deepVocab: return ModelPaths.ctcModelDir
            }
        }
        /// Apple-provided model managed by the OS (`AssetInventory`) — no local
        /// on-disk size, no download-to-our-dir, no delete.
        var isSystemManaged: Bool { self == .appleSpeech }
    }

    enum ManagedModelState: Equatable {
        case notDownloaded
        case downloading(Double)
        case preparing
        case ready(bytes: Int64)
    }

    /// Per-model download/on-disk state observed by the settings model manager.
    private(set) var modelStates: [ManagedModel: ManagedModelState] = [:]

    /// Resolved BCP-47 locale of the Apple Speech engine (shown in the Models
    /// pane, e.g. "en-US"). System-managed; refreshed with its install state.
    private(set) var appleSpeechLocale: String = "en-US"

    // MARK: - Local cleanup engine (Settings → Models)

    /// Which on-device model serves the LOCAL cleanup tier: Apple Foundation
    /// Models (default) or a downloaded Qwen GGUF run through llama.cpp. Stored
    /// (not computed) so `@Observable` tracks changes made via
    /// `setLocalCleanupEngine` — the same reason as `cleanupOverride` above (the
    /// v0.2.2 bug class). Initialized GATED on disk
    /// (`LocalCleanupEngine.resolvedFromDefaults()`), so a deleted or
    /// half-downloaded GGUF never shows as selected at launch.
    private(set) var localCleanupEngine: LocalCleanupEngine

    /// Per-model download/on-disk state for the Qwen GGUF models (Settings →
    /// Models, "Cleanup · on device"), keyed by `LocalCleanupModel.id`. Apple
    /// Intelligence isn't in here — it's never downloaded.
    private(set) var cleanupModelStates: [String: ManagedModelState] = [:]

    @ObservationIgnored private let cleanupDownloader = CleanupModelDownloader()
    /// The backend currently wired into the orchestrator's local cleaner tier —
    /// held here (not just inside its `LocalCleaner`) so an engine switch, idle
    /// unload, and the quit hook can all reach it directly. A `QwenCleanupBackend`
    /// when `localCleanupEngine` is `.llama`; the Apple backend otherwise (which
    /// has nothing to preload/unload).
    @ObservationIgnored private var localCleanupBackend: any LocalCleanupBackend

    /// Select the local cleanup engine (Apple Foundation Models or a downloaded
    /// Qwen GGUF). Persists, then swaps the orchestrator's local cleaner and
    /// warms the new backend / frees the old one — both off the paste path — so
    /// the change takes effect on the very next dictation with no app restart.
    func setLocalCleanupEngine(_ engine: LocalCleanupEngine) {
        let resolved = engine.resolved
        guard resolved != localCleanupEngine else { return } // already selected — no-op
        localCleanupEngine = resolved
        UserDefaults.standard.set(resolved.persistedValue, forKey: LocalCleanupEngine.defaultsKey)
        swapLocalCleanupBackend(to: resolved)
    }

    /// Build the backend for `engine`, wire it into the orchestrator, warm it,
    /// and free whichever backend it replaced. Called on every engine switch and
    /// once at launch (see `bootstrapSelection`) to warm a previously-selected
    /// Qwen engine.
    private func swapLocalCleanupBackend(to engine: LocalCleanupEngine) {
        let previous = localCleanupBackend
        let next = engine.makeBackend()
        localCleanupBackend = next
        Task { [orchestrator, next] in await orchestrator.setLocalCleaner(LocalCleaner(backend: next)) }
        let intensity = cleanupIntensity
        Task { [weak self] in
            if let qwen = next as? QwenCleanupBackend {
                let instructions = CleanupPrompt.compactInstructions(context: CleanupContext(intensity: intensity))
                await qwen.preload(instructions: instructions)
            }
            if let qwen = previous as? QwenCleanupBackend {
                await qwen.unload()
            }
            self?.refreshCleanupModelStates()
        }
    }

    /// MANDATORY on quit: synchronously (but boundedly) wait for the active Qwen
    /// backend to unload before the process exits. llama.cpp's Metal backend
    /// ABORTS in a static destructor if a context is still alive at `exit()`
    /// (see the warning on `LlamaRunner.unload()`) — a bare `Task { await
    /// qwen.unload() }` fired from `applicationWillTerminate` would race the
    /// process teardown and lose. `LlamaRunner` runs on its own private
    /// `DispatchSerialQueue` (not the main thread), so blocking the main thread
    /// here on a semaphore cannot deadlock against it; a generous 3 s bound
    /// still protects against a genuinely wedged unload. No-op when the active
    /// engine is Apple Foundation Models (nothing to unload).
    func blockingUnloadLocalCleanupBackendBeforeQuit() {
        guard let qwen = localCleanupBackend as? QwenCleanupBackend else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await qwen.unload()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
    }

    // MARK: - Audio devices (Settings → Audio)

    static let inputDeviceKey = "audio.inputDeviceUID"
    let audioDevices = AudioDeviceManager()
    private(set) var inputDevices: [AudioInputDevice] = []
    /// Selected input-device UID (nil = system default).
    private(set) var selectedDeviceUID: String?

    /// Global cleanup override backing the menu "Cleanup" submenu. "auto" = use
    /// the resolved mode's tier; "raw"/"local"/"cloud" force that tier.
    static let cleanupOverrideKey = "cleanupTierOverride"
    /// The persisted override raw value ("auto"/"raw"/"local"/"cloud"). Stored
    /// (not computed) so `@Observable` tracks changes made via `setCleanupOverride`
    /// — a computed property reading UserDefaults directly never triggers SwiftUI
    /// re-renders, which left the Settings picker visually stuck on its old value.
    private(set) var cleanupOverride: String

    /// How aggressively the cleanup stage edits (Settings → General, Cleanup
    /// section). Stored for the same `@Observable`-tracking reason as
    /// `cleanupOverride` above.
    static let cleanupIntensityKey = CleanupIntensity.defaultsKey
    private(set) var cleanupIntensity: CleanupIntensity

    /// Cleanup timeout in seconds; 0 = disabled (wait for cleanup with no cap).
    /// Settings → General. Stored (not computed) so `@Observable` tracks changes
    /// made via `setCleanupTimeout` — see the hard rule on settings bindings.
    static let cleanupTimeoutKey = "cleanup.timeoutSeconds"
    private(set) var cleanupTimeoutSeconds: Int
    /// Map the seconds setting to the orchestrator's optional cap (0 → nil).
    static func cleanupTimeoutDuration(_ seconds: Int) -> Duration? {
        seconds <= 0 ? nil : .seconds(seconds)
    }

    /// VAD silence-trim toggle (Settings → Audio; default ON). Trims quiet
    /// lead-in/trailing air from each clip before STT. Stored (not computed) so
    /// `@Observable` tracks it; persisted under the trimmer's kill-switch key.
    static let vadTrimKey = VadClipTrimmer.enabledKey
    private(set) var vadClipTrimEnabled: Bool

    /// How long a pause ends a hands-free (double-tap-lock) dictation — 1, 2,
    /// or 3 seconds (Settings → General). Push-to-talk is unaffected; Fn
    /// release ends those regardless. Stored (not computed) for the same
    /// `@Observable`-tracking reason as `cleanupOverride` above.
    static let handsFreeSilenceSecondsKey = "handsFree.silenceSeconds"
    private(set) var handsFreeSilenceSeconds: Int

    // MARK: - History (Settings → History)

    /// Audio retention opt-in (default OFF — PRD §8, phase-5a spec §2).
    /// `nonisolated` so the `HistoryHub` retention closure (a plain `@Sendable`
    /// closure, not main-actor-isolated) can read it directly.
    nonisolated static let historyAudioRetentionKey = "history.audioRetentionEnabled"

    /// Stored (not computed) so `@Observable` tracks it (v0.2.2 bug class).
    private(set) var audioRetentionEnabled: Bool

    func setAudioRetentionEnabled(_ enabled: Bool) {
        audioRetentionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.historyAudioRetentionKey)
        if enabled {
            // Newly on: apply the retention window to anything already on disk.
            pruneAudio()
        } else {
            // Turning retention off deletes every stored audio file (rows stay).
            deleteAllStoredAudio()
        }
    }

    /// Audio retention window in days (default 7). Applies to retained audio
    /// *files* only — pruning nulls `audio_path` and deletes the file, keeping
    /// the text row. Never 0 (there is no "forever" for audio).
    /// Stored (not computed) so `@Observable` tracks it (v0.2.2 bug class).
    private(set) var audioRetentionDays: Int

    func setAudioRetentionDays(_ days: Int) {
        audioRetentionDays = HistoryStore.audioRetentionDays(stored: days)
        UserDefaults.standard.set(days, forKey: HistoryStore.audioRetentionDefaultsKey)
        pruneAudio()
    }

    /// Prune retained audio files past the retention window. No-op when
    /// retention is off (there's nothing being written). Off any latency path.
    private func pruneAudio() {
        guard audioRetentionEnabled else { return }
        let days = audioRetentionDays
        Task { [historyStore] in _ = try? await historyStore?.pruneAudio(olderThanDays: days) }
    }

    /// Deletes every retained audio file; the text history rows stay.
    func deleteAllStoredAudio() {
        Task { [historyHub] in await historyHub?.deleteAllAudio() }
    }

    // MARK: - Re-transcribe (History window)

    /// Engines offered by History → Re-transcribe. The three local engines are
    /// always available; cloud STT models appear only when an API key is stored
    /// — picking one is the sole path on which a retained clip leaves the Mac
    /// (an explicit user action, allowed per the privacy invariants).
    var retranscribeEngines: [RetranscribeEngine] {
        var list: [RetranscribeEngine] = [.parakeet, .whisper, .appleSpeech]
        if hasAPIKey {
            for entry in sttModels {
                list.append(.cloud(slug: entry.slug, label: entry.label))
            }
        }
        return list
    }

    /// Re-transcribe a retained clip with a FRESHLY-instantiated engine, never
    /// touching the live dictation engine's warm state (a separate instance is
    /// built here and released after). Replaces the row's raw text + engine
    /// column via `Retranscription.run`. Returns the new raw text; throws on a
    /// missing clip or engine error. `nonisolated` so it runs off the main
    /// actor — the History view awaits it from a `Task`.
    nonisolated func retranscribe(id: Int64, audioPath: String, using engine: RetranscribeEngine) async throws -> String {
        guard let store = historyStore else { throw Retranscription.Failure.audioUnavailable }
        let transcriber = makeRetranscriber(engine)
        defer { Task { await Self.shutdownEngine(transcriber) } }
        return try await Retranscription.run(store: store, id: id, audioPath: audioPath, transcriber: transcriber)
    }

    /// Build a standalone transcriber for the re-transcribe path. Distinct from
    /// the live-dictation engines (`parakeet`/`whisper`/`appleSpeech`) so warming
    /// or releasing it can't disturb whatever engine dictation is using.
    private nonisolated func makeRetranscriber(_ engine: RetranscribeEngine) -> any Transcriber {
        switch engine {
        case .parakeet: return FluidAudioParakeet()
        case .whisper: return WhisperKitWhisper()
        case .appleSpeech: return SpeechAnalyzerTranscriber()
        case .cloud(let slug, let label):
            return OpenRouterCloud(
                client: openRouterClient,
                entry: ModelRegistryEntry(slug: slug, label: label, providerPin: nil, kind: .stt, sort: 0)
            )
        }
    }

    /// History retention window in days (0 = keep forever). Prunes immediately
    /// on change and at every launch.
    /// Stored (not computed) so `@Observable` tracks it (v0.2.2 bug class).
    private(set) var retentionDays: Int

    func setRetentionDays(_ days: Int) {
        retentionDays = days
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

    // MARK: - Diagnostics export (Settings → Account)

    /// Assemble a single hand-off diagnostics file — app version, settings,
    /// recent-dictation METADATA (counts/timings, never transcript text), and
    /// content-free log lines — and prompt the user to save it. All the gathering
    /// (OSLogStore + history reads) runs off the main actor; only the save panel
    /// and note posting are main-actor. Off any latency path (a Settings button).
    func exportDiagnostics() {
        let settings = diagnosticsSettingsSnapshot()
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
        let info = buildInfo
        let store = historyStore
        Task { [weak self] in
            let report = await DiagnosticsExporter.buildReport(
                appVersion: version, buildInfo: info, settings: settings, historyStore: store
            )
            DiagnosticsExporter.save(report: report) { note in self?.showNote(note) }
        }
    }

    /// Snapshot the user's current, non-secret configuration for the report.
    /// Reads only in-memory settings state (no keychain, no file paths).
    private func diagnosticsSettingsSnapshot() -> DiagnosticsReport.Settings {
        DiagnosticsReport.Settings(
            sttEngine: Self.sttEngineLabel(modelSelection.sttChoice),
            cleanupOverride: cleanupOverride,
            cleanupModelSlug: modelSelection.cleanupSlug,
            cleanupIntensity: cleanupIntensity.rawValue,
            cleanupTimeoutSeconds: cleanupTimeoutSeconds,
            whisperModeOn: whisperModeOn,
            hotkeyKeyboard: hotkeyKeyboard.displayName,
            hotkeyMouse: hotkeyMouse?.displayName,
            hotkeyCommand: hotkeyCommand?.displayName,
            contextAwareCleanup: contextAwareCleanupEnabled,
            translationEnabled: translateEnabled,
            translationLanguage: translateTargetLanguage,
            audioRetentionEnabled: audioRetentionEnabled,
            audioRetentionDays: audioRetentionDays,
            historyRetentionDays: retentionDays,
            pressEnterEnabled: pressEnterEnabled,
            livePreviewEnabled: livePreviewEnabled,
            pauseMediaEnabled: pauseMediaEnabled,
            deepVocabEnabled: deepVocabEnabled,
            inputDeviceSelected: selectedDeviceUID?.isEmpty == false
        )
    }

    private static func sttEngineLabel(_ choice: STTChoice) -> String {
        switch choice {
        case .localParakeet: return "Parakeet (local)"
        case .localWhisper: return "Whisper (local)"
        case .localApple: return "Apple Speech (local)"
        case .cloud(let slug): return "Cloud: \(slug)"
        case .groqDirect: return "Groq direct: \(GroqCloud.defaultModel)"
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
    ///
    /// STORED (not computed) so `@Observable` tracks it: the Settings toggle
    /// binds to this, and a computed property reading `SMAppService` is invisible
    /// to observation — the switch would register the tap, register no change,
    /// and snap back (the v0.2.2/v0.7.3 bug class, CLAUDE.md). Refreshed from the
    /// system after every change we make and whenever Settings opens, so an
    /// external edit (System Settings → General → Login Items) still shows up.
    private(set) var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status

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

    /// Re-read the system's login-item state into the stored property. Cheap and
    /// local (Service Management's own registration record).
    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
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
        // Always re-read rather than assuming `enabled`: registering can land on
        // `.requiresApproval` instead of `.enabled`, and a throw leaves the old
        // state. The toggle must show what the system actually did.
        refreshLaunchAtLoginStatus()
    }

    /// Live model selection (cleanup slug + STT engine), UserDefaults-backed.
    let modelSelection: ModelSelection
    /// Shared OpenRouter client (reads the key from Keychain per request, so a
    /// key dropped in later lights up cloud with no restart).
    let openRouterClient: OpenRouterClient

    private let capture = AudioCaptureService()
    private let parakeet: FluidAudioParakeet
    /// Deep-vocabulary rescorer (Settings → Dictionary, opt-in). Built once;
    /// wired into the orchestrator only while the toggle is on, and it keeps the
    /// CTC helper model resident only when actually rescoring (idle-unload +
    /// unload-on-off). See `setDeepVocabEnabled`.
    private let deepVocabRescorer: FluidAudioDeepVocabularyRescorer
    private let whisper: WhisperKitWhisper
    private let appleSpeech: SpeechAnalyzerTranscriber
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

    /// Correction auto-learn (opt-in). The reader re-reads AX-inserted fields;
    /// the watcher (built in `start()`, needs `self`) runs the bounded poll +
    /// filter. nil until `start()` when persistence is available.
    @ObservationIgnored private let correctionReader = AXCorrectionFieldReader()
    @ObservationIgnored private var correctionWatcher: CorrectionWatcher?

    /// Bridges @Sendable notice callbacks built during init to `showNote`.
    @ObservationIgnored private let noticeRelay = NoticeRelay()

    /// Registry-backed provider pins for cloud cleanup slugs. The cloud-cleaner
    /// factory runs off the main actor (one cleaner per dictation), so it reads
    /// pins from this lock-backed snapshot rather than the main-actor
    /// `cleanupModels` list; `reloadRegistryLists` republishes it. Seeded from
    /// `ModelRegistryEntry.seed`, so it answers correctly before any DB read.
    @ObservationIgnored private let cleanupPins = CleanupProviderPins()

    // Model-preparation states arrive on an arbitrary queue; funnel them through
    // a Sendable stream (tagged with which model) and apply them on the main
    // actor (see start()).
    @ObservationIgnored private let prepStream: AsyncStream<(ManagedModel, ModelPreparationState)>
    @ObservationIgnored private var noteClearTask: Task<Void, Never>?
    /// Deferred launch note (e.g. "history disabled") shown once start() runs.
    @ObservationIgnored private var pendingStatusNote: String?

    @ObservationIgnored private lazy var hudPanel = HUDPanelController(model: hud, controller: self)
    /// Learned-word notice, attached below the pill (see `HUDBannerPanelController`).
    @ObservationIgnored private lazy var hudBannerPanel = HUDBannerPanelController(
        model: hud, pillPanel: hudPanel, onUndo: { [weak self] in self?.hud.undoLearnedBanner() }
    )
    @ObservationIgnored private var onboardingWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var started = false

    init() {
        let (stream, cont) = AsyncStream<(ManagedModel, ModelPreparationState)>.makeStream(bufferingPolicy: .bufferingNewest(16))
        prepStream = stream
        parakeet = FluidAudioParakeet(progress: { state in cont.yield((.parakeet, state)) })
        whisper = WhisperKitWhisper(progress: { state in cont.yield((.whisper, state)) })
        appleSpeech = SpeechAnalyzerTranscriber(progress: { state in cont.yield((.appleSpeech, state)) })
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
        hotkeyCommand = UserDefaults.standard.string(forKey: HotkeyBinding.defaultsKeyCommand)
            .flatMap(HotkeyBinding.init(rawValue:))
        hotkeyCycleCleanup = UserDefaults.standard.string(forKey: HotkeyBinding.defaultsKeyCycleCleanup)
            .flatMap(HotkeyBinding.init(rawValue:))

        pressEnterEnabled = UserDefaults.standard.bool(forKey: Self.pressEnterKey)
        dictionaryAutoLearn = UserDefaults.standard.bool(forKey: Self.dictionaryAutoLearnKey)
        learnFromCorrectionsEnabled = UserDefaults.standard.bool(forKey: Self.learnFromCorrectionsKey)
        audioRetentionEnabled = UserDefaults.standard.bool(forKey: Self.historyAudioRetentionKey)
        audioRetentionDays = HistoryStore.audioRetentionDays(
            stored: UserDefaults.standard.integer(forKey: HistoryStore.audioRetentionDefaultsKey)
        )
        retentionDays = UserDefaults.standard.integer(forKey: HistoryStore.retentionDefaultsKey)
        contextAwareCleanupEnabled = UserDefaults.standard.bool(forKey: Self.contextAwareCleanupKey)
        livePreviewEnabled = UserDefaults.standard.bool(forKey: Self.livePreviewKey)
        pauseMediaEnabled = UserDefaults.standard.bool(forKey: Self.pauseMediaKey)
        translateEnabled = UserDefaults.standard.bool(forKey: Self.translateEnabledKey)
        translateTargetLanguage = UserDefaults.standard.string(forKey: Self.translateLanguageKey)
            ?? Self.translateDefaultLanguage
        cleanupOverride = UserDefaults.standard.string(forKey: Self.cleanupOverrideKey) ?? "auto"
        cleanupIntensity = CleanupIntensity.persisted()
        cleanupTimeoutSeconds = (UserDefaults.standard.object(forKey: Self.cleanupTimeoutKey) as? Int) ?? 2
        vadClipTrimEnabled = VadClipTrimmer.persistedEnabled()
        let storedSilenceSeconds = UserDefaults.standard.object(forKey: Self.handsFreeSilenceSecondsKey) as? Int
        handsFreeSilenceSeconds = FluidAudioVAD.clampedSilenceSeconds(storedSilenceSeconds ?? 2)

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

        // Key comes from the in-memory cache, NOT a keychain read per request:
        // `keyProvider` is called while building every request, including the
        // cloud STT request on the dictation path, and a synchronous
        // `SecItemCopyMatching` there can block on the keychain mutex (or an
        // authorization prompt) for longer than the request's own timeout — the
        // request hasn't started, so nothing is timing it. See `APIKeyCache`.
        let client = OpenRouterClient(keyProvider: { APIKeyCache.shared.current() })
        openRouterClient = client
        modelSelection = ModelSelection(registry: registryStore)

        // Cloud cleanup slot: build an OpenRouterCleaner per slug on demand. The
        // provider pin is RESOLVED from the registry, not assumed: the shipped
        // cleanup models are Groq-pinned for speed, but a slug the registry
        // doesn't know gets no pin at all. Force-pinning an arbitrary
        // user-entered slug to Groq (what this used to do) inverts the point of
        // pinning — Groq may not serve that model, so the request lands wherever
        // `allow_fallbacks` takes it and the user's model switch stops meaning
        // anything. Runs off the main actor, hence the lock-backed snapshot.
        let pins = cleanupPins
        let cloudFactory: @Sendable (String) -> (any Cleaner)? = { slug in
            guard !slug.isEmpty else { return nil }
            return OpenRouterCleaner(
                client: client,
                entry: ModelRegistryEntry(
                    slug: slug,
                    label: slug,
                    providerPin: pins.providerPin(for: slug),
                    kind: .cleanup,
                    sort: 0
                )
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

        // Deep-vocabulary rescorer reads the same dictionary the pipeline uses;
        // its model prep reports through the shared prep stream like other models.
        deepVocabRescorer = FluidAudioDeepVocabularyRescorer(
            dictionary: dictionaryProvider,
            progress: { state in cont.yield((.deepVocab, state)) }
        )
        // Voice Command Mode runner: cloud via the shared OpenRouter client (the
        // user's cleanup model), local via the on-device backend. Selection text
        // reaches the cloud only when the cleanup tier is cloud (privacy §7).
        let commandRunner = CommandRunner(
            client: client,
            localBackend: LocalCleaner.makeDefaultBackend(),
            providerPin: { [cleanupPins] slug in cleanupPins.providerPin(for: slug) }
        )

        // Local cleanup engine: Apple Foundation Models by default, a local
        // Qwen GGUF (llama.cpp) when one is selected AND downloaded —
        // `.resolvedFromDefaults()` applies that gate, so a deleted or
        // half-downloaded model silently keeps cleanup on Apple instead of
        // failing every dictation. Held on `self` (not just inside the
        // `LocalCleaner`) so `setLocalCleanupEngine` can swap/preload/unload it
        // later, off the paste path.
        let resolvedLocalEngine = LocalCleanupEngine.resolvedFromDefaults()
        localCleanupEngine = resolvedLocalEngine
        let localBackend = resolvedLocalEngine.makeBackend()
        localCleanupBackend = localBackend

        orchestrator = DictationOrchestrator(
            capture: capture,
            transcriber: parakeet,
            injector: injector,
            endpointer: endpointer,
            cleaners: CleanerRegistry(
                local: LocalCleaner(backend: localBackend),
                cloudFactory: cloudFactory,
                notice: cleanupNotice
            ),
            modeProvider: modeProvider,
            dictionary: dictionaryProvider,
            frontmostBundleID: frontmost.snapshot,
            // Captured-target focus guard: the transcript belongs to the app that
            // was frontmost at fn-down. If focus moved by paste time, bring that
            // app back (bounded) or abort rather than type into the wrong window.
            focusGuard: CapturedTargetGuard(
                // Live read, not the monitor's cached snapshot: the guard has to
                // verify a just-requested activation, and the cache only updates
                // when the didActivateApplication notification is delivered.
                frontmost: CapturedTargetGuard.liveFrontmost,
                activate: CapturedTargetGuard.liveActivator,
                // Window-level identity: the bundle ID can't tell two documents
                // of the same app apart, and pasting (or pressing Return) into
                // the wrong TextEdit window or Mail compose is the damaging case.
                focusedWindow: CapturedTargetGuard.liveFocusedWindow
            ),
            snippets: snippetsProvider,
            fieldContextReader: AXFieldContextReader(),
            commandRunner: commandRunner,
            // Live-preview prototype: streams the SAME warm Parakeet models via a
            // sliding-window manager. `loadedModels()` returns nil until warm-up
            // completes, in which case makeSession() yields no session.
            livePreview: FluidAudioLivePreviewProvider(
                modelsSource: { [parakeet] in await parakeet.loadedModels() }
            ),
            historyRecord: historyHub?.recordSink(appInfo: frontmost.infoSnapshot),
            historyUpdate: historyHub?.updateSink()
        )
    }

    /// Human-readable HUD state for the menu.
    var statusLine: String {
        switch hud.state {
        case .idle: return "Idle"
        case .listening: return "Listening"
        case .commandListening: return "Listening (command)"
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
                // Both listening variants (dictation + command) drive the
                // start/stop cues, media pause, and waveform.
                let isListening: Bool = {
                    switch state {
                    case .listening, .commandListening: return true
                    default: return false
                    }
                }()
                let isIdle: Bool = { if case .idle = state { return true } else { return false } }()
                if isListening, !wasListening {
                    sounds.playStart()
                    // A new dictation shouldn't compete with a lingering
                    // learned-word banner for attention on the pill.
                    hud.dismissLearnedBanner()
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
                switch state {
                // The cap countdown rides on the state itself (`HUDModel
                // .capSecondsRemaining` reads it), so nothing to mirror here.
                case let .listening(level, preview, _):
                    hud.pushLevel(level)
                    // Live-preview prototype text (nil unless the setting is on).
                    hud.preview = preview
                case let .commandListening(level):
                    hud.pushLevel(level)
                case .idle:
                    hud.resetWaveform()
                    hud.preview = nil
                case .processing:
                    hud.preview = nil
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
        // Hotkey-tap failures the pipeline can't see (the tap dying is invisible
        // to the orchestrator, which simply never hears from it again).
        Task { [monitor, weak self] in
            for await note in monitor.notes {
                self?.showNote(note)
            }
        }
        // Optional cleanup-cycle trigger (PRD §7). A plain edge — no session, no
        // pipeline involvement — so it's applied here, exactly as the menus do.
        Task { [monitor, weak self] in
            for await _ in monitor.cleanupCycles {
                self?.cycleCleanupSelection()
            }
        }
        // A refused start (session still processing) may have left the hotkey
        // layer holding a hands-free lock for a session that never began —
        // release it so the next press isn't eaten as a phantom stop.
        Task { [monitor, orchestrator] in
            for await _ in orchestrator.refusedStarts {
                await MainActor.run { monitor.noteStartRefused() }
            }
        }
        // A hands-free session the pipeline ended itself (VAD endpoint, 120 s
        // cap, cancel) leaves the hotkey layer's double-tap lock behind —
        // release it so the next press starts fresh.
        Task { [monitor, orchestrator] in
            for await _ in orchestrator.handsFreeEnded {
                await MainActor.run { monitor.noteHandsFreeSessionEnded() }
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
        refreshAppleSpeechState()
        refreshCleanupModelStates()
        applyWhisperTuning()
        startAudioDevices()

        // The transcriber is not ready until its model finishes preparing.
        Task { [orchestrator] in await orchestrator.setTranscriberReady(false) }
        hud.isPreparing = true

        // Prepare the ACTIVE local speech engine + VAD concurrently at launch
        // (VAD degrades gracefully). Every other engine stays cold until selected.
        warmActiveEngineAtLaunch()
        Task { [endpointer, whisperModeOn, handsFreeSilenceSeconds] in
            await endpointer.prepare()
            await endpointer.setTuning(.forWhisperMode(whisperModeOn))
            await endpointer.setMinSilenceDuration(TimeInterval(handsFreeSilenceSeconds))
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
        Task { [orchestrator, contextAwareCleanupEnabled] in
            await orchestrator.setContextAwareCleanupEnabled(contextAwareCleanupEnabled)
        }
        Task { [orchestrator, livePreviewEnabled] in
            await orchestrator.setLivePreviewEnabled(livePreviewEnabled)
        }
        applyTranslationSetting()
        // Cache key presence off-main so no SwiftUI body ever touches the
        // keychain (main-thread mutex hang; see hasAPIKey).
        refreshAPIKeyPresence()
        // Deep-vocabulary migrations, in order. The v0.12.2 kill switch forced
        // the feature off while its matcher corrupted cleaned text (spotter
        // rescue replaced unrelated words with dictionary terms). The matcher
        // is fixed (rescue pass disabled in FluidAudioDeepVocabularyRescorer),
        // so the v0.12.3 one-shot turns it back on for anyone the kill switch
        // hit. Both markers stay set so neither runs twice.
        if UserDefaults.standard.bool(forKey: Self.deepVocabKillSwitchKey) {
            if !UserDefaults.standard.bool(forKey: Self.deepVocabReEnableKey) {
                UserDefaults.standard.set(true, forKey: Self.deepVocabReEnableKey)
                if !deepVocabEnabled {
                    deepVocabEnabled = true
                    UserDefaults.standard.set(true, forKey: Self.deepVocabKey)
                    showNote("Deep vocabulary matching is back on — the text-corruption bug is fixed.")
                }
            }
        } else {
            // Fresh installs skip both migrations (default is already ON).
            UserDefaults.standard.set(true, forKey: Self.deepVocabKillSwitchKey)
            UserDefaults.standard.set(true, forKey: Self.deepVocabReEnableKey)
        }
        // Re-arm deep vocabulary at launch. Default-on means the CTC helper may
        // not be on disk yet — download it with progress (Models pane) instead
        // of silently flipping the setting off, so "on by default" survives a
        // fresh install. The rescorer itself still loads lazily on first use.
        if deepVocabEnabled, deepVocabRescorer.isModelDownloaded {
            Task { [orchestrator, deepVocabRescorer] in await orchestrator.setRescorer(deepVocabRescorer) }
        } else if deepVocabEnabled {
            enableDeepVocab()
        }
        pruneHistory()
        pruneAudio()
        refreshStats()

        // Build the correction auto-learn watcher (needs a dictionary store) and
        // wire the orchestrator's AX-settle signal to it. The toggle is checked
        // per-utterance in `handleCorrectionSettled`, so this is safe to wire
        // unconditionally.
        setUpCorrectionLearning()

        // The monitor self-gates on Accessibility, so starting it is always safe.
        // Bindings are applied first so a non-default hotkey works from launch.
        monitor.setBindings(keyboard: hotkeyKeyboard, mouse: hotkeyMouse)
        monitor.setCommandBinding(hotkeyCommand)
        monitor.setCleanupCycleBinding(hotkeyCycleCleanup)
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

    /// Warm exactly the local speech engine the PERSISTED selection uses.
    ///
    /// This used to be an unconditional `parakeet.warmUp()` fired before
    /// `bootstrapSelection()` applied the persisted choice: a user on Whisper or
    /// Apple Speech who had deleted the Parakeet model got an unrequested Hugging
    /// Face connection and a ~483 MB download at every launch (P2-4). The choice
    /// is a single synchronous UserDefaults read (`ModelSelection` loads it in
    /// `init`), so it is already known here — nothing has to wait for the
    /// database. A fresh install (Parakeet selected) warms exactly as before, and
    /// a cloud selection warms the local engine that backs its `FallbackTranscriber`.
    ///
    /// Routed through `rebuildGate` like every other engine rebuild: a selection
    /// change (or `bootstrapSelection`'s own rebuild) supersedes this one instead
    /// of racing its install and teardown.
    private func warmActiveEngineAtLaunch() {
        let choice = modelSelection.sttChoice
        activeLocal = choice.warmLocalEngine(cloudFallback: activeLocal)
        let engine = localEngine(for: activeLocal)
        let token = rebuildGate.begin(choice)
        Task { [engine, orchestrator, choice, weak self] in
            try? await engine.warmUp()
            // Install only for a LOCAL selection: a cloud selection's transcriber
            // is the `FallbackTranscriber` that `rebuildTranscriber()` builds, and
            // this warm exists only to have its local fallback resident. A rebuild
            // that started while we warmed owns the install either way (the warm
            // itself is never wasted — it's the engine that rebuild keeps).
            guard choice.isLocal, let self, self.isCurrentRebuild(token) else { return }
            await orchestrator.setTranscriber(engine)
            await orchestrator.setTranscriberReady(true)
        }
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
        cleanupPins.publish(cleanupModels)
        try? await modeStore?.seedIfEmpty()

        applyCleanupOverride(cleanupOverride)
        Task { [orchestrator, cleanupIntensity] in await orchestrator.setCleanupIntensity(cleanupIntensity) }
        Task { [orchestrator, cleanupTimeoutSeconds] in await orchestrator.setCleanupTimeout(Self.cleanupTimeoutDuration(cleanupTimeoutSeconds)) }
        Task { [orchestrator, vadClipTrimEnabled] in await orchestrator.setVadTrimEnabled(vadClipTrimEnabled) }
        // Warm a previously-selected Qwen engine off the paste path (Apple
        // Foundation Models needs no such warm-up — its backend has no preload).
        if let qwen = localCleanupBackend as? QwenCleanupBackend {
            let instructions = CleanupPrompt.compactInstructions(context: CleanupContext(intensity: cleanupIntensity))
            await qwen.preload(instructions: instructions)
        }
        refreshCleanupModelStates()
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
        observeAccessibilityEdges()
    }

    /// Accessibility can be revoked at ANY point, not just during onboarding —
    /// and when it goes the hotkey tap dies with nothing on screen to say why.
    /// This subscription lives for the whole app lifetime (the onboarding
    /// auto-advance above is still one-shot, and the onboarding window is never
    /// reopened behind the user's back).
    private func observeAccessibilityEdges() {
        Task { [weak self] in
            guard let self else { return }
            var previous = self.permissions.accessibility
            for await snapshot in self.permissions.changes {
                let current = snapshot.accessibility
                guard current != previous else { continue }
                if previous == .granted {
                    self.showNote(Self.accessibilityRevokedNote)
                } else if current == .granted {
                    self.showNote(Self.accessibilityRestoredNote)
                    self.applyHUDVisibility()
                }
                previous = current
            }
        }
    }

    static let accessibilityRevokedNote =
        "Accessibility permission was removed — dictation is disabled until you "
        + "re-grant it in System Settings > Privacy & Security > Accessibility."
    static let accessibilityRestoredNote = "Accessibility restored — dictation is back."

    // MARK: - Model preparation + notes

    private func applyModelPrep(_ model: ManagedModel, _ prep: ModelPreparationState) {
        // Per-model manager state (all models).
        switch prep {
        case .checking, .loading:
            modelStates[model] = .preparing
        case let .downloading(progress):
            modelStates[model] = .downloading(progress)
        case .ready:
            // System-managed models have no measurable on-disk size — report
            // "ready" without a byte count (the row hides size for them).
            modelStates[model] = model.isSystemManaged
                ? .ready(bytes: 0)
                : .ready(bytes: ModelPaths.installedSize(at: model.directory))
        case .failed:
            if model.isSystemManaged {
                modelStates[model] = .notDownloaded
            } else {
                modelStates[model] = ModelPaths.isPresent(at: model.directory)
                    ? .ready(bytes: ModelPaths.installedSize(at: model.directory))
                    : .notDownloaded
            }
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
        switch activeLocal {
        case .localWhisper: return .whisper
        case .localApple: return .appleSpeech
        default: return .parakeet
        }
    }

    /// The local engine instance backing an STT choice (used for warm/keep/drop).
    private func localEngine(for choice: STTChoice) -> any Transcriber {
        switch choice {
        case .localWhisper: return whisper
        case .localApple: return appleSpeech
        default: return parakeet
        }
    }

    func showNote(_ note: String) {
        statusNote = note
        noteClearTask?.cancel()
        noteClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.statusNote = nil }
        }
    }

    // MARK: - Correction auto-learn (Settings → Dictionary)

    /// Build the bounded correction watcher and route the orchestrator's
    /// AX-settle signal to it. Requires a dictionary store; without one the
    /// feature stays dark (nothing to learn into).
    private func setUpCorrectionLearning() {
        guard let dictionaryStore else { return }
        let checker = SystemCommonWordChecker()
        correctionWatcher = CorrectionWatcher(
            reader: correctionReader,
            dictionary: dictionaryStore,
            isCommonWord: { checker.isCommonWord($0) },
            learn: { [weak self] entry in
                // Upsert off the main actor to learn the row id Undo needs.
                let upserted = try? await self?.dictionaryStore?.upsert(entry)
                await MainActor.run {
                    guard let self, let id = upserted?.id else {
                        self?.showNote("Learned “\(entry.phrase)” from your correction")
                        return
                    }
                    // Attach to the HUD pill when it's actually on screen;
                    // otherwise (style .hidden, or idle pill toggled off with
                    // nothing else showing) a banner nobody can see is no
                    // notice at all — fall back to the plain status note.
                    if self.hudPanelIsVisible {
                        self.hud.noteLearned(word: entry.phrase, entryID: id)
                    } else {
                        self.showNote("Learned “\(entry.phrase)” from your correction")
                    }
                }
            }
        )
        // Undo needs the store too; deferred here (rather than at HUDModel's
        // construction) because dictionaryStore isn't known until start().
        hud.configureAutoLearnDelete { [weak self] id in
            guard let store = self?.dictionaryStore else { return false }
            return (try? await store.delete(id: id)) ?? false
        }
        // Force the banner panel's lazy init now so it's wired before any
        // word is ever learned.
        _ = hudBannerPanel

        Task { [orchestrator, weak self] in
            await orchestrator.setCorrectionSettled { token, finalText in
                Task { @MainActor in self?.handleCorrectionSettled(token: token, finalText: finalText) }
            }
        }
    }

    /// Whether the HUD panel is actually on screen right now (used to decide
    /// between a HUD-attached learned banner and the plain status note).
    private var hudPanelIsVisible: Bool {
        HUDMetrics.isVisible(
            state: hud.state, hovering: hud.isHovering, style: hud.style,
            showIdlePill: hud.showIdlePill, isPreparing: hud.isPreparing
        )
    }

    /// An AX insertion settled. If auto-learn is on and the target is watchable
    /// (still focused, not secure, not a password manager), start the bounded
    /// watcher. All the AX work happens here on the main actor, off the paste
    /// path (this runs after the pipeline finished the utterance).
    private func handleCorrectionSettled(token: InsertionToken, finalText: String) {
        guard learnFromCorrectionsEnabled else { return }
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let watch = correctionReader.makeWatch(token: token, finalText: finalText, bundleID: bundleID) else {
            return
        }
        correctionWatcher?.start(watch)
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
            case .commandListening, .processing:
                // A command session is a physical key hold (no HUD-button
                // control); ignore the record button while one is active.
                break
            }
        }
    }

    func cancelRecording() {
        Task { [orchestrator] in await orchestrator.handle(.cancel) }
    }

    // MARK: - Deep links (skylark://)

    private static let deepLinkLogger = Logger(subsystem: "com.jjromano.skylark", category: "deeplink")

    /// Refusals for a record deep link that has nowhere sensible to dictate.
    /// Never any transcript content.
    static let deepLinkSelfFocusedNote =
        "Skylark has focus — click the app you want to dictate into, then try again"
    static let deepLinkNoTargetNote =
        "Couldn't tell which app to dictate into — click it first, then try again"

    /// Route a `skylark://` URL (Raycast/Shortcuts/terminal automation).
    /// Unknown routes are logged (no content) and otherwise ignored.
    func handleDeepLink(_ url: URL) {
        guard let route = DeepLink.parse(url) else {
            Self.deepLinkLogger.notice("unrecognized deep link route")
            return
        }
        switch route {
        case .recordStart:
            // Like the HUD record button (start + arm hands-free), but against
            // an explicitly resolved target — see `startDeepLinkSession`.
            startDeepLinkSession()
        case .recordStop:
            Task { [orchestrator] in await orchestrator.handle(.stopRecording) }
        case .recordToggle:
            // Starting needs the target resolution; stopping doesn't.
            if case .idle = hud.state {
                startDeepLinkSession()
            } else {
                toggleHandsFree()
            }
        case .recordCancel:
            cancelRecording()
        case .settings:
            showSettings()
        }
    }

    /// Where a deep-link dictation should land.
    private enum DeepLinkTarget {
        /// Dictate into this app.
        case app(String)
        /// Skylark's own window holds focus — there is nowhere to dictate.
        case skylarkItself
        /// Frontmost is Skylark (activated by `open`) and nothing behind it
        /// could be resolved.
        case unresolved
    }

    /// Begin a hands-free session from a deep link, dictating into the app the
    /// user was actually working in (P1-4).
    ///
    /// `open skylark://record/start` ACTIVATES Skylark before macOS delivers the
    /// URL, so the orchestrator's own fn-down frontmost read captured
    /// `com.jjromano.skylark` (not AX-editable) and the transcript was pasted
    /// into Skylark's own window — the dictation was simply lost. The Shortcuts
    /// and Stream Deck workflows are exactly the ones that hit this. The hotkey
    /// path is unaffected and still reads frontmost itself.
    private func startDeepLinkSession() {
        switch resolveDeepLinkTarget() {
        case let .app(bundleID):
            Task { [orchestrator] in
                // Ordered awaits on one actor: the target is in place before the
                // session captures it.
                await orchestrator.setPendingTarget(bundleID: bundleID)
                await orchestrator.handle(.startRecording)
                await orchestrator.handle(.engageHandsFree)
            }
        case .skylarkItself:
            // Refuse rather than paste into ourselves.
            Self.deepLinkLogger.notice("record deep link refused — Skylark itself holds focus")
            showNote(Self.deepLinkSelfFocusedNote)
        case .unresolved:
            Self.deepLinkLogger.notice("record deep link refused — no resolvable target app")
            showNote(Self.deepLinkNoTargetNote)
        }
    }

    /// Resolve the app a deep-link dictation should target, at URL-receipt time.
    ///
    /// Frontmost is normally the answer (a deep link fired from a hotkey manager
    /// that doesn't activate us). When frontmost is Skylark we distinguish two
    /// cases: a real Skylark window holding key focus means the user is genuinely
    /// in Skylark (refuse), while no key window means `open` activated a
    /// menu-bar-only app and the real target is whatever sits behind us.
    private func resolveDeepLinkTarget() -> DeepLinkTarget {
        let own = Bundle.main.bundleIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, frontmost != own {
            return .app(frontmost)
        }
        // The HUD panels are `.nonactivatingPanel` and answer `canBecomeKey ==
        // false`, so a non-nil key window really is Settings/History/onboarding.
        if NSApp.keyWindow != nil { return .skylarkItself }
        guard let behind = Self.frontmostRegularAppBehindSelf() else { return .unresolved }
        return .app(behind)
    }

    /// Bundle ID of the frontmost REGULAR app that isn't us, read from the
    /// window server's front-to-back on-screen window list. Layer 0 filters out
    /// menu-bar items, status windows and other chrome; the activation-policy
    /// check filters out agents that have no user-facing window to dictate into.
    ///
    /// Only pid and layer are read, both of which the window list reports
    /// without Screen Recording permission (window *titles* are the part that
    /// needs it, and we never ask for one).
    private static func frontmostRegularAppBehindSelf() -> String? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier
            else { continue }
            return bundleID
        }
        return nil
    }

    // MARK: - Cleanup override (menu bar)

    /// Set from the menu; persists and pushes the tier into mode resolution.
    /// Choosing Cloud without a stored key warns immediately instead of
    /// letting every dictation degrade in silence.
    func setCleanupOverride(_ raw: String) {
        cleanupOverride = raw
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

    // MARK: - Cleanup cycle hotkey (PRD §7)

    /// Advance the active cleanup selection one step and say what it landed on.
    ///
    /// The ring is the same set the menus offer — Auto, Raw, Apple Intelligence,
    /// each Qwen model actually on disk, then the cloud models when a key is
    /// stored (`CleanupCycle`) — and each stop is applied through the very same
    /// setters the menu items call, so the menu-bar check marks and the Settings
    /// pickers follow along with no extra bookkeeping. Bound to nothing by
    /// default; `hotkeyCycleCleanup` is where the user opts in.
    func cycleCleanupSelection() {
        let options = CleanupCycle.options(
            localModels: LocalCleanupModel.installed,
            cloudModels: cleanupModels,
            hasAPIKey: hasAPIKey
        )
        let current = CleanupCycle.current(
            tierOverride: cleanupOverride,
            localEngine: localCleanupEngine,
            cloudSlug: currentCleanupSlug,
            options: options
        )
        guard let next = CleanupCycle.next(after: current, in: options) else { return }
        applyCleanupCycleOption(next)
        showNote("Cleanup: \(next.displayName)")
    }

    /// Apply one ring stop exactly as the corresponding menu item would.
    private func applyCleanupCycleOption(_ option: CleanupCycleOption) {
        switch option {
        case .auto, .raw:
            setCleanupOverride(option.tierOverride)
        case .local(let engine):
            // Engine first, then the tier: the swap warms the new backend, and
            // the tier change is what routes the next dictation to it.
            setLocalCleanupEngine(engine)
            setCleanupOverride(option.tierOverride)
        case .cloud(let slug, _):
            selectCleanupSlug(slug)
            setCleanupOverride(option.tierOverride)
        }
    }

    // MARK: - Cleanup intensity (Settings → General)

    /// Set from Settings; persists and pushes the level to the orchestrator.
    /// Disabled in the UI when `cleanupOverride == "raw"` (nothing to tune).
    func setCleanupIntensity(_ intensity: CleanupIntensity) {
        cleanupIntensity = intensity
        UserDefaults.standard.set(intensity.rawValue, forKey: Self.cleanupIntensityKey)
        Task { [orchestrator] in await orchestrator.setCleanupIntensity(intensity) }
    }

    /// Set the cleanup timeout (Settings → General). `0` disables the cap so a
    /// paste waits for cleanup however long it takes. Persists and pushes to the
    /// orchestrator; takes effect next dictation.
    func setCleanupTimeout(seconds: Int) {
        cleanupTimeoutSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: Self.cleanupTimeoutKey)
        Task { [orchestrator] in await orchestrator.setCleanupTimeout(Self.cleanupTimeoutDuration(seconds)) }
    }

    /// Toggle VAD silence trimming (Settings → Audio). Persists and pushes to the
    /// orchestrator; takes effect next dictation.
    func setVadClipTrimEnabled(_ enabled: Bool) {
        vadClipTrimEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.vadTrimKey)
        Task { [orchestrator] in await orchestrator.setVadTrimEnabled(enabled) }
    }

    /// Set the hands-free silence tolerance (Settings → General). Persists and
    /// pushes to the endpointer; takes effect on the next hands-free session
    /// (`beginSession`). Push-to-talk is not affected.
    func setHandsFreeSilenceSeconds(_ seconds: Int) {
        let clamped = FluidAudioVAD.clampedSilenceSeconds(seconds)
        handsFreeSilenceSeconds = clamped
        UserDefaults.standard.set(clamped, forKey: Self.handsFreeSilenceSecondsKey)
        Task { [endpointer] in await endpointer.setMinSilenceDuration(TimeInterval(clamped)) }
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
        // Keep the off-main-actor pin snapshot in step with the rows the menus
        // show — a slug the user just added must resolve its pin, not fall
        // through to "unknown".
        cleanupPins.publish(cleanupModels)
    }

    private static let engineLogger = Logger(subsystem: "com.jjromano.skylark", category: "engine")

    /// Staleness guard for transcriber rebuilds. Every rebuild path is
    /// asynchronous (keychain read, engine warm-up, waiting out a live session),
    /// so without it the LAST completion wins instead of the last SELECTION —
    /// and a cloud rebuild landing after a local one uploads audio while the menu
    /// reads "Local". See `STTRebuildGate`.
    @ObservationIgnored private var rebuildGate = STTRebuildGate()

    /// Build the transcriber for the current STT choice and swap it into the
    /// orchestrator, honouring the memory policy: only the active local engine
    /// stays warm. Cloud wraps the active local engine in a `FallbackTranscriber`;
    /// a missing key falls straight back to local with a one-time notice.
    ///
    /// Every path takes a gate token and rechecks it before constructing and
    /// again before installing; a superseded rebuild drops its work silently.
    private func rebuildTranscriber() {
        let choice = modelSelection.sttChoice
        let token = rebuildGate.begin(choice)
        switch choice {
        case .localParakeet, .localWhisper, .localApple:
            switchLocalEngine(to: choice, token: token)
        case .groqDirect:
            // Same off-main-actor keychain discipline as the OpenRouter branch
            // below, over the SEPARATE Groq key item.
            Task { [weak self] in
                let hasKey = await Self.reloadGroqKeyOffMainActor()
                self?.finishGroqRebuild(hasKey: hasKey, token: token)
            }
        case .cloud(let slug):
            // Read the key OFF the main actor: with a self-signed dev build,
            // `SecItemCopyMatching` can raise a keychain authorization prompt
            // and block until it's answered — on the main actor at launch that
            // froze the entire app (no menu-bar icon, no UI) until the dialog
            // was dismissed. That same unbounded wait is why the completion
            // below cannot trust the selection it started with.
            // `Task` (not `Task.detached`) inherits this method's main-actor
            // isolation, so `self` is never sent across an isolation boundary —
            // a detached task capturing `self` and hopping back through
            // `MainActor.run` is a "sending 'self' risks causing data races"
            // error under Swift 6.2 strict concurrency (the toolchain CLAUDE.md
            // pins). The keychain read still happens off the main actor.
            Task { [weak self] in
                let hasKey = await Self.reloadAPIKeyOffMainActor()
                self?.finishCloudRebuild(slug: slug, hasKey: hasKey, token: token)
            }
        }
    }

    /// Reloads the cached API key on a background executor and reports only
    /// whether one exists. Split out so the caller stays main-actor-isolated
    /// while the potentially-blocking keychain read does not.
    private nonisolated static func reloadAPIKeyOffMainActor() async -> Bool {
        await Task.detached(priority: .userInitiated) { APIKeyCache.shared.reload() != nil }.value
    }

    /// The Groq-key counterpart of `reloadAPIKeyOffMainActor`.
    private nonisolated static func reloadGroqKeyOffMainActor() async -> Bool {
        await Task.detached(priority: .userInitiated) { APIKeyCache.groq.reload() != nil }.value
    }

    /// Install the direct-Groq engine behind the same local fallback the
    /// OpenRouter path uses. Mirrors `finishCloudRebuild`, including its
    /// re-check of the rebuild token before anything is built or installed —
    /// the keychain read that got here is unbounded, and installing a cloud
    /// engine after the user moved to a local one would upload audio they
    /// asked to keep on the machine.
    private func finishGroqRebuild(hasKey: Bool, token: STTRebuildGate.Token) {
        guard isCurrentRebuild(token) else { return }
        guard hasKey else {
            showNote("No Groq API key — using local engine")
            switchLocalEngine(to: activeLocal, token: token)
            return
        }
        let cloud = GroqCloud(client: GroqSpeechClient(keyProvider: { APIKeyCache.groq.current() }))
        let notice: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.showNote(message) }
        }
        let localFallback = localEngine(for: activeLocal)
        let idle: [any Transcriber] = [parakeet, whisper, appleSpeech].filter { $0.id != localFallback.id }
        let fallback = FallbackTranscriber(primary: cloud, fallback: localFallback, notice: notice)
        Task { [orchestrator, idle, weak self] in
            guard let self, await self.waitForIdleSession(token) else { return }
            try? await fallback.warmUp()
            guard self.isCurrentRebuild(token) else { return }
            await orchestrator.setTranscriber(fallback)
            await orchestrator.setTranscriberReady(true)
            for engine in idle { await Self.shutdownEngine(engine) }
        }
    }

    private func finishCloudRebuild(slug: String, hasKey: Bool, token: STTRebuildGate.Token) {
        // Recheck BEFORE building anything: the keychain read that got us here is
        // unbounded (an unanswered authorization prompt holds it open), so the
        // user may have moved to a local engine — and completed a local rebuild —
        // in the meantime. Installing now would leave a cloud-primary
        // transcriber behind a menu that reads "Local", and the next dictation
        // would upload audio. Privacy invariant, not a cosmetic race.
        guard isCurrentRebuild(token) else { return }
        guard hasKey else {
            showNote("No API key — using local engine")
            switchLocalEngine(to: activeLocal, token: token)
            return
        }
        let entry = sttModels.first { $0.slug == slug }
            ?? ModelRegistryEntry(slug: slug, label: slug, providerPin: nil, kind: .stt, sort: 0)
        let cloud = OpenRouterCloud(client: openRouterClient, entry: entry)
        let notice: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.showNote(message) }
        }
        // Fallback = whichever local engine is currently active (stays warm);
        // every other local engine is freed to stay within the memory budget.
        let localFallback = localEngine(for: activeLocal)
        let idle: [any Transcriber] = [parakeet, whisper, appleSpeech].filter { $0.id != localFallback.id }
        let fallback = FallbackTranscriber(primary: cloud, fallback: localFallback, notice: notice)
        Task { [orchestrator, idle, weak self] in
            guard let self, await self.waitForIdleSession(token) else { return }
            try? await fallback.warmUp()
            guard self.isCurrentRebuild(token) else { return }
            await orchestrator.setTranscriber(fallback)
            await orchestrator.setTranscriberReady(true)
            for engine in idle { await Self.shutdownEngine(engine) }
        }
    }

    /// Switch the active local engine, warming the new one and (after the switch
    /// completes) shutting the other down to stay within the 16 GB memory budget.
    private func switchLocalEngine(to choice: STTChoice, token: STTRebuildGate.Token) {
        activeLocal = choice
        let keep = localEngine(for: choice)
        let drop: [any Transcriber] = [parakeet, whisper, appleSpeech].filter { $0.id != keep.id }
        Task { [orchestrator, keep, drop, weak self] in
            guard let self, await self.waitForIdleSession(token) else { return }
            let ready = await Self.engineReady(keep)
            if !ready { await orchestrator.setTranscriberReady(false) }
            guard self.isCurrentRebuild(token) else { return }
            await orchestrator.setTranscriber(keep)
            try? await keep.warmUp()
            guard self.isCurrentRebuild(token) else { return }
            await orchestrator.setTranscriberReady(true)
            for engine in drop { await Self.shutdownEngine(engine) }
            self.applyWhisperTuning()
        }
    }

    /// Whether `token` still owns its rebuild's outcome (no newer rebuild, and
    /// the live selection still matches). Logs the drop — no user content, just
    /// the fact that a stale completion was discarded.
    private func isCurrentRebuild(_ token: STTRebuildGate.Token) -> Bool {
        guard rebuildGate.isCurrent(token, selection: modelSelection.sttChoice) else {
            Self.engineLogger.debug(
                "stt rebuild superseded — dropping stale completion (gen \(token.generation, privacy: .public))"
            )
            return false
        }
        return true
    }

    /// Suspend until the pipeline is between sessions, so an engine swap never
    /// lands mid-dictation: `setTranscriber` would change the engine an in-flight
    /// decode reports its timings and history label from, and the teardown right
    /// after it would `shutdown()` a model WhisperKit is still decoding with.
    /// Like every other setting here, an engine change takes effect on the next
    /// dictation. Returns false if the rebuild was superseded while waiting (a
    /// newer one owns the outcome, including releasing these engines).
    private func waitForIdleSession(_ token: STTRebuildGate.Token) async -> Bool {
        while await orchestrator.phase != .idle {
            guard isCurrentRebuild(token) else { return false }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return isCurrentRebuild(token)
    }

    private static func engineReady(_ engine: any Transcriber) async -> Bool {
        if let p = engine as? FluidAudioParakeet { return await p.isReady }
        if let w = engine as? WhisperKitWhisper { return await w.isReady }
        if let a = engine as? SpeechAnalyzerTranscriber { return await a.isReady }
        return true
    }

    private static func shutdownEngine(_ engine: any Transcriber) async {
        if let p = engine as? FluidAudioParakeet { await p.shutdown() }
        else if let w = engine as? WhisperKitWhisper { await w.shutdown() }
        else if let a = engine as? SpeechAnalyzerTranscriber { await a.shutdown() }
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
        Task { [parakeet, whisper, appleSpeech, endpointer, orchestrator, whisperModeOn] in
            await parakeet.setSilenceFloor(tuning.silenceFloor)
            await whisper.setSilenceFloor(tuning.silenceFloor)
            await appleSpeech.setSilenceFloor(tuning.silenceFloor)
            await endpointer.setTuning(tuning)
            await orchestrator.setSilencePeakThreshold(
                whisperModeOn ? SilenceDetector.whisperPeakThreshold : SilenceDetector.peakThreshold
            )
            // Post-capture clip normalization runs only when whisper mode is on
            // (mirrors the silence-floor push; the tap's fixed gain stays dumb).
            await orchestrator.setWhisperNormalizationEnabled(whisperModeOn)
        }
    }

    // MARK: - Model manager (Settings → Models)

    /// Re-read on-disk model presence/size (skips models mid-download/prepare).
    func refreshModelStates() {
        for model in ManagedModel.allCases {
            // System-managed models (Apple Speech) aren't on disk here — their
            // install state comes from `AssetInventory` via refreshAppleSpeechState().
            if model.isSystemManaged { continue }
            switch modelStates[model] {
            case .downloading, .preparing: continue
            default: break
            }
            let size = ModelPaths.installedSize(at: model.directory)
            modelStates[model] = size > 0 ? .ready(bytes: size) : .notDownloaded
        }
    }

    /// Re-read the Apple Speech asset install state + resolved locale from the
    /// OS (`AssetInventory`); never clobbers an in-flight download/prepare.
    func refreshAppleSpeechState() {
        Task { [weak self] in
            guard let self else { return }
            let installed = await self.appleSpeech.isAssetInstalled()
            let locale = await self.appleSpeech.localeIdentifier()
            switch self.modelStates[.appleSpeech] {
            case .downloading, .preparing: break
            default: self.modelStates[.appleSpeech] = installed ? .ready(bytes: 0) : .notDownloaded
            }
            self.appleSpeechLocale = locale
        }
    }

    /// Whether a model is the active speech engine (delete is blocked for it).
    func isModelInUse(_ model: ManagedModel) -> Bool {
        switch model {
        case .parakeet: return activeSpeechModel == .parakeet
        case .whisper: return activeSpeechModel == .whisper
        case .appleSpeech: return activeSpeechModel == .appleSpeech
        case .vad: return false
        case .deepVocab: return false
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
        case .appleSpeech:
            modelStates[.appleSpeech] = .preparing
            Task { [appleSpeech, weak self] in
                // Downloading = ensuring the OS asset is installed + preheated.
                try? await appleSpeech.warmUp()
                if self?.activeSpeechModel != .appleSpeech { await appleSpeech.shutdown() }
                self?.refreshAppleSpeechState()
            }
        case .vad:
            modelStates[.vad] = .preparing
            Task { [endpointer, weak self] in
                await endpointer.prepare()
                // refreshModelStates() skips `.preparing`, so set VAD explicitly.
                let size = ModelPaths.installedSize(at: ManagedModel.vad.directory)
                self?.modelStates[.vad] = size > 0 ? .ready(bytes: size) : .notDownloaded
            }
        case .deepVocab:
            modelStates[.deepVocab] = .preparing
            Task { [deepVocabRescorer, weak self] in
                try? await deepVocabRescorer.prepareModel()
                // Downloaded-but-off keeps nothing resident; unload unless the
                // toggle is on (in which case the orchestrator holds it warm).
                if self?.deepVocabEnabled != true { await deepVocabRescorer.unload() }
                self?.refreshModelStates()
            }
        }
    }

    /// Delete a model from disk (confirmed). Blocked for the in-use engine.
    func deleteModel(_ model: ManagedModel) {
        // System-managed assets (Apple Speech) aren't ours to delete, and their
        // `directory` is a placeholder — never touch disk for them.
        guard !model.isSystemManaged else {
            showNote("Apple Speech is managed by macOS — remove it in System Settings.")
            return
        }
        guard !isModelInUse(model) else {
            showNote("Can't delete the speech engine in use")
            return
        }
        // Deleting the deep-vocabulary model force-disables the feature (it can't
        // run without the model); do it before the confirm so the toggle and the
        // wired stage never outlive the files.
        if model == .deepVocab, deepVocabEnabled {
            setDeepVocabEnabled(false)
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(model.label)?"
        alert.informativeText = "The model files will be removed from disk. It re-downloads the next time it's used."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [parakeet, whisper, deepVocabRescorer, weak self] in
            switch model {
            case .parakeet: await parakeet.shutdown()
            case .whisper: await whisper.shutdown()
            case .appleSpeech: break // guarded above — never reached
            case .vad: break
            case .deepVocab: await deepVocabRescorer.unload()
            }
            try? ModelPaths.removeFromDisk(at: model.directory)
            self?.refreshModelStates()
        }
    }

    // MARK: - Local cleanup model manager (Settings → Models)

    /// Re-read on-disk presence/size for the Qwen GGUF models (skips one
    /// mid-download/preparing, exactly like `refreshModelStates`).
    func refreshCleanupModelStates() {
        for model in LocalCleanupModel.all {
            switch cleanupModelStates[model.id] {
            case .downloading, .preparing: continue
            default: break
            }
            cleanupModelStates[model.id] = model.isInstalled
                ? .ready(bytes: ModelPaths.installedSize(at: model.fileURL))
                : .notDownloaded
        }
    }

    /// Whether `model` backs the currently active local cleanup engine (delete
    /// is blocked for it, matching `isModelInUse` for the STT models).
    func isCleanupModelInUse(_ model: LocalCleanupModel) -> Bool {
        localCleanupEngine.model?.id == model.id
    }

    /// Download a Qwen GGUF to disk. Progress/failure surface through
    /// `cleanupModelStates`; the row becomes selectable once it reads `.ready`.
    func downloadCleanupModel(_ model: LocalCleanupModel) {
        cleanupModelStates[model.id] = .preparing
        Task { [cleanupDownloader, weak self] in
            await cleanupDownloader.start(model) { state in
                Task { @MainActor in self?.applyCleanupModelPrep(model, state) }
            }
        }
    }

    /// Cancel an in-flight download. The partial transfer never counted as
    /// installed (`LocalCleanupModel.isInstalled` requires the exact byte
    /// count), so this just resets the row back to not-downloaded.
    func cancelCleanupModelDownload(_ model: LocalCleanupModel) {
        Task { [cleanupDownloader] in await cleanupDownloader.cancel(model) }
        cleanupModelStates[model.id] = .notDownloaded
    }

    /// Delete a downloaded Qwen GGUF (confirmed). Blocked for the in-use engine.
    func deleteCleanupModel(_ model: LocalCleanupModel) {
        guard !isCleanupModelInUse(model) else {
            showNote("Can't delete the cleanup model in use")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(model.displayName)?"
        alert.informativeText = "The model file will be removed from disk. It re-downloads the next time you select it."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? ModelPaths.removeFromDisk(at: model.fileURL)
        refreshCleanupModelStates()
    }

    private func applyCleanupModelPrep(_ model: LocalCleanupModel, _ prep: ModelPreparationState) {
        switch prep {
        case .checking, .loading:
            cleanupModelStates[model.id] = .preparing
        case let .downloading(progress):
            cleanupModelStates[model.id] = .downloading(progress)
        case .ready:
            cleanupModelStates[model.id] = .ready(bytes: ModelPaths.installedSize(at: model.fileURL))
        case let .failed(message):
            // A failed download no longer implies "not downloaded": the installer
            // validates the new bytes while staged and leaves any previously
            // installed model in place, so re-derive the row from disk.
            cleanupModelStates[model.id] = model.isInstalled
                ? .ready(bytes: ModelPaths.installedSize(at: model.fileURL))
                : .notDownloaded
            showNote("\(model.displayName) download failed: \(message)")
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
            message: "Enter an OpenRouter model slug (e.g. openai/gpt-oss-120b)."
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
            hotkeyName: hotkeyKeyboard.displayName,
            commandHotkeyName: hotkeyCommand?.displayName
        ) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        // Fixed format: the content is a fixed-width walkthrough and its height
        // varies with grant state, so the window is sized once and the root
        // scrolls rather than negotiating with the hosting view.
        let window = Self.makeWindow(
            title: "Welcome to Skylark",
            content: view,
            width: OnboardingView.contentWidth,
            height: OnboardingView.contentHeight,
            fixedSize: true
        )
        onboardingWindow = window
        permissions.startPolling()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        // Login-item state can change behind our back (System Settings → Login
        // Items); re-read it before the pane that shows it appears.
        refreshLaunchAtLoginStatus()
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
            content: HistoryView(
                store: historyStore,
                hub: historyHub,
                modeStore: modeStore,
                dictionaryStore: dictionaryStore,
                retranscribeEngines: retranscribeEngines,
                retranscribe: { [weak self] id, path, engine in
                    guard let self else { throw Retranscription.Failure.audioUnavailable }
                    return try await self.retranscribe(id: id, audioPath: path, using: engine)
                }
            ),
            width: 720, height: 480
        )
        historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Whether an OpenRouter key is currently stored (drives cloud warnings).
    /// CACHED, never read from the keychain here: SwiftUI bodies evaluate this
    /// on the main thread, and a synchronous `SecItemCopyMatching` can block on
    /// the Security framework's keychain mutex while a background read (e.g.
    /// `rebuildTranscriber`) holds it — a whole-app main-thread hang, observed
    /// live opening Settings (v0.7.3). Refreshed off-main at launch and on any
    /// key change.
    private(set) var hasAPIKey: Bool = false

    /// Re-read key presence OFF the main actor and publish the cached flag.
    /// `completion` (if any) runs on the main actor after the flag updates.
    func refreshAPIKeyPresence(completion: (@MainActor () -> Void)? = nil) {
        Task.detached(priority: .utility) {
            // One off-main read serves both purposes: it warms `APIKeyCache` (so
            // no request path ever reads the keychain) and tells us whether a key
            // exists. The key itself stays in memory only — never persisted,
            // never logged.
            let exists = APIKeyCache.shared.reload() != nil
            await MainActor.run { [weak self] in
                self?.hasAPIKey = exists
                completion?()
            }
        }
    }

    /// Called when the stored API key changes (added/replaced/removed). The
    /// transcriber was built against the OLD key state — a cloud STT selection
    /// made while keyless silently ran local until now, so rebuild it.
    func apiKeyDidChange() {
        refreshAPIKeyPresence { [weak self] in
            guard let self else { return }
            self.rebuildTranscriber()
            if case .cloud = self.modelSelection.sttChoice {
                self.showNote(self.hasAPIKey ? "Cloud speech engine active" : "Key removed — using local speech engine")
            }
        }
    }

    /// `fixedSize` makes the WINDOW the sole authority on geometry: the style
    /// mask drops `.resizable` and the hosting controller stops publishing a
    /// preferred content size. Required for any root whose height is derived
    /// from the proposed height — such a root and the default
    /// `.preferredContentSize` hosting controller form a cycle (hosting view
    /// proposes a size → `NSWindow._setFrameCommon` → the hosting view's
    /// safe-area insets are invalidated → another update-constraints pass),
    /// and AppKit throws once a window takes more constraint passes than it
    /// has views. That is a launch crash, not a glitch: `+[NSApplication
    /// _crashOnException:]` kills the process.
    ///
    /// Roots with a fully fixed frame (Settings) or a flexible split view
    /// (History) settle on the first pass, so they keep the default sizing and
    /// stay user-resizable.
    private static func makeWindow(
        title: String,
        content: some View,
        width: CGFloat,
        height: CGFloat,
        fixedSize: Bool = false
    ) -> NSWindow {
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if !fixedSize { styleMask.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        let hosting = NSHostingController(rootView: content)
        if fixedSize { hosting.sizingOptions = [] }
        window.contentViewController = hosting
        // `contentViewController` re-sizes the window to the hosting view's
        // fitting size, which is zero once sizing options are cleared — restore
        // the requested content size after the assignment, not before.
        if fixedSize { window.setContentSize(NSSize(width: width, height: height)) }
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
