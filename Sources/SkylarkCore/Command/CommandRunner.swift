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

/// Result of one command run: the produced text plus an optional user-facing
/// note when the run degraded off the requested tier (e.g. a cloud outage that
/// was served on-device). The note is a marker for the UI, never content.
public struct CommandOutcome: Sendable, Equatable {
    public let text: String
    /// Non-nil when the run silently degraded and the UI should say so, e.g.
    /// "Cloud unavailable — used on-device model". Nil on the normal path.
    public let note: String?
    public init(text: String, note: String? = nil) {
        self.text = text
        self.note = note
    }
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
    /// text (already trimmed) plus a degrade note if the requested tier fell
    /// back. Throws on unavailability/failure so the caller leaves the user's
    /// selection untouched.
    func run(instruction: String, selection: String?, tier: CleanupTier) async throws -> CommandOutcome
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

    /// Note surfaced when a cloud outage was served on-device (mirrors the
    /// dictation cloud→local degrade, so a command isn't hard-failed by the same
    /// outage that dictation shrugs off).
    public static let cloudDegradedNote = "Cloud unavailable — used on-device model"

    public func run(instruction: String, selection: String?, tier: CleanupTier) async throws -> CommandOutcome {
        let hasSelection = !(selection?.isEmpty ?? true)
        let system = CommandPrompt.systemPrompt(hasSelection: hasSelection)
        let user = CommandPrompt.userMessage(instruction: instruction, selection: selection)
        let maxTokens = CommandPrompt.maxResponseTokens(selection: selection)

        let raw: String
        var note: String?
        switch tier {
        case .raw:
            throw CommandError.needsCleanupModel
        case .local:
            if let reason = await localBackend.unavailability() {
                throw CommandError.unavailable(reason: reason)
            }
            raw = try await generateLocal(system: system, user: user, maxTokens: maxTokens)
        case .cloud(let slug):
            do {
                raw = try await runCloud(slug: slug, system: system, user: user, maxTokens: maxTokens)
            } catch let cloudError as CommandError {
                // Cloud outage (missing key / network). Degrade to the on-device
                // model — the same outage silently degrades dictation cloud→
                // local, so a command shouldn't hard-fail on it. Never degrade to
                // raw (a command with no model is meaningless): if local is also
                // unavailable, surface the original cloud error and leave the
                // selection untouched.
                guard case .unavailable = cloudError else { throw cloudError }
                guard await localBackend.unavailability() == nil else { throw cloudError }
                raw = try await generateLocal(system: system, user: user, maxTokens: maxTokens)
                note = Self.cloudDegradedNote
            }
        }

        let cleaned = CommandRunner.sanitize(raw)
        guard !cleaned.isEmpty else { throw CommandError.emptyResult }
        return CommandOutcome(text: cleaned, note: note)
    }

    /// Generate on the on-device backend, mapping any generation failure to the
    /// shared `unavailable` error. Assumes availability was already checked.
    private func generateLocal(system: String, user: String, maxTokens: Int) async throws -> String {
        do {
            return try await localBackend.generate(
                instructions: system, userMessage: user, maximumResponseTokens: maxTokens
            )
        } catch {
            throw CommandError.unavailable(reason: "on-device generation failed")
        }
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
