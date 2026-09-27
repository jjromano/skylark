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
    private let idleTimer: IdleTimer?
    /// Mirrors of the runner's state, kept HERE so `isReadyNow` can answer
    /// while a load is running: the runner is an actor busy for the whole
    /// load, so asking it would wait the load out.
    private var resident = false
    private var loading = false
    /// A backend replaced by an engine switch must never reload itself from
    /// an in-flight dictation that still holds its cleaner.
    private var retired = false
    /// Bumped by every `unload`. A load or generate that was already in
    /// flight when an unload started must not mark the model resident when it
    /// finishes: the runner runs the queued unload right after it, and a stale
    /// `resident` would send the next paste into a cold load.
    private var unloadEpoch = 0
    /// Last instructions seen, so a load started by `isReadyNow` can also warm
    /// the shared prompt prefix.
    private var lastInstructions: String?
    private static let logger = Logger(subsystem: "com.jjromano.skylark", category: "cleanup.llama")

    /// An explicit idle timeout is useful for callers that choose to trade
    /// readiness for memory. The selected cleanup model stays resident by
    /// default until the user switches engines or quits.
    public static let idleUnloadTimeout: Duration = .seconds(300)

    public init(model: LocalCleanupModel, idleTimeout: Duration? = nil) {
        self.model = model
        self.runner = LlamaRunner(
            configuration: .init(modelURL: model.fileURL, contextTokens: model.contextTokens)
        )
        self.idleTimer = idleTimeout.map { IdleTimer(timeout: $0) }
    }

    /// Seam for a non-default engine configuration (smaller context, prefix reuse
    /// off, a hand-placed GGUF — see `LocalCleanupModel.custom`).
    public init(model: LocalCleanupModel, runner: LlamaRunner, idleTimeout: Duration? = nil) {
        self.model = model
        self.runner = runner
        self.idleTimer = idleTimeout.map { IdleTimer(timeout: $0) }
    }

    public var displayName: String { model.displayName }

    /// History provenance, so a row cleaned by this model is not labelled
    /// "Apple Intelligence" (see `LocalCleanupBackend.engineID`).
    public nonisolated var engineID: String { "local:\(model.id)" }

    // MARK: - LocalCleanupBackend

    public func unavailability() async -> String? {
        guard model.isInstalled else {
            return "the \(model.displayName) cleanup model isn't downloaded yet"
        }
        return nil
    }

    public func generate(instructions: String, userMessage: String, maximumResponseTokens: Int) async throws -> String {
        guard !retired else { throw LlamaRunner.Failure.notLoaded }
        let prompt = Self.prompt(instructions: instructions, userMessage: userMessage, model: model)
        lastInstructions = instructions
        let epoch = unloadEpoch
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
        if unloadEpoch == epoch { resident = true }
        if let idleTimer { await idleTimer.touch { [weak self] in await self?.unload() } }
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
        guard !retired else { return }
        guard await runner.isLoaded else { return }
        try? await runner.warm(prompt: LlamaChatML.systemPrefix(instructions: instructions))
    }

    // MARK: - Explicit lifecycle (off the paste path)

    /// Load the model and, when `instructions` are supplied, prefill them. Call
    /// this when the user selects this engine or after the download completes —
    /// never from the dictation path. Best-effort: failures leave the backend
    /// cold and the next `generate` retries.
    public func preload(instructions: String? = nil) async {
        guard !retired else { return }
        loading = true
        defer { loading = false }
        if let instructions { lastInstructions = instructions }
        let epoch = unloadEpoch
        do {
            try await runner.load()
            guard !retired, unloadEpoch == epoch else { return }
            if let instructions {
                try await runner.warm(prompt: LlamaChatML.systemPrefix(instructions: instructions))
            }
            guard !retired, unloadEpoch == epoch else { return }
            resident = true
            if let idleTimer { await idleTimer.touch { [weak self] in await self?.unload() } }
        } catch {
            Self.logger.error("qwen preload failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Free the model (~1–3 GB resident). Safe to call at any time; the next
    /// `generate` transparently reloads. Called on engine switch, quit, or by
    /// an explicitly configured idle timer. See `LlamaRunner.unload()`.
    public func unload() async {
        if let idleTimer { await idleTimer.cancel() }
        unloadEpoch += 1
        resident = false
        await runner.unload()
    }

    /// Permanently retire a replaced backend. Ordinary `unload()` still allows
    /// an explicitly configured idle timer to reload a selected backend.
    public func retire() async {
        retired = true
        await unload()
    }

    /// Ready once a load (and its prefix warm) has finished. Cold and idle, it
    /// starts that load in the background and says not ready, so the paste
    /// path uses Apple Intelligence now and this model next time, instead of
    /// spending the user's whole cleanup timeout on a 2.5 GB load (the first
    /// cleanup after a relaunch timed out in the 2026-09-08 human pass).
    public func isReadyNow() async -> Bool {
        guard !retired else { return false }
        if resident, !loading { return true }
        if !loading, model.isInstalled {
            loading = true
            let instructions = lastInstructions
            Task { await self.preload(instructions: instructions) }
        }
        return false
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
