import Testing
import SkylarkCore

// MARK: - Test doubles

private final class CmdFakeCapture: AudioCapturing, @unchecked Sendable {
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

/// Stub command runner: returns a fixed result, or throws, and records the
/// (selection, tier) it was asked to run.
private actor StubCommandRunner: CommandRunning {
    enum Behavior: Sendable { case succeed(String); case fail }
    private let behavior: Behavior
    private(set) var runCount = 0
    private(set) var lastSelection: String?
    private(set) var lastTier: CleanupTier?

    init(_ behavior: Behavior) { self.behavior = behavior }

    func run(instruction: String, selection: String?, tier: CleanupTier) async throws -> CommandOutcome {
        runCount += 1
        lastSelection = selection
        lastTier = tier
        switch behavior {
        case let .succeed(text): return CommandOutcome(text: text)
        case .fail: throw CommandError.unavailable(reason: "stub failure")
        }
    }

    func runs() -> Int { runCount }
    func selection() -> String? { lastSelection }
}

/// Spy injector for command mode: readSelection returns a configured selection
/// (or nil), and both replaceSelection and insert are recorded.
private actor CommandSpyInjector: TextInjecting {
    private let selectionText: String?
    private let replaceSucceeds: Bool
    private(set) var inserted: [String] = []
    private(set) var replaced: [String] = []
    private(set) var readSelectionCount = 0

    init(selectionText: String?, replaceSucceeds: Bool = true) {
        self.selectionText = selectionText
        self.replaceSucceeds = replaceSucceeds
    }

    func insert(_ text: String) async throws -> InsertionToken {
        inserted.append(text)
        return InsertionToken(method: .paste, text: text, pasteUncertain: false)
    }

    func replace(_ token: InsertionToken, with text: String) async throws {}

    func canInsertDirectly() async -> Bool { false }

    func readSelection() async -> CommandSelection? {
        readSelectionCount += 1
        guard let selectionText else { return nil }
        return CommandSelection(text: selectionText)
    }

    func replaceSelection(_ selection: CommandSelection, with text: String) async -> Bool {
        replaced.append(text)
        return replaceSucceeds
    }

    func insertedTexts() -> [String] { inserted }
    func replacedTexts() -> [String] { replaced }
    func reads() -> Int { readSelectionCount }
}

// MARK: - Tests

@Suite("Command mode orchestrator")
struct CommandModeOrchestratorTests {
    private func makeClip() -> AudioClip {
        AudioClip(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 16_000, duration: 0.25)
    }

    private func makeOrchestrator(
        injector: any TextInjecting,
        runner: any CommandRunning
    ) -> DictationOrchestrator {
        DictationOrchestrator(
            capture: CmdFakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: injector,
            commandRunner: runner
        )
    }

    @Test("Selection present → the command result replaces the selection (no insert)")
    func replaceOnSelection() async {
        let injector = CommandSpyInjector(selectionText: "the old text")
        let runner = StubCommandRunner(.succeed("the friendly new text"))
        let orchestrator = makeOrchestrator(injector: injector, runner: runner)
        await orchestrator.setTierOverride(.cloud(slug: "test/model"))

        await orchestrator.handle(.startCommand)
        await orchestrator.handle(.stopCommand)

        await #expect(orchestrator.phase == .idle)
        await #expect(injector.replacedTexts() == ["the friendly new text"])
        await #expect(injector.insertedTexts().isEmpty)
        await #expect(runner.runs() == 1)
        await #expect(runner.selection() == "the old text")
    }

    @Test("No selection → the command result is inserted at the cursor")
    func insertOnNoSelection() async {
        let injector = CommandSpyInjector(selectionText: nil)
        let runner = StubCommandRunner(.succeed("a freshly generated sentence"))
        let orchestrator = makeOrchestrator(injector: injector, runner: runner)
        await orchestrator.setTierOverride(.local)

        await orchestrator.handle(.startCommand)
        await orchestrator.handle(.stopCommand)

        await #expect(orchestrator.phase == .idle)
        await #expect(injector.insertedTexts() == ["a freshly generated sentence"])
        await #expect(injector.replacedTexts().isEmpty)
        await #expect(runner.selection() == nil)
    }

    @Test("Raw tier → refuse: no selection read, nothing inserted or replaced")
    func rawTierRefusal() async {
        let injector = CommandSpyInjector(selectionText: "important selected text")
        let runner = StubCommandRunner(.succeed("should never be produced"))
        let orchestrator = makeOrchestrator(injector: injector, runner: runner)
        await orchestrator.setTierOverride(.raw)

        await orchestrator.handle(.startCommand)
        await orchestrator.handle(.stopCommand)

        await #expect(orchestrator.phase == .idle)
        await #expect(injector.reads() == 0)          // nothing destructive: never read
        await #expect(injector.replacedTexts().isEmpty)
        await #expect(injector.insertedTexts().isEmpty)
        await #expect(runner.runs() == 0)             // LLM never called
    }

    @Test("LLM failure leaves the selection untouched (no replace, no insert)")
    func llmFailureLeavesSelection() async {
        let injector = CommandSpyInjector(selectionText: "keep me exactly as-is")
        let runner = StubCommandRunner(.fail)
        let orchestrator = makeOrchestrator(injector: injector, runner: runner)
        await orchestrator.setTierOverride(.cloud(slug: "test/model"))

        await orchestrator.handle(.startCommand)
        await orchestrator.handle(.stopCommand)

        await #expect(orchestrator.phase == .idle)
        await #expect(injector.replacedTexts().isEmpty)
        await #expect(injector.insertedTexts().isEmpty)
        await #expect(runner.runs() == 1)             // it was attempted…
    }

    @Test("Model echoing the selection unchanged is a no-op (no write)")
    func echoedSelectionIsNoOp() async {
        let injector = CommandSpyInjector(selectionText: "unchanged text")
        let runner = StubCommandRunner(.succeed("unchanged text"))
        let orchestrator = makeOrchestrator(injector: injector, runner: runner)
        await orchestrator.setTierOverride(.local)

        await orchestrator.handle(.startCommand)
        await orchestrator.handle(.stopCommand)

        await #expect(orchestrator.phase == .idle)
        await #expect(injector.replacedTexts().isEmpty)
        await #expect(injector.insertedTexts().isEmpty)
    }

    @Test("A command session is distinct from dictation: startCommand drives the command path")
    func startCommandDrivesCommandPath() async {
        // With no runner wired, startCommand must NOT start a recording (it needs
        // a runner); it stays idle rather than falling through to dictation.
        let injector = CommandSpyInjector(selectionText: "x")
        let orchestrator = DictationOrchestrator(
            capture: CmdFakeCapture(clip: makeClip()),
            transcriber: StubTranscriber(),
            injector: injector,
            commandRunner: nil
        )
        await orchestrator.handle(.startCommand)
        await #expect(orchestrator.phase == .idle)
    }
}
