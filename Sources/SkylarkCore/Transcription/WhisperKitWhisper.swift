import Foundation
import WhisperKit
import os

/// Local WhisperKit large-v3-turbo engine — the fallback local ASR (phase-4).
/// Same shape as `FluidAudioParakeet`: `warmUp()` downloads (progress mapped
/// onto `ModelPreparationState`) then loads + prewarms and keeps the model
/// resident until `shutdown()`. Batch path only: the whole clip is fed to
/// `transcribe(audioArray:)` on release.
///
/// `WhisperKit` is a non-`Sendable` class; the actor owns exactly one instance
/// and never lets it escape. The reference is held `nonisolated(unsafe)` so
/// calls to WhisperKit's own (non-isolated) async methods don't trip Swift 6's
/// region isolation — correctness comes from the actor serializing every access.
public actor WhisperKitWhisper: Transcriber {
    public nonisolated let id: TranscriberID = .whisperKit

    /// large-v3-turbo, the ~626 MB compressed variant (their default for capable
    /// Macs). `openai_whisper-large-v3-v20240930` is the turbo checkpoint.
    public static let variant = "openai_whisper-large-v3-v20240930_626MB"

    /// Same short-clip floor as Parakeet (WhisperKit tolerates short audio but
    /// the guard keeps latency + privacy behaviour uniform across engines).
    public static let minClipDuration: TimeInterval = 0.3
    static let silenceFloor: Float = 1e-4

    private let downloadBase: URL
    private let progress: @Sendable (ModelPreparationState) -> Void

    /// Owned WhisperKit instance — see the type doc for why `nonisolated(unsafe)`.
    private nonisolated(unsafe) var whisperKit: WhisperKit?
    private var preparing: Task<Void, Error>?
    private var silenceFloor: Float = WhisperKitWhisper.silenceFloor

    public private(set) var isReady = false

    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "asr")

    /// - Parameters:
    ///   - downloadBase: WhisperKit `downloadBase` (its HubApi cache root).
    ///     Defaults to the shared Skylark `whisperkit/` models subdir.
    ///   - progress: preparation-state callback. Defaults to a no-op (bench/tests).
    public init(
        downloadBase: URL = ModelPaths.whisperKitBase,
        progress: @escaping @Sendable (ModelPreparationState) -> Void = { _ in }
    ) {
        self.downloadBase = downloadBase
        self.progress = progress
    }

    // MARK: - Lifecycle

    /// Ensure the model is downloaded and loaded. Idempotent; concurrent calls
    /// share one preparation task.
    public func warmUp() async throws {
        if isReady { return }
        if let preparing {
            try await preparing.value
            return
        }
        let task = Task { try await self.prepare() }
        preparing = task
        do {
            try await task.value
            preparing = nil
        } catch {
            preparing = nil
            progress(.failed(message: error.localizedDescription))
            throw error
        }
    }

    private func prepare() async throws {
        progress(.checking)
        ModelPaths.ensureModelsDirectory()
        try? FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)

        let alreadyDownloaded = ModelPaths.isPresent(at: downloadBase)
        if alreadyDownloaded {
            progress(.loading)
        }

        // Download (idempotent — HubApi skips files already present). Progress is
        // reported on an unspecified queue; keep it allocation-light, content-free.
        let report = progress
        let base = downloadBase
        let variant = Self.variant
        let modelFolder = try await WhisperKit.download(
            variant: variant,
            downloadBase: base,
            progressCallback: { p in
                report(.downloading(progress: p.fractionCompleted))
            }
        )

        progress(.loading)
        // Load the local folder (download already done above) and prewarm so the
        // first utterance pays no compile cost.
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: base,
            modelFolder: modelFolder.path,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
        isReady = true
        progress(.ready)
        logger.info("WhisperKit ready")
    }

    /// Release the models (only on quit / engine switch, never mid-session).
    public func shutdown() async {
        if let whisperKit {
            await whisperKit.unloadModels()
        }
        whisperKit = nil
        isReady = false
    }

    /// Apply the whisper-mode tuning (silence floor for the skip guard).
    public func setSilenceFloor(_ floor: Float) {
        silenceFloor = floor
    }

    // MARK: - Transcription

    public func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        // Guard first — a too-short/silent clip returns "" without touching the
        // model (privacy + latency: never throw for that).
        if ClipGuard.shouldSkip(clip, minDuration: Self.minClipDuration, silenceFloor: silenceFloor) {
            return ""
        }

        guard let whisperKit else { throw WhisperKitError.notReady }

        // English-only for our use; prefill prompt keeps language detection off.
        let options = DecodingOptions(
            task: .transcribe,
            language: hint.locale ?? "en"
        )
        let results = try await whisperKit.transcribe(audioArray: clip.samples, decodeOptions: options)
        // Join per-window results and trim. Never log the content.
        let text = results.map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum WhisperKitError: Error, Sendable {
    /// `transcribe` was called before `warmUp()` completed.
    case notReady
}
