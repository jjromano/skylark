import Testing
import SkylarkCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Fake backend so prompt/hygiene/availability paths are testable without real
/// on-device generation (unavailable on the CLT-only box).
private actor FakeBackend: LocalCleanupBackend {
    let unavailable: String?
    let output: String
    let shouldThrow: Bool
    private(set) var lastInstructions: String?
    private(set) var lastUserMessage: String?
    private(set) var lastMaxTokens: Int?
    private(set) var prewarmCount = 0

    init(unavailable: String? = nil, output: String = "", shouldThrow: Bool = false) {
        self.unavailable = unavailable
        self.output = output
        self.shouldThrow = shouldThrow
    }

    func unavailability() async -> String? { unavailable }

    func generate(instructions: String, userMessage: String, maximumResponseTokens: Int) async throws -> String {
        lastInstructions = instructions
        lastUserMessage = userMessage
        lastMaxTokens = maximumResponseTokens
        if shouldThrow { throw CleanerError.unusableOutput }
        return output
    }

    func prewarm(instructions: String) async { prewarmCount += 1 }

    func instructions() -> String? { lastInstructions }
    func userMessage() -> String? { lastUserMessage }
    func maxTokens() -> Int? { lastMaxTokens }
    func prewarms() -> Int { prewarmCount }
}

/// Backend that maps each generation's fenced transcript to an output via a
/// closure, recording every chunk it was handed — lets chunking tests drive
/// per-chunk behavior (clean one chunk, fail another) that the fixed-output
/// `FakeBackend` can't express.
private actor MappingBackend: LocalCleanupBackend {
    let responder: @Sendable (String) throws -> String
    private(set) var seenTranscripts: [String] = []
    private(set) var prewarmCount = 0

    init(responder: @escaping @Sendable (String) throws -> String) {
        self.responder = responder
    }

    func unavailability() async -> String? { nil }

    func generate(instructions: String, userMessage: String, maximumResponseTokens: Int) async throws -> String {
        let transcript = Self.unfence(userMessage)
        seenTranscripts.append(transcript)
        return try responder(transcript)
    }

    func prewarm(instructions: String) async { prewarmCount += 1 }

    func transcripts() -> [String] { seenTranscripts }
    func prewarms() -> Int { prewarmCount }

    /// Recover the raw chunk from the `<transcript>…</transcript>` user message.
    static func unfence(_ userMessage: String) -> String {
        var s = userMessage
        if let r = s.range(of: "<transcript>") { s = String(s[r.upperBound...]) }
        if let r = s.range(of: "</transcript>", options: .backwards) { s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite("LocalCleaner")
struct LocalCleanerTests {
    @Test("Unavailable model throws CleanerError.unavailable with the reason")
    func unavailablePath() async {
        let backend = FakeBackend(unavailable: "Apple Intelligence is not enabled")
        let cleaner = LocalCleaner(backend: backend)
        await #expect(throws: CleanerError.self) {
            _ = try await cleaner.clean("hello there", context: CleanupContext())
        }
    }

    @Test("Local tier uses the COMPACT prompt (not the cloud instructions) + fenced user message")
    func promptAssembly() async throws {
        let backend = FakeBackend(output: "Hello there.")
        let cleaner = LocalCleaner(backend: backend)
        let context = CleanupContext(registerHint: "email", dictionaryTerms: ["Skylark"])
        _ = try await cleaner.clean("hello there", context: context)

        let instructions = await backend.instructions()
        let user = await backend.userMessage()
        // The local cleaner diverged onto the compact prompt; it must NOT send
        // the fuller cloud instructions.
        #expect(instructions == CleanupPrompt.compactInstructions(context: context))
        #expect(instructions != CleanupPrompt.instructions(context: context))
        #expect(user == CleanupPrompt.userMessage(transcript: "hello there"))
    }

    @Test("Prewarms the next session after a successful generation")
    func prewarmsNext() async throws {
        let backend = FakeBackend(output: "Clean.")
        let cleaner = LocalCleaner(backend: backend)
        _ = try await cleaner.clean("clean", context: CleanupContext())
        await #expect(backend.prewarms() == 1)
    }

    @Test("Hygiene strips surrounding quotes and trims")
    func hygieneStripsQuotes() async throws {
        let backend = FakeBackend(output: "  \"Hello there.\"  ")
        let cleaner = LocalCleaner(backend: backend)
        let out = try await cleaner.clean("hello there", context: CleanupContext())
        #expect(out == "Hello there.")
    }

    @Test("Empty output is unusable")
    func emptyOutputUnusable() async {
        let backend = FakeBackend(output: "   ")
        let cleaner = LocalCleaner(backend: backend)
        await #expect(throws: CleanerError.self) {
            _ = try await cleaner.clean("hello there", context: CleanupContext())
        }
    }

    @Test("Output longer than 3× input is unusable")
    func runawayOutputUnusable() async {
        let input = "hi"
        let backend = FakeBackend(output: String(repeating: "x", count: input.count * 3 + 1))
        let cleaner = LocalCleaner(backend: backend)
        await #expect(throws: CleanerError.self) {
            _ = try await cleaner.clean(input, context: CleanupContext())
        }
    }

    @Test("Backend failure surfaces as an error, keeping raw")
    func backendFailure() async {
        let backend = FakeBackend(shouldThrow: true)
        let cleaner = LocalCleaner(backend: backend)
        await #expect(throws: Error.self) {
            _ = try await cleaner.clean("hello there", context: CleanupContext())
        }
    }

    @Test("Arbitrarily long transcript no longer bails out — it is chunked and succeeds")
    func longTranscriptChunks() async throws {
        // Each chunk is returned uppercased so we can see it was cleaned, not
        // dropped. With chunking, a 5k-token transcript succeeds (old behavior
        // threw .unavailable).
        let backend = MappingBackend { chunk in chunk.uppercased() }
        let cleaner = LocalCleaner(backend: backend)
        let long = Array(repeating: "The build finished cleanly on staging today.", count: 40)
            .joined(separator: " ")
        let out = try await cleaner.clean(long, context: CleanupContext())
        #expect(out == long.uppercased())
        // Proof it actually chunked: more than one generation.
        await #expect(backend.transcripts().count > 1)
        await #expect(backend.prewarms() == 1)
    }

    @Test("A chunk that fails validation keeps ITS raw text; good chunks stay cleaned")
    func chunkLevelFallback() async throws {
        // Good chunks come back uppercased (cleaned); the chunk containing the
        // marker word returns off-topic garbage that fails the retention guard,
        // so that chunk falls back to its raw (lowercase) text — without
        // failing the whole transcript.
        let marker = "pineapple"
        let backend = MappingBackend { chunk in
            chunk.lowercased().contains(marker)
                ? "completely unrelated words with zero overlap whatsoever here"
                : chunk.uppercased()
        }
        let cleaner = LocalCleaner(backend: backend)

        // Build a transcript long enough to chunk, with the marker in exactly
        // one sentence.
        var sentences = Array(repeating: "The nightly build passed on staging.", count: 20)
        sentences.insert("We shipped the \(marker) release this morning.", at: 10)
        let transcript = sentences.joined(separator: " ")

        let chunks = LocalCleaner.sentenceChunks(transcript, maxTokens: 120)
        let badChunk = try #require(chunks.first { $0.lowercased().contains(marker) })
        let goodChunk = try #require(chunks.first { !$0.lowercased().contains(marker) })

        let out = try await cleaner.clean(transcript, context: CleanupContext())
        // Bad chunk preserved verbatim (raw); good chunk present uppercased.
        #expect(out.contains(badChunk))
        #expect(out.contains(goodChunk.uppercased()))
        // The garbage the model returned for the bad chunk never reaches output.
        #expect(!out.lowercased().contains("completely unrelated words"))
    }

    @Test("sentenceChunks: packs sentences up to the budget, splits on boundaries")
    func sentenceChunkBoundaries() {
        let text = "One two three. Four five six. Seven eight nine. Ten eleven twelve."
        // Budget ~4 tokens (~16 chars) → each ~14-char sentence is its own chunk.
        let tiny = LocalCleaner.sentenceChunks(text, maxTokens: 4)
        #expect(tiny.count == 4)
        #expect(tiny[0].contains("One"))
        #expect(tiny[3].contains("Ten"))

        // Generous budget → the whole thing packs into one chunk.
        let big = LocalCleaner.sentenceChunks(text, maxTokens: 500)
        #expect(big.count == 1)
    }

    @Test("sentenceChunks: input already within budget is a single passthrough chunk")
    func sentenceChunkShortPassthrough() {
        let text = "Just one short sentence here."
        let chunks = LocalCleaner.sentenceChunks(text, maxTokens: 120)
        #expect(chunks == [text])
    }

    @Test("sentenceChunks: an unpunctuated over-long 'sentence' is split into word windows")
    func sentenceChunkWordWindows() {
        // Raw dictation often arrives without punctuation as one long run;
        // it must still be bounded so arbitrarily long input succeeds.
        let run = Array(repeating: "word", count: 100).joined(separator: " ") // ~500 chars
        let chunks = LocalCleaner.sentenceChunks(run, maxTokens: 20)
        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(LocalCleaner.estimatedTokens(chunk) <= 20)
        }
        // No words dropped: rejoining recovers the original run.
        #expect(chunks.joined(separator: " ") == run)
    }

    #if canImport(FoundationModels)
    @Test("Local generation uses greedy (deterministic) decoding")
    func greedyDecoding() {
        let opts = LocalCleaner.cleanupOptions(maximumResponseTokens: 128)
        #expect(opts == GenerationOptions(sampling: .greedy, maximumResponseTokens: 128))
        #expect(opts != GenerationOptions(temperature: 0.1, maximumResponseTokens: 128))
    }
    #endif

    @Test("Response token budget is ~2× transcript tokens, clamped")
    func tokenBudget() {
        #expect(LocalCleaner.maximumResponseTokens(forTranscriptTokens: 10) == 64)   // floor
        #expect(LocalCleaner.maximumResponseTokens(forTranscriptTokens: 100) == 200) // 2×
        #expect(LocalCleaner.maximumResponseTokens(forTranscriptTokens: 5000) == 1024) // cap
    }

    @Test("sanitize handles smart quotes and whitespace")
    func sanitizeVariants() {
        #expect(LocalCleaner.sanitize("\u{201C}hi\u{201D}") == "hi")
        #expect(LocalCleaner.sanitize("  plain  ") == "plain")
        #expect(LocalCleaner.sanitize("no quotes here") == "no quotes here")
    }
}
