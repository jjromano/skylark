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
    /// Lowercase hex SHA-256 of the GGUF at `remoteURL`, or nil for a file we
    /// didn't fetch (`custom(fileURL:)`). A GGUF is parsed and executed as model
    /// weights, so a downloaded one is verified against this digest before it is
    /// installed (see `CleanupModelInstaller`). Taken from the Hugging Face
    /// blob metadata (`lfs.sha256`, echoed as `x-linked-etag` on the resolve
    /// redirect) for the pinned revision in `remoteURL`.
    public let sha256: String?
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
        sha256: String? = nil,
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
        self.sha256 = sha256
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
    /// lets the download manager re-fetch. Deliberately size-only: the SHA-256 is
    /// verified once, at install time (`CleanupModelInstaller`), because hashing
    /// gigabytes on every menu render would be absurd.
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
        //
        // PINNED to an immutable revision, not `resolve/main`: `main` is a
        // mutable pointer, so a re-quantized upload would change the bytes under
        // a fixed size/digest (and a moving target can't be digest-checked at
        // all). Revision d7f544eead698dbd1f15126ef60b45a1e1933222 is the repo's
        // main as of 2026-07-31 (HF API `sha`; repo last modified 2025-06-08).
        remoteURL: URL(string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/d7f544eead698dbd1f15126ef60b45a1e1933222/Qwen3-1.7B-Q4_K_M.gguf")!,
        downloadBytes: 1_107_409_472,
        sha256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897",
        suppressesThinking: true
    )

    /// Qwen3 4B Instruct 2507, Q4_K_M (~2.33 GB). Better cleanup quality at
    /// roughly 2× the latency and memory. A non-thinking release, so no
    /// think-suppression scaffolding is emitted.
    public static let qwen3_4BInstruct = LocalCleanupModel(
        id: "qwen3-4b-instruct",
        displayName: "Qwen3 4B Instruct",
        fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        // Pinned revision (see `qwen3_1_7B`):
        // a06e946bb6b655725eafa393f4a9745d460374c9 is the repo's main as of
        // 2026-07-31 (HF API `sha`; repo last modified 2025-08-20).
        remoteURL: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
        downloadBytes: 2_497_281_120,
        sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
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
