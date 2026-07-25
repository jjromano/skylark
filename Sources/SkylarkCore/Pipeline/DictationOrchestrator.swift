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
    /// The app that was frontmost at record start (fn-down) — the app the user
    /// dictated INTO. The guard compares it against frontmost before injecting.
    private var capturedTargetBundleID: String?
    /// Current snippets (loaded per session in `buildSetup`, off the paste
    /// path). Nil = snippets feature not wired (tests/headless).
    private let snippetProvider: (@Sendable () async -> [SnippetRecord])?

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
    /// Optional deep-vocabulary rescorer (PRD §8, opt-in, default off). When set,
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

    private let hudContinuation: AsyncStream<HUDState>.Continuation
    /// HUD snapshots for the UI to observe.
    public nonisolated let hudStates: AsyncStream<HUDState>

    private let noteContinuation: AsyncStream<String>.Continuation
    /// Transient status notes for the menu bar (e.g. "Speech model still preparing…").
    public nonisolated let statusNotes: AsyncStream<String>

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
        waitForCleanTimeout: Duration = .seconds(2)
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
        let (stream, continuation) = AsyncStream<HUDState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        hudStates = stream
        hudContinuation = continuation
        let (notes, noteCont) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(4))
        statusNotes = notes
        noteContinuation = noteCont
        let (lat, latCont) = AsyncStream<DictationLatency>.makeStream(bufferingPolicy: .bufferingNewest(4))
        latencies = lat
        latencyContinuation = latCont
        continuation.yield(.idle)
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
        }
    }

    // MARK: - Transitions

    private func startRecording(kind: SessionKind) {
        guard phase == .idle else { return }
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
            publish(.idle)
            return
        }
        phase = .recording
        sessionKind = kind
        isHandsFree = false
        sessionInterruption = nil
        startInterruptionForwarding()
        // Capture the target app AT dictation start (fn-down) and resolve the
        // mode + dictionary off the paste path while the user speaks.
        let bundleID = frontmostBundleID()
        capturedTargetBundleID = bundleID
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
            : .listening(level: level, preview: currentPreview)
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
                    await self?.handle(.stopRecording)
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

        guard !clip.isEmpty else {
            phase = .idle
            publish(.idle)
            if finalization.interrupted { noteContinuation.yield(Self.interruptedNote) }
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
            noteContinuation.yield(finalization.interrupted ? Self.interruptedNote : "No speech detected")
            return
        }

        // Something took the mic mid-utterance: the text we're about to insert may
        // be missing its tail, so say so (never block the insert on it).
        if finalization.interrupted {
            noteContinuation.yield(Self.interruptedNote)
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

        // Captured-target focus guard (WS3): don't type into the wrong app. One
        // frontmost read; only a focus change pays for re-activation.
        let focusLost = await capturedTargetLost()

        if focusLost {
            // Abort every write (text AND the "press enter" Return — a stray
            // Return in the wrong app can send a message). The transcript is not
            // lost: the history row below is still emitted, exactly like the
            // replace-failure path keeps its text and reports the degrade.
            injectMethod = "aborted-focus"
            cleanupEngineRan = "skipped"
            noteContinuation.yield("Focus moved to another app — text not pasted, kept in History")
        } else if let snippetReplacement {
            syncCleanText = snippetReplacement
            syncCleanupEngine = "snippet"
            cleanupEngineRan = "snippet"
            if let token = await insertRaw(snippetReplacement) { injectMethod = Self.methodString(token) }
        } else if rawText.isEmpty {
            // The whole utterance was the "press enter" command — nothing to
            // insert; the Return below is the entire action.
        } else if effectiveTier == .raw {
            // Tier 0: raw stands, no cleanup stage.
            syncCleanupEngine = "raw"
            cleanupEngineRan = "raw"
            if let token = await insertRaw(rawText) {
                settledToken = token
                settledFinalText = token.text
                injectMethod = Self.methodString(token)
            }
        } else if pressEnter {
            // Return must land after the FINAL text: the detached AX replace
            // would race the keystroke (a chat message would send, then get
            // edited), so wait for clean here even on AX targets.
            let cleaner = cleaners.cleaner(for: effectiveTier)
            let outcome = await cleanForPaste(cleaner, tier: effectiveTier, text: rawText, context: cleanupContext)
            if let outcome {
                syncCleanupEngine = outcome.engine
                if outcome.text != rawText { syncCleanText = outcome.text }
            }
            cleanupEngineRan = outcome?.engine ?? "raw"
            let final = outcome?.text ?? rawText
            if let token = await insertRaw(final) {
                settledToken = token
                settledFinalText = token.text
                injectMethod = Self.methodString(token)
            }
        } else if let token = await insertDirectRaw(rawText) {
            // The AX write landed VERIFIED — raw is on screen (latency bar);
            // replace with cleaned text after cleanup, detached from the HUD
            // state. Routing on the actual insert (not a capability probe)
            // matters: Chrome claims writable AX selection but silently drops
            // writes, which previously pasted raw here and lost the cleanup.
            let cleaner = cleaners.cleaner(for: effectiveTier)
            let context = cleanupContext
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
                    context: context, historyTimestamp: historyTimestamp,
                    rescoreSamples: rescoreSamples, rescoreTimings: rescoreTimings
                )
            }
        } else {
            // No verified in-place target (a paste would be needed): wait-for-
            // clean before inserting (deliberate PRD deviation; select-back is
            // unsafe here). Race the cleaner against a 2 s clock; on timeout/
            // failure inject raw — and say so.
            let cleaner = cleaners.cleaner(for: effectiveTier)
            let outcome = await cleanForPaste(cleaner, tier: effectiveTier, text: rawText, context: cleanupContext)
            if let outcome {
                syncCleanupEngine = outcome.engine
                if outcome.text != rawText { syncCleanText = outcome.text }
            }
            cleanupEngineRan = outcome?.engine ?? "raw"
            let final = outcome?.text ?? rawText
            if let token = await insertRaw(final) {
                settledToken = token
                settledFinalText = token.text
                injectMethod = Self.methodString(token)
            }
        }

        if pressEnter, !focusLost {
            await injector.pressReturn()
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
        switch sessionKind {
        case .dictation: await finishRecording()
        case .command: await finishCommand()
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
        return Finalization(clip: working, interrupted: interrupted, trimmed: trimmed)
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
            configuration: configuration
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
        if finalization.interrupted { noteContinuation.yield(Self.interruptedNote) }
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

        let instruction: String
        do {
            instruction = try await transcriber.transcribe(clip, hint: hint)
        } catch {
            logger.error("command transcription failed: \(error.localizedDescription, privacy: .public)")
            finishCommandIdle(note: "Couldn't hear the command")
            return
        }
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Nothing said — quietly return to idle (nothing destructive).
            phase = .idle
            publish(.idle)
            return
        }

        // Resolve the tier (override or resolved mode). Raw has no LLM to run:
        // refuse and do nothing destructive (no selection read, no insert).
        let setup = await resolvedSetup()
        let tier = tierOverride ?? setup.mode.cleanupTier
        if tier == .raw {
            finishCommandIdle(note: "Command mode needs a cleanup model")
            return
        }

        // Same captured-target guard as dictation: a command rewrites the text of
        // the app the user spoke to, so refuse (nothing destructive) rather than
        // rewrite a selection in whatever app grabbed focus meanwhile.
        if await capturedTargetLost() {
            finishCommandIdle(note: "Focus moved to another app — command not applied")
            return
        }

        // Read the selection BEFORE the LLM call so any failure leaves it as-is.
        // nil = no readable selection → generate text at the cursor.
        let selection = await injector.readSelection()

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
        if let selection, !selection.text.isEmpty {
            // Rewrite. When the model echoed the selection unchanged (its
            // "instruction unclear" fallback), there's nothing to write.
            guard result != selection.text else {
                phase = .idle
                publish(.idle)
                return
            }
            let ok = await injector.replaceSelection(selection, with: result)
            if !ok {
                noteContinuation.yield("Couldn't replace the selection")
            }
        } else {
            // Generate at the cursor via the shared verified-insert path.
            _ = await insertRaw(result)
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

    /// The one check the injection boundary makes before writing anything: is the
    /// app the user dictated INTO still frontmost? If focus moved, re-activate it
    /// (bounded, ~300 ms) and only inject once it is verifiably back.
    ///
    /// Returns true when injection must be ABORTED. Costs a single NSWorkspace
    /// frontmost read on the happy path (no AX, no activation, no sleeps), so the
    /// fn-up→paste path is unchanged for the overwhelmingly common case. Nil guard
    /// (tests/headless) → never aborts.
    ///
    /// Covers both injection paths: it runs before the AX-vs-paste decision, so an
    /// AX-verified in-place insert and a synthesized paste are equally gated. The
    /// *detached* cleanup replace needs no guard — `performAXReplace` re-verifies
    /// that the token's element is still focused and no-ops otherwise.
    private func capturedTargetLost() async -> Bool {
        guard let focusGuard else { return false }
        switch await focusGuard.decide(captured: capturedTargetBundleID) {
        case .proceed:
            return false
        case .reactivated:
            logger.notice("focus guard: captured target re-activated before injection")
            return false
        case let .abort(current):
            logger.notice("""
                focus guard: injection aborted — frontmost=\(current ?? "nil", privacy: .public) \
                captured=\(self.capturedTargetBundleID ?? "nil", privacy: .public)
                """)
            return true
        }
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

    private func cancelRecording() {
        guard phase == .recording else { return }
        stopHandsFree()
        stopLivePreview()
        setupTask?.cancel()
        setupTask = nil
        sessionSetup = nil
        // Drop any in-flight/late field-context read (bump the session so a
        // completing read is ignored) and clear the captured value.
        fieldContextSession &+= 1
        fieldContextTask?.cancel()
        fieldContextTask = nil
        capturedFieldContext = nil
        capturedTargetBundleID = nil
        sessionInterruption = nil
        _ = capture.stop() // discard audio
        phase = .idle
        publish(.idle)
    }

    // MARK: - Cleanup / mode setup

    /// Everything resolved at dictation start, consumed at paste time.
    struct SessionSetup {
        let mode: DictationMode
        let context: CleanupContext
        let corrector: DictionaryCorrector
        let snippets: [SnippetRecord]
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
        return SessionSetup(mode: mode, context: context, corrector: corrector, snippets: snippets)
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
        context: CleanupContext,
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

        var outcome = await cleanWithTimeout(cleaner, sourceText, context: context, cap: cleanupTimeout)
        if outcome == nil {
            // Cloud too slow → degrade to local cleanup (it replaces the on-screen
            // raw in place) instead of leaving raw silently.
            outcome = await localFallbackAfterTimeout(sourceText, context: context, timedOutTier: tier)
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

    /// Wait-for-clean for a paste target: run `cleaner` under the configurable
    /// cleanup timeout, then degrade to local, then to raw — noting each step.
    /// `nil` return means raw should stand.
    private func cleanForPaste(
        _ cleaner: any Cleaner, tier: CleanupTier, text: String, context: CleanupContext
    ) async -> CleanOutcome? {
        if let outcome = await cleanWithTimeout(cleaner, text, context: context, cap: cleanupTimeout) {
            return outcome
        }
        if let local = await localFallbackAfterTimeout(text, context: context, timedOutTier: tier) {
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
