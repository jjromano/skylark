import ApplicationServices
import Testing
import SkylarkCore

// MARK: - Test doubles

private final class FakeCapture: AudioCapturing, @unchecked Sendable {
    let clip: AudioClip
    let levels: AsyncStream<Float>

    init(clip: AudioClip) {
        self.clip = clip
        // Empty, already-finished stream so level forwarding ends immediately.
        let (stream, cont) = AsyncStream<Float>.makeStream()
        cont.finish()
        levels = stream
    }

    func prepare() {}
    func start() throws {}
    func stop() -> AudioClip { clip }
}

private struct ThrowingTranscriber: Transcriber {
    let id: TranscriberID = .stub
    func warmUp() async throws {}
    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        throw ParakeetError.notReady
    }
}

private actor SpyInjector: TextInjecting {
    private(set) var inserted: [String] = []
    private(set) var replaced: [String] = []
    private let direct: Bool
    /// When true, insert reports an AX token so the orchestrator uses the
    /// replace path; otherwise a paste token.
    init(direct: Bool = false) { self.direct = direct }

    func insert(_ text: String) async throws -> InsertionToken {
        inserted.append(text)
        let method: InsertionToken.Method = direct ? .ax(AXUIElementCreateSystemWide()) : .paste
        return InsertionToken(method: method, text: text, pasteUncertain: false)
    }

    func replace(_ token: InsertionToken, with text: String) async throws {
        replaced.append(text)
    }

    func canInsertDirectly() async -> Bool { direct }

    func count() -> Int { inserted.count }
    func first() -> String? { inserted.first }
    func replaceCount() -> Int { replaced.count }
    func firstReplaced() -> String? { replaced.first }
    func lastInserted() -> String? { inserted.last }
}

// MARK: - Tests

@Suite("DictationOrchestrator transitions")
struct DictationOrchestratorTests {
    private func makeClip() -> AudioClip {
        AudioClip(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 16_000, duration: 0.25)
    }

    @Test("Happy path: start → stop inserts the transcript and returns to idle")
    func happyPath() async {
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy
        )

        await orchestrator.handle(.startRecording)
        await #expect(orchestrator.phase == .recording)

        await orchestrator.handle(.stopRecording)
        await #expect(orchestrator.phase == .idle)
        await #expect(spy.count() == 1)
        await #expect(spy.first() == StubTranscriber.output)
    }

    @Test("Cancel drops audio without transcribing or inserting")
    func cancelDropsAudio() async {
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

    @Test("Discard drops audio without inserting")
    func discardDropsAudio() async {
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.discard)
        await #expect(orchestrator.phase == .idle)
        await #expect(spy.count() == 0)
    }

    @Test("Empty clip does not insert")
    func emptyClipNoInsert() async {
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: .empty),
            transcriber: StubTranscriber(),
            injector: spy
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await #expect(orchestrator.phase == .idle)
        await #expect(spy.count() == 0)
    }

    @Test("stopRecording while idle is a no-op")
    func stopWhileIdle() async {
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy
        )
        await orchestrator.handle(.stopRecording)
        await #expect(orchestrator.phase == .idle)
        await #expect(spy.count() == 0)
    }

    @Test("Transcriber not ready: start is discarded, nothing recorded or inserted")
    func notReadyDiscards() async {
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy
        )
        await orchestrator.setTranscriberReady(false)
        await orchestrator.handle(.startRecording)
        // Never entered recording.
        await #expect(orchestrator.phase == .idle)
        await orchestrator.handle(.stopRecording)
        await #expect(spy.count() == 0)
    }

    @Test("Transcriber throws: drops to idle with no injection")
    func transcriberThrowsNoInjection() async {
        let spy = SpyInjector()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: ThrowingTranscriber(),
            injector: spy
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await #expect(orchestrator.phase == .idle)
        await #expect(spy.count() == 0)
    }
}

// MARK: - Cleanup stage

/// Cleaner double: returns a fixed transform, optionally throws, optionally
/// hangs (to exercise the wait/replace timeouts).
private struct SpyCleaner: Cleaner {
    enum Behaviour { case transform(String); case fail; case hang }
    let tier: CleanupTier
    let behaviour: Behaviour

    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        switch behaviour {
        case let .transform(out): return out
        case .fail: throw CleanerError.unusableOutput
        case .hang:
            try await Task.sleep(for: .seconds(60))
            return transcript
        }
    }
}

private func modes(defaultTier: CleanupTier) -> InMemoryModeProvider {
    InMemoryModeProvider(modes: [
        DictationMode(id: "d", name: "Default", bundleIDPattern: nil, cleanupTier: defaultTier, isDefault: true),
    ])
}

@Suite("DictationOrchestrator cleanup stage")
struct DictationOrchestratorCleanupTests {
    private func makeClip() -> AudioClip {
        AudioClip(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 16_000, duration: 0.25)
    }

    /// Wait for the detached cleanup+replace task to run.
    private func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("AX target: raw inserted immediately, then replaced with cleaned text")
    func axReplaceWithCleaned() async {
        let spy = SpyInjector(direct: true)
        let cleaner = SpyCleaner(tier: .local, behaviour: .transform("CLEANED"))
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(defaultTier: .local)
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await #expect(spy.count() == 1)
        await #expect(spy.first() == StubTranscriber.output) // raw first
        await settle()
        await #expect(spy.replaceCount() == 1)
        await #expect(spy.firstReplaced() == "CLEANED")
    }

    @Test("Cleaner failure leaves the raw text; no replace")
    func cleanerFailureLeavesRaw() async {
        let spy = SpyInjector(direct: true)
        let cleaner = SpyCleaner(tier: .local, behaviour: .fail)
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(defaultTier: .local)
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()
        await #expect(spy.count() == 1)
        await #expect(spy.replaceCount() == 0)
    }

    @Test("Raw tier: no cleanup, no replace")
    func rawTierNoCleanup() async {
        let spy = SpyInjector(direct: true)
        let cleaner = SpyCleaner(tier: .local, behaviour: .transform("CLEANED"))
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(defaultTier: .raw)
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()
        await #expect(spy.first() == StubTranscriber.output)
        await #expect(spy.replaceCount() == 0)
    }

    @Test("Paste target: wait-for-clean inserts the cleaned text")
    func pasteWaitForCleanSucceeds() async {
        let spy = SpyInjector(direct: false)
        let cleaner = SpyCleaner(tier: .local, behaviour: .transform("CLEANED"))
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(defaultTier: .local)
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await #expect(spy.count() == 1)
        await #expect(spy.first() == "CLEANED") // cleaned inserted directly
        await #expect(spy.replaceCount() == 0)  // paste path never replaces
    }

    @Test("Paste target: wait-for-clean times out to raw")
    func pasteWaitForCleanTimesOut() async {
        let spy = SpyInjector(direct: false)
        let cleaner = SpyCleaner(tier: .local, behaviour: .hang)
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(defaultTier: .local),
            waitForCleanTimeout: .milliseconds(30)
        )
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await #expect(spy.count() == 1)
        await #expect(spy.first() == StubTranscriber.output) // fell back to raw
    }
}
