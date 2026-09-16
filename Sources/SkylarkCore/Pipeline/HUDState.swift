import Foundation

/// Snapshot of the pipeline state for the HUD (PRD §9). The orchestrator is the
/// only writer; the UI observes these values.
public enum HUDState: Sendable, Equatable {
    case idle
    /// Dictation is recording. `level` drives the waveform. `capSecondsRemaining`
    /// is non-nil only inside the last stretch before the hard recording cap, and
    /// the pill renders it as a countdown so the limit is never a surprise
    /// (decision 4).
    case listening(
        level: Float,
        capSecondsRemaining: TimeInterval? = nil
    )
    case processing
    /// Voice Command Mode is recording an instruction. Distinct from `.listening`
    /// so the HUD pill can render a different tint + a "Command" label; the level
    /// still drives the waveform.
    case commandListening(level: Float)
}
