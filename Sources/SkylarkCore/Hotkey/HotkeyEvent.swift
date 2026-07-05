import Foundation

/// High-level recording intents produced by the hotkey layer and consumed by
/// the `DictationOrchestrator`. (The `.none` case from the spec is modelled as
/// `nil` from `HotkeyProcessor.process`.)
public enum HotkeyEvent: Sendable, Equatable {
    /// Begin a new recording session.
    case startRecording
    /// Finish recording and run the pipeline.
    case stopRecording
    /// Explicit cancellation (ESC / chord interruption): drop audio, no paste.
    case cancel
    /// Silent discard of an accidental/too-short activation: drop audio, no paste.
    case discard
}
