import Foundation
import Testing
import SkylarkCore

/// Model-free coverage of the llama.cpp/Qwen cleanup tier: ChatML assembly,
/// Qwen3 thinking suppression, `<think>` stripping, GGUF path resolution, and the
/// on-disk gate that keeps Apple Foundation Models the default. The live
/// generation path is exercised separately by `LlamaLiveSmokeTests` (opt-in).
@Suite("Llama cleanup (Qwen) — prompt, hygiene, paths")
struct LlamaCleanupTests {

    // MARK: - ChatML formatting

    @Test("ChatML wraps each turn and opens an assistant turn")
    func chatMLShape() {
        let prompt = LlamaChatML.prompt(
            messages: [
                .init(role: .system, content: "SYS"),
                .init(role: .user, content: "USER"),
            ],
            suppressThinking: false
        )
        #expect(prompt == "<|im_start|>system\nSYS<|im_end|>\n<|im_start|>user\nUSER<|im_end|>\n<|im_start|>assistant\n")
    }

    @Test("Thinking suppression pre-fills an empty think block and nothing else")
    func chatMLNoThink() {
        let prompt = LlamaChatML.prompt(
            messages: [
                .init(role: .system, content: "SYS"),
                .init(role: .user, content: "USER"),
            ],
            suppressThinking: true
        )
        // Qwen3's own template with enable_thinking=false emits exactly this
        // closed, empty think block after opening the assistant turn.
        #expect(prompt == "<|im_start|>system\nSYS<|im_end|>\n<|im_start|>user\nUSER<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n")
        // The user turn is NOT perturbed — no `/no_think` soft switch (a 1.5 B
        // model echoed it as content instead of cleaning the transcript).
        #expect(!prompt.contains("/no_think"))
    }

    @Test("Multi-turn messages keep their order and roles")
    func multiTurnOrder() {
        let prompt = LlamaChatML.prompt(
            messages: [
                .init(role: .user, content: "FIRST"),
                .init(role: .assistant, content: "REPLY"),
                .init(role: .user, content: "SECOND"),
            ],
            suppressThinking: false
        )
        #expect(prompt == "<|im_start|>user\nFIRST<|im_end|>\n<|im_start|>assistant\nREPLY<|im_end|>\n"
            + "<|im_start|>user\nSECOND<|im_end|>\n<|im_start|>assistant\n")
    }

    @Test("systemPrefix is the exact leading substring of the full prompt")
    func systemPrefixIsAPrefix() {
        let instructions = CleanupPrompt.compactInstructions(context: CleanupContext(intensity: .standard))
        let prefix = LlamaChatML.systemPrefix(instructions: instructions)
        let full = QwenCleanupBackend.prompt(
            instructions: instructions,
            userMessage: CleanupPrompt.userMessage(transcript: "hello there"),
            model: .qwen3_1_7B
        )
        // KV-cache prefix reuse (and therefore the whole prewarm win) depends on
        // this being a byte-exact prefix.
        #expect(full.hasPrefix(prefix))
    }

    @Test("Backend prompt carries the SHARED compact local instructions and the fenced transcript")
    func promptUsesSharedInstructions() {
        let instructions = CleanupPrompt.compactInstructions(context: CleanupContext(intensity: .standard))
        let prompt = QwenCleanupBackend.prompt(
            instructions: instructions,
            userMessage: CleanupPrompt.userMessage(transcript: "um so ship it friday"),
            model: .qwen3_1_7B
        )
        #expect(prompt.contains(instructions))
        #expect(prompt.contains("<transcript>\num so ship it friday\n</transcript>"))
        #expect(prompt.hasSuffix("<think>\n\n</think>\n\n"))
    }

    @Test("A non-thinking model gets no think scaffolding")
    func instructModelSkipsThinkScaffolding() {
        let prompt = QwenCleanupBackend.prompt(
            instructions: "SYS",
            userMessage: "USER",
            model: .qwen3_4BInstruct
        )
        #expect(prompt.hasSuffix("<|im_start|>assistant\n"))
        #expect(!prompt.contains("<think>"))
    }

    // MARK: - Output hygiene

    @Test("postprocess strips a leaked think block")
    func stripsThinkBlock() {
        #expect(QwenCleanupBackend.postprocess("<think>\nthe user said x\n</think>\n\nShip it Friday.")
            == "Ship it Friday.")
    }

    @Test("postprocess strips ChatML residue after the answer")
    func stripsChatMLResidue() {
        #expect(QwenCleanupBackend.postprocess("Ship it Friday.<|im_end|>\n<|im_start|>user\n")
            == "Ship it Friday.")
        #expect(QwenCleanupBackend.postprocess("Ship it Friday.<|endoftext|>") == "Ship it Friday.")
    }

    @Test("An unclosed think block yields nothing, so hygiene keeps the raw transcript")
    func unclosedThinkBecomesEmpty() {
        // Truncated mid-thought by the token cap: better to return nothing (which
        // `CleanupHygiene.validate` rejects → raw text survives) than a fragment
        // of the model's reasoning.
        #expect(QwenCleanupBackend.postprocess("<think>\nhmm the speaker probably").isEmpty)
    }

    @Test("postprocess leaves ordinary output untouched")
    func leavesCleanOutputAlone() {
        #expect(QwenCleanupBackend.postprocess("Can you investigate what happened here?")
            == "Can you investigate what happened here?")
    }

    // MARK: - Runner pure helpers

    @Test("commonPrefixLength measures KV-cache reuse")
    func commonPrefix() {
        #expect(LlamaRunner.commonPrefixLength([1, 2, 3, 4], [1, 2, 9]) == 2)
        #expect(LlamaRunner.commonPrefixLength([], [1, 2]) == 0)
        #expect(LlamaRunner.commonPrefixLength([1, 2], [1, 2]) == 2)
        #expect(LlamaRunner.commonPrefixLength([5], [1, 2]) == 0)
    }

    @Test("stopIndex finds the earliest stop string")
    func stopIndexEarliest() {
        let text = "Ship it Friday.<|im_end|> trailing"
        let index = LlamaRunner.stopIndex(in: text, stop: ["<|endoftext|>", "<|im_end|>"])
        #expect(index != nil)
        #expect(String(text[text.startIndex..<index!]) == "Ship it Friday.")
        #expect(LlamaRunner.stopIndex(in: "no stop here", stop: ["<|im_end|>"]) == nil)
        #expect(LlamaRunner.stopIndex(in: "anything", stop: [""]) == nil)
    }

    // MARK: - Model paths / registry

    @Test("GGUF paths resolve under Application Support/Skylark/Models/Cleanup")
    func pathResolution() {
        let expectedDirectory = ModelPaths.models.appendingPathComponent("Cleanup", isDirectory: true)
        #expect(ModelPaths.cleanupModels.standardizedFileURL == expectedDirectory.standardizedFileURL)
        #expect(ModelPaths.cleanupModels.path.hasSuffix("Application Support/Skylark/Models/Cleanup"))

        for model in LocalCleanupModel.all {
            #expect(model.fileURL.deletingLastPathComponent().standardizedFileURL
                == ModelPaths.cleanupModels.standardizedFileURL)
            #expect(model.fileURL.lastPathComponent == model.fileName)
            #expect(model.fileURL.pathExtension == "gguf")
            #expect(model.downloadBytes > 0)
            #expect(model.remoteURL?.scheme == "https")
        }
    }

    @Test("Registry exposes both Qwen entries by stable id")
    func registryLookup() {
        #expect(LocalCleanupModel.all.map(\.id) == ["qwen3-1.7b", "qwen3-4b-instruct"])
        #expect(LocalCleanupModel.model(id: "qwen3-1.7b") == .qwen3_1_7B)
        #expect(LocalCleanupModel.model(id: "qwen3-4b-instruct") == .qwen3_4BInstruct)
        #expect(LocalCleanupModel.model(id: "nope") == nil)
        // Only the hybrid-reasoning model needs think suppression.
        #expect(LocalCleanupModel.qwen3_1_7B.suppressesThinking)
        #expect(!LocalCleanupModel.qwen3_4BInstruct.suppressesThinking)
    }

    @Test("A model whose file is absent reports itself uninstalled")
    func absentModelIsNotInstalled() {
        let absent = LocalCleanupModel(
            id: "test-absent",
            displayName: "Absent",
            fileName: "definitely-not-here-\(UUID().uuidString).gguf",
            remoteURL: URL(string: "https://example.invalid/model.gguf")!,
            downloadBytes: 1_000,
            suppressesThinking: true
        )
        #expect(!absent.isInstalled)
    }

    @Test("A truncated download counts as uninstalled")
    func truncatedDownloadIsNotInstalled() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skylark-gguf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("short.gguf")
        try Data(count: 16).write(to: file)
        #expect(LocalCleanupModel.custom(fileURL: file).isInstalled)
        // An unknown GGUF gets no think scaffolding by default (safe for a
        // non-thinking model).
        #expect(!LocalCleanupModel.custom(fileURL: file).suppressesThinking)

        // `isInstalled` compares against the expected byte count, so a partial
        // file keeps the pipeline on its Apple/raw fallback instead of failing
        // every dictation on an unloadable GGUF.
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.size] as? Int64) == 16)
        let model = LocalCleanupModel(
            id: "test-truncated",
            displayName: "Truncated",
            fileName: "short.gguf",
            remoteURL: URL(string: "https://example.invalid/model.gguf")!,
            downloadBytes: 1_000_000,
            suppressesThinking: true,
            directory: directory
        )
        #expect(!model.isInstalled)
    }

    // MARK: - Engine selection / gating

    @Test("Engine choice round-trips through its persisted string")
    func enginePersistence() {
        #expect(LocalCleanupEngine.appleFoundationModels.persistedValue == "apple")
        #expect(LocalCleanupEngine.llama(modelID: "qwen3-1.7b").persistedValue == "llama:qwen3-1.7b")
        #expect(LocalCleanupEngine(persistedValue: nil) == .appleFoundationModels)
        #expect(LocalCleanupEngine(persistedValue: "apple") == .appleFoundationModels)
        #expect(LocalCleanupEngine(persistedValue: "garbage") == .appleFoundationModels)
        #expect(LocalCleanupEngine(persistedValue: "llama:qwen3-4b-instruct")
            == .llama(modelID: "qwen3-4b-instruct"))
    }

    @Test("An unknown model id degrades to Apple Foundation Models")
    func unknownModelDegrades() {
        #expect(LocalCleanupEngine.llama(modelID: "not-a-model").resolved == .appleFoundationModels)
        #expect(LocalCleanupEngine.appleFoundationModels.resolved == .appleFoundationModels)
    }

    @Test("A selected-but-not-downloaded Qwen degrades to Apple Foundation Models")
    func uninstalledModelDegrades() {
        // The gate is "file present on disk". On a box where the GGUF happens to
        // be installed the choice legitimately stands, so assert the invariant
        // both ways rather than assuming an empty models directory.
        let engine = LocalCleanupEngine.llama(modelID: LocalCleanupModel.qwen3_1_7B.id)
        if LocalCleanupModel.qwen3_1_7B.isInstalled {
            #expect(engine.resolved == engine)
        } else {
            #expect(engine.resolved == .appleFoundationModels)
        }
    }

    @Test("Defaults with no stored value resolve to Apple (Qwen is opt-in)")
    func defaultsFallBackToApple() {
        let defaults = UserDefaults(suiteName: "skylark.tests.\(UUID().uuidString)")!
        #expect(LocalCleanupEngine.resolvedFromDefaults(defaults) == .appleFoundationModels)
        defaults.set("llama:not-a-model", forKey: LocalCleanupEngine.defaultsKey)
        #expect(LocalCleanupEngine.resolvedFromDefaults(defaults) == .appleFoundationModels)
    }

    @Test("An uninstalled Qwen backend is unavailable, never a hard failure")
    func qwenBackendReportsUnavailable() async {
        let absent = LocalCleanupModel(
            id: "test-absent-backend",
            displayName: "Absent Qwen",
            fileName: "missing-\(UUID().uuidString).gguf",
            remoteURL: URL(string: "https://example.invalid/model.gguf")!,
            downloadBytes: 1_000,
            suppressesThinking: true
        )
        let backend = QwenCleanupBackend(model: absent)
        let reason = await backend.unavailability()
        #expect(reason != nil)
        #expect(reason?.contains("Absent Qwen") == true)

        // The whole cleanup path must degrade, not throw into the paste path.
        let cleaner = LocalCleaner(backend: backend)
        await #expect(throws: CleanerError.self) {
            _ = try await cleaner.clean("um so ship it friday", context: CleanupContext(intensity: .standard))
        }
    }
}
