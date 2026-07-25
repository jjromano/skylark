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
    /// The current recording became a hands-free (double-tap-lock) session:
    /// there is no key to release, so the orchestrator arms VAD endpointing.
    case engageHandsFree
    /// Begin a Voice Command Mode session (a separate, optional trigger): the
    /// user speaks an INSTRUCTION rather than dictation. Press-and-hold only.
    case startCommand
    /// Finish the command session and run the command pipeline (transcribe the
    /// instruction, read the selection, run the tier LLM, replace/insert).
    case stopCommand
    /// The input path was disrupted mid-utterance (our event tap stalled — the
    /// signature of another app seizing the key/mic). The orchestrator finalizes
    /// what it has at this boundary instead of accumulating silence, and warns
    /// that the text may be incomplete. Never discards audio.
    case captureInterrupted
}
