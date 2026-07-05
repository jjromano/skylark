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

private actor SpyInjector: TextInjecting {
    private(set) var inserted: [String] = []

    func insert(_ text: String) async throws -> InsertionToken {
        inserted.append(text)
        return InsertionToken(method: .paste, text: text, pasteUncertain: false)
    }

    func replace(_ token: InsertionToken, with text: String) async throws {
        throw InjectionError.replaceNotImplemented
    }

    func count() -> Int { inserted.count }
    func first() -> String? { inserted.first }
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
}
