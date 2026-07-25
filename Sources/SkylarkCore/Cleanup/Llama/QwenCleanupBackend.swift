import Foundation
import os

/// `LocalCleanupBackend` conformer for a local Qwen GGUF run through llama.cpp —
/// the second on-device cleanup tier alongside `FoundationModelBackend`.
///
/// The two conformers are interchangeable by design: `LocalCleaner` owns prompt
/// selection (`CleanupPrompt.compactInstructions` — ONE shared local prompt),
/// chunking, and the `CleanupHygiene` faithfulness guards, so everything
/// model-specific lives HERE: ChatML assembly, Qwen3 thinking suppression, stop
/// strings, and context sizing.
///
/// Unavailability is a supported runtime state, exactly like Apple Intelligence
/// being off: if the GGUF isn't on disk this backend says so and the cleanup
/// pipeline degrades (Apple → raw). Cleanup never blocks the paste.
public actor QwenCleanupBackend: LocalCleanupBackend {
    private let model: LocalCleanupModel
    private let runner: LlamaRunner
    private let idleTimer: IdleTimer
    private static let logger = Logger(subsystem: "com.jjromano.skylark", category: "cleanup.llama")

    /// Unload the model after this long with no cleanup activity. Weights are
    /// ~1–2.5 GB resident, too much to hold indefinitely for an occasionally-used
    /// tier on a 16 GB machine; the next cleanup transparently reloads. Mirrors
    /// `FluidAudioDeepVocabularyRescorer`'s idle-unload window.
    public static let idleUnloadTimeout: Duration = .seconds(300)

    public init(model: LocalCleanupModel, idleTimeout: Duration = QwenCleanupBackend.idleUnloadTimeout) {
        self.model = model
        self.runner = LlamaRunner(
            configuration: .init(modelURL: model.fileURL, contextTokens: model.contextTokens)
        )
        self.idleTimer = IdleTimer(timeout: idleTimeout)
    }

    /// Seam for a non-default engine configuration (smaller context, prefix reuse
    /// off, a hand-placed GGUF — see `LocalCleanupModel.custom`).
    public init(model: LocalCleanupModel, runner: LlamaRunner, idleTimeout: Duration = QwenCleanupBackend.idleUnloadTimeout) {
        self.model = model
        self.runner = runner
        self.idleTimer = IdleTimer(timeout: idleTimeout)
    }

    public var displayName: String { model.displayName }

    // MARK: - LocalCleanupBackend

    public func unavailability() async -> String? {
        guard model.isInstalled else {
            return "the \(model.displayName) cleanup model isn't downloaded yet"
        }
        return nil
    }

    public func generate(instructions: String, userMessage: String, maximumResponseTokens: Int) async throws -> String {
        let prompt = Self.prompt(instructions: instructions, userMessage: userMessage, model: model)
        let result = try await runner.generate(
            prompt: prompt,
            maxTokens: maximumResponseTokens,
            stop: LlamaChatML.stopStrings
        )
        // Content-free: token counts and timings only (CLAUDE.md).
        Self.logger.info("""
            qwen cleanup: model=\(self.model.id, privacy: .public) \
            prompt=\(result.promptTokens, privacy: .public) \
            decoded=\(result.decodedPromptTokens, privacy: .public) \
            out=\(result.generatedTokens, privacy: .public) \
            ms=\(Int(result.totalSeconds * 1000), privacy: .public) \
            capped=\(result.hitTokenLimit, privacy: .public)
            """)
        // Keep the model warm for a follow-up dictation, then unload on idle.
        await idleTimer.touch { [weak self] in await self?.unload() }
        return Self.postprocess(result.text)
    }

    /// Warm the shared system prefix into the KV cache so the NEXT cleanup only
    /// prefills the transcript (the instructions are ~1.2 k tokens — by far the
    /// bulk of the prompt).
    ///
    /// Deliberately does NOT load the model: `LocalCleaner` awaits `prewarm`
    /// immediately after a generation, i.e. on the paste path, and a cold
    /// `llama_model_load_from_file` costs hundreds of milliseconds. Loading is
    /// `preload()`'s job, off the critical path.
    public func prewarm(instructions: String) async {
        guard await runner.isLoaded else { return }
        try? await runner.warm(prompt: LlamaChatML.systemPrefix(instructions: instructions))
    }

    // MARK: - Explicit lifecycle (off the paste path)

    /// Load the model and, when `instructions` are supplied, prefill them. Call
    /// this when the user selects this engine or after the download completes —
    /// never from the dictation path. Best-effort: failures leave the backend
    /// cold and the next `generate` retries.
    public func preload(instructions: String? = nil) async {
        do {
            try await runner.load()
            if let instructions {
                try await runner.warm(prompt: LlamaChatML.systemPrefix(instructions: instructions))
            }
            await idleTimer.touch { [weak self] in await self?.unload() }
        } catch {
            Self.logger.error("qwen preload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Free the model (~1–3 GB resident). Safe to call at any time; the next
    /// `generate` transparently reloads. Call it from the idle-unload timer AND
    /// on app termination — see the warning on `LlamaRunner.unload()`.
    public func unload() async {
        await idleTimer.cancel()
        await runner.unload()
    }

    /// Whether the weights are currently resident — the idle-unload timer's input.
    public func isModelLoaded() async -> Bool {
        await runner.isLoaded
    }

    // MARK: - Pure helpers (unit-tested)

    /// ChatML prompt for one cleanup turn: the shared local instructions as the
    /// system message, the fenced transcript as the user message, and an opened
    /// assistant turn (with Qwen3 thinking suppressed for the models that have a
    /// thinking mode).
    public static func prompt(instructions: String, userMessage: String, model: LocalCleanupModel) -> String {
        LlamaChatML.prompt(
            messages: [
                .init(role: .system, content: instructions),
                .init(role: .user, content: userMessage),
            ],
            suppressThinking: model.suppressesThinking
        )
    }

    /// Trim ChatML residue and any `<think>` leakage before the text reaches
    /// `CleanupHygiene.validate`.
    ///
    /// Reasoning removal is delegated to `CleanupHygiene.stripReasoningBlocks`,
    /// which `validate`'s sanitizer also runs — doing it here too is idempotent
    /// and keeps this backend's own contract ("never returns a reasoning block")
    /// true regardless of who consumes it. An UNCLOSED `<think>` — a response
    /// truncated mid-thought by the token cap — is stripped to empty, which
    /// hygiene then rejects so the raw transcript survives.
    public static func postprocess(_ raw: String) -> String {
        var text = raw
        for token in [LlamaChatML.imEnd, LlamaChatML.endOfText] {
            if let range = text.range(of: token) {
                text = String(text[text.startIndex..<range.lowerBound])
            }
        }
        return CleanupHygiene.stripReasoningBlocks(text)
    }
}
