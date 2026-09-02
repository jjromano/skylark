import AppKit

/// Skylark's mark — the faceted lark — as an AppKit *template* image.
///
/// One asset, generated from the same source artwork as the app icon by
/// `Scripts/make-icon.swift`, so the Dock and the menu bar can never show two
/// different birds again. Being a template, only its alpha matters: macOS tints
/// it for light and dark menu bars and for the highlighted state, exactly the
/// way native status items behave.
@MainActor
enum SkylarkMark {
    /// The conventional status-item glyph height.
    static let menuBarHeight: CGFloat = 18

    /// The mark at menu-bar size. Never nil: if the bundled asset is somehow
    /// missing, this falls back to the stock SF Symbol rather than returning
    /// nothing, because a `MenuBarExtra` with no drawable label is
    /// indistinguishable from the app having failed to launch at all.
    static let menuBar: NSImage = sized(height: menuBarHeight)

    /// The mark scaled to `height` points, preserving its aspect ratio.
    static func sized(height: CGFloat) -> NSImage {
        guard let url = Bundle.module.url(forResource: "SkylarkMark", withExtension: "png"),
              let image = NSImage(contentsOf: url),
              image.size.height > 0 else {
            return fallback(height: height)
        }
        let aspect = image.size.width / image.size.height
        image.size = NSSize(width: (height * aspect).rounded(), height: height)
        image.isTemplate = true
        return image
    }

    private static func fallback(height: CGFloat) -> NSImage {
        let image = NSImage(systemSymbolName: "bird.fill",
                            accessibilityDescription: "Skylark") ?? NSImage()
        if image.size.height > 0 {
            let aspect = image.size.width / image.size.height
            image.size = NSSize(width: (height * aspect).rounded(), height: height)
        }
        image.isTemplate = true
        return image
    }
}
