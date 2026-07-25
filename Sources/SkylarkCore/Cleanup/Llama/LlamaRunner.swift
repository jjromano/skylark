import Foundation
import llama
import os

/// Single-threaded llama.cpp engine.
///
/// EVERY llama.cpp C call in Skylark happens inside this actor — the C API is not
/// thread-safe per context, and the pointers it hands back (`llama_model`,
/// `llama_context`, `llama_sampler`) are non-`Sendable` by nature. Isolating them
/// behind one actor makes that safety structural instead of a convention.
///
/// The actor deliberately runs on its OWN serial dispatch queue rather than the
/// global cooperative pool (`unownedExecutor` below): `llama_decode` is a long
/// synchronous call, and blocking a cooperative-pool thread with it would starve
/// the pool the audio/paste path also uses. Latency is the product (CLAUDE.md).
///
/// Backed by the prebuilt llama.cpp `binaryTarget` (upstream release b10107,
/// MIT — see `Vendor/LICENSE-llama.cpp.txt` and the target comment in
/// Package.swift). The load → tokenize → greedy-sample → decode shape follows
/// llama.cpp's own `simple` example; no GPL sources were consulted.
public actor LlamaRunner {
    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// GGUF file on disk. Nothing is downloaded here — see `LocalCleanupModel`.
        public var modelURL: URL
        /// KV-cache size in tokens. Must fit the (long) cleanup instructions plus
        /// the transcript plus the response.
        public var contextTokens: UInt32
        /// Logical batch size — the prefill is submitted in chunks this large.
        public var batchTokens: UInt32
        /// Layers to offload to Metal. `-1` = all (the fast path on Apple silicon).
        public var gpuLayers: Int32
        /// Generation threads; `0` lets llama.cpp pick.
        public var threads: Int32
        /// Reuse the KV cache across calls when the new prompt shares a prefix
        /// with the previous one. The cleanup instructions are byte-identical
        /// between dictations, so this skips ~1k tokens of prefill per utterance.
        public var reusePrefix: Bool

        public init(
            modelURL: URL,
            contextTokens: UInt32 = 4096,
            batchTokens: UInt32 = 512,
            gpuLayers: Int32 = -1,
            threads: Int32 = 0,
            reusePrefix: Bool = true
        ) {
            self.modelURL = modelURL
            self.contextTokens = contextTokens
            self.batchTokens = batchTokens
            self.gpuLayers = gpuLayers
            self.threads = threads
            self.reusePrefix = reusePrefix
        }
    }

    /// Content-free result of one generation. `text` is the ONLY field that ever
    /// holds model output; everything else is metadata safe to log.
    public struct Result: Sendable {
        public let text: String
        public let promptTokens: Int
        /// Prompt tokens actually decoded (the rest were served from the KV cache).
        public let decodedPromptTokens: Int
        public let generatedTokens: Int
        public let prefillSeconds: Double
        public let generateSeconds: Double
        /// True when generation stopped because it hit `maxTokens`, not EOG/stop.
        public let hitTokenLimit: Bool

        public var totalSeconds: Double { prefillSeconds + generateSeconds }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case modelFileMissing(String)
        case modelLoadFailed(String)
        case contextCreationFailed
        case samplerCreationFailed
        case tokenizationFailed
        case promptTooLong(promptTokens: Int, contextTokens: Int)
        case decodeFailed
        case notLoaded

        public var errorDescription: String? {
            switch self {
            case .modelFileMissing(let name): return "the \(name) model isn't downloaded"
            case .modelLoadFailed(let name): return "the \(name) model could not be loaded"
            case .contextCreationFailed: return "the local model context could not be created"
            case .samplerCreationFailed: return "the local model sampler could not be created"
            case .tokenizationFailed: return "the local model could not tokenize the request"
            case .promptTooLong: return "the request is too long for the local model's context"
            case .decodeFailed: return "the local model failed while generating"
            case .notLoaded: return "the local model is not loaded"
            }
        }
    }

    // MARK: - Own serial executor

    private let queue: DispatchSerialQueue

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    // MARK: - State

    /// Owns the llama.cpp pointers so their lifetime is structural: releasing the
    /// box frees the sampler, context and model in the right order, exactly once.
    /// That also sidesteps the fact that an actor's `deinit` is nonisolated and
    /// therefore cannot touch non-`Sendable` stored properties like these.
    ///
    /// `@unchecked Sendable` is sound by construction: the box is only ever read
    /// inside `LlamaRunner`'s isolation, and by the time `deinit` runs nothing
    /// else can reference it.
    private final class Handles: @unchecked Sendable {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocab: OpaquePointer
        let sampler: UnsafeMutablePointer<llama_sampler>

        init(
            model: OpaquePointer,
            context: OpaquePointer,
            vocab: OpaquePointer,
            sampler: UnsafeMutablePointer<llama_sampler>
        ) {
            self.model = model
            self.context = context
            self.vocab = vocab
            self.sampler = sampler
        }

        deinit {
            llama_sampler_free(sampler)
            llama_free(context)
            llama_model_free(model)
        }
    }

    private var configuration: Configuration
    private var handles: Handles?

    /// Tokens currently represented in the KV cache (prompt + what we generated),
    /// used for prefix reuse. Token IDs only — never detokenized, never logged.
    private var cachedTokens: [llama_token] = []

    /// Preallocated scratch so the hot path allocates nothing per call: the
    /// tokenizer buffer grows to the high-water mark and stays there, and
    /// `pieceBuffer` is reused for every detokenized token.
    private var tokenScratch: [llama_token] = []
    private var pieceBuffer = [CChar](repeating: 0, count: 256)

    private static let logger = Logger(subsystem: "com.jjromano.skylark", category: "llama")

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.queue = DispatchSerialQueue(label: "com.jjromano.skylark.llama", qos: .userInitiated)
    }

    // MARK: - Lifecycle

    public var isLoaded: Bool { handles != nil }

    public var modelURL: URL { configuration.modelURL }

    /// Load the model + context. Idempotent: a second call is a no-op.
    ///
    /// Loading a 1–4 B Q4 GGUF takes ~0.2–1.5 s (mmap + Metal buffer setup) and
    /// must therefore never be triggered from the paste path — drive it from
    /// `QwenCleanupBackend.preload()`, off the critical path.
    public func load() throws {
        guard handles == nil else { return }
        LlamaBackend.ensureInitialized()

        let path = configuration.modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw Failure.modelFileMissing(configuration.modelURL.lastPathComponent)
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = configuration.gpuLayers
        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw Failure.modelLoadFailed(configuration.modelURL.lastPathComponent)
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = configuration.contextTokens
        contextParams.n_batch = configuration.batchTokens
        contextParams.n_threads = configuration.threads > 0
            ? configuration.threads
            : contextParams.n_threads
        contextParams.n_threads_batch = contextParams.n_threads
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw Failure.contextCreationFailed
        }

        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            llama_free(context)
            llama_model_free(model)
            throw Failure.samplerCreationFailed
        }
        // Greedy (argmax) decoding only — deterministic, and the right mode for
        // strict instruction following on a small model (same rationale as the
        // Apple backend's `.greedy` sampling in `LocalCleaner.cleanupOptions`).
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        guard let vocab = llama_model_get_vocab(model) else {
            llama_sampler_free(sampler)
            llama_free(context)
            llama_model_free(model)
            throw Failure.modelLoadFailed(configuration.modelURL.lastPathComponent)
        }
        handles = Handles(model: model, context: context, vocab: vocab, sampler: sampler)
        cachedTokens = []

        Self.logger.info("llama model loaded (n_ctx=\(self.configuration.contextTokens, privacy: .public))")
    }

    /// Free the context and model. Idempotent. Called when the user switches
    /// cleanup engines or the idle-unload timer fires (the ~1–3 GB resident cost
    /// is the reason unload exists at all).
    ///
    /// IMPORTANT: also call this before the process exits. llama.cpp's Metal
    /// backend asserts in a static destructor
    /// (`GGML_ASSERT([rsets->data count] == 0)`, ggml-metal-device.m) when a
    /// context is still alive at `exit()` — observed in the live smoke test, and
    /// it disappears once every runner is unloaded. Doing it here (awaiting the
    /// actor) is race-free; an `atexit` hook would not be, since a decode could
    /// still be in flight.
    public func unload() {
        guard handles != nil else { return }
        handles = nil // `Handles.deinit` frees sampler → context → model.
        cachedTokens = []
        Self.logger.info("llama model unloaded")
    }

    // MARK: - Generation

    /// Decode `prompt` into the KV cache WITHOUT generating — so the next
    /// `generate` whose prompt starts with the same text skips that prefill.
    /// Loads the model first if needed. Errors are the caller's to swallow:
    /// warming is best-effort.
    public func warm(prompt: String) throws {
        try load()
        let tokens = try tokenize(prompt, addSpecial: true)
        guard !tokens.isEmpty else { return }
        _ = try prefill(tokens)
        cachedTokens = tokens
    }

    /// Run one greedy generation over `prompt`.
    ///
    /// - Parameters:
    ///   - prompt: fully formatted model input (ChatML for Qwen — see `LlamaChatML`).
    ///   - maxTokens: hard cap on generated tokens.
    ///   - stop: literal strings that end generation when they appear in the
    ///     output; the matched text is trimmed off. End-of-generation tokens are
    ///     always honored in addition.
    /// - Throws: `CancellationError` when the task is cancelled between decode
    ///   steps (the cleanup timeout path), or `Failure` on an engine error.
    public func generate(prompt: String, maxTokens: Int, stop: [String] = []) throws -> Result {
        try load()
        guard let handles else { throw Failure.notLoaded }
        let context = handles.context

        let promptTokens = try tokenize(prompt, addSpecial: true)
        let contextLimit = Int(llama_n_ctx(context))
        guard promptTokens.count + 1 < contextLimit else {
            throw Failure.promptTooLong(promptTokens: promptTokens.count, contextTokens: contextLimit)
        }
        let budget = min(maxTokens, contextLimit - promptTokens.count - 1)

        try Task.checkCancellation()

        let prefillStart = ContinuousClock.now
        let decodedPromptTokens = try prefill(promptTokens)
        let prefillSeconds = Self.seconds(ContinuousClock.now - prefillStart)

        let generateStart = ContinuousClock.now
        var output = ""
        // Detokenized BYTES, not characters: a multi-byte character can straddle
        // two tokens (byte-fallback), so decoding each piece in isolation would
        // emit U+FFFD mid-character — visible the moment translation mode emits
        // non-ASCII. Re-decoding the whole (short) buffer each step is cheap and
        // always yields well-formed text.
        var outputBytes: [UInt8] = []
        outputBytes.reserveCapacity(budget * 4)
        var generated: [llama_token] = []
        generated.reserveCapacity(budget)
        var hitLimit = true

        while generated.count < budget {
            // Cancellation is checked between decode steps (a single
            // `llama_decode` is not interruptible). The cleanup timeout cancels
            // this task; the orchestrator then keeps the raw transcript.
            try Task.checkCancellation()

            let token = llama_sampler_sample(handles.sampler, context, -1)
            if llama_vocab_is_eog(handles.vocab, token) { hitLimit = false; break }
            generated.append(token)
            appendPiece(of: token, to: &outputBytes)
            output = String(decoding: outputBytes, as: UTF8.self)

            if let cut = Self.stopIndex(in: output, stop: stop) {
                output = String(output[output.startIndex..<cut])
                hitLimit = false
                break
            }
            guard generated.count < budget else { break }
            try decode([token])
        }

        let generateSeconds = Self.seconds(ContinuousClock.now - generateStart)
        cachedTokens = configuration.reusePrefix ? promptTokens + generated : []

        // Metadata only — never the prompt or the output (CLAUDE.md).
        Self.logger.debug("""
            llama gen: prompt=\(promptTokens.count, privacy: .public) \
            decoded=\(decodedPromptTokens, privacy: .public) \
            out=\(generated.count, privacy: .public) \
            prefill=\(Int(prefillSeconds * 1000), privacy: .public)ms \
            gen=\(Int(generateSeconds * 1000), privacy: .public)ms
            """)

        return Result(
            text: output,
            promptTokens: promptTokens.count,
            decodedPromptTokens: decodedPromptTokens,
            generatedTokens: generated.count,
            prefillSeconds: prefillSeconds,
            generateSeconds: generateSeconds,
            hitTokenLimit: hitLimit
        )
    }

    // MARK: - Prefill / decode

    /// Feed `tokens` into the KV cache, reusing the longest prefix already there.
    /// Returns how many tokens were actually decoded (the rest were cache hits).
    private func prefill(_ tokens: [llama_token]) throws -> Int {
        guard let handles else { throw Failure.notLoaded }
        let memory = llama_get_memory(handles.context)

        var reused = configuration.reusePrefix ? Self.commonPrefixLength(cachedTokens, tokens) : 0
        // At least one token must be decoded for the sampler to have logits.
        if reused == tokens.count { reused -= 1 }
        if reused <= 0 {
            llama_memory_clear(memory, true)
            reused = 0
        } else {
            // Drop everything after the shared prefix so positions line up.
            llama_memory_seq_rm(memory, 0, llama_pos(reused), -1)
        }

        var index = reused
        let batchSize = max(1, Int(configuration.batchTokens))
        while index < tokens.count {
            try Task.checkCancellation()
            let end = min(index + batchSize, tokens.count)
            try decode(Array(tokens[index..<end]))
            index = end
        }
        return tokens.count - reused
    }

    /// One `llama_decode`. `llama_batch_get_one` leaves positions unset, which
    /// makes llama.cpp continue from the sequence's current position — exactly
    /// what the chunked prefill and the token-by-token loop both want.
    private func decode(_ tokens: [llama_token]) throws {
        guard let handles else { throw Failure.notLoaded }
        var mutable = tokens
        let status = mutable.withUnsafeMutableBufferPointer { buffer -> Int32 in
            let batch = llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))
            return llama_decode(handles.context, batch)
        }
        guard status == 0 else { throw Failure.decodeFailed }
    }

    // MARK: - Tokenize / detokenize

    /// Tokenize into the reusable `tokenScratch` buffer (two-pass: llama.cpp
    /// returns the negated required capacity when the buffer is too small).
    private func tokenize(_ text: String, addSpecial: Bool) throws -> [llama_token] {
        guard let vocab = handles?.vocab else { throw Failure.notLoaded }
        let utf8Count = text.utf8.count
        if tokenScratch.count < utf8Count + 8 {
            tokenScratch = [llama_token](repeating: 0, count: utf8Count + 8)
        }
        var written: Int32 = 0
        text.withCString { cString in
            let length = Int32(strlen(cString))
            written = tokenScratch.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(vocab, cString, length, buffer.baseAddress, Int32(buffer.count), addSpecial, true)
            }
        }
        guard written > 0 else { throw Failure.tokenizationFailed }
        return Array(tokenScratch[0..<Int(written)])
    }

    /// Detokenize one token into the reusable piece buffer and append its raw
    /// bytes to `bytes`. llama.cpp returns the negated required capacity when the
    /// buffer is too small (only possible for pathological tokens).
    private func appendPiece(of token: llama_token, to bytes: inout [UInt8]) {
        guard let vocab = handles?.vocab else { return }
        var written = pieceBuffer.withUnsafeMutableBufferPointer { buffer in
            llama_token_to_piece(vocab, token, buffer.baseAddress, Int32(buffer.count), 0, false)
        }
        if written < 0 {
            pieceBuffer = [CChar](repeating: 0, count: Int(-written) + 1)
            written = pieceBuffer.withUnsafeMutableBufferPointer { buffer in
                llama_token_to_piece(vocab, token, buffer.baseAddress, Int32(buffer.count), 0, false)
            }
        }
        guard written > 0 else { return }
        for index in 0..<Int(written) { bytes.append(UInt8(bitPattern: pieceBuffer[index])) }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Length of the shared leading run of two token arrays — the KV-cache reuse
    /// decision. (`llama_token` is `Int32`; spelled out so the public surface
    /// doesn't leak the C module's typealias.)
    public static func commonPrefixLength(_ lhs: [Int32], _ rhs: [Int32]) -> Int {
        var index = 0
        let limit = min(lhs.count, rhs.count)
        while index < limit, lhs[index] == rhs[index] { index += 1 }
        return index
    }

    /// Index of the earliest `stop` string in `text`, or nil when none appears.
    public static func stopIndex(in text: String, stop: [String]) -> String.Index? {
        var earliest: String.Index?
        for needle in stop where !needle.isEmpty {
            guard let range = text.range(of: needle) else { continue }
            if earliest == nil || range.lowerBound < earliest! { earliest = range.lowerBound }
        }
        return earliest
    }

    /// `Duration` → seconds, for the metadata-only timing fields on `Result`.
    public static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// Process-wide llama.cpp backend init + log routing. `llama_backend_init` must
/// run exactly once per process and `llama_log_set` installs a global callback,
/// so neither belongs to an individual `LlamaRunner`.
enum LlamaBackend {
    /// `static let` gives us lazy, thread-safe, exactly-once initialization.
    private static let initialized: Bool = {
        // Route llama.cpp's own logging BEFORE init so its load-time chatter is
        // captured too. llama.cpp's verbose levels can echo prompt-derived text,
        // and Skylark never logs transcript content (CLAUDE.md) — so the default
        // callback DISCARDS everything. `SKYLARK_LLAMA_LOG=1` (developer-only)
        // forwards warnings and errors, which are metadata, to the unified log.
        let forward = ProcessInfo.processInfo.environment["SKYLARK_LLAMA_LOG"] != nil
        if forward {
            llama_log_set({ level, text, _ in
                guard level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue, let text else { return }
                Logger(subsystem: "com.jjromano.skylark", category: "llama")
                    .warning("llama: \(String(cString: text), privacy: .public)")
            }, nil)
        } else {
            llama_log_set({ _, _, _ in }, nil)
        }
        llama_backend_init()
        return true
    }()

    /// Idempotent; safe from any isolation domain.
    static func ensureInitialized() {
        _ = initialized
    }
}
