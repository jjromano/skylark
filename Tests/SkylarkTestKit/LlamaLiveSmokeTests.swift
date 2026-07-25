import Foundation
import Testing
import SkylarkCore

/// LIVE llama.cpp generation — off by default because it needs a multi-gigabyte
/// GGUF on disk. Enable with both variables set:
///
///     SKYLARK_LIVE_LLAMA_EVAL=1 \
///     SKYLARK_LLAMA_GGUF=/path/to/qwen.gguf \
///     make test
///
/// Add `SKYLARK_LLAMA_NO_THINK=1` when the GGUF is a hybrid-reasoning Qwen3
/// (1.7B/8B): that emits the `enable_thinking=false` scaffolding. Leave it unset
/// for a non-thinking model (Qwen2.5, the `-Instruct-2507` releases).
///
/// It proves the whole WS4 stack end to end on this machine: the vendored
/// llama.xcframework loads, Metal shaders compile at runtime, the actor's
/// tokenize → prefill → greedy-decode loop produces text, and `LocalCleaner`'s
/// hygiene accepts it. It also prints the latency numbers (cold vs warm, and the
/// KV-prefix-reuse win) that PRD §12 acceptance is judged on.
@Suite("LIVE llama.cpp smoke", .serialized)
struct LlamaLiveSmokeTests {
    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["SKYLARK_LIVE_LLAMA_EVAL"] != nil
            && ProcessInfo.processInfo.environment["SKYLARK_LLAMA_GGUF"] != nil
    }

    private static var modelURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SKYLARK_LLAMA_GGUF"] ?? "")
    }

    private static var smokeModel: LocalCleanupModel {
        .custom(
            fileURL: modelURL,
            suppressesThinking: ProcessInfo.processInfo.environment["SKYLARK_LLAMA_NO_THINK"] != nil
        )
    }

    /// Always unload before returning: llama.cpp's Metal backend asserts in a
    /// static destructor if the process exits with a context still alive.
    private func withRunner<T>(
        contextTokens: UInt32 = 2048,
        _ body: (LlamaRunner) async throws -> T
    ) async throws -> T {
        let runner = LlamaRunner(configuration: .init(modelURL: Self.modelURL, contextTokens: contextTokens))
        do {
            let value = try await body(runner)
            await runner.unload()
            return value
        } catch {
            await runner.unload()
            throw error
        }
    }

    @Test("LIVE: runner generates text and reuses the instruction prefix",
          .enabled(if: Self.enabled))
    func liveGeneration() async throws {
        try await withRunner { runner in
            let instructions = CleanupPrompt.compactInstructions(context: CleanupContext(intensity: .standard))
            let model = Self.smokeModel
            let raw = "um so i want to restructure uh i mean refactor the code"
            let prompt = QwenCleanupBackend.prompt(
                instructions: instructions,
                userMessage: CleanupPrompt.userMessage(transcript: raw),
                model: model
            )

            let coldStart = ContinuousClock.now
            let first = try await runner.generate(prompt: prompt, maxTokens: 96, stop: LlamaChatML.stopStrings)
            let coldSeconds = LlamaRunner.seconds(ContinuousClock.now - coldStart)

            #expect(first.generatedTokens > 0)
            #expect(!QwenCleanupBackend.postprocess(first.text).isEmpty)
            #expect(first.decodedPromptTokens == first.promptTokens) // cold: nothing cached

            // Second utterance shares the (long) instruction prefix, so most of
            // the prompt should come straight from the KV cache.
            let secondPrompt = QwenCleanupBackend.prompt(
                instructions: instructions,
                userMessage: CleanupPrompt.userMessage(transcript: "send it to bob actually alice"),
                model: model
            )
            let warmStart = ContinuousClock.now
            let second = try await runner.generate(
                prompt: secondPrompt, maxTokens: 96, stop: LlamaChatML.stopStrings
            )
            let warmSeconds = LlamaRunner.seconds(ContinuousClock.now - warmStart)

            #expect(second.generatedTokens > 0)
            #expect(second.decodedPromptTokens < second.promptTokens) // prefix reuse happened

            print("""

                ===== LIVE llama.cpp smoke (\(Self.modelURL.lastPathComponent)) =====
                cold : prompt=\(first.promptTokens) decoded=\(first.decodedPromptTokens) \
                out=\(first.generatedTokens) prefill=\(Int(first.prefillSeconds * 1000))ms \
                gen=\(Int(first.generateSeconds * 1000))ms total(incl. model load)=\(Int(coldSeconds * 1000))ms
                warm : prompt=\(second.promptTokens) decoded=\(second.decodedPromptTokens) \
                out=\(second.generatedTokens) prefill=\(Int(second.prefillSeconds * 1000))ms \
                gen=\(Int(second.generateSeconds * 1000))ms total=\(Int(warmSeconds * 1000))ms
                in  : \(raw)
                out : \(QwenCleanupBackend.postprocess(first.text))
                out2: \(QwenCleanupBackend.postprocess(second.text))
                =========================================================

                """)
        }
    }

    @Test("LIVE: cleanup runs end to end through LocalCleaner",
          .enabled(if: Self.enabled))
    func liveCleanerIntegration() async throws {
        let backend = QwenCleanupBackend(model: Self.smokeModel)
        #expect(await backend.unavailability() == nil)
        let instructions = CleanupPrompt.compactInstructions(context: CleanupContext(intensity: .standard))
        await backend.preload(instructions: instructions)

        let cleaner = LocalCleaner(backend: backend)
        let start = ContinuousClock.now
        let cleaned: String
        do {
            cleaned = try await cleaner.clean(
                "um so i think we should meet on tuesday no wait friday",
                context: CleanupContext(intensity: .standard)
            )
        } catch {
            await backend.unload()
            throw error
        }
        let seconds = LlamaRunner.seconds(ContinuousClock.now - start)
        await backend.unload()

        #expect(!cleaned.isEmpty)
        // Hygiene must never hand back reasoning or ChatML scaffolding.
        #expect(!cleaned.contains("<think>"))
        #expect(!cleaned.contains("<|im_"))
        print("\n===== LIVE LocalCleaner+Qwen: \(Int(seconds * 1000))ms (prewarmed) =====\nout: \(cleaned)\n")
    }

    @Test("LIVE: cancellation stops generation promptly",
          .enabled(if: Self.enabled))
    func liveCancellation() async throws {
        try await withRunner { runner in
            // Preload so the measurement covers generation, not the model load.
            try await runner.load()
            let task = Task {
                try await runner.generate(
                    // A prompt with no natural stop, so only cancellation ends it.
                    prompt: LlamaChatML.prompt(
                        messages: [.init(role: .user, content: "Count upward from one, forever.")],
                        suppressThinking: false
                    ),
                    maxTokens: 4096,
                    stop: LlamaChatML.stopStrings
                )
            }
            try await Task.sleep(for: .milliseconds(300))
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
    }
}
