import CoreGraphics
import SkylarkCore

/// Single source of truth for HUD sizes, shared by the SwiftUI view and the
/// panel controller so the panel frame always matches the content (no jumps).
enum HUDMetrics {
    /// Gap below the notch / menu bar.
    static let topGap: CGFloat = 6

    static func size(for state: HUDState, hovering: Bool) -> CGSize {
        switch state {
        case .idle:
            // Idle-ready is a deliberately small, minimal black pill (no dot).
            return hovering ? CGSize(width: 180, height: 28) : CGSize(width: 40, height: 10)
        case .listening:
            return CGSize(width: 120, height: 24)
        case .processing:
            return CGSize(width: 96, height: 20)
        }
    }
}
