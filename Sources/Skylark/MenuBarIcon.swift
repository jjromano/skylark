import AppKit

/// The status-item glyph: the same tilted feather as the app icon
/// (Scripts/make-icon.swift), rendered as a monochrome template image so it
/// adapts to menu-bar appearance (light/dark, active/inactive) like native
/// items. Drawn once, vector, at any backing scale.
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

    /// Mirrors the feather geometry in Scripts/make-icon.swift: a vesica
    /// silhouette (tip up) with a knocked-out quill line, tilted -22°.
    private static func draw(in context: CGContext, size: CGFloat) {
        let feather = CGMutablePath()
        let halfWidth = 0.62
        feather.move(to: CGPoint(x: 0, y: 1))
        feather.addCurve(
            to: CGPoint(x: 0, y: -1),
            control1: CGPoint(x: halfWidth, y: 0.45),
            control2: CGPoint(x: halfWidth, y: -0.55)
        )
        feather.addCurve(
            to: CGPoint(x: 0, y: 1),
            control1: CGPoint(x: -halfWidth, y: -0.55),
            control2: CGPoint(x: -halfWidth, y: 0.45)
        )
        feather.closeSubpath()

        // Slightly larger relative scale than the app icon (0.44 vs 0.29):
        // a status item has no rounded-rect frame to clear, so the glyph can
        // fill more of the canvas and stay legible at 18 pt.
        let scale = size * 0.44
        let rotation = -22.0 * .pi / 180
        var transform = CGAffineTransform(translationX: size / 2, y: size / 2)
        transform = transform.rotated(by: rotation)
        transform = transform.scaledBy(x: scale, y: scale)

        context.saveGState()
        context.addPath(feather.copy(using: &transform)!)
        context.setFillColor(.black) // template: only alpha matters
        context.fillPath()

        // Quill knockout — clears a center line so the silhouette reads as a
        // feather, not a leaf-shaped blob, in both menu-bar appearances.
        let quill = CGMutablePath()
        quill.move(to: CGPoint(x: 0, y: 0.82))
        quill.addLine(to: CGPoint(x: 0, y: -0.86))
        context.addPath(quill.copy(using: &transform)!)
        context.setBlendMode(.clear)
        context.setLineWidth(max(1, size * 0.075))
        context.setLineCap(.round)
        context.strokePath()
        context.restoreGState()
    }
}
