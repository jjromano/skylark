import Foundation

/// Abstraction over the microphone capture path so the orchestrator can be
/// tested with a fake. All methods are cheap and non-blocking on the caller.
public protocol AudioCapturing: Sendable {
    /// Pre-start the engine so the first hotkey press pays no cold-start cost.
    func prepare()
    /// Begin capturing into the preallocated buffer.
    func start() throws
    /// Stop capturing and return the finalized clip (16 kHz mono Float32).
    func stop() -> AudioClip
    /// RMS levels per tap callback for the HUD waveform (emitted even in Phase 0).
    var levels: AsyncStream<Float> { get }
    /// Raw 16 kHz mono frames for streaming VAD (hands-free endpointing only).
    /// Emitted only while frame delivery is enabled, so the push-to-talk path
    /// pays nothing.
    ///
    /// CONTRACT: every access returns a FRESH stream and retires the previous
    /// one. Consumers iterate it in a task that gets CANCELLED at the end of a
    /// hands-free session, and a cancelled iteration finishes an `AsyncStream`
    /// permanently — so a stored stream endpoints once per launch and then dies
    /// silently (P1-2a). Implementations must mint per access; consumers must
    /// take the stream ONCE per session and iterate that value.
    var frames: AsyncStream<[Float]> { get }
    /// Enable/disable raw-frame delivery on `frames`. Off by default.
    func setFramesWanted(_ wanted: Bool)
    /// Raw 16 kHz mono frames for the optional live transcription preview.
    /// Delivered on a separate stream from `frames` so preview and hands-free
    /// VAD never contend for the same single-consumer iterator. Emitted only
    /// while preview delivery is enabled.
    var previewFrames: AsyncStream<[Float]> { get }
    /// Enable/disable raw-frame delivery on `previewFrames`. Off by default.
    func setPreviewWanted(_ wanted: Bool)
    /// Disruptions of the input path observed while recording (engine
    /// configuration change, failed restart). The orchestrator finalizes the
    /// utterance on the ones capture can't recover from; the rest are stamped
    /// onto the returned clip. Off the audio thread.
    var interruptions: AsyncStream<CaptureInterruption> { get }
    /// Seconds left before capture hits its hard recording cap, once inside the
    /// warning window; nil while there's plenty of headroom (the normal case) or
    /// when the implementation has no cap. Read per HUD tick, so it must be a
    /// cheap snapshot — never blocking, never a lock the audio thread can hold.
    func capCountdown() -> TimeInterval?
}

public extension AudioCapturing {
    /// Default: no frame delivery (fakes and Phase-0 callers don't need it).
    var frames: AsyncStream<[Float]> { AsyncStream { $0.finish() } }
    func setFramesWanted(_ wanted: Bool) {}
    var previewFrames: AsyncStream<[Float]> { AsyncStream { $0.finish() } }
    func setPreviewWanted(_ wanted: Bool) {}
    /// Default: nothing ever interrupts (fakes and Phase-0 callers).
    var interruptions: AsyncStream<CaptureInterruption> { AsyncStream { $0.finish() } }
    /// Default: no cap to warn about (fakes return a preset clip).
    func capCountdown() -> TimeInterval? { nil }
}
