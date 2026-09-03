import CoreGraphics
import SkylarkCore

/// Single source of truth for HUD sizes, shared by the SwiftUI view and the
/// panel controller so the panel frame always matches the content (no jumps).
enum HUDMetrics {
    /// Gap below the notch / menu bar.
    static let topGap: CGFloat = 6

    /// The fixed footprint of the pill while a status note is showing. A
    /// CONSTANT on purpose: the note is rendered inside it with truncation,
    /// never by growing the panel. Resizing a hosting panel from inside a view
    /// update recursed through `NSHostingView.windowDidLayout` →
    /// `updateAnimatedWindowSize` and blew the main thread's stack (13 SIGSEGVs
    /// in a 25-note stress run, the reverted 0.20.1 attempt), so the size is
    /// decided here, before the note is shown, exactly like every other state.
    /// Two lines of 11 pt text fit; anything longer is clipped.
    static func noteSize(style: HUDStyle) -> CGSize {
        style == .minimal ? CGSize(width: 300, height: 34) : CGSize(width: 340, height: 40)
    }

    /// Whether a pending note takes over the pill in `state`. While the mic is
    /// open the waveform must stay (the user is watching it to know they are
    /// being recorded); the note waits for the recording to end.
    static func showsNote(in state: HUDState) -> Bool {
        switch state {
        case .listening, .commandListening: return false
        case .idle, .processing: return true
        }
    }

    static func size(for state: HUDState, hovering: Bool, style: HUDStyle = .standard, note: Bool = false) -> CGSize {
        if note, showsNote(in: state) { return noteSize(style: style) }
        switch state {
        case .idle:
            // Idle-ready is a deliberately small, minimal black pill (no dot).
            if hovering { return CGSize(width: 180, height: 28) }
            return style == .minimal ? CGSize(width: 28, height: 7) : CGSize(width: 40, height: 10)
        case let .listening(_, preview, capSecondsRemaining):
            // Live-preview prototype: widen + grow the pill to fit 1-2 lines of
            // interim text under the waveform. Only when preview text exists;
            // otherwise the pill is exactly as before (batch path unaffected).
            if let preview, !preview.isEmpty {
                return CGSize(width: 300, height: style == .minimal ? 52 : 58)
            }
            // Room for the cap countdown ("12s"), and only then.
            let capWidth: CGFloat = capSecondsRemaining == nil ? 0 : 26
            return style == .minimal
                ? CGSize(width: 92 + capWidth, height: 18)
                : CGSize(width: 120 + capWidth, height: 24)
        case .commandListening:
            // Wider than dictation to fit the "Command" label + icon.
            return style == .minimal ? CGSize(width: 104, height: 18) : CGSize(width: 176, height: 24)
        case .processing:
            return style == .minimal ? CGSize(width: 76, height: 16) : CGSize(width: 96, height: 20)
        }
    }

    /// Whether the panel should be on screen at all for this combination.
    /// `.hidden` removes the indicator entirely; hiding the idle pill keeps the
    /// preparing dot visible so model loading still has a cue.
    static func isVisible(
        state: HUDState, hovering: Bool, style: HUDStyle, showIdlePill: Bool, isPreparing: Bool, note: Bool = false
    ) -> Bool {
        guard style != .hidden else { return false }
        // A note brings the pill on screen even when the idle pill is off —
        // it is the one place a user typing in another app can see it.
        if note, showsNote(in: state) { return true }
        if case .idle = state {
            return showIdlePill || hovering || isPreparing
        }
        return true
    }
}
