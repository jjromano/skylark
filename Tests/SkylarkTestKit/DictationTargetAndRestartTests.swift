import ApplicationServices
import Foundation
import Testing
@testable import SkylarkCore

// P1-4 (deep-link target capture), P1-6 (cloud dictionary filtering at the
// orchestrator seam) and U5 (a hotkey press while the previous utterance is
// still processing).

// MARK: - Doubles

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

private struct FixedTranscriber: Transcriber {
    let id: TranscriberID = .stub
    let text: String
    func warmUp() async throws {}
    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String { text }
}

/// Counts decodes and blocks inside `transcribe` until released.
private final class GatedCountingTranscriber: Transcriber, @unchecked Sendable {
    let id: TranscriberID = .stub
    let entered: Latch
    let release: Latch
    private let lock = NSLock()
    private var calls = 0

    init(entered: Latch, release: Latch) {
        self.entered = entered
        self.release = release
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    private func bump() {
        lock.lock(); calls += 1; lock.unlock()
    }

    func warmUp() async throws {}
    func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        bump()
        entered.open()
        await release.wait()
        return StubTranscriber.output
    }
}

/// Records the dictionary terms the cleaner was actually handed.
private final class RecordingCleaner: Cleaner, @unchecked Sendable {
    let tier: CleanupTier
    private let lock = NSLock()
    private var seen: [String]?

    init(tier: CleanupTier) { self.tier = tier }

    var receivedTerms: [String]? {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    private func record(_ terms: [String]) {
        lock.lock(); seen = terms; lock.unlock()
    }

    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        record(context.dictionaryTerms)
        return "CLEANED"
    }
}

private actor SpyInjector: TextInjecting {
    private(set) var inserted: [String] = []
    private let direct: Bool

    init(direct: Bool = false) { self.direct = direct }

    func insert(_ text: String) async throws -> InsertionToken {
        inserted.append(text)
        return InsertionToken(
            method: direct ? .ax(AXUIElementCreateSystemWide()) : .paste,
            text: text,
            pasteUncertain: false
        )
    }

    func replace(_ token: InsertionToken, with text: String) async throws {}
    func canInsertDirectly() async -> Bool { direct }
    func count() -> Int { inserted.count }
    func first() -> String? { inserted.first }
}

/// Mutable frontmost-app state shared by the guard's closures.
private final class FrontmostState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var activationRequests: [String] = []

    init(_ value: String?) { self.value = value }

    var current: String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    var activations: [String] {
        lock.lock(); defer { lock.unlock() }
        return activationRequests
    }

    /// Activation succeeds and actually brings the app forward.
    func activate(_ bundleID: String) -> Bool {
        lock.lock()
        activationRequests.append(bundleID)
        value = bundleID
        lock.unlock()
        return true
    }
}

private func modes(defaultTier: CleanupTier) -> InMemoryModeProvider {
    InMemoryModeProvider(modes: [
        DictationMode(id: "d", name: "Default", bundleIDPattern: nil, cleanupTier: defaultTier, isDefault: true),
    ])
}

private func makeClip() -> AudioClip {
    AudioClip(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 16_000, duration: 0.25)
}

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

// MARK: - Deep-link target capture (P1-4)

@Suite("Deep-link dictation target")
struct DeepLinkTargetTests {
    private static let ownBundleID = "com.jjromano.skylark"

    /// An orchestrator whose frontmost app is Skylark itself — the state
    /// `open skylark://record/start` leaves behind.
    private func makeOrchestrator(state: FrontmostState, spy: SpyInjector) -> DictationOrchestrator {
        DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: spy,
            frontmostBundleID: { state.current },
            focusGuard: CapturedTargetGuard(
                frontmost: { state.current },
                activate: { state.activate($0) },
                ownBundleID: Self.ownBundleID,
                pollInterval: .milliseconds(1),
                timeout: .milliseconds(200)
            )
        )
    }

    @Test("Without an explicit target, a Skylark-frontmost start captures Skylark (the bug)")
    func withoutPendingTargetCapturesSkylark() async {
        let state = FrontmostState(Self.ownBundleID)
        let spy = SpyInjector()
        let orchestrator = makeOrchestrator(state: state, spy: spy)

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        // The guard stands down for our own bundle ID, so nothing is activated
        // and the text lands wherever Skylark is — this is P1-4 reproduced.
        #expect(state.activations.isEmpty)
        await #expect(spy.count() == 1)
    }

    @Test("A deep-link target is captured instead of Skylark and is activated before the write")
    func pendingTargetIsCapturedAndActivated() async {
        let state = FrontmostState(Self.ownBundleID)
        let spy = SpyInjector()
        let orchestrator = makeOrchestrator(state: state, spy: spy)

        await orchestrator.setPendingTarget(bundleID: "com.apple.TextEdit")
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        #expect(state.activations == ["com.apple.TextEdit"])
        await #expect(spy.count() == 1)
        #expect(state.current == "com.apple.TextEdit")
    }

    @Test("A deep-link target applies to exactly one session")
    func pendingTargetIsConsumedOnce() async {
        let state = FrontmostState(Self.ownBundleID)
        let spy = SpyInjector()
        let orchestrator = makeOrchestrator(state: state, spy: spy)

        await orchestrator.setPendingTarget(bundleID: "com.apple.TextEdit")
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(state.activations == ["com.apple.TextEdit"])

        // Second session: frontmost is now TextEdit (activated above) and no
        // target was supplied, so the normal fn-down read applies — no further
        // activation request.
        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        #expect(state.activations == ["com.apple.TextEdit"])
        await #expect(spy.count() == 2)
    }

    @Test("A refused start does not leave a stale target behind")
    func refusedStartClearsPendingTarget() async {
        let state = FrontmostState(Self.ownBundleID)
        let spy = SpyInjector()
        let orchestrator = makeOrchestrator(state: state, spy: spy)
        await orchestrator.setTranscriberReady(false)

        await orchestrator.setPendingTarget(bundleID: "com.apple.TextEdit")
        await orchestrator.handle(.startRecording) // refused: model not ready
        await orchestrator.setTranscriberReady(true)

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)
        // The stale target must not have been adopted by this session.
        #expect(state.activations.isEmpty)
    }
}

// MARK: - Cloud dictionary filtering (P1-6)

@Suite("Cloud dictionary filtering")
struct CloudDictionaryFilterTests {
    private let dictionary = InMemoryDictionaryProvider(entries: [
        DictionaryEntry(phrase: "Kubernetes", source: .manual),
        DictionaryEntry(phrase: "Anthropic", source: .manual),
        DictionaryEntry(phrase: "Priya Raghunathan", source: .manual),
    ])

    @Test("A cloud request carries only the terms the transcript approximates")
    func cloudGetsFilteredTerms() async {
        let cleaner = RecordingCleaner(tier: .cloud(slug: "m"))
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: FixedTranscriber(text: "redeploy the kubernetes cluster tonight"),
            injector: SpyInjector(),
            cleaners: CleanerRegistry(cloud: ["m": cleaner]),
            modeProvider: modes(defaultTier: .cloud(slug: "m")),
            dictionary: dictionary
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        #expect(cleaner.receivedTerms == ["Kubernetes"])
    }

    @Test("A cloud request with no matching term carries no dictionary at all")
    func cloudGetsNothingWhenNothingMatches() async {
        let cleaner = RecordingCleaner(tier: .cloud(slug: "m"))
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: FixedTranscriber(text: "remind me to buy milk on the way home"),
            injector: SpyInjector(),
            cleaners: CleanerRegistry(cloud: ["m": cleaner]),
            modeProvider: modes(defaultTier: .cloud(slug: "m")),
            dictionary: dictionary
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        #expect(cleaner.receivedTerms == [])
    }

    @Test("Local cleanup still gets the whole dictionary — nothing leaves the machine")
    func localKeepsFullDictionary() async {
        let cleaner = RecordingCleaner(tier: .local)
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: FixedTranscriber(text: "remind me to buy milk on the way home"),
            injector: SpyInjector(),
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: modes(defaultTier: .local),
            dictionary: dictionary
        )

        await orchestrator.handle(.startRecording)
        await orchestrator.handle(.stopRecording)

        #expect(cleaner.receivedTerms == ["Kubernetes", "Anthropic", "Priya Raghunathan"])
    }
}

// MARK: - Start during processing (U5)

@Suite("Start while the previous utterance is processing")
struct StartDuringProcessingTests {
    @Test("The press is refused with a note and never starts a second capture")
    func startDuringProcessingIsRefused() async {
        let spy = SpyInjector()
        let entered = Latch()
        let release = Latch()
        let transcriber = GatedCountingTranscriber(entered: entered, release: release)
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: transcriber,
            injector: spy
        )

        await orchestrator.handle(.startRecording)
        let finish = Task { await orchestrator.handle(.stopRecording) }
        await entered.wait()

        // Hotkey pressed again while the first utterance is still decoding.
        await orchestrator.handle(.startRecording)
        #expect(await firstNote(orchestrator) == DictationOrchestrator.stillProcessingNote)
        await #expect(orchestrator.phase == .transcribing) // still the FIRST session

        // ...and the release that follows must not finalize an empty clip.
        await orchestrator.handle(.stopRecording)
        release.open()
        await finish.value

        await #expect(orchestrator.phase == .idle)
        #expect(transcriber.callCount == 1)
        await #expect(spy.count() == 1)
    }

    @Test("A fresh session right after the refusal works normally")
    func sessionAfterRefusalWorks() async {
        let spy = SpyInjector()
        let entered = Latch()
        let release = Latch()
        let orchestrator = DictationOrchestrator(
            capture: FakeCapture(clip: makeClip()),
            transcriber: GatedCountingTranscriber(entered: entered, release: release),
            injector: spy
        )

        await orchestrator.handle(.startRecording)
        let finish = Task { await orchestrator.handle(.stopRecording) }
        await entered.wait()
        await orchestrator.handle(.startRecording) // refused
        release.open()
        await finish.value
        await #expect(spy.count() == 1)

        await orchestrator.handle(.startRecording)
        await #expect(orchestrator.phase == .recording)
        await orchestrator.handle(.stopRecording)
        await #expect(spy.count() == 2)
    }
}
