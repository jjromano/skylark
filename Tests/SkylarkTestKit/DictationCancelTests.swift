import ApplicationServices
import Testing
@testable import SkylarkCore

// P1-3: cancel used to be honored only while the mic was open (`phase ==
// .recording`), so an Esc — or `skylark://record/cancel` — during the
// transcribe/clean/inject window was dropped with no log and no UI, and the
// text landed anyway. These drive a cancel into each processing stage.
//
// P1-10: the pre-paste cleanup ceiling (nothing on screen ⇒ always bounded,
// even with the Settings timeout set to "Off").

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

/// Never returns — for the pre-paste ceiling tests.
private struct HangingCleaner: Cleaner {
    let tier: CleanupTier = .local
    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return transcript
    }
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
        // story) and finishes cleanup detached. A cancel arriving here is a
        // stray Esc against a finished session: silent, and harmless.
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

// MARK: - Pre-paste cleanup ceiling (P1-10)

@Suite("Pre-paste cleanup ceiling")
struct PrePasteCeilingTests {
    @Test("The cap is the configured timeout, bounded by the ceiling, and never nil")
    func capIsAlwaysBounded() async {
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: SpyInjector(),
            prePasteCeiling: .seconds(10)
        )
        await #expect(orchestrator.prePasteCap(nil) == .seconds(10))         // "Off"
        await #expect(orchestrator.prePasteCap(.seconds(2)) == .seconds(2))
        await #expect(orchestrator.prePasteCap(.seconds(30)) == .seconds(10)) // clamped
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
            prePasteCeiling: .milliseconds(80)
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
            prePasteCeiling: .milliseconds(10)
        )
        await orchestrator.setCleanupTimeout(nil)

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()

        // Raw is on screen and the detached cleanup is still waiting — the
        // ceiling must NOT have cut it short into a "raw kept" degrade.
        await #expect(spy.count() == 1)
        await #expect(spy.replaceCount() == 0)
    }
}
