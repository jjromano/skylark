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

    /// Temporary global cleanup override from the menu bar (nil = auto/use mode).
    private var tierOverride: CleanupTier?

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
        setupTask = Task { [modeProvider, dictionary] in
            await Self.buildSetup(bundleID: bundleID, modeProvider: modeProvider, dictionary: dictionary)
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
        let rawText = setup.corrector.apply(text)
        let effectiveTier = tierOverride ?? setup.mode.cleanupTier

        phase = .injecting

        // Stamp the dictation now so a late clean-text update correlates back to
        // this exact history row (HistoryHub keys by timestamp).
        let historyTimestamp = Date()
        // Clean text known synchronously (paste wait-for-clean path only); the AX
        // path learns it later and updates the record then.
        var syncCleanText: String?

        if effectiveTier == .raw {
            // Tier 0: raw stands, no cleanup stage.
            await insertRaw(rawText)
        } else if await injector.canInsertDirectly() {
            // AX target: paste raw now (latency bar), replace after cleanup
            // detached from the HUD state.
            let token = await insertRaw(rawText)
            if let token {
                let cleaner = cleaners.cleaner(for: effectiveTier)
                let context = setup.context
                Task { [weak self] in
                    await self?.runCleanupAndReplace(
                        token: token, rawText: rawText, cleaner: cleaner,
                        context: context, historyTimestamp: historyTimestamp
                    )
                }
            }
        } else {
            // Paste target: wait-for-clean before inserting (deliberate PRD
            // deviation; select-back is unsafe here). Race the cleaner against a
            // 2 s clock; on timeout/failure inject raw.
            let cleaner = cleaners.cleaner(for: effectiveTier)
            let cleaned = await cleanWithTimeout(
                cleaner, rawText, context: setup.context, cap: waitForCleanTimeout
            )
            if let cleaned, cleaned != rawText { syncCleanText = cleaned }
            await insertRaw(cleaned ?? rawText)
        }

        let afterInject = ContinuousClock.now
        let summary = recordLatency(
            captureClose: t0.duration(to: afterCapture),
            transcribe: afterCapture.duration(to: afterTranscribe),
            inject: afterTranscribe.duration(to: afterInject),
            total: t0.duration(to: afterInject)
        )

        emitHistory(
            timestamp: historyTimestamp,
            rawText: rawText,
            cleanText: syncCleanText,
            modeID: setup.mode.id,
            durationSec: clip.duration,
            latencyMs: summary.totalMs,
            clip: clip
        )

        phase = .idle
        publish(.idle)
    }

    /// Append a completed dictation to history via the detached sink (off the
    /// paste path; no-op when no sink is wired). Never logs transcript content.
    private func emitHistory(
        timestamp: Date,
        rawText: String,
        cleanText: String?,
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
            engine: Self.engineString(transcriber.id),
            durationMs: Int((durationSec * 1000).rounded()),
            latencyMs: Int(latencyMs.rounded()),
            audioPath: nil
        )
        historyRecord(record, clip)
    }

    /// Stable engine string for the history row.
    private static func engineString(_ id: TranscriberID) -> String {
        switch id {
        case .parakeet: return "parakeet"
        case .whisperKit: return "whisperkit"
        case .cloud(let slug): return slug
        case .stub: return "stub"
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
    }

    /// Resolve mode + dictionary off the paste path (compiles correction regexes
    /// here, not on the latency path). Runs during recording via `setupTask`.
    private static func buildSetup(
        bundleID: String?,
        modeProvider: any ModeProviding,
        dictionary: any DictionaryProviding
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
        return SessionSetup(mode: mode, context: context, corrector: corrector)
    }

    /// The setup for the active session — the prepared one if ready, else built
    /// inline (very short utterances that finish before `setupTask`).
    private func resolvedSetup() async -> SessionSetup {
        if let sessionSetup { return sessionSetup }
        let setup: SessionSetup
        if let setupTask {
            setup = await setupTask.value
        } else {
            setup = await Self.buildSetup(bundleID: frontmostBundleID(), modeProvider: modeProvider, dictionary: dictionary)
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
        guard let cleaned = await cleanWithTimeout(cleaner, rawText, context: context, cap: replaceTimeout) else {
            return
        }
        guard cleaned != rawText else { return }
        do {
            try await injector.replace(token, with: cleaned)
            // Replace succeeded — record the clean text against this dictation.
            emitHistoryUpdate(timestamp: historyTimestamp, cleanText: cleaned)
        } catch {
            logger.notice("cleanup replace skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Emit a clean-text update for a previously-recorded dictation (matched by
    /// timestamp in the sink). Off the paste path; no-op without a sink.
    private func emitHistoryUpdate(timestamp: Date, cleanText: String) {
        guard let historyUpdate else { return }
        historyUpdate(HistoryRecord(
            timestamp: timestamp,
            rawText: "",
            cleanText: cleanText,
            engine: "",
            durationMs: 0,
            latencyMs: 0
        ))
    }

    /// Race a cleaner against a timeout; returns the cleaned text, or nil on
    /// timeout or failure (caller keeps raw). Never throws.
    private func cleanWithTimeout(
        _ cleaner: any Cleaner,
        _ text: String,
        context: CleanupContext,
        cap: Duration
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await cleaner.clean(text, context: context)
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
