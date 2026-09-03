import ApplicationServices
import Testing
@testable import SkylarkCore

// P1-3: cancel used to be honored only while the mic was open (`phase ==
// .recording`), so an Esc — or `skylark://record/cancel` — during the
// transcribe/clean/inject window was dropped with no log and no UI, and the
// text landed anyway. These drive a cancel into each processing stage.
//
// P1-10 / D9: the pre-paste cleanup bound (nothing on screen ⇒ always bounded,
// independent of the Settings cleanup timeout, which governs only the detached
// path).
//
// D8: a cancel that arrives after a fast dictation has already finished lands in
// `.idle` and must still be answered, not silently dropped.

// MARK: - Doubles

/// One-shot async latch: `wait()` suspends until `open()` (before or after).
private final class Latch: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let made = AsyncStream<Void>.makeStream(of: Void.self)
        stream = made.stream
        continuation = made.continuation
    }

    func open() { continuation.finish() }
    func wait() async { for await _ in stream {} }
}

private struct FakeCapture: AudioCapturing {
    let clip: AudioClip
    var levels: AsyncStream<Float> {
        let made = AsyncStream<Float>.makeStream(of: Float.self)
        made.continuation.finish()
        return made.stream
    }

    func prepare() {}
    func start() throws {}
    func stop() -> AudioClip { clip }
}

/// Blocks inside `transcribe` until released, so a cancel can be delivered
/// while the session sits in `.transcribing`.
private struct GatedTranscriber: Transcriber {
    let id: TranscriberID = .stub
    let entered: Latch
    let release: Latch

    func warmUp() async throws {}
    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        entered.open()
        await release.wait()
        return StubTranscriber.output
    }
}

/// Blocks inside `clean`, so a cancel can be delivered mid-cleanup.
private struct GatedCleaner: Cleaner {
    let tier: CleanupTier = .local
    let entered: Latch
    let release: Latch

    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        entered.open()
        await release.wait()
        return "CLEANED"
    }
}

/// Never returns — for the pre-paste bound tests.
private struct HangingCleaner: Cleaner {
    var tier: CleanupTier = .local
    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return transcript
    }
}

/// Returns cleaned text, but only after `delay` — a cleanup slower than the
/// pre-paste bound.
private struct SlowCleaner: Cleaner {
    var tier: CleanupTier = .local
    let delay: Duration
    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        try await Task.sleep(for: delay)
        return "CLEANED"
    }
}

/// Cleans instantly — stands in for the local engine the cloud tier degrades to.
private struct FastCleaner: Cleaner {
    var tier: CleanupTier = .local
    func clean(_ transcript: String, context: CleanupContext) async throws -> String { "CLEANED" }
}

private actor SpyInjector: TextInjecting {
    private(set) var inserted: [String] = []
    private(set) var replaced: [String] = []
    private let direct: Bool
    /// Optional latches so a cancel can land while the write is in flight.
    private let entered: Latch?
    private let release: Latch?

    init(direct: Bool = false, entered: Latch? = nil, release: Latch? = nil) {
        self.direct = direct
        self.entered = entered
        self.release = release
    }

    func insert(_ text: String) async throws -> InsertionToken {
        entered?.open()
        await release?.wait()
        inserted.append(text)
        return InsertionToken(
            method: direct ? .ax(AXUIElementCreateSystemWide()) : .paste,
            text: text,
            pasteUncertain: false
        )
    }

    func replace(_ token: InsertionToken, with text: String) async throws {
        replaced.append(text)
    }

    func canInsertDirectly() async -> Bool { direct }

    func count() -> Int { inserted.count }
    func first() -> String? { inserted.first }
    func replaceCount() -> Int { replaced.count }
}

private func modes(defaultTier: CleanupTier) -> InMemoryModeProvider {
    InMemoryModeProvider(modes: [
        DictationMode(id: "d", name: "Default", bundleIDPattern: nil, cleanupTier: defaultTier, isDefault: true),
    ])
}

private func makeClip() -> AudioClip {
    AudioClip(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 16_000, duration: 0.25)
}

/// First status note, or nil after `timeout` (notes buffer newest-4, so one
/// yielded during the dictation is already waiting).
private func firstNote(
    _ orchestrator: DictationOrchestrator, timeout: Duration = .milliseconds(300)
) async -> String? {
    await withTaskGroup(of: String?.self) { group in
        group.addTask {
            for await note in orchestrator.statusNotes { return note }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Every status note yielded within `window`. Notes buffer newest-4, so ones
/// yielded before collection starts are still delivered.
private func notes(
    _ orchestrator: DictationOrchestrator, window: Duration = .milliseconds(200)
) async -> [String] {
    let box = NoteBox()
    let collector = Task { for await note in orchestrator.statusNotes { await box.add(note) } }
    try? await Task.sleep(for: window)
    collector.cancel()
    return await box.all()
}

private actor NoteBox {
    private var seen: [String] = []
    func add(_ note: String) { seen.append(note) }
    func all() -> [String] { seen }
}

/// Let detached work (the AX cleanup+replace task) run.
private func settle() async {
    for _ in 0..<50 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

// MARK: - Cancel during processing

@Suite("Cancel during processing")
struct DictationCancelTests {
    @Test("Cancel while transcribing inserts nothing and returns to idle")
    func cancelWhileTranscribing() async {
        let spy = SpyInjector()
        let entered = Latch()
        let release = Latch()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: GatedTranscriber(entered: entered, release: release),
            injector: spy
        )

        await orchestrator.handle(.startRecording)
        let finish = Task { await orchestrator.handle(.stopRecording) }
        await entered.wait()
        await #expect(orchestrator.phase == .transcribing)
        await orchestrator.handle(.cancel)
        release.open()
        await finish.value

        await #expect(orchestrator.phase == .idle)
        await #expect(spy.count() == 0)
    }

    @Test("Cancel while cleaning (paste target) inserts nothing")
    func cancelWhileCleaning() async {
        let spy = SpyInjector()
        let entered = Latch()
        let release = Latch()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: GatedCleaner(entered: entered, release: release)),
            modeProvider: modes(defaultTier: .local)
        )

        await orchestrator.handle(.startRecording)
        let finish = Task { await orchestrator.handle(.stopRecording) }
        await entered.wait()
        await orchestrator.handle(.cancel)
        release.open()
        await finish.value

        await #expect(orchestrator.phase == .idle)
        await #expect(spy.count() == 0)
    }

    @Test("Cancel that races the write is answered 'too late' and the text stands")
    func cancelDuringWriteIsTooLate() async {
        let entered = Latch()
        let release = Latch()
        let spy = SpyInjector(entered: entered, release: release)
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy
        )

        await orchestrator.handle(.startRecording)
        let finish = Task { await orchestrator.handle(.stopRecording) }
        await entered.wait()
        await orchestrator.handle(.cancel)
        release.open()
        await finish.value

        await #expect(spy.count() == 1)
        #expect(await firstNote(orchestrator) == DictationOrchestrator.cancelTooLateNote)
    }

    @Test("Cancel once the text has landed cannot undo it, and never derails cleanup")
    func cancelAfterInsertionCannotUndo() async {
        // The AX path returns to idle as soon as raw is on screen (the latency
        // story) and finishes cleanup detached. A cancel arriving here is
        // answered "too late" (D8) and is otherwise harmless.
        let entered = Latch()
        let release = Latch()
        let spy = SpyInjector(direct: true)
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: GatedCleaner(entered: entered, release: release)),
            modeProvider: modes(defaultTier: .local)
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        // Raw landed synchronously; the cleanup runs detached.
        await #expect(spy.count() == 1)
        await entered.wait()
        await orchestrator.handle(.cancel)
        release.open()
        await settle()

        // Nothing was undone, and the cleaned replace still happened.
        await #expect(spy.count() == 1)
        await #expect(spy.replaceCount() == 1)
    }

    @Test("A cancelled session records no history row")
    func cancelledSessionRecordsNoHistory() async {
        let box = RecordBox()
        let spy = SpyInjector()
        let entered = Latch()
        let release = Latch()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: GatedTranscriber(entered: entered, release: release),
            injector: spy,
            historyRecord: { record, _ in Task { await box.add(record) } }
        )

        await orchestrator.handle(.startRecording)
        let finish = Task { await orchestrator.handle(.stopRecording) }
        await entered.wait()
        await orchestrator.handle(.cancel)
        release.open()
        await finish.value
        await settle()

        await #expect(box.count() == 0)
    }

    @Test("Cancel during recording still drops the audio (unchanged)")
    func cancelDuringRecordingStillWorks() async {
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.cancel)
        await #expect(orchestrator.phase == .idle)
        await #expect(spy.count() == 0)
    }

    @Test("Cancel while idle does nothing and raises no note")
    func cancelWhileIdleIsInert() async {
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy
        )
        await orchestrator.handle(.cancel)
        await #expect(orchestrator.phase == .idle)
        #expect(await firstNote(orchestrator, timeout: .milliseconds(100)) == nil)
    }

    // D8: `open skylark://record/cancel` takes ~300 ms to be delivered, while a
    // local dictation finishes in ~180 ms. The cancel therefore lands in `.idle`
    // routinely — and used to hit a bare `return`: no log, no note, nothing.
    @Test("A cancel that just missed the finished dictation is answered, once")
    func lateCancelAfterCompletedDictationIsAnswered() async {
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await #expect(spy.count() == 1)
        await #expect(orchestrator.phase == .idle)

        await orchestrator.handle(.cancel)

        let seen = await notes(orchestrator)
        #expect(seen == [DictationOrchestrator.cancelTooLateNote])
    }

    @Test("A cancel long after the text landed says nothing")
    func staleCancelOutsideTheWindowIsSilent() async {
        // A note about text inserted a minute ago would only confuse, so the
        // "too late" answer expires.
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            lateCancelWindow: .milliseconds(20)
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await #expect(spy.count() == 1)
        try? await Task.sleep(for: .milliseconds(60))

        await orchestrator.handle(.cancel)

        #expect(await notes(orchestrator, window: .milliseconds(100)).isEmpty)
    }

    @Test("The next dictation after a cancelled one works normally")
    func sessionAfterCancelIsClean() async {
        let spy = SpyInjector()
        let entered = Latch()
        let release = Latch()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: GatedTranscriber(entered: entered, release: release),
            injector: spy
        )

        await orchestrator.handle(.startRecording)
        let finish = Task { await orchestrator.handle(.stopRecording) }
        await entered.wait()
        await orchestrator.handle(.cancel)
        release.open()
        await finish.value
        await #expect(spy.count() == 0)

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await #expect(spy.count() == 1)
        await #expect(spy.first() == StubTranscriber.output)
    }
}

/// Collects history rows off the detached sink.
private actor RecordBox {
    private var records: [HistoryRecord] = []
    func add(_ record: HistoryRecord) { records.append(record) }
    func count() -> Int { records.count }
}

// MARK: - Command mode

private struct GatedCommandRunner: CommandRunning {
    let entered: Latch
    let release: Latch

    func run(instruction: String, selection: String?, tier: CleanupTier) async throws -> CommandOutcome {
        entered.open()
        await release.wait()
        return CommandOutcome(text: "REWRITTEN", note: nil)
    }
}

@Suite("Cancel during command processing")
struct CommandCancelTests {
    @Test("Cancel while the command LLM runs writes nothing")
    func cancelWhileCommandRuns() async {
        let spy = SpyInjector()
        let entered = Latch()
        let release = Latch()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: RawPassthrough()),
            modeProvider: modes(defaultTier: .local),
            commandRunner: GatedCommandRunner(entered: entered, release: release)
        )

        await orchestrator.handle(.startCommand)
        let finish = Task { await orchestrator.handle(.stopCommand) }
        await entered.wait()
        await orchestrator.handle(.cancel)
        release.open()
        await finish.value

        await #expect(orchestrator.phase == .idle)
        await #expect(spy.count() == 0)
    }
}

// MARK: - Pre-paste cleanup bound (P1-10, D9)

@Suite("Pre-paste cleanup bound")
struct PrePasteBoundTests {
    @Test("The bound always wins: the cleanup timeout can only shorten the pre-paste wait")
    func capIsAlwaysBounded() async {
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: SpyInjector(),
            prePasteBound: .milliseconds(600)
        )
        await #expect(orchestrator.prePasteCap(nil) == .milliseconds(600))   // "Off"
        // The v0.19.1 5 s cleanup timeout must NOT stretch the blank-screen wait.
        await #expect(orchestrator.prePasteCap(.seconds(2)) == .milliseconds(600))
        await #expect(orchestrator.prePasteCap(.seconds(5)) == .milliseconds(600))
        // A shorter setting still shortens it.
        await #expect(orchestrator.prePasteCap(.milliseconds(100)) == .milliseconds(100))
    }

    @Test("Timeout 'Off' no longer blocks the first paste indefinitely")
    func offStillCapsThePaste() async {
        let spy = SpyInjector() // paste target ⇒ wait-for-clean before inserting
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: HangingCleaner()),
            modeProvider: modes(defaultTier: .local),
            prePasteBound: .milliseconds(80)
        )
        await orchestrator.setCleanupTimeout(nil) // Settings → "Off — wait for cleanup"

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        // Raw text landed rather than hanging on the wedged cleaner.
        await #expect(spy.count() == 1)
        await #expect(spy.first() == StubTranscriber.output)
        await #expect(orchestrator.phase == .idle)
    }

    @Test("'Off' still means unbounded on the detached AX path (raw already visible)")
    func offRemainsUnboundedWhenRawIsOnScreen() async {
        let spy = SpyInjector(direct: true) // AX target ⇒ raw first, cleanup detached
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: HangingCleaner()),
            modeProvider: modes(defaultTier: .local),
            prePasteBound: .milliseconds(10)
        )
        await orchestrator.setCleanupTimeout(nil)

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()

        // Raw is on screen and the detached cleanup is still waiting — the
        // bound must NOT have cut it short into a "raw kept" degrade.
        await #expect(spy.count() == 1)
        await #expect(spy.replaceCount() == 0)
    }

    @Test("A slow cleaner cannot hold the paste past the bound")
    func slowCleanerCannotHoldThePaste() async {
        let spy = SpyInjector() // paste target ⇒ wait-for-clean before inserting
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: SlowCleaner(delay: .seconds(5))),
            modeProvider: modes(defaultTier: .local),
            prePasteBound: .milliseconds(80)
        )
        // The user's cleanup timeout is generous; the bound must ignore it.
        await orchestrator.setCleanupTimeout(.seconds(5))

        let start = ContinuousClock.now
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        let elapsed = start.duration(to: ContinuousClock.now)

        await #expect(spy.count() == 1)
        await #expect(spy.first() == StubTranscriber.output) // raw, not "CLEANED"
        // Without the bound this would have taken the cleaner's full 5 s. The
        // slack is generous on purpose: the suite runs highly parallel, so a
        // tight wall-clock assertion here would be flaky rather than strict.
        #expect(elapsed < .seconds(1))
    }

    @Test("The cloud→local fallback still runs while the bound has room left")
    func localFallbackRunsWithBudgetLeft() async {
        // Control for the test below: same wedged cloud tier, but the primary
        // burns only 30 ms of a 1 s bound, so the local rescue gets its turn.
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: FastCleaner(), cloud: ["slow": HangingCleaner(tier: .cloud(slug: "slow"))]),
            modeProvider: modes(defaultTier: .cloud(slug: "slow")),
            prePasteBound: .seconds(1)
        )
        await orchestrator.setCleanupTimeout(.milliseconds(30))

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        await #expect(spy.first() == "CLEANED")
    }

    @Test("The local fallback is skipped once the bound is spent")
    func localFallbackSkippedWhenBoundIsSpent() async {
        // Identical setup, except the primary burns the WHOLE bound. Starting a
        // second generation now would push the blank-screen wait past it, so the
        // fallback must not run — raw stands instead of the "CLEANED" the
        // control above proves the local engine would have produced.
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: FastCleaner(), cloud: ["slow": HangingCleaner(tier: .cloud(slug: "slow"))]),
            modeProvider: modes(defaultTier: .cloud(slug: "slow")),
            prePasteBound: .milliseconds(40)
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        await #expect(spy.first() == StubTranscriber.output)
    }
}
