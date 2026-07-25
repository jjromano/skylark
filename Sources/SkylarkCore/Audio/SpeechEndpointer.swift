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

    /// Batch-scan an ALREADY-CAPTURED 16 kHz clip for unpadded speech regions, so
    /// the finalize path can trim non-speech head/tail (WS2). Independent of the
    /// streaming session state above — safe to call between sessions.
    ///
    /// MUST return nil (never load a model, never block) when the VAD isn't
    /// already resident: this runs on the fn-up→paste path, where a cold CoreML
    /// load would be a latency disaster. nil = "no opinion", and the caller leaves
    /// the clip exactly as captured.
    func scanSpeechRegions(_ samples: [Float]) async -> [SpeechRegion]?
}

extension SpeechEndpointer {
    /// Endpointers that only do streaming (test doubles, future backends) opt out
    /// of clip trimming for free.
    public func scanSpeechRegions(_ samples: [Float]) async -> [SpeechRegion]? { nil }
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

    /// Apply whisper-mode tuning: nudge the VAD toward sensitive endpointing
    /// (longer speech padding, lower min-speech) while keeping the tuned silence
    /// duration. Takes effect on the next `beginSession`. `VadSegmentationConfig`
    /// doesn't expose the primary detection threshold (that lives in `VadConfig`),
    /// so we move the duration knobs it does expose (phase-4 spec §5).
    public func setTuning(_ tuning: WhisperModeTuning) {
        segmentationConfig.speechPadding = tuning.vadSpeechPadding
        segmentationConfig.minSpeechDuration = tuning.vadMinSpeechDuration
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

    /// Batch scan for the finalize-path trim (WS2). Reuses the SAME warm
    /// `VadManager` the hands-free endpointer uses — if it isn't loaded yet we
    /// return nil rather than pay a CoreML load on the fn-up→paste path.
    ///
    /// Padding is deliberately zeroed here: FluidAudio's segmenter would happily
    /// pad the regions itself, but `VadClipTrimmer` owns the prefill/hangover rule
    /// (one rule, unit-tested, shared floor with the WS1 dead-tail trim), so the
    /// scan reports raw speech bounds only. The duration knobs whisper mode tunes
    /// (`minSpeechDuration`, `minSilenceDuration`) still apply.
    public func scanSpeechRegions(_ samples: [Float]) async -> [SpeechRegion]? {
        guard let vad, !samples.isEmpty else { return nil }
        var config = segmentationConfig
        config.speechPadding = 0
        do {
            let segments = try await vad.segmentSpeech(samples, config: config)
            let rate = VadManager.sampleRate
            return segments.map {
                SpeechRegion(
                    startSample: $0.startSample(sampleRate: rate),
                    endSample: $0.endSample(sampleRate: rate)
                )
            }
        } catch {
            // No opinion beats a wrong one: the caller leaves the clip untouched.
            logger.debug("VAD clip scan failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
