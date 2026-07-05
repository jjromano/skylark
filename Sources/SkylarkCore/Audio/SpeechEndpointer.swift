import Foundation
import FluidAudio
import os

/// Streaming voice-activity endpointing for hands-free (double-tap-lock)
/// sessions. Push-to-talk never uses this — the Fn release ends those. On an
/// end-of-speech event the orchestrator synthesizes the same stop as Fn-up.
public protocol SpeechEndpointer: Sendable {
    /// Load the VAD model. Idempotent; on failure the endpointer stays
    /// unavailable and hands-free degrades to double-tap stop.
    func prepare() async
    /// Whether the model loaded and streaming endpointing can run.
    func available() async -> Bool
    /// Reset streaming state for a fresh hands-free session.
    func beginSession() async
    /// Feed raw 16 kHz frames; returns true once end-of-speech is detected.
    func feed(_ frames: [Float]) async -> Bool
}

/// FluidAudio Silero-VAD endpointer.
public actor FluidAudioVAD: SpeechEndpointer {
    /// Silence that ends an utterance (tuned in one place, per spec ≈ 1.0 s).
    public static let minSilenceDuration: TimeInterval = 1.0

    private let baseDirectory: URL
    private var vad: VadManager?
    private var streamState: VadStreamState?
    private var leftover: [Float] = []
    private var segmentationConfig: VadSegmentationConfig
    private var loadFailed = false

    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "vad")

    public init(baseDirectory: URL = ModelPaths.appSupport) {
        self.baseDirectory = baseDirectory
        var cfg = VadSegmentationConfig.default
        cfg.minSilenceDuration = Self.minSilenceDuration
        self.segmentationConfig = cfg
    }

    public func prepare() async {
        if vad != nil || loadFailed { return }
        do {
            // VadManager appends its own "Models" subfolder to this base, keeping
            // the VAD model alongside the ASR models under Skylark/Models.
            vad = try await VadManager(config: .default, modelDirectory: baseDirectory)
            logger.info("VAD ready")
        } catch {
            loadFailed = true
            logger.notice("VAD unavailable; hands-free will rely on double-tap stop: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func available() -> Bool { vad != nil }

    public func beginSession() async {
        guard let vad else { return }
        streamState = await vad.makeStreamState()
        leftover = []
    }

    public func feed(_ frames: [Float]) async -> Bool {
        guard let vad, var state = streamState else { return false }
        let (chunks, remainder) = VadChunker.split(buffer: leftover, incoming: frames)
        leftover = remainder

        var ended = false
        for chunk in chunks {
            do {
                let result = try await vad.processStreamingChunk(
                    chunk, state: state, config: segmentationConfig
                )
                state = result.state
                if let event = result.event, event.isEnd {
                    ended = true
                    break
                }
            } catch {
                // A single bad chunk must not wedge the session; log at debug.
                logger.debug("VAD chunk error: \(error.localizedDescription, privacy: .public)")
            }
        }
        streamState = state
        return ended
    }
}
