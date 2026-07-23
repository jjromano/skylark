import AVFoundation
import FluidAudio
import Foundation
import os

/// Live-preview provider backed by FluidAudio's `SlidingWindowAsrManager` over
/// the SAME warm Parakeet models the batch engine already loaded. The streaming
/// manager retains the shared `AsrModels` (`MLModel` instances) without
/// reloading from disk, so preview adds no model download and only a modest
/// resident-memory delta (a second decoder state + a ~15 s sample buffer).
///
/// Preview-only by design: the sliding window re-decodes overlapping windows for
/// interim display; the final pasted text always comes from the batch decode of
/// the full clip (identical quality/latency to today).
public struct FluidAudioLivePreviewProvider: LivePreviewProviding {
    /// Supplies the warm, shared models. Returns nil until the batch engine has
    /// finished warm-up, in which case no preview session is created.
    private let modelsSource: @Sendable () async -> AsrModels?
    private let config: SlidingWindowAsrConfig

    public init(
        modelsSource: @escaping @Sendable () async -> AsrModels?,
        config: SlidingWindowAsrConfig = FluidAudioLivePreviewSession.previewConfig
    ) {
        self.modelsSource = modelsSource
        self.config = config
    }

    public func makeSession() async -> (any LivePreviewSession)? {
        guard let models = await modelsSource() else { return nil }
        let session = FluidAudioLivePreviewSession(config: config)
        do {
            try await session.start(models: models)
        } catch {
            await session.finish()
            return nil
        }
        return session
    }
}

/// One live-preview streaming session. Wraps `SlidingWindowAsrManager`, maps its
/// volatile/confirmed updates onto `TranscriptPreview`, and feeds it the 16 kHz
/// mono frames captured for the current recording.
public actor FluidAudioLivePreviewSession: LivePreviewSession {
    /// Preview-tuned window layout: much smaller chunks than the batch/quality
    /// default (11+2+2) so interim text appears within a couple of seconds of
    /// speech instead of only after 13 s of audio. Quality of the preview text
    /// is secondary — the batch decode owns the pasted result.
    public static let previewConfig = SlidingWindowAsrConfig(
        chunkSeconds: 1.5,
        hypothesisChunkSeconds: 1.0,
        leftContextSeconds: 1.5,
        rightContextSeconds: 0.5,
        minContextForConfirmation: 1.0,
        confirmationThreshold: 0.75
    )

    private let manager: SlidingWindowAsrManager
    private var pumpTask: Task<Void, Never>?
    private var finished = false

    private let updatesContinuation: AsyncStream<TranscriptPreview>.Continuation
    public nonisolated let updates: AsyncStream<TranscriptPreview>

    private static let previewFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )

    private let logger = Logger(subsystem: "com.jjromano.skylark", category: "asr.preview")

    public init(config: SlidingWindowAsrConfig = FluidAudioLivePreviewSession.previewConfig) {
        self.manager = SlidingWindowAsrManager(config: config)
        let (stream, cont) = AsyncStream<TranscriptPreview>.makeStream(bufferingPolicy: .bufferingNewest(2))
        self.updates = stream
        self.updatesContinuation = cont
    }

    /// Load the shared models and start the streaming engine. Called by the
    /// provider before the session is handed to the orchestrator.
    func start(models: AsrModels) async throws {
        try await manager.loadModels(models)
        // Begin pumping updates BEFORE audio flows so the manager's update
        // continuation is installed and no early window is dropped.
        let mgr = manager
        let cont = updatesContinuation
        pumpTask = Task {
            // Each element signals "new interim text available"; its `.text` is
            // only the current chunk, so we read the manager's running
            // confirmed/volatile split for display rather than the element.
            for await _ in await mgr.transcriptionUpdates {
                if Task.isCancelled { break }
                let confirmed = await mgr.confirmedTranscript
                let volatile = await mgr.volatileTranscript
                cont.yield(TranscriptPreview(confirmed: confirmed, volatile: volatile))
            }
        }
        try await manager.startStreaming(source: .microphone)
    }

    public func feed(_ frame: [Float]) async {
        guard !finished, !frame.isEmpty, let buffer = Self.makeBuffer(frame) else { return }
        await manager.streamAudio(buffer)
    }

    public func finish() async {
        guard !finished else { return }
        finished = true
        pumpTask?.cancel()
        pumpTask = nil
        // `cancel()` (not `finish()`): we discard the preview's final text — the
        // batch path owns the pasted result — and want prompt teardown so the
        // streaming decoder stops touching the shared models before the batch
        // decode runs.
        await manager.cancel()
        updatesContinuation.finish()
    }

    /// Wrap 16 kHz mono Float32 samples in an `AVAudioPCMBuffer` for the
    /// manager's audio input (its internal converter treats 16 kHz as identity).
    private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = previewFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
