import Foundation

/// Tier 2 cleanup: cloud model via OpenRouter (ARCHITECTURE §2, §6). Uses the
/// fuller `CleanupPrompt.instructions` and the shared `CleanupHygiene` guards
/// at their default (0.34) floor; the local tier diverged onto a compact,
/// few-shot prompt with stricter floors (see the `CleanupPrompt` note) because
/// the ~3B on-device model needs the extra hand-holding. The task is the same;
/// only the prompt phrasing and guard strictness differ per model size.
/// Non-streaming for v1 — the in-place replace needs the full cleaned text anyway.
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
        // Budget covers BOTH the cleaned answer AND any reasoning tokens. gpt-oss
        // models reason before answering, so a stingy cap (the old max(64, …·2) —
        // just 64 tokens for a short sentence) let the reasoning consume the whole
        // budget and TRUNCATE the answer to its first few words — the "only the
        // first 5-7 words survive" bug. This is a CAP, not a target: a
        // non-reasoning model still stops as soon as it finishes, so the generous
        // floor costs nothing there while giving reasoning models room to answer.
        let estimatedTokens = max(1, transcript.count / 4)
        let maxTokens = max(1024, estimatedTokens * 4)

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

        // Shared hygiene with LocalCleaner: trim/unquote, and reject empty,
        // runaway, meta-commentary, or negation-dropping output so the caller
        // keeps the raw transcript. In translation mode the source-language
        // retention/content-loss/negation guards are bypassed (a correct
        // translation shares no source vocabulary); the empty/runaway and
        // meta-commentary checks still apply.
        return try CleanupHygiene.validate(
            output, transcript: transcript,
            fieldContext: context.fieldContext,
            translated: context.translateTo != nil
        )
    }
}
