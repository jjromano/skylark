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
}
