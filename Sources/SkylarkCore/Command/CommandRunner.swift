import Foundation

/// Errors from a Voice Command Mode run. Never carries selection/instruction
/// content — those may be private (privacy invariant §7).
public enum CommandError: Error, Sendable {
    /// The active cleanup tier is `.raw`; command mode needs a cleanup model.
    case needsCleanupModel
    /// The tier's LLM couldn't run (no key / Apple Intelligence off / network).
    case unavailable(reason: String)
    /// The model produced no usable text; the caller keeps the selection.
    case emptyResult
}

/// Runs one spoken instruction through the active cleanup-tier LLM. This is a
/// SEPARATE path from `Cleaner` (which cleans dictation with the cleanup
/// prompt): command mode uses `CommandPrompt` and a single, non-streaming
/// generation. Cloud → `OpenRouterClient` with the user's cleanup model; local
/// → the on-device `LocalCleanupBackend`; raw is refused by the orchestrator
/// before this is reached.
public protocol CommandRunning: Sendable {
    /// Apply `instruction` to `selection` (rewrite) or generate fresh text when
    /// `selection` is nil/empty, using the LLM for `tier`. Returns the resulting
    /// text (already trimmed). Throws on unavailability/failure so the caller
    /// leaves the user's selection untouched.
    func run(instruction: String, selection: String?, tier: CleanupTier) async throws -> String
}

/// Default implementation dispatching to cloud or local by tier.
public struct CommandRunner: CommandRunning {
    private let client: OpenRouterClient
    private let localBackend: any LocalCleanupBackend
    /// Provider pin applied to cloud requests (mirrors the cleanup cloudFactory,
    /// which Groq-pins the cleanup catalog per ARCHITECTURE §6).
    private let cloudProviderPin: String?

    public init(
        client: OpenRouterClient,
        localBackend: any LocalCleanupBackend,
        cloudProviderPin: String? = "groq"
    ) {
        self.client = client
        self.localBackend = localBackend
        self.cloudProviderPin = cloudProviderPin
    }

    public func run(instruction: String, selection: String?, tier: CleanupTier) async throws -> String {
        let hasSelection = !(selection?.isEmpty ?? true)
        let system = CommandPrompt.systemPrompt(hasSelection: hasSelection)
        let user = CommandPrompt.userMessage(instruction: instruction, selection: selection)
        let maxTokens = CommandPrompt.maxResponseTokens(selection: selection)

        let raw: String
        switch tier {
        case .raw:
            throw CommandError.needsCleanupModel
        case .local:
            if let reason = await localBackend.unavailability() {
                throw CommandError.unavailable(reason: reason)
            }
            do {
                raw = try await localBackend.generate(
                    instructions: system, userMessage: user, maximumResponseTokens: maxTokens
                )
            } catch {
                throw CommandError.unavailable(reason: "on-device generation failed")
            }
        case .cloud(let slug):
            raw = try await runCloud(slug: slug, system: system, user: user, maxTokens: maxTokens)
        }

        let cleaned = CommandRunner.sanitize(raw)
        guard !cleaned.isEmpty else { throw CommandError.emptyResult }
        return cleaned
    }

    private func runCloud(slug: String, system: String, user: String, maxTokens: Int) async throws -> String {
        let messages = [
            ChatMessage(role: .system, content: system),
            ChatMessage(role: .user, content: user),
        ]
        do {
            let stream = try await client.complete(
                messages: messages,
                model: slug,
                providerPin: cloudProviderPin,
                stream: false,
                temperature: 0.2,
                maxTokens: maxTokens
            )
            var collected = ""
            for try await chunk in stream { collected += chunk }
            return collected
        } catch OpenRouterError.noKey {
            throw CommandError.unavailable(reason: "No OpenRouter API key")
        } catch is OpenRouterError {
            throw CommandError.unavailable(reason: "OpenRouter request failed")
        }
    }

    /// Trim surrounding whitespace and a single layer of wrapping quotes — small
    /// models sometimes echo the result in quotes despite the instruction.
    /// Shared with the cleanup path's hygiene.
    public static func sanitize(_ output: String) -> String {
        CleanupHygiene.sanitize(output)
    }
}
