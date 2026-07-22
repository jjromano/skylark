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

    private let capture: any AudioCapturing
    /// Swappable at runtime (`setTranscriber`) so the menu-bar Speech Engine
    /// quick-switch can move between local and cloud without rebuilding the
    /// orchestrator. The ready-gate (`transcriberReady`) is independent.
    private var transcriber: any Transcriber
    private let injector: any TextInjecting
    private let endpointer: (any SpeechEndpointer)?
    private let hint: TranscriptionHint

    /// Detached history sinks (phase-3 spec §7). Both off the paste path; nil in
    /// tests/headless callers that don't record. `historyRecord` also carries
    /// the just-captured clip so the sink can retain audio when opted in
    /// (phase-5a spec §2); the sink itself decides whether to keep it.
    private let historyRecord: (@Sendable (HistoryRecord, AudioClip) -> Void)?
    private let historyUpdate: (@Sendable (HistoryRecord) -> Void)?

    // Cleanup wiring (Phase 2). Defaults keep behaviour raw-only + instant so the
    // 3-arg init and existing call sites are unaffected.
    private let cleaners: CleanerRegistry
    private let modeProvider: any ModeProviding
    private let dictionary: any DictionaryProviding
    private let frontmostBundleID: @Sendable () -> String?
    /// Current snippets (loaded per session in `buildSetup`, off the paste
    /// path). Nil = snippets feature not wired (tests/headless).
    private let snippetProvider: (@Sendable () async -> [SnippetRecord])?

    /// Temporary global cleanup override from the menu bar (nil = auto/use mode).
    private var tierOverride: CleanupTier?
    private var silencePeakThreshold: Float = SilenceDetector.peakThreshold
    /// Spoken "press enter" command opt-in (Settings → General). When on, a
    /// terminal "press enter"/"press return" is stripped from the transcript
    /// and a Return keystroke is synthesized after the text lands.
    private var pressEnterEnabled = false

    /// Fired when an utterance settles into an AX-verified field (raw stands, or
    /// cleanup replaced it): `(token, finalText)` where `finalText` is what now
    /// sits on screen. The app layer starts the bounded correction watcher off
    /// this signal (opt-in auto-learn). nil = feature not wired. Never called for
    /// paste-fallback insertions (no AX signal to re-read).
    private var correctionSettled: (@Sendable (InsertionToken, String) -> Void)?

    /// Resolved once per session at fn-down, consumed at paste time.
    private var sessionSetup: SessionSetup?
    private var setupTask: Task<SessionSetup, Never>?

    /// Cap on the cleanup+replace path (AX targets); raw already stands.
    private let replaceTimeout: Duration
    /// Cap on wait-for-clean before pasting (paste targets, deliberate wait).
    private let waitForCleanTimeout: Duration

    public private(set) var phase: Phase = .idle

    /// Whether the transcriber is ready to decode. Defaults true (engines with
    /// nothing to prepare, e.g. the stub, are ready immediately); the app flips
    /// it false while a model downloads/loads and true again on completion.
    /// Dictation attempted while false is discarded with a status note (no hang).
    private var transcriberReady = true

    /// True while the active session is hands-free (double-tap-lock): VAD, not a
    /// key release, ends it.
    private var isHandsFree = false
    private var vadTask: Task<Void, Never>?

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
        snippets: (@Sendable () async -> [SnippetRecord])? = nil,
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
        self.cleaners = cleaners
        self.modeProvider = modeProvider
        self.dictionary = dictionary
        self.frontmostBundleID = frontmostBundleID
        self.snippetProvider = snippets
        self.historyRecord = historyRecord
        self.historyUpdate = historyUpdate
        self.replaceTimeout = replaceTimeout
        self.waitForCleanTimeout = waitForCleanTimeout
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

    /// Temporary global cleanup override from the menu bar. `nil` = Auto (use the
    /// resolved mode's tier); a value forces that tier for every dictation.
    public func setTierOverride(_ tier: CleanupTier?) {
        tierOverride = tier
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
            startRecording()
        case .stopRecording:
            await finishRecording()
        case .cancel, .discard:
            cancelRecording()
        case .engageHandsFree:
            engageHandsFree()
        }
    }

    // MARK: - Transitions

    private func startRecording() {
        guard phase == .idle else { return }
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
        isHandsFree = false
        // Capture the target app AT dictation start (fn-down) and resolve the
        // mode + dictionary off the paste path while the user speaks.
        let bundleID = frontmostBundleID()
        sessionSetup = nil
        setupTask?.cancel()
        setupTask = Task { [modeProvider, dictionary, snippetProvider] in
            await Self.buildSetup(bundleID: bundleID, modeProvider: modeProvider, dictionary: dictionary, snippets: snippetProvider)
        }
        publish(.listening(level: 0))
        startLevelForwarding()
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

        // Fn-up → text-inserted is THE latency metric.
        let t0 = ContinuousClock.now
        let interval = signposter.beginInterval("fnup_to_inserted")
        defer { signposter.endInterval("fnup_to_inserted", interval) }

        let clip = capture.stop()
        let afterCapture = ContinuousClock.now
        phase = .transcribing
        publish(.processing)

        guard !clip.isEmpty else {
            phase = .idle
            publish(.idle)
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
            noteContinuation.yield("No speech detected")
            return
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
        let afterTranscribe = ContinuousClock.now

        // Empty transcript → no injection at all (nothing to paste).
        guard !text.isEmpty else {
            phase = .idle
            publish(.idle)
            return
        }

        // Resolve the session setup (usually already prepared during recording).
        let setup = await resolvedSetup()
        // Dictionary correction is part of the raw text — always applied, even
        // Tier 0 (PRD §8). Off-path regex compile happened in setup; this is the
        // ≤5 ms apply.
        let corrected = setup.corrector.apply(text)
        let effectiveTier = tierOverride ?? setup.mode.cleanupTier

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

        if let snippetReplacement {
            syncCleanText = snippetReplacement
            syncCleanupEngine = "snippet"
            await insertRaw(snippetReplacement)
        } else if rawText.isEmpty {
            // The whole utterance was the "press enter" command — nothing to
            // insert; the Return below is the entire action.
        } else if effectiveTier == .raw {
            // Tier 0: raw stands, no cleanup stage.
            syncCleanupEngine = "raw"
            if let token = await insertRaw(rawText) {
                settledToken = token
                settledFinalText = token.text
            }
        } else if pressEnter {
            // Return must land after the FINAL text: the detached AX replace
            // would race the keystroke (a chat message would send, then get
            // edited), so wait for clean here even on AX targets.
            let cleaner = cleaners.cleaner(for: effectiveTier)
            let outcome = await cleanWithTimeout(
                cleaner, rawText, context: setup.context, cap: waitForCleanTimeout
            )
            if let outcome {
                syncCleanupEngine = outcome.engine
                if outcome.text != rawText { syncCleanText = outcome.text }
            }
            let final = outcome?.text ?? rawText
            if let token = await insertRaw(final) {
                settledToken = token
                settledFinalText = token.text
            }
        } else if let token = await insertDirectRaw(rawText) {
            // The AX write landed VERIFIED — raw is on screen (latency bar);
            // replace with cleaned text after cleanup, detached from the HUD
            // state. Routing on the actual insert (not a capability probe)
            // matters: Chrome claims writable AX selection but silently drops
            // writes, which previously pasted raw here and lost the cleanup.
            let cleaner = cleaners.cleaner(for: effectiveTier)
            let context = setup.context
            Task { [weak self] in
                await self?.runCleanupAndReplace(
                    token: token, rawText: rawText, cleaner: cleaner,
                    context: context, historyTimestamp: historyTimestamp
                )
            }
        } else {
            // No verified in-place target (a paste would be needed): wait-for-
            // clean before inserting (deliberate PRD deviation; select-back is
            // unsafe here). Race the cleaner against a 2 s clock; on timeout/
            // failure inject raw — and say so.
            let cleaner = cleaners.cleaner(for: effectiveTier)
            let outcome = await cleanWithTimeout(
                cleaner, rawText, context: setup.context, cap: waitForCleanTimeout
            )
            if let outcome {
                syncCleanupEngine = outcome.engine
                if outcome.text != rawText { syncCleanText = outcome.text }
            } else {
                noteContinuation.yield("Cleanup didn't finish in time — raw text kept")
            }
            let final = outcome?.text ?? rawText
            if let token = await insertRaw(final) {
                settledToken = token
                settledFinalText = token.text
            }
        }

        if pressEnter {
            await injector.pressReturn()
        }

        let afterInject = ContinuousClock.now
        let summary = recordLatency(
            captureClose: t0.duration(to: afterCapture),
            transcribe: afterCapture.duration(to: afterTranscribe),
            inject: afterTranscribe.duration(to: afterInject),
            total: t0.duration(to: afterInject)
        )

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
        switch id {
        case .parakeet: return "parakeet"
        case .whisperKit: return "whisperkit"
        case .speechAnalyzer: return "appleSpeech"
        case .cloud(let slug): return slug
        case .stub: return "stub"
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
        setupTask?.cancel()
        setupTask = nil
        sessionSetup = nil
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
        snippets snippetProvider: (@Sendable () async -> [SnippetRecord])?
    ) async -> SessionSetup {
        let modes = (try? await modeProvider.modes()) ?? []
        let mode = ModeResolver.resolve(bundleID: bundleID, modes: modes)
        let entries = (try? await dictionary.entries()) ?? []
        let context = CleanupContext(
            targetAppBundleID: bundleID,
            registerHint: mode.registerHint,
            // Every correct-spelling phrase is protected during recognition.
            dictionaryTerms: entries.map(\.phrase)
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
            setup = await Self.buildSetup(bundleID: frontmostBundleID(), modeProvider: modeProvider, dictionary: dictionary, snippets: snippetProvider)
        }
        sessionSetup = setup
        return setup
    }

    /// Run the cleaner on `rawText` (capped at `replaceTimeout`) and, on a
    /// changed result, replace the AX-inserted range in place. Every failure is
    /// silent-to-the-user: raw stands, one log line.
    private func runCleanupAndReplace(
        token: InsertionToken,
        rawText: String,
        cleaner: any Cleaner,
        context: CleanupContext,
        historyTimestamp: Date
    ) async {
        guard let outcome = await cleanWithTimeout(cleaner, rawText, context: context, cap: replaceTimeout) else {
            // Timeout/failure: raw stands on screen — watch that.
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
        cap: Duration
    ) async -> CleanOutcome? {
        await withTaskGroup(of: CleanOutcome?.self) { group in
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

    // MARK: - Hands-free lifecycle

    private func stopHandsFree() {
        vadTask?.cancel()
        vadTask = nil
        if isHandsFree { capture.setFramesWanted(false) }
        isHandsFree = false
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
        publish(.listening(level: level))
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
