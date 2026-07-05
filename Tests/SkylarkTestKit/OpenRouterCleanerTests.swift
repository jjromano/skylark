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
