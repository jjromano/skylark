import Foundation
import SkylarkCore
import SwiftUI

/// Observable snapshot the HUD SwiftUI view renders from.
@MainActor
@Observable
final class HUDModel {
    /// Number of waveform bars in the listening pill.
    static let barCount = 24

    var state: HUDState = .idle
    var isHovering = false
    /// True while global Whisper Mode is on — the listening dot goes hollow as a
    /// subtle cue (phase-4 spec §5).
    var isWhisperMode = false
    /// True while the speech model is still downloading/loading — the idle dot
    /// pulses to signal "not ready yet".
    var isPreparing = false

    /// Rolling window of recent RMS levels; newest is last. Newest bar enters
    /// from the trailing edge. Seeded flat so the idle placeholder never pops.
    private(set) var waveform: [Float] = Array(repeating: 0, count: HUDModel.barCount)

    var isRecording: Bool {
        if case .listening = state { return true }
        return false
    }

    /// Push a new level onto the waveform (FIFO, fixed width).
    func pushLevel(_ level: Float) {
        waveform.removeFirst()
        waveform.append(level)
    }

    /// Reset the waveform to flat (leaving a recording session).
    func resetWaveform() {
        waveform = Array(repeating: 0, count: Self.barCount)
    }
}
