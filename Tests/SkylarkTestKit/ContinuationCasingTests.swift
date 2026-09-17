import ApplicationServices
import Testing
import SkylarkCore

// MARK: - The rule

@Suite("ContinuationCasing")
struct ContinuationCasingTests {
    private func mid(_ preceding: String = "so I think we should ") -> FieldContext {
        FieldContext(preceding: preceding, following: "")
    }

    @Test("Mid-sentence endings continue; sentence ends, line breaks and empty fields do not")
    func continuesSentence() {
        #expect(ContinuationCasing.continuesSentence("and then I"))
        #expect(ContinuationCasing.continuesSentence("and then I "))
        #expect(ContinuationCasing.continuesSentence("Hello, "))
        #expect(ContinuationCasing.continuesSentence("apples; "))
        #expect(ContinuationCasing.continuesSentence("version 2 "))
        #expect(ContinuationCasing.continuesSentence("the plan \u{2014} "))
        #expect(!ContinuationCasing.continuesSentence(""))
        #expect(!ContinuationCasing.continuesSentence("   "))
        #expect(!ContinuationCasing.continuesSentence("Done. "))
        #expect(!ContinuationCasing.continuesSentence("Really?"))
        #expect(!ContinuationCasing.continuesSentence("Wow!"))
        #expect(!ContinuationCasing.continuesSentence("Note:"))
        #expect(!ContinuationCasing.continuesSentence("a line\n"))
        #expect(!ContinuationCasing.continuesSentence("a line\n  "))
    }

    @Test("A continuation loses the recognizer's sentence-start capital")
    func lowercasesContinuation() {
        #expect(ContinuationCasing.apply("Make the button bigger.", context: mid()) == "make the button bigger.")
        #expect(ContinuationCasing.apply("Because it breaks.", context: mid("the reason is ")) == "because it breaks.")
        #expect(ContinuationCasing.apply("Please look at this.", context: mid("when you get a chance, ")) == "please look at this.")
        #expect(ContinuationCasing.apply("A quick fix.", context: mid("we need ")) == "a quick fix.")
    }

    @Test("No context, a finished sentence, or an already-lowercase start leaves the text alone")
    func leavesFreshStarts() {
        #expect(ContinuationCasing.apply("Make it so.", context: nil) == "Make it so.")
        #expect(ContinuationCasing.apply("Make it so.", context: mid("That works. ")) == "Make it so.")
        #expect(ContinuationCasing.apply("Make it so.", context: FieldContext(preceding: "", following: "tail")) == "Make it so.")
        #expect(ContinuationCasing.apply("make it so.", context: mid()) == "make it so.")
        #expect(ContinuationCasing.apply("", context: mid()) == "")
        #expect(ContinuationCasing.apply("\"Quoted\" text", context: mid()) == "\"Quoted\" text")
    }

    @Test("Genuine capitals survive: I, acronyms, mixed case, lone labels")
    func keepsGenuineCapitals() {
        #expect(ContinuationCasing.apply("I think so.", context: mid()) == "I think so.")
        #expect(ContinuationCasing.apply("I'm not sure.", context: mid()) == "I'm not sure.")
        #expect(ContinuationCasing.apply("API keys expire.", context: mid()) == "API keys expire.")
        #expect(ContinuationCasing.apply("GitHub is down.", context: mid()) == "GitHub is down.")
        #expect(ContinuationCasing.apply("X marks it.", context: mid()) == "X marks it.")
    }

    @Test("Proper nouns survive: dictionary terms, on-screen usage, and tagged names")
    func keepsProperNouns() {
        #expect(ContinuationCasing.apply("Zorblat works now.", context: mid(), protectedTerms: ["Zorblat"]) == "Zorblat works now.")
        #expect(ContinuationCasing.apply("Quibbly shipped.", context: mid("we asked Quibbly and ")) == "Quibbly shipped.")
        #expect(ContinuationCasing.apply("Quibbly shipped.", context: FieldContext(preceding: "and ", following: " so tell Quibbly.")) == "Quibbly shipped.")
        #expect(ContinuationCasing.apply("John about the bug.", context: mid("and then I told ")) == "John about the bug.")
        #expect(ContinuationCasing.apply("Chicago before it lands.", context: mid("the flight goes through ")) == "Chicago before it lands.")
    }

    @Test("A word capitalized only at sentence starts in the context is not treated as a name")
    func sentenceStartUsageIsNotEvidence() {
        let context = FieldContext(preceding: "It works. Make sure. And then ", following: "")
        #expect(ContinuationCasing.apply("Make the button bigger.", context: context) == "make the button bigger.")
    }
}

// MARK: - Every write path applies it

private final class CasingFakeCapture: AudioCapturing, @unchecked Sendable {
    let clip = AudioClip(samples: [0.1, 0.2, 0.3, 0.4], sampleRate: 16_000, duration: 0.25)
    let levels: AsyncStream<Float>
    init() {
        let (stream, cont) = AsyncStream<Float>.makeStream()
        cont.finish()
        levels = stream
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

private actor CasingInjector: TextInjecting {
    private let direct: Bool
    private(set) var inserted: [String] = []
    private(set) var replaced: [String] = []
    init(direct: Bool) { self.direct = direct }
    func insert(_ text: String) async throws -> InsertionToken {
        inserted.append(text)
        return InsertionToken(method: direct ? .ax(AXUIElementCreateSystemWide()) : .paste, text: text, pasteUncertain: false)
    }
    func replace(_ token: InsertionToken, with text: String) async throws { replaced.append(text) }
    func canInsertDirectly() async -> Bool { direct }
    func lastInserted() -> String? { inserted.last }
    func lastReplaced() -> String? { replaced.last }
}

private actor FixedContextReader: FieldContextReading {
    let result: FieldContext?
    init(_ result: FieldContext?) { self.result = result }
    func readFieldContext(bundleID: String?, precedingLimit: Int, followingLimit: Int) async -> FieldContext? { result }
}

/// Returns the transcript unchanged, like a cloud model that decided nothing needed editing.
private struct UnchangedCleaner: Cleaner {
    let tier: CleanupTier = .local
    func clean(_ transcript: String, context: CleanupContext) async throws -> String { transcript }
}

private struct SuffixCleaner: Cleaner {
    let tier: CleanupTier = .local
    func clean(_ transcript: String, context: CleanupContext) async throws -> String { transcript + " Done" }
}

@Suite("DictationOrchestrator continuation casing")
struct OrchestratorContinuationCasingTests {
    private let spoken = "Make the button bigger and move it to the left side"
    private let midSentence = FieldContext(preceding: "so I think we should ", following: "")

    private func settle() async {
        for _ in 0..<60 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func run(
        tier: CleanupTier, cleaner: any Cleaner, direct: Bool, context: FieldContext?, enabled: Bool = true
    ) async -> CasingInjector {
        let injector = CasingInjector(direct: direct)
        let orchestrator = DictationOrchestrator(
            capture: CasingFakeCapture(),
            transcriber: FixedTranscriber(text: spoken),
            injector: injector,
            cleaners: CleanerRegistry(local: cleaner),
            modeProvider: InMemoryModeProvider(modes: [
                DictationMode(id: "d", name: "Default", bundleIDPattern: nil, cleanupTier: tier, isDefault: true),
            ]),
            frontmostBundleID: { "com.anthropic.claudefordesktop" },
            fieldContextReader: FixedContextReader(context)
        )
        await orchestrator.setContextAwareCleanupEnabled(enabled)
        await orchestrator.handle(.startRecording)
        await settle()
        await orchestrator.handle(.stopRecording)
        await settle()
        return injector
    }

    @Test("Paste path: a cleanup that changed nothing still pastes lowercase mid-sentence")
    func pasteUnchangedCleanup() async {
        let injector = await run(tier: .local, cleaner: UnchangedCleaner(), direct: false, context: midSentence)
        await #expect(injector.lastInserted()?.hasPrefix("make the button bigger") == true)
    }

    @Test("Raw tier: no cleanup stage, still lowercase mid-sentence")
    func rawTier() async {
        let injector = await run(tier: .raw, cleaner: UnchangedCleaner(), direct: false, context: midSentence)
        await #expect(injector.lastInserted()?.hasPrefix("make the button bigger") == true)
    }

    @Test("In-place path: raw insert and the cleaned replacement are both lowercase")
    func inPlaceReplace() async {
        let injector = await run(tier: .local, cleaner: SuffixCleaner(), direct: true, context: midSentence)
        await #expect(injector.lastInserted()?.hasPrefix("make the button bigger") == true)
        await #expect(injector.lastReplaced()?.hasPrefix("make the button bigger") == true)
    }

    @Test("Start of a new sentence, or the feature off, keeps the capital")
    func keepsCapitalWithoutContinuation() async {
        let fresh = await run(tier: .local, cleaner: UnchangedCleaner(), direct: false,
                              context: FieldContext(preceding: "That works. ", following: ""))
        await #expect(fresh.lastInserted()?.hasPrefix("Make the button bigger") == true)
        let off = await run(tier: .local, cleaner: UnchangedCleaner(), direct: false, context: midSentence, enabled: false)
        await #expect(off.lastInserted()?.hasPrefix("Make the button bigger") == true)
    }
}
