import Foundation
import FluidAudio
import os

/// Local Parakeet TDT v3 (int8) engine via FluidAudio. Batch path only for the
/// Phase 1 MVP: the whole clip is fed to `AsrManager.transcribe` on release
/// (~140× real-time on ANE, comfortably inside the 300 ms bar). Models stay
/// resident in the actor until `shutdown()`; `reset()` clears decoder state
/// between utterances but keeps the models warm.
public actor FluidAudioParakeet: Transcriber {
    public nonisolated let id: TranscriberID = .parakeet

    /// Clips shorter than this (or effectively silent) are skipped without ever
    /// touching the model — returns an empty string, never throws. Set to cover
    /// FluidAudio's own 0.3 s floor so a borderline clip can't surface an error.
    public static let minClipDuration: TimeInterval = 0.3
    /// Peak-amplitude floor below which a clip is treated as silence.
    static let silenceFloor: Float = 1e-4

    private let modelsDirectory: URL
    private let progress: @Sendable (ModelPreparationState) -> Void

    /// Silence floor for the skip guard, tunable so whisper mode can accept
    /// quieter speech (phase-4 spec §5). Defaults to the standard floor.
    private var silenceFloor: Float = FluidAudioParakeet.silenceFloor

    private var models: AsrModels?
    private var manager: AsrManager?
    private var decoderState: TdtDecoderState?
    private var preparing: Task<Void, Error>?

    public private(set) var isReady = false

    /// - Parameters:
    ///   - modelsDirectory: where to download/load the Parakeet repo. Defaults to
    ///     the shared Skylark models directory.
    ///   - progress: preparation-state callback (menu-bar / HUD). Defaults to a
    ///     no-op for headless use (bench, tests).
    public init(
        modelsDirectory: URL = ModelPaths.models,
        progress: @escaping @Sendable (ModelPreparationState) -> Void = { _ in }
    ) {
        self.modelsDirectory = modelsDirectory
        self.progress = progress
    }

    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "asr")

    // MARK: - Lifecycle

    /// Ensure the model is downloaded and loaded. Idempotent and safe to call at
    /// launch; concurrent calls share one preparation task.
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

        let alreadyDownloaded = AsrModels.modelsExist(at: modelsDirectory)
        if alreadyDownloaded {
            progress(.loading)
        }

        // Map FluidAudio download phases onto our preparation states. Called on
        // an unspecified queue, so keep it allocation-light and content-free.
        let report = progress
        let loaded = try await AsrModels.downloadAndLoad(
            to: modelsDirectory,
            version: .v3,
            encoderPrecision: .int8,
            progressHandler: { p in
                switch p.phase {
                case .listing:
                    report(.checking)
                case .downloading:
                    report(.downloading(progress: p.fractionCompleted))
                case .compiling:
                    report(.loading)
                }
            }
        )

        progress(.loading)
        let mgr = AsrManager(config: .default)
        try await mgr.loadModels(loaded)

        self.models = loaded
        self.manager = mgr
        self.decoderState = try TdtDecoderState()
        self.isReady = true
        progress(.ready)
        logger.info("Parakeet ready")
    }

    /// The loaded ASR models (nil until warm-up completes). Handed to a
    /// `SlidingWindowAsrManager` for the optional live preview: the `MLModel`
    /// instances are shared read-only — the streaming manager retains them
    /// without reloading from disk, so preview adds no download and only a small
    /// resident-memory delta.
    public func loadedModels() -> AsrModels? { models }

    /// Apply the whisper-mode tuning (currently just the silence floor for the
    /// skip guard). Takes effect on the next `transcribe`.
    public func setSilenceFloor(_ floor: Float) {
        silenceFloor = floor
    }

    /// Release the models (only on quit / engine switch, never mid-session).
    public func shutdown() async {
        await manager?.cleanup()
        manager = nil
        models = nil
        decoderState = nil
        isReady = false
    }

    // MARK: - Transcription

    public func transcribe(_ clip: AudioClip, hint: TranscriptionHint) async throws -> String {
        // Guard first — a too-short or silent clip returns "" without loading or
        // touching the model (privacy + latency: never throw for that).
        if ClipGuard.shouldSkip(clip, minDuration: Self.minClipDuration, silenceFloor: silenceFloor) { return "" }

        guard let manager, decoderState != nil else {
            throw ParakeetError.notReady
        }

        var state = decoderState!
        let result = try await manager.transcribe(clip.samples, decoderState: &state, language: nil)
        decoderState = state
        // Clear decoder state between utterances; keep the models warm.
        await manager.reset()
        decoderState = try TdtDecoderState()

        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Clip guard (pure, unit-tested)

    /// Whether a clip is too short or too quiet to bother transcribing (default
    /// silence floor). Delegates to the shared `ClipGuard`.
    public static func shouldSkip(_ clip: AudioClip) -> Bool {
        ClipGuard.shouldSkip(clip, minDuration: minClipDuration, silenceFloor: silenceFloor)
    }
}

public enum ParakeetError: Error, Sendable {
    /// `transcribe` was called before `warmUp()` completed.
    case notReady
}
