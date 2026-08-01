import Foundation
import os

/// The session state machine: `idle → recording → transcribing → injecting →
/// idle` (+ `cancelled`). Owns the only pipeline-state writes, wiring
/// AudioCapture → Transcriber → TextInjector and publishing `HUDState`
/// snapshots for the UI. A failed optional stage never blocks the paste.
public actor DictationOrchestrator {
    public enum Phase: Sendable, Equatable {
        case idle
        case recording
        case transcribing
        case injecting
    }

    /// Which kind of session is active. Dictation transcribes → cleans → inserts;
    /// command speaks an instruction → LLM rewrite/generate → replace/insert.
    /// Capture + STT are shared exactly (same warm engines); only the post-
    /// transcription path differs. Command mode never touches the dictation
    /// Fn-up→paste path (latency invariant §6).
    public enum SessionKind: Sendable, Equatable {
        case dictation
        case command
    }

    private let capture: any AudioCapturing
    /// Swappable at runtime (`setTranscriber`) so the menu-bar Speech Engine
    /// quick-switch can move between local and cloud without rebuilding the
    /// orchestrator. The ready-gate (`transcriberReady`) is independent.
    private var transcriber: any Transcriber
    private let injector: any TextInjecting
    private let endpointer: (any SpeechEndpointer)?
    private let hint: TranscriptionHint

    /// Voice Command Mode runner (optional). nil = command mode not wired
    /// (headless/tests without it); a `.startCommand` then surfaces a note and
    /// does nothing destructive.
    private let commandRunner: (any CommandRunning)?

    /// Live transcription preview source (optional prototype). nil = not wired.
    /// Only used when `livePreviewEnabled` is on AND the active engine is
    /// Parakeet; produces interim HUD text that is NEVER pasted (the batch decode
    /// owns the final result). Everything here is off the Fn-up→paste path.
    private let livePreview: (any LivePreviewProviding)?
    /// Setting toggle (Settings → General, Recording indicator). Default off.
    private var livePreviewEnabled = false
    /// The active preview session for the current recording, if any.
    private var previewSession: (any LivePreviewSession)?
    private var previewFeedTask: Task<Void, Never>?
    private var previewPumpTask: Task<Void, Never>?
    /// Monotonic guard so a late `makeSession()` from a finished/cancelled
    /// recording can't attach itself to a newer session.
    private var previewSetupID = 0
    /// Latest interim preview text, folded into the `.listening` HUD state
    /// alongside the level. nil unless preview is active and has produced text.
    private var currentPreview: TranscriptPreview?
    /// Most recent RMS level, so a preview-text update can republish `.listening`
    /// without waiting for the next level tick (and vice-versa).
    private var lastLevel: Float = 0

    /// Kind of the active/last session (set at start; consumed at finish and by
    /// level forwarding so the command pill renders distinctly).
    private var sessionKind: SessionKind = .dictation

    /// Detached history sinks (phase-3 spec §7). Both off the paste path; nil in
    /// tests/headless callers that don't record. `historyRecord` also carries
    /// the just-captured clip so the sink can retain audio when opted in
    /// (phase-5a spec §2); the sink itself decides whether to keep it.
    private let historyRecord: (@Sendable (HistoryRecord, AudioClip) -> Void)?
    private let historyUpdate: (@Sendable (HistoryRecord) -> Void)?

    // Cleanup wiring (Phase 2). Defaults keep behaviour raw-only + instant so the
    // 3-arg init and existing call sites are unaffected.
    /// Swappable (`setLocalCleaner`) so the Settings "Local cleanup engine"
    /// picker can move between Apple Foundation Models and a Qwen GGUF without
    /// rebuilding the orchestrator, mirroring `setTranscriber` above.
    private var cleaners: CleanerRegistry
    private let modeProvider: any ModeProviding
    private let dictionary: any DictionaryProviding
    private let frontmostBundleID: @Sendable () -> String?
    /// Captured-target focus guard (WS3). nil = not wired (tests/headless) and
    /// injection proceeds exactly as before, with no extra reads.
    private let focusGuard: CapturedTargetGuard?
    /// The app — and, when it exposes one, the WINDOW — that was frontmost at
    /// record start (fn-down): what the user dictated INTO. The guard compares
    /// it against the live focus before every write.
    private var capturedTarget: CapturedTarget?
    /// Monotonic capture id, so a late window read from a previous recording
    /// can't write its identity into a newer session (same pattern as
    /// `fieldContextSession`).
    private var capturedTargetSession = 0
    private var capturedTargetTask: Task<Void, Never>?
    /// Current snippets (loaded per session in `buildSetup`, off the paste
    /// path). Nil = snippets feature not wired (tests/headless).
    private let snippetProvider: (@Sendable () async -> [SnippetRecord])?
    /// Explicit dictation target for the NEXT session, set by the deep-link
    /// route (`setPendingTarget`). Consumed — and cleared — by the next
    /// `startRecording`, so it can never leak into a later hotkey session.
    private var pendingTargetBundleID: String?

    /// Temporary global cleanup override from the menu bar (nil = auto/use mode).
    private var tierOverride: CleanupTier?
    private var silencePeakThreshold: Float = SilenceDetector.peakThreshold
    /// Whether Whisper Mode post-capture clip normalization runs. Pushed by
    /// `applyWhisperTuning` alongside the silence floor, so it mirrors the same
    /// whisper-on/off state the rest of the tuning uses. Off = clips untouched.
    private var whisperNormalizationEnabled = false
    /// Global cleanup intensity (Settings → General, Cleanup section).
    private var cleanupIntensity: CleanupIntensity = .standard
    /// Spoken "press enter" command opt-in (Settings → General). When on, a
    /// terminal "press enter"/"press return" is stripped from the transcript
    /// and a Return keystroke is synthesized after the text lands.
    private var pressEnterEnabled = false

    /// Translation mode (Settings → General; OFF by default). BCP-47 target
    /// language, or nil = off. Flows into `CleanupContext.translateTo` at session
    /// setup so the cleanup prompt translates the cleaned text. Requires a cleanup
    /// model: when the resolved tier is raw, dictation proceeds untranslated and a
    /// one-time note (below) is surfaced.
    private var translateTo: String?
    /// Guards the "Translation needs a cleanup model" note to once per app run, so
    /// a raw-tier user with translation left on isn't nagged every dictation.
    private var translationNeedsCleanupNoteShown = false

    /// Fired when an utterance settles into an AX-verified field (raw stands, or
    /// cleanup replaced it): `(token, finalText)` where `finalText` is what now
    /// sits on screen. The app layer starts the bounded correction watcher off
    /// this signal (opt-in auto-learn). nil = feature not wired. Never called for
    /// paste-fallback insertions (no AX signal to re-read).
    private var correctionSettled: (@Sendable (InsertionToken, String) -> Void)?

    /// Reads the on-screen text around the caret at recording start for
    /// context-aware cleanup (opt-in). nil = feature not wired (tests/headless).
    private let fieldContextReader: (any FieldContextReading)?
    /// Opt-in toggle (Settings → General). When on and a reader is wired, the AX
    /// read is kicked off at recording start.
    private var contextAwareCleanupEnabled = false
    /// Field context captured during the CURRENT recording, or nil when the read
    /// hasn't finished, wasn't enabled, or found nothing. Read — never awaited —
    /// at cleanup time so the AX read never delays Fn-up→paste.
    private var capturedFieldContext: FieldContext?
    /// Monotonic recording id: a late read from a previous recording can't write
    /// its context into a newer session.
    private var fieldContextSession = 0
    private var fieldContextTask: Task<Void, Never>?
    /// Optional deep-vocabulary rescorer (PRD §8, default on). When set,
    /// Parakeet utterances get a second on-device acoustic pass against the
    /// dictionary in the DETACHED post-insert flow (never on fn-up→paste), whose
    /// result feeds the cleanup stage. nil = feature off (nothing loaded, no work
    /// on any path). Failure of the stage always falls through to un-rescored text.
    private var rescorer: (any DeepVocabularyRescoring)?

    /// Resolved once per session at fn-down, consumed at paste time.
    private var sessionSetup: SessionSetup?
    private var setupTask: Task<SessionSetup, Never>?

    /// Cap on the cleanup+replace path (AX targets); raw already stands.
    private let replaceTimeout: Duration
    /// Cap on wait-for-clean before pasting (paste targets, deliberate wait).
    /// Configurable from Settings (raise it, or `nil` to disable and wait with no
    /// cap). Also the budget after which a slow CLOUD cleanup degrades to the
    /// local engine instead of keeping raw text.
    private var cleanupTimeout: Duration?
    /// Fixed hard cap for the LOCAL fallback that runs after a cloud timeout, so a
    /// wedged on-device model can't hang the paste even when the user disabled the
    /// main cleanup timeout.
    private let localFallbackTimeout: Duration = .seconds(6)
    /// Hard ceiling on a cleanup the user is WAITING on with nothing on screen
    /// (P1-10): paste targets, and the "press enter" path that must know the
    /// final text before it can synthesize Return.
    ///
    /// The Settings cleanup timeout may be set to "Off", meaning "wait for
    /// cleanup however long it takes". That is a sane choice on the DETACHED AX
    /// path — raw text is already visible there and only gets better. Ahead of
    /// the FIRST insertion it is a hang: the user held a key, released it, and
    /// stares at an empty field for as long as a wedged model feels like taking,
    /// while PRD §12 budgets the whole path in hundreds of ms. So the pre-paste
    /// stage is capped regardless of the setting — deliberately generous (a cold
    /// on-device model load is seconds) but finite. Injected only so tests need
    /// not wait it out.
    private let prePasteCeiling: Duration

    public private(set) var phase: Phase = .idle

    /// Whether the transcriber is ready to decode. Defaults true (engines with
    /// nothing to prepare, e.g. the stub, are ready immediately); the app flips
    /// it false while a model downloads/loads and true again on completion.
    /// Dictation attempted while false is discarded with a status note (no hang).
    private var transcriberReady = true

    /// Whether the finalize path VAD-trims the quiet head/tail of a clip (WS2).
    /// Default ON — the scan is measured at ≈3.5 ms for a 5 s clip and only runs on
    /// clips ≥ 2 s with a resident model (see `vadTrim`). No Settings control;
    /// `VadClipTrimmer.enabledKey` is a diagnostics kill switch.
    private var vadTrimEnabled = VadClipTrimmer.persistedEnabled()

    /// True while the active session is hands-free (double-tap-lock): VAD, not a
    /// key release, ends it.
    private var isHandsFree = false
    private var vadTask: Task<Void, Never>?

    /// Interruption reported for the CURRENT session from outside the clip: the
    /// hotkey tap stalled (`.captureInterrupted`), or capture couldn't restart
    /// after a configuration change. Merged with the clip's own signals in
    /// `resolveFinalization` — the single finalize decision — and cleared at every
    /// start/cancel. nil = nothing seen this session.
    private var sessionInterruption: CaptureInterruption?
    private var interruptionsTask: Task<Void, Never>?
    /// Shown whenever any interruption signal fired, for both push-to-talk and
    /// hands-free: the user must know the text may be missing its tail.
    private static let interruptedNote = "Mic interrupted — text may be incomplete"
    /// Shown when Accessibility died mid-utterance: the clip is still transcribed
    /// and recorded, but injection has no way to reach the target app, so the user
    /// is told where the text went.
    static let permissionLostNote = "Accessibility permission lost — dictation stopped. Transcript is in History."
    /// Shown when capture hit its hard 2-minute cap. A designed limit, not a
    /// fault, so it never borrows the mic-interrupted wording (P1-2b).
    static let capReachedNote = "Reached the 2-minute recording limit — transcribed what fit"
    /// Shown when the audio engine refused to start (device in use, no input
    /// device, hardware wedge). Names the remedy: without it the press simply
    /// does nothing (P1-8).
    static let captureFailedNote = "Microphone capture failed — check your input device"

    // MARK: Cancellation (P1-3)

    /// A cancel that arrived while the session was PROCESSING (transcribing /
    /// cleaning / injecting), not recording. Honored at every await boundary and
    /// immediately before every write, until the write is irreversible.
    ///
    /// Before this, `cancelRecording` guarded on `phase == .recording`, so Esc —
    /// or `skylark://record/cancel` — during the ~180 ms local / 350–680 ms cloud
    /// processing window was dropped silently: no teardown, no log, no UI. The
    /// text landed anyway.
    private var cancelRequested = false
    /// True once THIS session has written text into the user's document. From
    /// that instant a cancel can no longer undo anything, so it is reported as
    /// too late instead of quietly tearing down a session whose text is on
    /// screen. Reset at every start.
    private var writeCommitted = false
    /// Cancel arrived after the text had already landed — say so rather than
    /// leave the user believing the dictation was dropped.
    static let cancelTooLateNote = "Too late to cancel — text already inserted"
    /// A new session was requested while the previous one was still processing
    /// (U5). The press is refused, not queued.
    static let stillProcessingNote = "Still finishing the last dictation — try again in a moment"

    private let hudContinuation: AsyncStream<HUDState>.Continuation
    /// HUD snapshots for the UI to observe.
    public nonisolated let hudStates: AsyncStream<HUDState>

    private let noteContinuation: AsyncStream<String>.Continuation
    /// Transient status notes for the menu bar (e.g. "Speech model still preparing…").
    public nonisolated let statusNotes: AsyncStream<String>

    private let refusedStartContinuation: AsyncStream<Void>.Continuation
    /// Fires when a `.startRecording` was refused because a session was still
    /// processing. The hotkey layer uses it to release a hands-free lock that
    /// formed around the refused start (HotkeyMonitor.noteStartRefused).
    public nonisolated let refusedStarts: AsyncStream<Void>

    private let handsFreeEndedContinuation: AsyncStream<Void>.Continuation
    /// Fires when a hands-free session ends pipeline-side (VAD endpoint, the
    /// 120 s cap, cancel) rather than by a trigger tap. The hotkey layer's
    /// double-tap lock knows nothing about those, so it must be released here
    /// or the next press is eaten as a phantom stop.
    public nonisolated let handsFreeEnded: AsyncStream<Void>

    private let latencyContinuation: AsyncStream<DictationLatency>.Continuation
    /// Per-dictation latency summaries for the menu bar.
    public nonisolated let latencies: AsyncStream<DictationLatency>
    /// Rolling window of the last 20 summaries (advisory; ARCHITECTURE §8).
    public private(set) var recentLatencies: [DictationLatency] = []

    private var levelsTask: Task<Void, Never>?

    private let signposter = OSSignposter(subsystem: "com.jjromano.skylark", category: "pipeline")
    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "pipeline")

    public init(
        capture: any AudioCapturing,
        transcriber: any Transcriber,
        injector: any TextInjecting,
        endpointer: (any SpeechEndpointer)? = nil,
        hint: TranscriptionHint = .none,
        cleaners: CleanerRegistry = CleanerRegistry(),
        modeProvider: any ModeProviding = InMemoryModeProvider(),
        dictionary: any DictionaryProviding = InMemoryDictionaryProvider(),
        frontmostBundleID: @escaping @Sendable () -> String? = { nil },
        focusGuard: CapturedTargetGuard? = nil,
        snippets: (@Sendable () async -> [SnippetRecord])? = nil,
        fieldContextReader: (any FieldContextReading)? = nil,
        commandRunner: (any CommandRunning)? = nil,
        livePreview: (any LivePreviewProviding)? = nil,
        historyRecord: (@Sendable (HistoryRecord, AudioClip) -> Void)? = nil,
        historyUpdate: (@Sendable (HistoryRecord) -> Void)? = nil,
        replaceTimeout: Duration = .seconds(5),
        waitForCleanTimeout: Duration = .seconds(2),
        prePasteCeiling: Duration = .seconds(10)
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.injector = injector
        self.endpointer = endpointer
        self.hint = hint
        self.commandRunner = commandRunner
        self.livePreview = livePreview
        self.cleaners = cleaners
        self.modeProvider = modeProvider
        self.dictionary = dictionary
        self.frontmostBundleID = frontmostBundleID
        self.focusGuard = focusGuard
        self.snippetProvider = snippets
        self.fieldContextReader = fieldContextReader
        self.historyRecord = historyRecord
        self.historyUpdate = historyUpdate
        self.replaceTimeout = replaceTimeout
        self.cleanupTimeout = waitForCleanTimeout
        self.prePasteCeiling = prePasteCeiling
        let (stream, continuation) = AsyncStream<HUDState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        hudStates = stream
        hudContinuation = continuation
        let (notes, noteCont) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(4))
        statusNotes = notes
        noteContinuation = noteCont
        let (lat, latCont) = AsyncStream<DictationLatency>.makeStream(bufferingPolicy: .bufferingNewest(4))
        latencies = lat
        latencyContinuation = latCont
        let (refused, refusedCont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        refusedStarts = refused
        refusedStartContinuation = refusedCont
        let (hfEnded, hfEndedCont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        handsFreeEnded = hfEnded
        handsFreeEndedContinuation = hfEndedCont
        continuation.yield(.idle)
    }

    /// Name the app the NEXT session dictates into, instead of reading the
    /// frontmost app at start (P1-4).
    ///
    /// `open skylark://record/start` activates Skylark before macOS delivers the
    /// URL, so by the time the route runs, the frontmost app IS Skylark: the
    /// session captured Skylark as its target and the transcript was pasted into
    /// Skylark's own window, where the user never sees it. The deep-link route
    /// resolves the real target first and hands it over here. The value applies
    /// to exactly one session and is cleared whether that session starts or not;
    /// `nil` is a no-op (fall back to the frontmost read).
    ///
    /// The regular hotkey path never calls this — its fn-down read is already
    /// correct, and stays untouched.
    public func setPendingTarget(bundleID: String?) {
        pendingTargetBundleID = bundleID
    }

    /// The app calls this when model preparation completes (or fails).
    public func setTranscriberReady(_ ready: Bool) {
        transcriberReady = ready
    }

    /// Swap the active transcriber (menu-bar Speech Engine quick-switch). Takes
    /// effect on the next dictation; the ready-gate is managed separately.
    public func setTranscriber(_ transcriber: any Transcriber) {
        self.transcriber = transcriber
    }

    /// Swap the local-tier cleaner (Settings "Local cleanup engine" picker —
    /// Apple Foundation Models vs. a Qwen GGUF). Takes effect on the next
    /// dictation; raw/cloud tiers and the degrade chain are unaffected.
    public func setLocalCleaner(_ cleaner: any Cleaner) {
        cleaners = cleaners.withLocal(cleaner)
    }

    /// Temporary global cleanup override from the menu bar. `nil` = Auto (use the
    /// resolved mode's tier); a value forces that tier for every dictation.
    public func setTierOverride(_ tier: CleanupTier?) {
        tierOverride = tier
    }

    /// Cleanup timeout (Settings → General). A value caps how long a paste waits
    /// for cleanup before falling back (to local, then raw); `nil` disables the
    /// cap so the paste waits for cleanup however long it takes. Takes effect on
    /// the next dictation.
    public func setCleanupTimeout(_ timeout: Duration?) {
        cleanupTimeout = timeout
    }

    /// Set the global cleanup intensity (Settings → General, Cleanup
    /// section). Takes effect on the next dictation's `buildSetup`.
    public func setCleanupIntensity(_ intensity: CleanupIntensity) {
        cleanupIntensity = intensity
    }

    /// Toggle the spoken "press enter" command (Settings → General).
    public func setPressEnterEnabled(_ enabled: Bool) {
        pressEnterEnabled = enabled
    }

    /// Whisper-mode-aware silence floor for the push-to-talk no-speech guard;
    /// pushed by `applyWhisperTuning` alongside the engines' clip-skip floors.
    public func setSilencePeakThreshold(_ threshold: Float) {
        silencePeakThreshold = threshold
    }

    /// Enable/disable the finalize-path VAD trim (WS2). Exists for tests and the
    /// diagnostics kill switch; there is no Settings control (see `vadTrimEnabled`).
    public func setVadTrimEnabled(_ enabled: Bool) {
        vadTrimEnabled = enabled
    }

    /// Toggle Whisper Mode post-capture clip normalization. Pushed by
    /// `applyWhisperTuning` (whisper on ⇒ true). Applies to the next dictation.
    public func setWhisperNormalizationEnabled(_ enabled: Bool) {
        whisperNormalizationEnabled = enabled
    }

    /// Toggle context-aware cleanup (Settings → General). Applies to the next
    /// recording; no effect without a wired `fieldContextReader`.
    public func setContextAwareCleanupEnabled(_ enabled: Bool) {
        contextAwareCleanupEnabled = enabled
    }

    /// Toggle the live transcription preview (Settings → General, Recording
    /// indicator). Prototype, default off. Only takes effect when the active
    /// engine is Parakeet and a `livePreview` provider is wired; otherwise the
    /// flag is stored but no preview renders. Never affects the batch paste path.
    public func setLivePreviewEnabled(_ enabled: Bool) {
        livePreviewEnabled = enabled
    }

    /// Set (or clear) the translation target (Settings → General). `nil` = off.
    /// Resets the one-time raw-tier note so toggling translation back on can warn
    /// again if there's still no cleanup model.
    public func setTranslateTo(_ code: String?) {
        translateTo = code
        translationNeedsCleanupNoteShown = false
    }

    /// Wire (or clear) the deep-vocabulary rescorer (Settings → Dictionary).
    /// nil disables the stage entirely; the app layer also unloads the model.
    public func setRescorer(_ rescorer: (any DeepVocabularyRescoring)?) {
        self.rescorer = rescorer
    }

    /// Wire (or clear) the AX-settle signal that drives correction auto-learn.
    /// Set once by the app layer after launch; nil in tests/headless callers.
    public func setCorrectionSettled(_ handler: (@Sendable (InsertionToken, String) -> Void)?) {
        correctionSettled = handler
    }

    /// Notify the app layer that an AX insertion settled, so it can start the
    /// bounded correction watcher. Paste tokens carry no AX re-read signal and
    /// are ignored. Cheap and non-blocking (the handler just schedules work).
    private func fireCorrectionSettled(_ token: InsertionToken, finalText: String) {
        guard let correctionSettled, case .ax = token.method else { return }
        correctionSettled(token, finalText)
    }

    /// Consume hotkey events until the stream ends.
    public func run(events: AsyncStream<HotkeyEvent>) async {
        for await event in events {
            await handle(event)
        }
    }

    /// Handle a single hotkey event. Public for unit tests.
    public func handle(_ event: HotkeyEvent) async {
        switch event {
        case .startRecording:
            startRecording(kind: .dictation)
        case .stopRecording:
            await finishRecording()
        case .cancel, .discard:
            cancelRecording()
        case .engageHandsFree:
            engageHandsFree()
        case .startCommand:
            startRecording(kind: .command)
        case .stopCommand:
            await finishCommand()
        case .captureInterrupted:
            await handleCaptureInterruption(CaptureInterruption(reason: .triggerTapStalled))
        case .permissionLost:
            await handleCaptureInterruption(CaptureInterruption(reason: .permissionLost))
        }
    }

    // MARK: - Transitions

    private func startRecording(kind: SessionKind) {
        // Consume any deep-link target first, whatever happens next: a refused
        // start must never leave a stale target behind for the next hotkey
        // session (which captures the frontmost app itself).
        let deepLinkTarget = pendingTargetBundleID
        pendingTargetBundleID = nil
        guard phase == .idle else {
            // U5: a press while the PREVIOUS utterance is still processing used
            // to be swallowed in silence — no capture started, and the release
            // that followed was dropped too, so the whole second utterance
            // vanished with no feedback. Refuse cleanly and say so; nothing is
            // queued (starting capture mid-processing would snapshot the wrong
            // target and the user has no way to know which utterance is live).
            // Deliberately does NOT publish: the HUD must keep showing the
            // in-flight session's Processing state.
            logger.notice("start ignored — previous dictation still processing")
            noteContinuation.yield(Self.stillProcessingNote)
            refusedStartContinuation.yield(())
            return
        }
        // Command mode needs a runner; refuse early (nothing destructive) rather
        // than record an instruction we can't act on.
        if kind == .command, commandRunner == nil {
            logger.notice("command mode attempted but no runner wired; ignored")
            noteContinuation.yield("Command mode isn't available")
            publish(.idle)
            return
        }
        guard transcriberReady else {
            logger.notice("dictation attempted before model ready; discarded")
            noteContinuation.yield("Speech model still preparing…")
            publish(.idle)
            return
        }
        do {
            try capture.start()
        } catch {
            logger.error("capture.start failed: \(error.localizedDescription, privacy: .public)")
            // Capture cleans its own tap up on the throw path, so nothing leaks
            // here — but the press must not fail silently.
            noteContinuation.yield(Self.captureFailedNote)
            publish(.idle)
            return
        }
        phase = .recording
        sessionKind = kind
        isHandsFree = false
        sessionInterruption = nil
        cancelRequested = false
        writeCommitted = false
        startInterruptionForwarding()
        // Capture the target app AT dictation start (fn-down) and resolve the
        // mode + dictionary off the paste path while the user speaks. A
        // deep-link start supplies the target explicitly: `open skylark://…`
        // has already made Skylark frontmost by the time the URL is delivered,
        // so reading frontmost here would capture Skylark itself (P1-4).
        let bundleID = deepLinkTarget ?? frontmostBundleID()
        capturedTarget = CapturedTarget(bundleID: bundleID)
        captureTargetWindow(bundleID: bundleID)
        sessionSetup = nil
        setupTask?.cancel()
        setupTask = Task { [modeProvider, dictionary, snippetProvider, cleanupIntensity, translateTo] in
            await Self.buildSetup(bundleID: bundleID, modeProvider: modeProvider, dictionary: dictionary, snippets: snippetProvider, intensity: cleanupIntensity, translateTo: translateTo)
        }
        // Context-aware cleanup (opt-in): read the on-screen text around the caret
        // now, while the user speaks — detached, off the audio/paste path. The
        // result is consumed at cleanup time ONLY if it has arrived; it must never
        // delay Fn-up→paste, so it is never awaited on the pipeline path.
        fieldContextSession &+= 1
        capturedFieldContext = nil
        fieldContextTask?.cancel()
        fieldContextTask = nil
        if contextAwareCleanupEnabled, let fieldContextReader {
            let session = fieldContextSession
            fieldContextTask = Task { [weak self] in
                let context = await fieldContextReader.readFieldContext(
                    bundleID: bundleID,
                    precedingLimit: FieldContext.precedingLimit,
                    followingLimit: FieldContext.followingLimit
                )
                await self?.storeFieldContext(context, session: session)
            }
        }
        // Live transcription preview (prototype, off the paste path). No-op
        // unless enabled AND the engine is Parakeet AND a provider is wired.
        lastLevel = 0
        currentPreview = nil
        startLivePreview()
        publish(listeningState(level: 0))
        startLevelForwarding()
    }

    // MARK: - Live preview (prototype)

    /// Spin up a live-preview session for the current recording, if enabled and
    /// supported. Everything here is additive and off the Fn-up→paste path: the
    /// batch decode of the full clip still produces the pasted text unchanged.
    private func startLivePreview() {
        guard livePreviewEnabled,
              sessionKind == .dictation,
              transcriber.id == .parakeet,
              let livePreview
        else { return }

        // Enable the gated preview-frame tap and invalidate any prior setup.
        capture.setPreviewWanted(true)
        previewSetupID &+= 1
        let setupID = previewSetupID
        // Session creation (loading a sliding-window manager over the SHARED warm
        // models) runs off the recording path in its own Task; frames captured
        // before it's ready are simply dropped.
        Task { [weak self, livePreview] in
            guard let session = await livePreview.makeSession() else {
                await self?.livePreviewSetupFailed(setupID: setupID)
                return
            }
            await self?.attachLivePreview(session, setupID: setupID)
        }
    }

    /// Attach a freshly created preview session: begin feeding it captured frames
    /// and pumping its interim text into the HUD. Discards the session if the
    /// recording already ended (or a newer one started) while it was loading.
    private func attachLivePreview(_ session: any LivePreviewSession, setupID: Int) {
        guard phase == .recording, sessionKind == .dictation, setupID == previewSetupID else {
            Task { await session.finish() }
            return
        }
        previewSession = session
        previewFeedTask = Task { [capture] in
            for await frame in capture.previewFrames {
                if Task.isCancelled { break }
                await session.feed(frame)
            }
        }
        previewPumpTask = Task { [weak self] in
            for await update in session.updates {
                if Task.isCancelled { break }
                await self?.applyLivePreview(update, setupID: setupID)
            }
        }
    }

    private func livePreviewSetupFailed(setupID: Int) {
        guard setupID == previewSetupID else { return }
        // Nothing to preview this session; clear the gate if still recording.
        if phase != .recording { capture.setPreviewWanted(false) }
    }

    /// Fold a preview-text update into the `.listening` HUD state. Guarded so a
    /// late update from a torn-down session can't repaint the pill.
    private func applyLivePreview(_ preview: TranscriptPreview, setupID: Int) {
        guard phase == .recording, sessionKind == .dictation, setupID == previewSetupID else { return }
        currentPreview = preview
        publish(listeningState(level: lastLevel))
    }

    /// Tear down the preview session promptly (recording ended or cancelled).
    /// Cancels feed/pump, invalidates in-flight setup, disables the frame tap,
    /// and clears the interim text. Called BEFORE the batch decode so the
    /// streaming decoder stops touching the shared models first.
    private func stopLivePreview() {
        previewSetupID &+= 1
        previewFeedTask?.cancel()
        previewFeedTask = nil
        previewPumpTask?.cancel()
        previewPumpTask = nil
        if let session = previewSession {
            previewSession = nil
            Task { await session.finish() }
        }
        capture.setPreviewWanted(false)
        currentPreview = nil
    }

    /// Store the AX-read field context for the current recording. Rejected when a
    /// newer recording started meanwhile (stale read), so context never bleeds
    /// across sessions.
    private func storeFieldContext(_ context: FieldContext?, session: Int) {
        guard session == fieldContextSession else { return }
        capturedFieldContext = context
    }

    /// The listening HUD state for the active session kind (command mode renders
    /// a distinct pill).
    private func listeningState(level: Float) -> HUDState {
        sessionKind == .command
            ? .commandListening(level: level)
            : .listening(
                level: level,
                preview: currentPreview,
                // One relaxed atomic read; nil until the capture buffer is
                // within its warning window of the hard cap.
                capSecondsRemaining: capture.capCountdown()
            )
    }

    /// Arm VAD endpointing for a hands-free (double-tap-lock) session. If VAD is
    /// unavailable the session still works via a second double-tap stop.
    private func engageHandsFree() {
        guard phase == .recording, !isHandsFree else { return }
        isHandsFree = true
        guard let endpointer else { return }
        capture.setFramesWanted(true)
        vadTask?.cancel()
        vadTask = Task { [weak self, capture, endpointer] in
            guard await endpointer.available() else { return }
            await endpointer.beginSession()
            for await frame in capture.frames {
                if Task.isCancelled { break }
                if await endpointer.feed(frame) {
                    // Unstructured on purpose: finishRecording runs stopHandsFree,
                    // which cancels THIS task — an awaited call here would poison
                    // the rest of the finalize with that cancellation (the cloud
                    // transcribe's URLSession throws CancellationError and the
                    // whole endpointed session is dropped). A fresh Task does not
                    // inherit this task's cancellation.
                    Task { [weak self] in await self?.handle(.stopRecording) }
                    break
                }
            }
        }
    }

    private func finishRecording() async {
        guard phase == .recording else { return }
        // Snapshot before stopHandsFree() resets it — the silence check below
        // only applies to push-to-talk clips (hands-free is VAD-endpointed,
        // speech by construction).
        let wasHandsFree = isHandsFree
        stopHandsFree()
        // The stop may have come from VAD/the cap rather than a trigger tap, in
        // which case the hotkey layer still holds its double-tap lock — tell it
        // the session is over (idempotent when a tap already released it).
        if wasHandsFree { handsFreeEndedContinuation.yield(()) }
        // Tear down the live preview FIRST: stop feeding/pumping and cancel the
        // streaming decoder before the batch decode runs, so the two never
        // contend for the shared models and the latency metric below is clean.
        stopLivePreview()

        // Fn-up → text-inserted is THE latency metric.
        let t0 = ContinuousClock.now
        let interval = signposter.beginInterval("fnup_to_inserted")
        defer { signposter.endInterval("fnup_to_inserted", interval) }

        var clip = capture.stop()
        let afterCapture = ContinuousClock.now
        phase = .transcribing
        publish(.processing)

        // THE finalize decision (WS1): every interruption signal converges here
        // and every trim of the captured audio happens here, for both push-to-talk
        // and hands-free.
        let finalization = await resolveFinalization(clip)
        clip = finalization.clip
        // Cancellation checkpoint (P1-3). The VAD scan above can take a few ms
        // and an Esc during it must not be dropped.
        if honorCancelIfRequested() { return }

        guard !clip.isEmpty else {
            phase = .idle
            publish(.idle)
            if finalization.interrupted { noteContinuation.yield(Self.interruptedNote(for: finalization)) }
            return
        }

        // Push-to-talk only: a mic that heard nothing must never reach the
        // transcriber (never mind paste whatever it hallucinates from
        // silence). Cheap O(n) pass over samples already in memory, off the
        // audio thread (this actor). Quiet-but-real speech and too-short
        // clips both fall through to transcription (false-negative bias).
        if !wasHandsFree, SilenceDetector.isSilent(clip, threshold: silencePeakThreshold) {
            phase = .idle
            publish(.idle)
            // An interruption explains the silence better than "nothing heard".
            noteContinuation.yield(
                finalization.interrupted ? Self.interruptedNote(for: finalization) : "No speech detected"
            )
            return
        }

        // Something took the mic mid-utterance: the text we're about to insert may
        // be missing its tail, so say so (never block the insert on it).
        if finalization.interrupted {
            noteContinuation.yield(Self.interruptedNote(for: finalization))
        }

        // Whisper Mode only: normalize the finalized clip's peak up toward a
        // healthy target before transcription. Deliberately AFTER the silence
        // guard above (which judges the RAW tap-gained clip with the whisper
        // threshold, so a boosted whisper can't wrongly clear it) and AFTER any
        // VAD endpointing decision (hands-free VAD already saw the tap-gained
        // signal; this only rescales what the transcriber hears, never re-runs
        // endpointing). Off the audio thread (this actor); no-op when off.
        if whisperNormalizationEnabled {
            clip = normalizeWhisperClip(clip)
        }

        let text: String
        do {
            text = try await transcriber.transcribe(clip, hint: hint)
        } catch {
            logger.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            phase = .idle
            publish(.idle)
            return
        }
        // The decode is the longest await in the window a cancel has to land in
        // (local ≈180 ms, cloud STT 350–680 ms): the single most important
        // checkpoint of the fix.
        if honorCancelIfRequested() { return }
        // Deep-vocabulary side channel: grab THIS utterance's TDT token timings
        // right after decode (before a later dictation can overwrite the engine's
        // stash), to feed the detached rescorer. Gated so a disabled feature — or
        // any non-Parakeet engine — adds nothing to the paste path. The rescore
        // itself runs later, detached (never on fn-up→paste).
        let rescoreTimings: [TranscriptTiming]?
        if rescorer != nil, transcriber.id == .parakeet {
            rescoreTimings = await transcriber.lastTokenTimings()
        } else {
            rescoreTimings = nil
        }

        let afterTranscribe = ContinuousClock.now

        // Empty transcript → no injection at all (nothing to paste).
        guard !text.isEmpty else {
            phase = .idle
            publish(.idle)
            return
        }

        // Resolve the session setup (usually already prepared during recording).
        let setup = await resolvedSetup()
        if honorCancelIfRequested() { return }
        // Merge the (off-path) field-context read into the cleanup context. nil
        // when the toggle is off or the read hadn't finished by now — cleanup then
        // behaves exactly as before. Read here, never awaited: absence just means
        // no context for this dictation, never a delayed paste.
        let cleanupContext = setup.context.withFieldContext(capturedFieldContext)
        // Dictionary correction is part of the raw text — always applied, even
        // Tier 0 (PRD §8). Off-path regex compile happened in setup; this is the
        // ≤5 ms apply.
        let corrected = setup.corrector.apply(text)
        let effectiveTier = tierOverride ?? setup.mode.cleanupTier

        // Translation needs a cleanup model to run. When it's on but the resolved
        // tier is raw (no cleanup stage), dictation proceeds UNtranslated — never
        // blocked — and we surface a one-time note. The context still carries
        // `translateTo`, but `RawPassthrough` ignores it, so the text is untouched.
        if translateTo != nil, effectiveTier == .raw, !translationNeedsCleanupNoteShown {
            translationNeedsCleanupNoteShown = true
            noteContinuation.yield("Translation needs a cleanup model.")
        }

        // Spoken "press enter": strip the terminal command before injection and
        // remember to synthesize Return after the final text lands. `rawText`
        // stays a `let` — the detached AX-replace Task below captures it, and a
        // `var` capture would make that closure non-Sendable.
        let stripped = pressEnterEnabled ? PressEnterCommand.strip(corrected) : (text: corrected, pressEnter: false)
        let rawText = stripped.text
        let pressEnter = stripped.pressEnter

        // Snippet expansion: a whole-utterance trigger inserts its saved text
        // verbatim — no cleanup stage (the replacement is already final).
        let snippetReplacement = SnippetMatcher.match(text: rawText, snippets: setup.snippets)

        // P1-6: the pair of contexts this utterance's cleanup may use. A CLOUD
        // request carries only the dictionary terms this transcript plausibly
        // contains; a local one (including the post-timeout fallback) keeps the
        // full list, because nothing leaves the machine there.
        let contexts = cleanupContexts(cleanupContext, entries: setup.entries, tier: effectiveTier, transcript: rawText)

        phase = .injecting

        // Stamp the dictation now so a late clean-text update correlates back to
        // this exact history row (HistoryHub keys by timestamp).
        let historyTimestamp = Date()
        // Clean text known synchronously (paste wait-for-clean path only); the AX
        // path learns it later and updates the record then.
        var syncCleanText: String?
        // Which cleanup engine produced the final text ("raw"/"local"/slug/
        // "snippet"); nil on the AX path until the detached replace lands.
        var syncCleanupEngine: String?
        // If a synchronous insertion landed in an AX-verified field, remember it
        // so the correction watcher can start after the latency measurement (off
        // the paste path). The async AX-cleanup path fires its own settle signal
        // from `runCleanupAndReplace`. Snippets (verbatim expansions) aren't
        // watched — a user edit there isn't a dictation correction.
        var settledToken: InsertionToken?
        var settledFinalText: String?
        // Diagnostics summary (content-free): how the text landed and which
        // cleanup engine actually ran. "detached" = the AX in-place path where
        // cleanup runs after the paste-measurement (its own log line lands when
        // it resolves); "none" = nothing inserted (bare "press enter").
        var injectMethod = "none"
        var cleanupEngineRan = "none"

        // Captured-target focus guard (WS3): don't type into the wrong app — or
        // the wrong window of the right app. Evaluated here so a lost target
        // skips the cleanup stage entirely, and RE-evaluated immediately before
        // every write below (`guardedInsert`) and before the Return: cleanup can
        // take seconds, and a verdict taken before it says nothing about where a
        // keystroke is about to land.
        let initialVerdict = await focusVerdict()
        var focusLost = initialVerdict.lost

        /// Book the diagnostics for a write the guard refused. Synchronous — the
        /// refusal itself is decided by `guardedInsert` (an actor method), so
        /// nothing crosses an isolation boundary here.
        func recordRefusal(_ verdict: FocusVerdict) {
            focusLost = true
            injectMethod = "aborted-focus"
            noteContinuation.yield(verdict.note)
        }

        if focusLost {
            // Abort every write (text AND the "press enter" Return — a stray
            // Return in the wrong app can send a message). The transcript is not
            // lost: the history row below is still emitted, exactly like the
            // replace-failure path keeps its text and reports the degrade.
            injectMethod = "aborted-focus"
            cleanupEngineRan = "skipped"
            noteContinuation.yield(initialVerdict.note)
        } else if let snippetReplacement {
            syncCleanText = snippetReplacement
            syncCleanupEngine = "snippet"
            cleanupEngineRan = "snippet"
            let write = await guardedInsert(snippetReplacement)
            if write.cancelled { return abortCancelledSession(stage: "injecting") }
            if let refusal = write.refusal {
                recordRefusal(refusal)
            } else if let token = write.token {
                injectMethod = Self.methodString(token)
            }
        } else if rawText.isEmpty {
            // The whole utterance was the "press enter" command — nothing to
            // insert; the Return below is the entire action.
        } else if effectiveTier == .raw {
            // Tier 0: raw stands, no cleanup stage.
            syncCleanupEngine = "raw"
            cleanupEngineRan = "raw"
            let write = await guardedInsert(rawText)
            if write.cancelled { return abortCancelledSession(stage: "injecting") }
            if let refusal = write.refusal {
                recordRefusal(refusal)
            } else if let token = write.token {
                settledToken = token
                settledFinalText = token.text
                injectMethod = Self.methodString(token)
            }
        } else if pressEnter {
            // Return must land after the FINAL text: the detached AX replace
            // would race the keystroke (a chat message would send, then get
            // edited), so wait for clean here even on AX targets.
            let cleaner = cleaners.cleaner(for: effectiveTier)
            let outcome = await cleanForPaste(cleaner, tier: effectiveTier, text: rawText, contexts: contexts)
            if let outcome {
                syncCleanupEngine = outcome.engine
                if outcome.text != rawText { syncCleanText = outcome.text }
            }
            cleanupEngineRan = outcome?.engine ?? "raw"
            let final = outcome?.text ?? rawText
            // Cleanup just ran (up to the pre-paste ceiling) — the guard and the
            // cancellation check are both re-run inside `guardedInsert`.
            let write = await guardedInsert(final)
            if write.cancelled { return abortCancelledSession(stage: "injecting") }
            if let refusal = write.refusal {
                recordRefusal(refusal)
            } else if let token = write.token {
                settledToken = token
                settledFinalText = token.text
                injectMethod = Self.methodString(token)
            }
        } else {
            let direct = await guardedInsert(rawText, direct: true)
            if direct.cancelled { return abortCancelledSession(stage: "injecting") }
            if let refusal = direct.refusal {
                // The guard refused the write (focus moved between the verdict
                // above and this instant) — nothing was typed, and there is no
                // fallback path to try: a paste would land in the same wrong place.
                recordRefusal(refusal)
            } else if let token = direct.token {
                // The AX write landed VERIFIED — raw is on screen (latency bar);
                // replace with cleaned text after cleanup, detached from the HUD
                // state. Routing on the actual insert (not a capability probe)
                // matters: Chrome claims writable AX selection but silently drops
                // writes, which previously pasted raw here and lost the cleanup.
                let cleaner = cleaners.cleaner(for: effectiveTier)
                let detachedContexts = contexts
                // Only the detached AX path rescores: it already replaces in place, so
                // the deep-vocabulary pass and the cleanup share one final replacement
                // (never a second one, never any paste-path cost). rescoreTimings is
                // nil unless the feature is on and this was a Parakeet utterance.
                let rescoreSamples = rescoreTimings != nil ? clip.samples : []
                let tier = effectiveTier
                injectMethod = Self.methodString(token)
                cleanupEngineRan = "detached"
                Task { [weak self] in
                    await self?.runCleanupAndReplace(
                        token: token, rawText: rawText, cleaner: cleaner, tier: tier,
                        contexts: detachedContexts, historyTimestamp: historyTimestamp,
                        rescoreSamples: rescoreSamples, rescoreTimings: rescoreTimings
                    )
                }
            } else {
                // No verified in-place target (a paste would be needed): wait-for-
                // clean before inserting (deliberate PRD deviation; select-back is
                // unsafe here). Race the cleaner against a 2 s clock; on timeout/
                // failure inject raw — and say so.
                let cleaner = cleaners.cleaner(for: effectiveTier)
                let outcome = await cleanForPaste(cleaner, tier: effectiveTier, text: rawText, contexts: contexts)
                if let outcome {
                    syncCleanupEngine = outcome.engine
                    if outcome.text != rawText { syncCleanText = outcome.text }
                }
                cleanupEngineRan = outcome?.engine ?? "raw"
                let final = outcome?.text ?? rawText
                let write = await guardedInsert(final)
                if write.cancelled { return abortCancelledSession(stage: "injecting") }
                if let refusal = write.refusal {
                    recordRefusal(refusal)
                } else if let token = write.token {
                    settledToken = token
                    settledFinalText = token.text
                    injectMethod = Self.methodString(token)
                }
            }
        }

        // The Return is the most destructive write of all (it sends the message)
        // and the furthest in time from the first verdict, so it gets its own
        // fresh check rather than riding on the one the text write used.
        if pressEnter, !focusLost {
            // A pasted transcript is only "posted" until the target reads the
            // pasteboard; Return into a target that ignored the paste submits
            // an empty field. confirmedLanding is bounded by the restore
            // ceiling, so this waits at most ~500 ms and usually tens of ms.
            // (A bare "press enter" utterance has no token — Return is the
            // whole action and fires on the focus verdict alone.)
            let landing = await settledToken?.confirmedLanding()
            if landing == .posted || landing == .notPosted {
                noteContinuation.yield("Paste may not have landed — Return not sent")
            } else {
                let returnVerdict = await focusVerdict()
                if returnVerdict.lost {
                    noteContinuation.yield("Focus moved — Return not sent")
                } else {
                    await injector.pressReturn()
                }
            }
        }

        let afterInject = ContinuousClock.now
        let summary = recordLatency(
            captureClose: t0.duration(to: afterCapture),
            transcribe: afterCapture.duration(to: afterTranscribe),
            inject: afterTranscribe.duration(to: afterInject),
            total: t0.duration(to: afterInject)
        )

        // Content-free per-dictation summary for diagnostics export: which
        // engine/tier ran, how the text landed, and total latency. Never any
        // transcript text — only ids, counts, and the resolved routing.
        logger.notice("""
            dictation summary — stt: \(Self.engineString(self.transcriber.lastRunID), privacy: .public), \
            clip-ms: \(Int((clip.duration * 1000).rounded()), privacy: .public), \
            tier: \(Self.tierString(effectiveTier), privacy: .public), \
            cleanup-ran: \(cleanupEngineRan, privacy: .public), \
            inject: \(injectMethod, privacy: .public), \
            latency-ms: \(summary.totalMs, format: .fixed(precision: 1), privacy: .public)
            """)

        // A bare "press enter" (no remaining text, no snippet) inserts nothing —
        // don't record an empty history row for it.
        if snippetReplacement != nil || !rawText.isEmpty {
            emitHistory(
                timestamp: historyTimestamp,
                rawText: rawText,
                cleanText: syncCleanText,
                cleanupEngine: syncCleanupEngine,
                modeID: setup.mode.id,
                durationSec: clip.duration,
                latencyMs: summary.totalMs,
                clip: clip
            )
        }

        // Off the latency path now: let the app layer start the correction
        // watcher for a synchronous AX-verified insertion. No-op unless the
        // feature is wired and the insertion landed via AX.
        if let settledToken, let settledFinalText {
            fireCorrectionSettled(settledToken, finalText: settledFinalText)
        }

        phase = .idle
        publish(.idle)
    }

    // MARK: - Interruption model (WS1)

    /// Long-lived consumer of `capture.interruptions` (same shape as the levels
    /// consumer: an `AsyncStream` is single-consumer, so re-iterating it per
    /// dictation would starve the 2nd+ session).
    private func startInterruptionForwarding() {
        guard interruptionsTask == nil else { return }
        interruptionsTask = Task { [capture, weak self] in
            for await interruption in capture.interruptions {
                if Task.isCancelled { break }
                await self?.handleCaptureInterruption(interruption)
            }
        }
    }

    /// Record an interruption for the current session and, when it means capture
    /// can't continue (`finalizesUtterance`), finish the utterance at THIS
    /// boundary — the whole point of WS1: never let a stolen mic pad the clip
    /// with silence the transcriber will then drop. Nothing is discarded; the
    /// samples captured so far go through the normal pipeline, plus a note.
    private func handleCaptureInterruption(_ interruption: CaptureInterruption) async {
        guard phase == .recording else { return }
        if sessionInterruption == nil { sessionInterruption = interruption }
        logger.notice("""
            capture interrupted (\(interruption.reason.rawValue, privacy: .public)) \
            \(interruption.reason.finalizesUtterance ? "— finalizing at the boundary" : "— recording continues", privacy: .public)
            """)
        guard interruption.reason.finalizesUtterance else { return }
        let permissionLost = interruption.reason == .permissionLost
        switch sessionKind {
        case .dictation: await finishRecording()
        case .command: await finishCommand()
        }
        // Last note wins in the menu bar, so this goes AFTER the finalize: without
        // Accessibility the insertion can't reach the target app, and the generic
        // "text may be incomplete" note would leave the user hunting for text that
        // was never pasted. Named explicitly so the remedy is obvious.
        if permissionLost {
            noteContinuation.yield(Self.permissionLostNote)
        }
    }

    /// What the finalize step decided about a captured clip.
    private struct Finalization {
        /// The audio that goes to STT (trimmed, if anything was trimmed).
        var clip: AudioClip
        /// Any interruption signal fired → the user gets the incomplete-text note.
        var interrupted: Bool
        /// Dead tail removed before STT.
        var trimmed: TimeInterval
        /// The session ended because capture hit its hard cap. Interrupted, yes,
        /// but by a designed limit — so it gets its own notice (P1-2b).
        var capReached = false
    }

    /// The note for an interrupted finalize. The 2-minute cap is a limit, not a
    /// mic fault, so it must never surface as "Mic interrupted".
    private static func interruptedNote(for finalization: Finalization) -> String {
        finalization.capReached ? capReachedNote : interruptedNote
    }

    /// The ONE place a finalized clip is decided. Five independent signals
    /// converge here:
    ///
    /// 1. `sessionInterruption` — hotkey tap stalled mid-hold, or capture failed
    ///    to restart (both already finalized the session; this is the record).
    /// 2. `clip.interruption` — `AVAudioEngineConfigurationChange` during capture
    ///    (restart preserved the recording, so the marker is all that's left).
    /// 3. `clip.tapStalled` — wall-clock ≫ sample duration: the tap stopped
    ///    delivering with NO silent tail to detect (samples just stop).
    /// 4. `TrailingSilenceAnalyzer` (WS1) — "energy early, long dead tail": the
    ///    speech-then-silence clip an interruption leaves behind. Trims the DEAD
    ///    tail, and is the only signal that also raises the interruption note.
    /// 5. `VadClipTrimmer` over a Silero scan (WS2) — trims the QUIET head and
    ///    tail a human leaves around an utterance. See `vadTrim`.
    ///
    /// Signals 1–4 are a pure decision + one O(n) prefix copy: no I/O, no locks,
    /// nothing that can block the fn-up→paste path. On a clean clip the analyzer
    /// finds nothing to trim and they return the input unchanged.
    ///
    /// Signal 5 is the one step here that isn't pure, so it is gated and bounded
    /// (short clips and a non-resident model skip it outright, before any await)
    /// and it may only ever shrink pauses, never veto an utterance.
    private func resolveFinalization(_ clip: AudioClip) async -> Finalization {
        var interrupted = false
        var reasons: [String] = []

        if let session = sessionInterruption {
            interrupted = true
            reasons.append(session.reason.rawValue)
        }
        if let marker = clip.interruption, marker.reason != sessionInterruption?.reason {
            interrupted = true
            reasons.append(marker.reason.rawValue)
        }
        // The cap is its own reason, never "stalledTap": at the cap the sample
        // count is pinned by design, which the stalled-tap ratio would otherwise
        // read as a dying microphone (P1-2c). `AudioClip.tapStalled` already
        // stands down for a capped clip; this names what actually happened.
        let capReached = clip.capReached || sessionInterruption?.reason == .capReached
        if capReached {
            interrupted = true
            if sessionInterruption?.reason != .capReached { reasons.append("capReached") }
        }
        if clip.tapStalled {
            interrupted = true
            reasons.append("stalledTap")
        }

        var working = clip
        var trimmed: TimeInterval = 0
        if let trace = clip.rms {
            let verdict = TrailingSilenceAnalyzer.analyze(trace, configuration: trailingSilenceConfiguration)
            if verdict.suspectsInterruption {
                interrupted = true
                reasons.append("deadTail")
            }
            if let keep = verdict.keepSamples, keep < working.samples.count {
                let before = working.duration
                working = working.trimmed(toSampleCount: keep)
                trimmed = max(0, before - working.duration)
            }
        }

        // WS2: VAD trim of the quiet head/tail, composed on top of the dead-tail
        // trim above (which already handled the digital-silence case, so the VAD
        // never sees a stolen mic's zeros).
        let vad = await vadTrim(working)
        if vad.trimmed > 0 {
            working = vad.clip
            trimmed += vad.trimmed
            reasons.append("vad")
        }

        // Content-free: reasons, durations and trimmed length only.
        if interrupted || trimmed > 0 {
            logger.notice("""
                capture finalize — interrupted: \(interrupted, privacy: .public) \
                [\(reasons.joined(separator: ","), privacy: .public)], \
                trimmed-ms: \(Int((trimmed * 1000).rounded()), privacy: .public), \
                kept-ms: \(Int((working.duration * 1000).rounded()), privacy: .public), \
                wall-ms: \(Int(((clip.wallDuration ?? 0) * 1000).rounded()), privacy: .public)
                """)
        }
        return Finalization(
            clip: working, interrupted: interrupted, trimmed: trimmed, capReached: capReached
        )
    }

    /// VAD trim of a finalized clip (WS2), for both push-to-talk and hands-free.
    ///
    /// Why this is safe on the fn-up→paste path:
    /// - **Bounded work.** Silero runs on 4096-sample (256 ms) chunks, so the scan
    ///   is ~4 CoreML inferences per second of audio and scales linearly. Measured
    ///   on the M3 Air (`VadClipTrimTests.liveScanLatency`): **3.5 ms for a 5 s
    ///   clip, 8.3 ms for 11.4 s** (≈0.73 ms per second of audio). The same 11.4 s
    ///   real-speech clip lost 1.60 s of head and 1.72 s of tail — 29 % less audio
    ///   for STT to decode. It pays for itself by an order of magnitude; that
    ///   measurement is why the default is ON.
    /// - **Never a cold load.** `available()` reports whether the model is already
    ///   resident and never loads one. Not resident (VAD download pending, load
    ///   failed, no endpointer wired) ⇒ skip, don't wait.
    /// - **Short clips skip entirely**, before any await: under 2 s there is
    ///   nothing worth cutting, and that's the latency-sensitive quick utterance.
    /// - **A failure is a no-op** — `scanSpeechRegions` returns nil, and nil means
    ///   "leave the clip as captured".
    ///
    /// Returns the (possibly identical) clip plus how much was removed.
    private func vadTrim(_ clip: AudioClip) async -> (clip: AudioClip, trimmed: TimeInterval) {
        let configuration = vadTrimConfiguration
        guard vadTrimEnabled,
              let endpointer,
              VadClipTrimmer.isWorthScanning(
                  durationSeconds: clip.duration, configuration: configuration
              ),
              await endpointer.available()
        else { return (clip, 0) }

        let started = ContinuousClock.now
        let state = signposter.beginInterval("vad_trim")
        let regions = await endpointer.scanSpeechRegions(clip.samples)
        signposter.endInterval("vad_trim", state)
        guard let regions else { return (clip, 0) }

        let verdict = VadClipTrimmer.decide(
            regions: regions,
            sampleCount: clip.samples.count,
            sampleRate: clip.sampleRate,
            configuration: configuration,
            // Enables the audible guard: a quiet word the VAD scored as silence
            // is still kept (audit U7). Scans only the head/tail about to be cut,
            // and stops at the first real gap.
            samples: clip.samples
        )
        let scanMs = started.duration(to: .now).milliseconds
        // Content-free: how long the scan took and how much air it removed. Logged
        // for every scan (not just trims) so the paste-path cost stays auditable in
        // the diagnostics export.
        logger.info("""
            vad trim — scan-ms: \(scanMs, format: .fixed(precision: 1), privacy: .public), \
            regions: \(regions.count, privacy: .public), \
            head-ms: \(Int((verdict.headTrimmed * 1000).rounded()), privacy: .public), \
            tail-ms: \(Int((verdict.tailTrimmed * 1000).rounded()), privacy: .public)
            """)

        guard let keep = verdict.keepRange else { return (clip, 0) }
        let trimmedClip = clip.trimmed(toSampleRange: keep)
        return (trimmedClip, max(0, clip.duration - trimmedClip.duration))
    }

    /// VAD-trim configuration for the active mode, with both pads floored at the
    /// current VAD speech padding — the same floor the dead-tail trim uses, so the
    /// two never disagree about how much air to keep.
    private var vadTrimConfiguration: VadClipTrimmer.Configuration {
        VadClipTrimmer.Configuration.default.withPaddingFloor(
            WhisperModeTuning.forWhisperMode(whisperNormalizationEnabled).vadSpeechPadding
        )
    }

    /// Dead-tail configuration for the active mode. The keep-padding floor is the
    /// current VAD speech padding, so a trim never keeps less tail than the VAD
    /// path would (`whisperNormalizationEnabled` mirrors whisper mode — both are
    /// pushed together by `applyWhisperTuning`).
    private var trailingSilenceConfiguration: TrailingSilenceAnalyzer.Configuration {
        TrailingSilenceAnalyzer.Configuration.default.withPaddingFloor(
            WhisperModeTuning.forWhisperMode(whisperNormalizationEnabled).vadSpeechPadding
        )
    }

    // MARK: - Voice Command Mode

    /// Command-mode finish path. Reuses capture + STT exactly (same warm
    /// engines), then makes ONE LLM call (per the active cleanup tier) over the
    /// spoken instruction and the AX selection: replace the selection, or insert
    /// at the cursor when nothing is selected. Deliberately slower than dictation
    /// (an LLM round-trip) but entirely OFF the dictation Fn-up→paste path
    /// (latency invariant §6). A failed LLM call, an empty result, or a raw tier
    /// leaves the user's selection untouched and surfaces a failure note.
    private func finishCommand() async {
        guard phase == .recording, sessionKind == .command else { return }
        stopHandsFree()

        // Same single finalize decision as dictation (a stolen mic truncates a
        // spoken command just as badly), then the command pipeline proceeds.
        let finalization = await resolveFinalization(capture.stop())
        let clip = finalization.clip
        if finalization.interrupted { noteContinuation.yield(Self.interruptedNote(for: finalization)) }
        phase = .transcribing
        publish(.processing)

        guard let commandRunner else {
            finishCommandIdle(note: "Command mode isn't available")
            return
        }
        guard !clip.isEmpty else {
            phase = .idle
            publish(.idle)
            return
        }

        if honorCancelIfRequested() { return }

        let instruction: String
        do {
            instruction = try await transcriber.transcribe(clip, hint: hint)
        } catch {
            logger.error("command transcription failed: \(error.localizedDescription, privacy: .public)")
            finishCommandIdle(note: "Couldn't hear the command")
            return
        }
        if honorCancelIfRequested() { return }
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing said — quietly return to idle (nothing destructive).
            phase = .idle
            publish(.idle)
            return
        }

        // Resolve the tier (override or resolved mode). Raw has no LLM to run:
        // refuse and do nothing destructive (no selection read, no insert).
        let setup = await resolvedSetup()
        if honorCancelIfRequested() { return }
        let tier = tierOverride ?? setup.mode.cleanupTier
        if tier == .raw {
            finishCommandIdle(note: "Command mode needs a cleanup model")
            return
        }

        // Same captured-target guard as dictation: a command rewrites the text of
        // the app (and window) the user spoke to, so refuse (nothing destructive)
        // rather than rewrite a selection in whatever grabbed focus meanwhile.
        if await capturedTargetLost() {
            finishCommandIdle(note: "Focus moved to another app — command not applied")
            return
        }

        // Read the selection BEFORE the LLM call so any failure leaves it as-is.
        // nil = no readable selection → generate text at the cursor.
        let selection = await injector.readSelection()
        if honorCancelIfRequested() { return }

        let outcome: CommandOutcome
        do {
            outcome = try await commandRunner.run(
                instruction: instruction, selection: selection?.text, tier: tier
            )
        } catch {
            logger.error("command run failed: \(error.localizedDescription, privacy: .public)")
            finishCommandIdle(note: "Command failed — selection left unchanged")
            return
        }
        // Surface any degrade marker (e.g. cloud outage served on-device) without
        // blocking the write.
        if let degradeNote = outcome.note { noteContinuation.yield(degradeNote) }
        let result = outcome.text

        phase = .injecting
        // The LLM call above can take seconds — the pre-call verdict is stale by
        // now, so re-check before touching the user's document (same rule as the
        // dictation write path).
        if await capturedTargetLost() {
            finishCommandIdle(note: "Focus moved to another app — command not applied")
            return
        }
        // Last chance to honor a cancel: the LLM round trip above is the longest
        // await in a command session, and rewriting a selection is destructive.
        if honorCancelIfRequested() { return }
        if let selection, !selection.text.isEmpty {
            // Rewrite. When the model echoed the selection unchanged (its
            // "instruction unclear" fallback), there's nothing to write.
            guard result != selection.text else {
                phase = .idle
                publish(.idle)
                return
            }
            switch await injector.replaceSelectionOutcome(selection, with: result) {
            case .replaced:
                commitWrite()
            case .anchorStale:
                // The selection moved while the model ran — writing now would
                // paste over whatever is selected TODAY, so nothing was written.
                noteContinuation.yield("Selection changed — command result not applied")
            case .failed:
                noteContinuation.yield("Couldn't replace the selection")
            }
        } else {
            // Generate at the cursor via the shared verified-insert path.
            if await insertRaw(result) != nil { commitWrite() }
        }

        phase = .idle
        publish(.idle)
    }

    /// Return to idle with a status note (command failure/refusal surface). The
    /// selection is never modified before this is called on a failure path.
    private func finishCommandIdle(note: String) {
        noteContinuation.yield(note)
        phase = .idle
        publish(.idle)
    }

    /// Append a completed dictation to history via the detached sink (off the
    /// paste path; no-op when no sink is wired). Never logs transcript content.
    private func emitHistory(
        timestamp: Date,
        rawText: String,
        cleanText: String?,
        cleanupEngine: String?,
        modeID: String,
        durationSec: TimeInterval,
        latencyMs: Double,
        clip: AudioClip
    ) {
        guard let historyRecord else { return }
        let record = HistoryRecord(
            timestamp: timestamp,
            rawText: rawText,
            cleanText: cleanText,
            modeID: modeID,
            // `lastRunID`, not `id`: a cloud primary that timed out and fell
            // back to local must be recorded as the engine that actually ran.
            engine: Self.engineString(transcriber.lastRunID),
            durationMs: Int((durationSec * 1000).rounded()),
            latencyMs: Int(latencyMs.rounded()),
            audioPath: nil,
            cleanupEngine: cleanupEngine
        )
        historyRecord(record, clip)
    }

    /// Stable engine string for the history row.
    private static func engineString(_ id: TranscriberID) -> String {
        id.historyColumn
    }

    /// Content-free label for how an insertion landed (diagnostics logging).
    private static func methodString(_ token: InsertionToken) -> String {
        switch token.method {
        case .ax: return "ax"
        case .paste: return "paste"
        }
    }

    /// Content-free label for a resolved cleanup tier (diagnostics logging).
    private static func tierString(_ tier: CleanupTier) -> String {
        switch tier {
        case .raw: return "raw"
        case .local: return "local"
        case .cloud(let slug): return "cloud:\(slug)"
        }
    }

    // MARK: - Captured-target focus guard

    /// Why a write was refused at the injection boundary (content-free).
    enum FocusVerdict: Sendable, Equatable {
        /// The captured target still holds focus — write.
        case ok
        /// Focus is in a different APP and couldn't be restored.
        case appMoved
        /// The captured app is frontmost but a different WINDOW of it has focus.
        case windowMoved

        var lost: Bool { self != .ok }

        /// User-facing status note (never any transcript content).
        var note: String {
            switch self {
            case .ok: return ""
            case .appMoved: return "Focus moved to another app — text not pasted, kept in History"
            case .windowMoved: return "Focus moved to another window — text not pasted, kept in History"
            }
        }
    }

    /// The check the injection boundary makes before writing anything: is the
    /// app — and the window — the user dictated INTO still focused? If the app
    /// moved, re-activate it (bounded, ~300 ms) and only inject once it is
    /// verifiably back; if a different window of the same app took focus, refuse
    /// the write (raising a window under the user is worse than not pasting).
    ///
    /// Costs one NSWorkspace frontmost read plus, only when a window identity was
    /// captured, one AX focused-window read bounded by a 200 ms AX messaging
    /// timeout. Nil guard (tests/headless) → never aborts.
    ///
    /// Called immediately before EVERY write and again before the synthesized
    /// Return: cleanup between them can take seconds (cold local model reload, or
    /// no timeout at all), so one verdict can't cover the whole finalize path.
    /// The *detached* cleanup replace needs no guard — `performAXReplace`
    /// re-verifies that the token's element is still focused and no-ops otherwise.
    private func focusVerdict() async -> FocusVerdict {
        guard let focusGuard else { return .ok }
        // Make sure the record-start window read has landed before the first
        // verdict. It started at fn-down and is bounded by a 200 ms AX messaging
        // timeout, so by paste time it has long finished — this await is free in
        // practice and makes the guard deterministic instead of racy for very
        // short utterances. (Actors are reentrant: the read's store hop can run.)
        await capturedTargetTask?.value
        switch await focusGuard.decide(captured: capturedTarget) {
        case .proceed:
            return .ok
        case .reactivated:
            logger.notice("focus guard: captured target re-activated before injection")
            return .ok
        case let .abort(current):
            logger.notice("""
                focus guard: write refused — reason=app-changed \
                frontmost=\(current ?? "nil", privacy: .public) \
                captured=\(self.capturedTarget?.bundleID ?? "nil", privacy: .public)
                """)
            return .appMoved
        case .abortWrongWindow:
            logger.notice("""
                focus guard: write refused — reason=window-changed \
                app=\(self.capturedTarget?.bundleID ?? "nil", privacy: .public)
                """)
            return .windowMoved
        }
    }

    /// Convenience for the paths that only need the boolean (command mode).
    private func capturedTargetLost() async -> Bool {
        await focusVerdict().lost
    }

    /// Resolve the focused WINDOW of the captured app, off the record-start path
    /// (an AX round trip; the HUD must not wait on it). Same detached shape as
    /// the field-context read: if it hasn't landed by paste time, the guard
    /// simply compares bundle IDs, exactly as it did before window identity
    /// existed. No-op without a guard or a captured app.
    private func captureTargetWindow(bundleID: String?) {
        capturedTargetSession &+= 1
        capturedTargetTask?.cancel()
        capturedTargetTask = nil
        guard let focusGuard, let bundleID else { return }
        let session = capturedTargetSession
        capturedTargetTask = Task { [weak self] in
            let target = await focusGuard.captureTarget(bundleID: bundleID)
            await self?.storeCapturedTarget(target, session: session)
        }
    }

    /// Adopt a window identity read for `session`. Dropped when the session moved
    /// on, or when the app changed under the read (the snapshot would describe a
    /// window the user never dictated into).
    private func storeCapturedTarget(_ target: CapturedTarget, session: Int) {
        guard session == capturedTargetSession,
              let current = capturedTarget, current.bundleID == target.bundleID
        else { return }
        capturedTarget = target
    }

    /// Result of a write that went through the focus guard.
    private struct GuardedWrite {
        /// Non-nil when the guard REFUSED the write — nothing was written, and
        /// the caller books `aborted-focus` + the verdict's note.
        var refusal: FocusVerdict?
        /// The insertion token when text landed; nil when the guard refused or
        /// the injector didn't take the write.
        var token: InsertionToken?
        /// The user cancelled before the write — nothing was written and the
        /// caller must abandon the session entirely (P1-3).
        var cancelled = false
    }

    /// Revalidate the captured target, then write. This is the ONLY way the
    /// finalize path inserts text: the guard runs immediately before the write,
    /// never before a cleanup stage that can take seconds.
    ///
    /// It is also the last point at which a cancel can still change the outcome,
    /// so the cancellation check sits here, immediately before the write and
    /// again after the focus verdict's await. Once the injector has taken the
    /// text, `commitWrite` closes the window.
    private func guardedInsert(_ text: String, direct: Bool = false) async -> GuardedWrite {
        if cancelRequested, !writeCommitted { return GuardedWrite(cancelled: true) }
        let verdict = await focusVerdict()
        if cancelRequested, !writeCommitted { return GuardedWrite(cancelled: true) }
        guard !verdict.lost else { return GuardedWrite(refusal: verdict) }
        let token = direct ? await insertDirectRaw(text) : await insertRaw(text)
        if token != nil { commitWrite() }
        return GuardedWrite(token: token)
    }

    /// AX-verified in-place insert attempt (nil = nothing inserted, caller
    /// should wait-for-clean). Failures degrade to nil, never wedge.
    private func insertDirectRaw(_ text: String) async -> InsertionToken? {
        do {
            return try await injector.insertDirect(text)
        } catch {
            logger.error("direct injection failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Insert text, swallowing failures so injection never wedges the state
    /// machine. Returns the token on success.
    @discardableResult
    private func insertRaw(_ text: String) async -> InsertionToken? {
        do {
            return try await injector.insert(text)
        } catch {
            logger.error("injection failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Esc, `skylark://record/cancel`, or a trigger+key chord. Cancel is honored
    /// for the WHOLE session, not just while the mic is open (P1-3):
    ///
    /// - `.recording` — the original path: drop the audio, nothing was decoded.
    /// - `.transcribing` / `.injecting` — the ~180 ms local (350–680 ms cloud)
    ///   processing window. The request is recorded and the finalize path honors
    ///   it at its next checkpoint, tearing the session down with no injection
    ///   and no history row.
    /// - after the text has landed (`writeCommitted`) — nothing to undo: report
    ///   it instead of pretending, and let the session finish normally.
    private func cancelRecording() {
        switch phase {
        case .idle:
            return
        case .recording:
            cancelDuringRecording()
        case .transcribing, .injecting:
            guard !writeCommitted else {
                logger.notice("cancel ignored — text already inserted")
                noteContinuation.yield(Self.cancelTooLateNote)
                return
            }
            cancelRequested = true
            logger.notice("cancel requested during \(Self.stageString(self.phase), privacy: .public)")
        }
    }

    /// Content-free label for the stage a cancel landed in.
    private static func stageString(_ phase: Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .injecting: return "injecting"
        }
    }

    /// Tear down everything a session accumulated, without touching `phase` or
    /// the capture device. Shared by the recording-phase cancel (which also
    /// stops capture) and the processing-phase cancel (where capture is already
    /// closed and the clip is in flight).
    private func teardownSessionState() {
        setupTask?.cancel()
        setupTask = nil
        sessionSetup = nil
        // Drop any in-flight/late field-context read (bump the session so a
        // completing read is ignored) and clear the captured value.
        fieldContextSession &+= 1
        fieldContextTask?.cancel()
        fieldContextTask = nil
        capturedFieldContext = nil
        capturedTargetSession &+= 1
        capturedTargetTask?.cancel()
        capturedTargetTask = nil
        capturedTarget = nil
        sessionInterruption = nil
    }

    /// A cancel that arrived while the mic was still open: nothing was decoded,
    /// so the audio is simply dropped.
    private func cancelDuringRecording() {
        if isHandsFree { handsFreeEndedContinuation.yield(()) }
        stopHandsFree()
        stopLivePreview()
        teardownSessionState()
        cancelRequested = false
        _ = capture.stop() // discard audio
        phase = .idle
        publish(.idle)
    }

    /// Honor a cancel that landed mid-processing. Same teardown as a cancel
    /// during recording, minus the capture stop (already closed): no injection,
    /// no history row, no latency sample — the session never happened. Silent,
    /// exactly like the recording-phase cancel; the HUD dropping back to idle is
    /// the feedback.
    private func abortCancelledSession(stage: String) {
        logger.notice("dictation cancelled during \(stage, privacy: .public)")
        stopLivePreview()
        teardownSessionState()
        cancelRequested = false
        phase = .idle
        publish(.idle)
    }

    /// Checkpoint for the finalize paths: honor a pending cancel, or carry on.
    /// Called after every await that can span the processing window and
    /// immediately before every write (`guardedInsert`).
    private func honorCancelIfRequested() -> Bool {
        guard cancelRequested, !writeCommitted else { return false }
        abortCancelledSession(stage: Self.stageString(phase))
        return true
    }

    /// The write just landed. Anything a cancel could still have prevented is
    /// now on screen, so a request that raced the write is answered honestly
    /// rather than tearing down a session whose text the user can see.
    private func commitWrite() {
        writeCommitted = true
        guard cancelRequested else { return }
        cancelRequested = false
        logger.notice("cancel arrived during the write — text already inserted")
        noteContinuation.yield(Self.cancelTooLateNote)
    }

    // MARK: - Cleanup / mode setup

    /// Everything resolved at dictation start, consumed at paste time.
    struct SessionSetup {
        let mode: DictationMode
        let context: CleanupContext
        let corrector: DictionaryCorrector
        let snippets: [SnippetRecord]
        /// The dictionary as loaded, kept so the cloud-bound term list can be
        /// filtered against the transcript (P1-6). `context.dictionaryTerms`
        /// remains the FULL phrase list — that's what local cleanup gets.
        let entries: [DictionaryEntry]
    }

    /// The cleanup contexts for one utterance.
    ///
    /// `primary` goes to the resolved tier's cleaner; `local` goes to any
    /// on-device fallback. They differ in exactly one field — the dictionary
    /// terms — and only when the primary tier is CLOUD.
    private struct CleanupContexts: Sendable {
        let primary: CleanupContext
        let local: CleanupContext
    }

    /// Build the context pair for this utterance. Local and raw tiers reuse the
    /// same context for both slots (no filtering: nothing leaves the machine).
    /// A cloud tier gets a transcript-filtered dictionary — see
    /// `DictionaryRelevance`; an empty result means no dictionary line at all.
    ///
    /// The filter runs ON the latency path (it gates the cloud request, so it
    /// cannot be deferred) and is deliberately cheap: one tokenization of the
    /// transcript plus length-bucketed fuzzy lookups.
    private func cleanupContexts(
        _ context: CleanupContext, entries: [DictionaryEntry], tier: CleanupTier, transcript: String
    ) -> CleanupContexts {
        guard case .cloud = tier, !entries.isEmpty else {
            return CleanupContexts(primary: context, local: context)
        }
        let relevant = DictionaryRelevance.relevantPhrases(entries: entries, transcript: transcript)
        // Content-free: counts only, never the terms themselves.
        logger.info("""
            cloud dictionary filter — sent: \(relevant.count, privacy: .public) \
            of \(entries.count, privacy: .public)
            """)
        return CleanupContexts(primary: context.withDictionaryTerms(relevant), local: context)
    }

    /// Resolve mode + dictionary + snippets off the paste path (compiles
    /// correction regexes here, not on the latency path). Runs during recording
    /// via `setupTask`.
    private static func buildSetup(
        bundleID: String?,
        modeProvider: any ModeProviding,
        dictionary: any DictionaryProviding,
        snippets snippetProvider: (@Sendable () async -> [SnippetRecord])?,
        intensity: CleanupIntensity,
        translateTo: String?
    ) async -> SessionSetup {
        let modes = (try? await modeProvider.modes()) ?? []
        let mode = ModeResolver.resolve(bundleID: bundleID, modes: modes)
        let entries = (try? await dictionary.entries()) ?? []
        let context = CleanupContext(
            targetAppBundleID: bundleID,
            registerHint: mode.registerHint,
            // Every correct-spelling phrase is protected during recognition.
            dictionaryTerms: entries.map(\.phrase),
            intensity: intensity,
            translateTo: translateTo
        )
        let corrector = DictionaryCorrector(entries: entries)
        let snippets = await snippetProvider?() ?? []
        return SessionSetup(mode: mode, context: context, corrector: corrector, snippets: snippets, entries: entries)
    }

    /// The setup for the active session — the prepared one if ready, else built
    /// inline (very short utterances that finish before `setupTask`).
    private func resolvedSetup() async -> SessionSetup {
        if let sessionSetup { return sessionSetup }
        let setup: SessionSetup
        if let setupTask {
            setup = await setupTask.value
        } else {
            setup = await Self.buildSetup(bundleID: frontmostBundleID(), modeProvider: modeProvider, dictionary: dictionary, snippets: snippetProvider, intensity: cleanupIntensity, translateTo: translateTo)
        }
        sessionSetup = setup
        return setup
    }

    /// Run the cleaner on `rawText` (capped at the cleanup timeout) and, on a
    /// changed result, replace the AX-inserted range in place. A slow cloud
    /// degrades to local cleanup; if even that yields nothing, raw stands and a
    /// note says so (no longer a silent keep).
    private func runCleanupAndReplace(
        token: InsertionToken,
        rawText: String,
        cleaner: any Cleaner,
        tier: CleanupTier,
        contexts: CleanupContexts,
        historyTimestamp: Date,
        rescoreSamples: [Float] = [],
        rescoreTimings: [TranscriptTiming]? = nil
    ) async {
        // Deep-vocabulary pass (optional; detached, off the paste path). Rescore
        // the raw text FIRST, then feed the (possibly corrected) text to cleanup.
        // Any failure returns nil → we keep rawText (optional-stage invariant).
        var sourceText = rawText
        if let rescorer, let rescoreTimings, !rescoreSamples.isEmpty,
           let rescored = await rescorer.rescore(rawText: rawText, samples: rescoreSamples, timings: rescoreTimings) {
            sourceText = rescored
        }

        // The DETACHED path is the one place "Off" still means unbounded: the raw
        // text is already on screen, so a long cleanup delays nothing the user is
        // waiting for. (Contrast `cleanForPaste`, which is capped — see
        // `prePasteCleanupCeiling`.)
        var outcome = await cleanWithTimeout(cleaner, sourceText, context: contexts.primary, cap: cleanupTimeout)
        if outcome == nil {
            // Cloud too slow → degrade to local cleanup (it replaces the on-screen
            // raw in place) instead of leaving raw silently.
            outcome = await localFallbackAfterTimeout(sourceText, context: contexts.local, timedOutTier: tier)
        }
        guard let outcome else {
            logger.notice("cleanup degraded: timeout→raw kept (tier \(Self.tierString(tier), privacy: .public))")
            noteContinuation.yield("Cleanup didn't finish in time — raw text kept")
            fireCorrectionSettled(token, finalText: token.text)
            return
        }
        guard outcome.text != rawText else {
            // Cleanup was a no-op: raw stands on screen — watch that.
            fireCorrectionSettled(token, finalText: token.text)
            return
        }
        do {
            try await injector.replace(token, with: outcome.text)
            // Replace succeeded — record the clean text against this dictation.
            emitHistoryUpdate(timestamp: historyTimestamp, cleanText: outcome.text, cleanupEngine: outcome.engine)
            // The cleaned text (with the same leading separator the replace
            // re-applied) is what now sits on screen — watch that.
            fireCorrectionSettled(token, finalText: token.leadingSeparator + outcome.text)
        } catch {
            logger.notice("cleanup replace skipped: \(error.localizedDescription, privacy: .public)")
            // The cleaned text exists but can't be applied here — say so
            // instead of silently leaving raw (the user picked a cleanup tier).
            noteContinuation.yield("This app doesn't support in-place cleanup — raw text kept")
            // Raw still stands on screen — watch that.
            fireCorrectionSettled(token, finalText: token.text)
        }
    }

    /// Emit a clean-text update for a previously-recorded dictation (matched by
    /// timestamp in the sink). Off the paste path; no-op without a sink.
    private func emitHistoryUpdate(timestamp: Date, cleanText: String, cleanupEngine: String? = nil) {
        guard let historyUpdate else { return }
        historyUpdate(HistoryRecord(
            timestamp: timestamp,
            rawText: "",
            cleanText: cleanText,
            engine: "",
            durationMs: 0,
            latencyMs: 0,
            cleanupEngine: cleanupEngine
        ))
    }

    /// Race a cleaner against a timeout; returns the cleaned text, or nil on
    /// timeout or failure (caller keeps raw). Never throws.
    private func cleanWithTimeout(
        _ cleaner: any Cleaner,
        _ text: String,
        context: CleanupContext,
        cap: Duration?
    ) async -> CleanOutcome? {
        guard let cap else {
            // Timeout disabled (Settings): wait for the cleaner however long it
            // takes. A failed cleaner still returns nil, so raw stands.
            return try? await cleaner.cleanTracked(text, context: context)
        }
        return await withTaskGroup(of: CleanOutcome?.self) { group in
            group.addTask {
                try? await cleaner.cleanTracked(text, context: context)
            }
            group.addTask {
                try? await Task.sleep(for: cap)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// After a (cloud) cleanup timed out, try the LOCAL engine before giving up to
    /// raw — a slow cloud degrades to on-device cleanup, not none. Returns nil if
    /// the timed-out tier already WAS local, or local is unavailable / a no-op /
    /// also times out. Emits a status note on success so the switch is never
    /// silent (the invisible-degrade complaint).
    private func localFallbackAfterTimeout(
        _ text: String, context: CleanupContext, timedOutTier: CleanupTier
    ) async -> CleanOutcome? {
        guard timedOutTier != .local else { return nil }
        let local = cleaners.cleaner(for: .local)
        guard let outcome = await cleanWithTimeout(local, text, context: context, cap: localFallbackTimeout),
              outcome.text != text
        else { return nil }
        logger.notice("cleanup degraded: cloud→local after timeout (from tier \(Self.tierString(timedOutTier), privacy: .public))")
        noteContinuation.yield("Cloud cleanup was slow — used local cleanup instead")
        return outcome
    }

    /// The cap for a pre-paste cleanup: the configured timeout, never above the
    /// ceiling, and the ceiling itself when the setting is "Off".
    func prePasteCap(_ configured: Duration?) -> Duration {
        guard let configured else { return prePasteCeiling }
        return min(configured, prePasteCeiling)
    }

    /// Wait-for-clean for a paste target: run `cleaner` under the pre-paste cap,
    /// then degrade to local, then to raw — noting each step. `nil` return means
    /// raw should stand.
    private func cleanForPaste(
        _ cleaner: any Cleaner, tier: CleanupTier, text: String, contexts: CleanupContexts
    ) async -> CleanOutcome? {
        if let outcome = await cleanWithTimeout(
            cleaner, text, context: contexts.primary, cap: prePasteCap(cleanupTimeout)
        ) {
            return outcome
        }
        if let local = await localFallbackAfterTimeout(text, context: contexts.local, timedOutTier: tier) {
            return local
        }
        logger.notice("cleanup degraded: timeout→raw kept for paste target (tier \(Self.tierString(tier), privacy: .public))")
        noteContinuation.yield("Cleanup didn't finish in time — raw text kept")
        return nil
    }

    // MARK: - Hands-free lifecycle

    private func stopHandsFree() {
        vadTask?.cancel()
        vadTask = nil
        if isHandsFree { capture.setFramesWanted(false) }
        isHandsFree = false
    }

    // MARK: - Whisper Mode normalization

    /// Apply Whisper Mode post-capture peak normalization to `clip`. Returns the
    /// original clip untouched when nothing was boosted (already-loud, clipped,
    /// empty, or too-short), so whisper-off / no-op cases stay byte-identical.
    /// Never logs audio content — only the clipped-sample count and applied gain.
    private func normalizeWhisperClip(_ clip: AudioClip) -> AudioClip {
        let result = WhisperClipNormalizer.normalize(clip.samples)
        if result.leftClipped {
            logger.debug("whisper normalize: clip left as-is (clipped samples=\(result.clippedSampleCount, privacy: .public))")
        } else if result.appliedGain != 1 {
            logger.debug("whisper normalize: boosted ×\(result.appliedGain, format: .fixed(precision: 2), privacy: .public)")
        }
        guard result.appliedGain != 1 else { return clip }
        // `replacingSamples` keeps the capture-integrity metadata (wall duration,
        // interruption marker, and — since the length is unchanged — the RMS
        // trace) that the finalize decision already consumed.
        return clip.replacingSamples(result.samples)
    }

    // MARK: - Latency

    @discardableResult
    private func recordLatency(captureClose: Duration, transcribe: Duration, inject: Duration, total: Duration) -> DictationLatency {
        let summary = DictationLatency(
            captureCloseMs: captureClose.milliseconds,
            transcribeMs: transcribe.milliseconds,
            injectMs: inject.milliseconds,
            totalMs: total.milliseconds
        )
        recentLatencies.append(summary)
        if recentLatencies.count > 20 { recentLatencies.removeFirst(recentLatencies.count - 20) }
        logger.info("""
            dictation latency ms — capture-close: \(summary.captureCloseMs, format: .fixed(precision: 1), privacy: .public), \
            transcribe: \(summary.transcribeMs, format: .fixed(precision: 1), privacy: .public), \
            inject: \(summary.injectMs, format: .fixed(precision: 1), privacy: .public), \
            total: \(summary.totalMs, format: .fixed(precision: 1), privacy: .public)
            """)
        latencyContinuation.yield(summary)
        return summary
    }

    // MARK: - Levels

    /// Start the single, long-lived levels consumer. `capture.levels` is an
    /// `AsyncStream` (single-consumer): re-iterating it per dictation left the
    /// 2nd+ attempts with no waveform (the fresh iterator received nothing).
    /// We consume it once for the app's lifetime and gate forwarding by phase in
    /// `forwardLevel`, so idle levels are simply dropped.
    private func startLevelForwarding() {
        guard levelsTask == nil else { return }
        levelsTask = Task { [capture, weak self] in
            for await level in capture.levels {
                if Task.isCancelled { break }
                await self?.forwardLevel(level)
            }
        }
    }

    private func forwardLevel(_ level: Float) {
        guard phase == .recording else { return }
        lastLevel = level
        publish(listeningState(level: level))
    }

    private func publish(_ state: HUDState) {
        hudContinuation.yield(state)
    }
}

private extension Duration {
    var milliseconds: Double {
        let (s, atto) = components
        return Double(s) * 1000 + Double(atto) / 1e15
    }
}
