import CoreGraphics
import SkylarkCore

/// Single source of truth for HUD sizes, shared by the SwiftUI view and the
/// panel controller so the panel frame always matches the content (no jumps).
enum HUDMetrics {
    /// Gap below the notch / menu bar.
    static let topGap: CGFloat = 6

    static func size(for state: HUDState, hovering: Bool, style: HUDStyle = .standard) -> CGSize {
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
    static func isVisible(state: HUDState, hovering: Bool, style: HUDStyle, showIdlePill: Bool, isPreparing: Bool) -> Bool {
        guard style != .hidden else { return false }
        if case .idle = state {
            return showIdlePill || hovering || isPreparing
        }
        return true
    }
}
