import Foundation

/// Tier 2 cleanup: cloud model via OpenRouter (ARCHITECTURE §2, §6). Uses the
/// same instruction set as `LocalCleaner` (`CleanupPrompt`) so tier switches
/// change the model, not the task. Non-streaming for v1 — the in-place replace
/// needs the full cleaned text anyway.
public struct OpenRouterCleaner: Cleaner {
    public let tier: CleanupTier

    private let client: OpenRouterClient
    private let entry: ModelRegistryEntry

    public init(client: OpenRouterClient, entry: ModelRegistryEntry) {
        self.client = client
        self.entry = entry
        self.tier = .cloud(slug: entry.slug)
    }

    public func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        let messages = [
            ChatMessage(role: .system, content: CleanupPrompt.instructions(context: context)),
            ChatMessage(role: .user, content: CleanupPrompt.userMessage(transcript: transcript)),
        ]
        // ~2× transcript tokens, estimating 4 chars/token; floor so short
        // transcripts still get room for punctuation/capitalization fixes.
        let estimatedTokens = max(1, transcript.count / 4)
        let maxTokens = max(64, estimatedTokens * 2)

        let output: String
        do {
            let stream = try await client.complete(
                messages: messages,
                model: entry.slug,
                providerPin: entry.providerPin,
                stream: false,
                temperature: 0.1,
                maxTokens: maxTokens
            )
            var collected = ""
            for try await chunk in stream {
                collected += chunk
            }
            output = collected
        } catch OpenRouterError.noKey {
            throw CleanerError.unavailable(reason: "No OpenRouter API key")
        } catch is OpenRouterError {
            throw CleanerError.unavailable(reason: "OpenRouter cleanup request failed")
        }

        return try Self.hygiene(output: output, inputLength: transcript.count)
    }

    /// Same output hygiene as `LocalCleaner`: trim whitespace, strip a single
    /// pair of wrapping quotes if the model added them, and reject empty or
    /// wildly-inflated output (caller keeps the raw text either way).
    private static func hygiene(output: String, inputLength: Int) throws -> String {
        var trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            trimmed = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty, trimmed.count <= inputLength * 3 else {
            throw CleanerError.unusableOutput
        }
        return trimmed
    }
}
