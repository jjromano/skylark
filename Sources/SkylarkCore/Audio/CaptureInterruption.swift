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
        /// found the tap dead. Correlates with a focus/mic steal.
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
    /// immediately: capture can't continue, so anything after this point would
    /// only be accumulated silence. A configuration change that we successfully
    /// restarted through does NOT finalize — recording continues, the clip just
    /// carries the marker.
    var finalizesUtterance: Bool {
        switch self {
        case .configurationChange: return false
        case .restartFailed, .triggerTapStalled: return true
        }
    }
}
