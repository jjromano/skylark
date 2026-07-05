import Foundation

/// Snapshot of the pipeline state for the HUD (PRD §9). The orchestrator is the
/// only writer; the UI observes these values.
public enum HUDState: Sendable, Equatable {
    case idle
    case listening(level: Float)
    case processing
}
