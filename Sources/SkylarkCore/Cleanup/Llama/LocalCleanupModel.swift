import Foundation

/// A downloadable GGUF cleanup model (llama.cpp / Qwen tier).
///
/// This type only DESCRIBES the models and where they live on disk — fetching
/// them is the download manager's job. `QwenCleanupBackend` loads a model
/// if-present and reports itself unavailable otherwise, so the cleanup pipeline
/// degrades to Apple Foundation Models (the default) or raw text.
public struct LocalCleanupModel: Sendable, Hashable, Identifiable {
    /// Stable identifier — persisted in UserDefaults as the user's engine choice,
    /// so never rename an existing case's id.
    public let id: String
    /// Human label for Settings.
    public let displayName: String
    /// File name on disk.
    public let fileName: String
    /// Resolved on-disk location — normally
    /// `~/Library/Application Support/Skylark/Models/Cleanup/<fileName>`, mirroring
    /// how the STT engines keep their weights under `Models/`.
    public let fileURL: URL
    /// Where the download manager fetches it from; nil for a GGUF the user
    /// already has on disk (see `custom(fileURL:)`).
    public let remoteURL: URL?
    /// Exact size in bytes (verified against the Hugging Face `x-linked-size`
    /// header) so the download UI can show real progress and the manager can
    /// detect a truncated file.
    public let downloadBytes: Int64
    /// KV-cache size to allocate. The cleanup instructions run ~1.2 k tokens, so
    /// 4096 leaves ample room for a long dictation plus its response while
    /// keeping the cache small (context size drives the resident-memory cost).
    public let contextTokens: UInt32
    /// Whether to emit Qwen3's `enable_thinking=false` scaffolding (empty
    /// `<think></think>` + `/no_think`). True for the hybrid-reasoning Qwen3
    /// models, where thinking would otherwise add seconds per cleanup; false for
    /// the `-Instruct-2507` releases, which have no thinking mode at all and
    /// whose chat template never contains a think block.
    public let suppressesThinking: Bool

    public init(
        id: String,
        displayName: String,
        fileName: String,
        remoteURL: URL?,
        downloadBytes: Int64,
        contextTokens: UInt32 = 4096,
        suppressesThinking: Bool,
        directory: URL = ModelPaths.cleanupModels
    ) {
        self.id = id
        self.displayName = displayName
        self.fileName = fileName
        self.fileURL = directory.appendingPathComponent(fileName)
        self.remoteURL = remoteURL
        self.downloadBytes = downloadBytes
        self.contextTokens = contextTokens
        self.suppressesThinking = suppressesThinking
    }

    /// Describe a GGUF that already exists at an arbitrary path — the escape
    /// hatch for a hand-placed model file (and what the gated live smoke test
    /// points at). Nothing is downloadable, so `remoteURL` is nil.
    /// `suppressesThinking` defaults to FALSE because it's the safe choice for an
    /// unknown GGUF: a non-thinking model handed an empty `<think></think>` block
    /// degrades badly, whereas a thinking model merely thinks (slower, still
    /// correct, and `CleanupHygiene` strips the block).
    public static func custom(
        fileURL: URL,
        contextTokens: UInt32 = 4096,
        suppressesThinking: Bool = false
    ) -> LocalCleanupModel {
        LocalCleanupModel(
            id: "custom:\(fileURL.lastPathComponent)",
            displayName: fileURL.deletingPathExtension().lastPathComponent,
            fileName: fileURL.lastPathComponent,
            remoteURL: nil,
            // Any non-empty file counts as present; there's no expected size to
            // compare against for a file we didn't fetch.
            downloadBytes: 1,
            contextTokens: contextTokens,
            suppressesThinking: suppressesThinking,
            directory: fileURL.deletingLastPathComponent()
        )
    }

    /// Present and plausibly complete. Size is checked because an interrupted
    /// download leaves a short file that llama.cpp would fail to load — treating
    /// it as "not installed" keeps the pipeline on its Apple/raw fallback and
    /// lets the download manager re-fetch.
    public var isInstalled: Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes?[.size] as? Int64 else { return false }
        return size >= downloadBytes
    }

    // MARK: - Registry

    /// Qwen3 1.7B, Q4_K_M (~1.03 GB). The fast default for the local llama tier.
    /// Hybrid-reasoning model — thinking is suppressed (see `suppressesThinking`).
    public static let qwen3_1_7B = LocalCleanupModel(
        id: "qwen3-1.7b",
        displayName: "Qwen3 1.7B",
        fileName: "Qwen3-1.7B-Q4_K_M.gguf",
        // Qwen's own `Qwen/Qwen3-1.7B-GGUF` repo publishes only Q8_0 (1.8 GB);
        // unsloth's requantization of the same Apache-2.0 weights provides the
        // Q4_K_M we want. URL + byte size verified live.
        remoteURL: URL(string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf")!,
        downloadBytes: 1_107_409_472,
        suppressesThinking: true
    )

    /// Qwen3 4B Instruct 2507, Q4_K_M (~2.33 GB). Better cleanup quality at
    /// roughly 2× the latency and memory. A non-thinking release, so no
    /// think-suppression scaffolding is emitted.
    public static let qwen3_4BInstruct = LocalCleanupModel(
        id: "qwen3-4b-instruct",
        displayName: "Qwen3 4B Instruct",
        fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        remoteURL: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
        downloadBytes: 2_497_281_120,
        suppressesThinking: false
    )

    /// Every model the app offers, in menu order.
    public static let all: [LocalCleanupModel] = [qwen3_1_7B, qwen3_4BInstruct]

    /// Look up by persisted id.
    public static func model(id: String) -> LocalCleanupModel? {
        all.first { $0.id == id }
    }

    /// The installed models, in menu order (empty until something is downloaded).
    public static var installed: [LocalCleanupModel] {
        all.filter(\.isInstalled)
    }
}

public extension ModelPaths {
    /// `~/Library/Application Support/Skylark/Models/Cleanup` — GGUF cleanup
    /// models, mirroring how the STT engines keep their weights under
    /// `Models/` (see `vadModelDir` / `whisperKitBase`). Runtime state: never in
    /// the repo, shared across worktrees (CLAUDE.md).
    static var cleanupModels: URL {
        models.appendingPathComponent("Cleanup", isDirectory: true)
    }

    /// Ensure the cleanup-models directory exists; ignore if it already does.
    static func ensureCleanupModelsDirectory() {
        try? FileManager.default.createDirectory(at: cleanupModels, withIntermediateDirectories: true)
    }
}
