import ApplicationServices
import Testing
import SkylarkCore

// MARK: - Test doubles

private final class FakeCapture: AudioCapturing, @unchecked Sendable {
    let clip: AudioClip
    let levels: AsyncStream<Float>
    init(clip: AudioClip) {
        self.clip = clip
        let (stream, cont) = AsyncStream<Float>.makeStream()
        cont.finish()
        levels = stream
    }
    func prepare() {}
    func start() throws {}
    func stop() -> AudioClip { clip }
}

/// A transcriber that reports as Parakeet and surfaces token timings, so the
/// orchestrator's deep-vocabulary side channel engages.
private struct StubParakeet: Transcriber {
    let id: TranscriberID = .parakeet
    static let output = "sky lark ships today"
    static let timings = [
        TranscriptTiming(token: "sky", tokenID: 1, startTime: 0.0, endTime: 0.2, confidence: 0.9),
        TranscriptTiming(token: "lark", tokenID: 2, startTime: 0.2, endTime: 0.4, confidence: 0.9),
    ]
    func warmUp() async throws {}
    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String { Self.output }
    func lastTokenTimings() async -> [TranscriptTiming]? { Self.timings }
}

/// Records every rescore call and returns a configured result (nil = keep raw).
private actor SpyRescorer: DeepVocabularyRescoring {
    private(set) var calls: [(raw: String, sampleCount: Int, timingCount: Int)] = []
    private let result: String?
    init(result: String?) { self.result = result }
    func rescore(rawText: String, samples: [Float], timings: [TranscriptTiming]) async -> String? {
        calls.append((rawText, samples.count, timings.count))
        return result
    }
    func callCount() -> Int { calls.count }
    func firstRaw() -> String? { calls.first?.raw }
    func firstSampleCount() -> Int? { calls.first?.sampleCount }
}

/// Cleaner that records the exact transcript it was asked to clean, then returns
/// it wrapped so the caller can tell cleanup ran.
private actor RecordingCleaner: Cleaner {
    nonisolated let tier: CleanupTier = .local
    private(set) var seen: [String] = []
    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        seen.append(transcript)
        return "CLEANED(\(transcript))"
    }
    func seenFirst() -> String? { seen.first }
}

private struct SpyInjector: TextInjecting {
    let tokenBox: TokenBox
    final class TokenBox: @unchecked Sendable {
        var inserted: [String] = []
        var replaced: [String] = []
    }
    init(box: TokenBox) { tokenBox = box }
    func insert(_ text: String) async throws -> InsertionToken {
        tokenBox.inserted.append(text)
        return InsertionToken(method: .ax(AXUIElementCreateSystemWide()), text: text, pasteUncertain: false)
    }
    func replace(_ token: InsertionToken, with text: String) async throws {
        tokenBox.replaced.append(text)
    }
    func canInsertDirectly() async -> Bool { true }
}

private func modes(_ tier: CleanupTier) -> InMemoryModeProvider {
    InMemoryModeProvider(modes: [
        DictationMode(id: "d", name: "Default", bundleIDPattern: nil, cleanupTier: tier, isDefault: true),
    ])
}

// MARK: - Tests

@Suite("DictationOrchestrator deep-vocabulary stage")
struct DeepVocabularyOrchestratorTests {
    private func makeClip() -> AudioClip {
        AudioClip(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 16_000, duration: 0.25)
    }

    private func settle() async {
        for _ in 0..<80 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("Rescored text is fed to the cleanup stage and replaced in place")
    func rescoreFeedsCleaner() async {
        let box = SpyInjector.TokenBox()
        let cleaner = RecordingCleaner()
        let rescorer = SpyRescorer(result: "Skylark ships today")
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubParakeet(),
            injector: SpyInjector(box: box),
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(.local)
        )
        await orchestrator.setRescorer(rescorer)

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        // Raw stands immediately.
        #expect(box.inserted == [StubParakeet.output])
        await settle()

        // Rescorer saw the raw text + the clip samples + the timings.
        #expect(await rescorer.callCount() == 1)
        #expect(await rescorer.firstRaw() == StubParakeet.output)
        #expect(await rescorer.firstSampleCount() == 4)
        // Cleaner ran on the RESCORED text, not the raw text.
        #expect(await cleaner.seenFirst() == "Skylark ships today")
        // The final in-place replacement is the cleaned(rescored) text.
        #expect(box.replaced == ["CLEANED(Skylark ships today)"])
    }

    @Test("Rescore failure (nil) falls through: cleaner runs on the raw text")
    func rescoreFailureFallsThrough() async {
        let box = SpyInjector.TokenBox()
        let cleaner = RecordingCleaner()
        let rescorer = SpyRescorer(result: nil) // no change / failure
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubParakeet(),
            injector: SpyInjector(box: box),
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(.local)
        )
        await orchestrator.setRescorer(rescorer)

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()

        #expect(await rescorer.callCount() == 1)
        #expect(await cleaner.seenFirst() == StubParakeet.output) // raw, un-rescored
        #expect(box.replaced == ["CLEANED(\(StubParakeet.output))"])
    }

    @Test("Non-Parakeet engine skips rescoring entirely")
    func nonParakeetSkips() async {
        let box = SpyInjector.TokenBox()
        let cleaner = RecordingCleaner()
        let rescorer = SpyRescorer(result: "SHOULD NOT BE USED")
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(), // id == .stub, not .parakeet
            injector: SpyInjector(box: box),
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(.local)
        )
        await orchestrator.setRescorer(rescorer)

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()

        #expect(await rescorer.callCount() == 0) // never called
        #expect(await cleaner.seenFirst() == StubTranscriber.output)
    }

    @Test("No rescorer wired: Parakeet path behaves exactly as before")
    func noRescorerNoOp() async {
        let box = SpyInjector.TokenBox()
        let cleaner = RecordingCleaner()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubParakeet(),
            injector: SpyInjector(box: box),
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(.local)
        )
        // No setRescorer call.
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        await settle()

        #expect(await cleaner.seenFirst() == StubParakeet.output)
        #expect(box.replaced == ["CLEANED(\(StubParakeet.output))"])
    }
}
