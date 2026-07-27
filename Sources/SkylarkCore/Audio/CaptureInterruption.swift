import Foundation

/// A disruption of the input path observed while an utterance was being
/// captured (WS1). Capture reports these on `AudioCapturing.interruptions` and
/// stamps the first one onto the finalized `AudioClip`; the hotkey layer raises
/// its own via `HotkeyEvent.captureInterrupted`. All of them converge on the
/// orchestrator's single finalize decision.
public struct CaptureInterruption: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// `AVAudioEngineConfigurationChange` fired mid-recording (device/route
        /// change, or another app seizing the input) and the engine was restarted
        /// preserving what had already been captured. Often the earliest signal
        /// that something took the mic.
        case configurationChange
        /// The engine could not be restarted after a configuration change —
        /// nothing more will arrive, so the utterance ends here.
        case restartFailed
        /// Our `CGEventTap` was disabled by TIMEOUT (the main run loop stalled
        /// past the OS's patience) while a session was live, or the 1 s watchdog
        /// found the tap dead. This CAN mean a focus/mic steal — but it also fires
        /// on a benign main-loop stall while the user is still holding the key, so
        /// it is recorded as a marker only and does NOT finalize (finalizing here
        /// would clip a still-holding user — the v0.7.5 failure mode). A genuine
        /// steal leaves a silent/short tail that the Fn-up finalize trims anyway.
        case triggerTapStalled
    }

    public let reason: Reason
    /// Seconds of audio already captured when the disruption was seen, when
    /// known (`nil` from the hotkey layer, which can't see the sample clock).
    public let at: TimeInterval?

    public init(reason: Reason, at: TimeInterval? = nil) {
        self.reason = reason
        self.at = at
    }
}

public extension CaptureInterruption.Reason {
    /// Whether this disruption means the current utterance must be finalized
    /// immediately: capture provably can't continue, so anything after this point
    /// would only be accumulated silence.
    ///
    /// Only `restartFailed` qualifies — the engine could not be restarted, so no
    /// more audio will ever arrive. `configurationChange` restarted successfully
    /// (recording continues; the clip carries the marker). `triggerTapStalled`
    /// does NOT finalize: it also fires on a benign main-loop stall while the user
    /// is still holding, so finalizing would clip them; the marker is recorded and
    /// the Fn-up finalize trims any silent/short tail a genuine steal left behind.
    var finalizesUtterance: Bool {
        switch self {
        case .configurationChange, .triggerTapStalled: return false
        case .restartFailed: return true
        }
    }
}
