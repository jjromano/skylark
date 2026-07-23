import Foundation

/// Snapshot of the pipeline state for the HUD (PRD §9). The orchestrator is the
/// only writer; the UI observes these values.
public enum HUDState: Sendable, Equatable {
    case idle
    /// Dictation is recording. `level` drives the waveform; `preview` carries
    /// interim transcription text when the live-preview prototype is enabled
    /// (nil otherwise — the common case). Preview text is display-only and never
    /// pasted.
    case listening(level: Float, preview: TranscriptPreview? = nil)
    case processing
    /// Voice Command Mode is recording an instruction. Distinct from `.listening`
    /// so the HUD pill can render a different tint + a "Command" label; the level
    /// still drives the waveform.
    case commandListening(level: Float)
}
