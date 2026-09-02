#!/usr/bin/env swift
//
// make-icon.swift — builds both of Skylark's identity assets from ONE source
// artwork, so the Dock icon and the menu-bar glyph can never drift apart again:
//
//   Resources/skylark-mark.png            (source: the faceted lark, alpha-cut)
//     ├─> Resources/AppIcon.icns          (the mark on a warm paper squircle)
//     └─> Sources/Skylark/Resources/SkylarkMark.png
//                                         (the mark's silhouette, as a template)
//
// Run with:
//
//     swift Scripts/make-icon.swift
//
// The menu-bar output is an AppKit *template* image: only its alpha matters,
// so macOS tints it for light/dark menu bars and for the highlighted state the
// way every native status item does.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paths

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let resourcesDir = repoRoot.appendingPathComponent("Resources")
let markURL = resourcesDir.appendingPathComponent("skylark-mark.png")
let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")
let glyphURL = repoRoot
    .appendingPathComponent("Sources/Skylark/Resources/SkylarkMark.png")

// MARK: - Palette
//
// Sampled from the source artwork's own paper, so the tile and the mark agree.

let paperTop = CGColor(red: 0xFA / 255, green: 0xF8 / 255, blue: 0xF1 / 255, alpha: 1)
let paperBottom = CGColor(red: 0xEE / 255, green: 0xEA / 255, blue: 0xDD / 255, alpha: 1)
let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

// MARK: - Source artwork

guard let markSource = CGImageSourceCreateWithURL(markURL as CFURL, nil),
      let mark = CGImageSourceCreateImageAtIndex(markSource, 0, nil) else {
    fatalError("Could not read \(markURL.path). The source artwork must exist.")
}
let markAspect = CGFloat(mark.width) / CGFloat(mark.height)

/// Aspect-fits `mark` inside a centred box covering `fraction` of `size`.
func markRect(in size: CGFloat, fraction: CGFloat, dy: CGFloat = 0) -> CGRect {
    let box = size * fraction
    let w = markAspect >= 1 ? box : box * markAspect
    let h = markAspect >= 1 ? box / markAspect : box
    return CGRect(x: (size - w) / 2, y: (size - h) / 2 + dy * size, width: w, height: h)
}

// MARK: - App icon

/// Draws the full app icon — paper squircle plus the mark — at `size` points.
func drawAppIcon(in context: CGContext, size: CGFloat) {
    context.saveGState()
    context.interpolationQuality = .high

    // Rounded-rect "squircle" ground with a barely-there vertical warmth.
    let cornerRadius = size * 0.225
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                           cornerHeight: cornerRadius, transform: nil))
    context.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [paperTop, paperBottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: 0, y: 0),
                               options: [])

    // The mark, sitting a touch above centre so it reads as optically centred
    // once the tail's visual weight is accounted for.
    context.draw(mark, in: markRect(in: size, fraction: 0.76, dy: 0.015))

    context.restoreGState()
}

// MARK: - Menu-bar template
//
// Only alpha survives: draw the mark, then flood black through `.sourceIn` so
// every opaque pixel becomes black and the shape's own alpha is preserved.

func drawMenuBarTemplate(in context: CGContext, width: CGFloat, height: CGFloat) {
    context.saveGState()
    context.interpolationQuality = .high
    context.draw(mark, in: CGRect(x: 0, y: 0, width: width, height: height))
    context.setBlendMode(.sourceIn)
    context.setFillColor(black)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.restoreGState()
}

// MARK: - Rendering helpers

func makeContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create a \(width)×\(height) context") }
    return context
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not create a PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write \(url.path)")
    }
}

// MARK: - Iconset assembly

let iconsetEntries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let fm = FileManager.default
let workDir = fm.temporaryDirectory.appendingPathComponent("SkylarkIcon-\(UUID().uuidString)")
let iconsetDir = workDir.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: workDir) }

print("→ Rendering \(iconsetEntries.count) iconset sizes from skylark-mark.png…")
for entry in iconsetEntries {
    let context = makeContext(width: entry.pixels, height: entry.pixels)
    drawAppIcon(in: context, size: CGFloat(entry.pixels))
    guard let image = context.makeImage() else {
        fatalError("Could not render \(entry.name)")
    }
    writePNG(image, to: iconsetDir.appendingPathComponent("\(entry.name).png"))
    print("  • \(entry.name).png")
}

print("→ Running iconutil -c icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}
print("✓ Wrote \(icnsURL.path)")

// MARK: - Menu-bar glyph
//
// 18 pt tall (the conventional status-item glyph height) rendered at 8× so it
// stays crisp on every backing scale; SkylarkMark.swift stamps the point size.

let glyphPointHeight = 18
let glyphScale = 8
let glyphHeight = glyphPointHeight * glyphScale
let glyphWidth = Int((CGFloat(glyphHeight) * markAspect).rounded())

let glyphContext = makeContext(width: glyphWidth, height: glyphHeight)
drawMenuBarTemplate(in: glyphContext, width: CGFloat(glyphWidth), height: CGFloat(glyphHeight))
guard let glyph = glyphContext.makeImage() else {
    fatalError("Could not render the menu-bar template")
}
writePNG(glyph, to: glyphURL)
print("✓ Wrote \(glyphURL.path) (\(glyphWidth)×\(glyphHeight), template)")
print("  menu-bar point size: \(String(format: "%.1f", CGFloat(glyphWidth) / CGFloat(glyphScale)))×\(glyphPointHeight)")
