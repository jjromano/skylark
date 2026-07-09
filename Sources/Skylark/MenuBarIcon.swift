import AppKit

/// The status-item glyph: a sleek skylark in flight (swept wing, forked tail),
/// rendered as a monochrome template image so it adapts to menu-bar appearance
/// (light/dark, active/inactive) like native items. Drawn once, vector, at any
/// backing scale.
@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: context, size: side)
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Bird silhouette in a unit square (origin bottom-left): beak at the
    /// right, single swept-up wing, forked tail at the left. Tuned visually at
    /// 256 px and 36 px so it stays legible at menu-bar size.
    private static func draw(in context: CGContext, size: CGFloat) {
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

        let bird = CGMutablePath()
        bird.move(to: pt(0.97, 0.55))                                            // beak tip
        bird.addCurve(to: pt(0.70, 0.44), control1: pt(0.90, 0.50), control2: pt(0.79, 0.44)) // chin
        bird.addCurve(to: pt(0.40, 0.34), control1: pt(0.60, 0.42), control2: pt(0.50, 0.36)) // belly
        bird.addCurve(to: pt(0.06, 0.20), control1: pt(0.26, 0.30), control2: pt(0.13, 0.24)) // lower tail tip
        bird.addCurve(to: pt(0.24, 0.40), control1: pt(0.13, 0.28), control2: pt(0.19, 0.35)) // tail notch
        bird.addCurve(to: pt(0.04, 0.50), control1: pt(0.17, 0.43), control2: pt(0.09, 0.47)) // upper tail tip
        bird.addCurve(to: pt(0.40, 0.55), control1: pt(0.16, 0.55), control2: pt(0.29, 0.57)) // back → wing root
        bird.addCurve(to: pt(0.33, 0.95), control1: pt(0.37, 0.68), control2: pt(0.33, 0.84)) // wing trailing edge
        bird.addCurve(to: pt(0.57, 0.63), control1: pt(0.42, 0.87), control2: pt(0.50, 0.72)) // wing tip → leading edge
        bird.addCurve(to: pt(0.78, 0.65), control1: pt(0.64, 0.61), control2: pt(0.71, 0.63)) // shoulder → crown
        bird.addCurve(to: pt(0.97, 0.55), control1: pt(0.86, 0.66), control2: pt(0.93, 0.61)) // crown → beak
        bird.closeSubpath()

        // Map the unit square onto the canvas with a 1-pt inset; nudge down
        // 0.5 pt to optically center (the wing carries visual weight upward).
        let inset: CGFloat = 1
        let scale = size - inset * 2
        var transform = CGAffineTransform(translationX: inset, y: inset - 0.5)
            .scaledBy(x: scale, y: scale)

        context.saveGState()
        context.addPath(bird.copy(using: &transform)!)
        context.setFillColor(.black) // template: only alpha matters
        context.fillPath()
        context.restoreGState()
    }
}
