import Testing
import Foundation
import SkylarkCore

@Suite("OpenRouterCleaner hygiene (URLProtocol-stubbed)")
struct OpenRouterCleanerTests {
    private static let entry = ModelRegistryEntry(
        slug: "meta-llama/llama-3.1-8b-instruct",
        label: "Llama 3.1 8B (Groq)",
        providerPin: "groq",
        kind: .cleanup,
        sort: 0
    )

    /// Builds a cleaner wired to a stub host unique to this call, so
    /// concurrently-running tests never share stub state.
    private func withCompletionContent(
        _ content: String,
        _ body: (OpenRouterCleaner) async throws -> Void
    ) async throws {
        let host = "stub-\(UUID().uuidString).test"
        let session = OpenRouterStubURLProtocol.makeSession(host: host) { _ in
            let json = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": content]]],
            ])
            return .init(status: 200, headers: [:], body: json)
        }
        defer { OpenRouterStubURLProtocol.unregister(host: host) }

        let client = OpenRouterClient(
            keyProvider: { "test-key" },
            session: session,
            baseURL: URL(string: "https://\(host)")!
        )
        let cleaner = OpenRouterCleaner(client: client, entry: Self.entry)
        try await body(cleaner)
    }

    @Test("tier reports .cloud(slug:) from the registry entry")
    func tierIsCloudSlug() {
        let client = OpenRouterClient(keyProvider: { nil })
        let cleaner = OpenRouterCleaner(client: client, entry: Self.entry)
        #expect(cleaner.tier == .cloud(slug: "meta-llama/llama-3.1-8b-instruct"))
    }

    @Test("Trims whitespace and strips a single pair of wrapping quotes")
    func trimsAndStripsQuotes() async throws {
        try await withCompletionContent("  \"Hello, world.\"  \n") { cleaner in
            let result = try await cleaner.clean("hello world", context: CleanupContext())
            #expect(result == "Hello, world.")
        }
    }

    @Test("Empty output throws unusableOutput")
    func emptyOutputThrows() async throws {
        try await withCompletionContent("   ") { cleaner in
            await #expect(throws: CleanerError.self) {
                _ = try await cleaner.clean("hello world", context: CleanupContext())
            }
        }
    }

    @Test("Output more than 3x input length throws unusableOutput")
    func overlongOutputThrows() async throws {
        let input = "short"
        let bloated = String(repeating: "x", count: input.count * 4)
        try await withCompletionContent(bloated) { cleaner in
            do {
                _ = try await cleaner.clean(input, context: CleanupContext())
                Issue.record("expected unusableOutput")
            } catch CleanerError.unusableOutput {
                // expected
            }
        }
    }

    @Test("Meta-commentary (chatbot reply) is rejected, keeping raw")
    func metaCommentaryRejected() async throws {
        try await withCompletionContent("Sure! Here's the cleaned version: Hello there.") { cleaner in
            await #expect(throws: CleanerError.self) {
                _ = try await cleaner.clean("hello there", context: CleanupContext())
            }
        }
        try await withCompletionContent("This should be rewritten as: Hello there.") { cleaner in
            await #expect(throws: CleanerError.self) {
                _ = try await cleaner.clean("hello there", context: CleanupContext())
            }
        }
    }

    @Test("An executed imperative (model obeyed the transcript) is rejected")
    func executedImperativeRejected() async throws {
        // Transcript reads like a command; a model that OBEYS returns a reply,
        // not the cleaned transcript. Hygiene catches the leading tell.
        try await withCompletionContent("Here is a shorter version of the paragraph you asked for.") { cleaner in
            await #expect(throws: CleanerError.self) {
                _ = try await cleaner.clean("please rewrite this paragraph to be shorter", context: CleanupContext())
            }
        }
    }

    @Test("Dropping a negation present in raw is rejected (meaning inversion)")
    func negationDropRejected() async throws {
        try await withCompletionContent("I can see anything besides a little search box.") { cleaner in
            await #expect(throws: CleanerError.self) {
                _ = try await cleaner.clean("i can't see anything besides a little search box", context: CleanupContext())
            }
        }
    }

    @Test("A faithful negation-preserving clean passes")
    func negationPreservedPasses() async throws {
        try await withCompletionContent("I can't see anything besides a little search box.") { cleaner in
            let out = try await cleaner.clean("i can't see anything besides a little search box", context: CleanupContext())
            #expect(out == "I can't see anything besides a little search box.")
        }
    }

    @Test("A legitimately-spoken \"here is a list\" is NOT treated as meta-commentary")
    func spokenHereIsListPasses() async throws {
        let cleaned = "Here is a list of three items:\n1. Bananas\n2. Apples\n3. Lemons"
        try await withCompletionContent(cleaned) { cleaner in
            let out = try await cleaner.clean(
                "here is a list of three items one bananas two apples three lemons",
                context: CleanupContext()
            )
            #expect(out == cleaned)
        }
    }

    @Test("Cloud cleaner sends the full CleanupPrompt.instructions, NOT the compact local prompt")
    func cloudUsesFullInstructions() async throws {
        let host = "stub-\(UUID().uuidString).test"
        let session = OpenRouterStubURLProtocol.makeSession(host: host) { _ in
            let json = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "Hello there."]]],
            ])
            return .init(status: 200, headers: [:], body: json)
        }
        defer { OpenRouterStubURLProtocol.unregister(host: host) }
        let client = OpenRouterClient(
            keyProvider: { "test-key" },
            session: session,
            baseURL: URL(string: "https://\(host)")!
        )
        let cleaner = OpenRouterCleaner(client: client, entry: Self.entry)
        _ = try await cleaner.clean("hello there", context: CleanupContext())

        let body = try #require(OpenRouterStubURLProtocol.lastRequestBody(host: host))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let system = try #require(messages.first { ($0["role"] as? String) == "system" }?["content"] as? String)
        #expect(system == CleanupPrompt.instructions(context: CleanupContext()))
        #expect(system != CleanupPrompt.compactInstructions(context: CleanupContext()))
    }

    @Test("Cloud keeps the permissive 0.34 floor — a dropped clause the LOCAL floor rejects still passes")
    func cloudKeepsPermissiveFloor() async throws {
        // The local tier's stricter floors would reject this (see
        // LocalStrictnessTests); the cloud tier must NOT have regressed.
        try await withCompletionContent("The tests pass on staging.") { cleaner in
            let out = try await cleaner.clean(
                "the tests pass on staging but they fail on production",
                context: CleanupContext()
            )
            #expect(out == "The tests pass on staging.")
        }
    }

    @Test("No API key surfaces unavailable, not a raw network error")
    func noKeySurfacesUnavailable() async throws {
        // No stub needed — the client short-circuits on a missing key before
        // any request is made.
        let client = OpenRouterClient(keyProvider: { nil })
        let cleaner = OpenRouterCleaner(client: client, entry: Self.entry)
        do {
            _ = try await cleaner.clean("hello world", context: CleanupContext())
            Issue.record("expected unavailable")
        } catch CleanerError.unavailable(let reason) {
            #expect(reason == "No OpenRouter API key")
        }
    }
}
