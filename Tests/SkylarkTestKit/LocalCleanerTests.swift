import Testing
import SkylarkCore

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

    @Test("Prompt assembly passes instructions + user message to the backend")
    func promptAssembly() async throws {
        let backend = FakeBackend(output: "Hello there.")
        let cleaner = LocalCleaner(backend: backend)
        let context = CleanupContext(registerHint: "email", dictionaryTerms: ["Skylark"])
        _ = try await cleaner.clean("hello there", context: context)

        let instructions = await backend.instructions()
        let user = await backend.userMessage()
        #expect(instructions == CleanupPrompt.instructions(context: context))
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

    @Test("Over-budget transcript is skipped (unavailable) before hitting the model")
    func truncationGuard() async {
        let backend = FakeBackend(output: "should not be used")
        let cleaner = LocalCleaner(backend: backend)
        let long = String(repeating: "word ", count: 4000) // ~20k chars → ~5k tokens
        await #expect(throws: CleanerError.self) {
            _ = try await cleaner.clean(long, context: CleanupContext())
        }
        let instructions = await backend.instructions()
        #expect(instructions == nil) // never called generate
    }

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
