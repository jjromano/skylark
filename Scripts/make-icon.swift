#!/usr/bin/env swift
//
// make-icon.swift — generates Resources/AppIcon.icns from scratch with plain
// CoreGraphics drawing: a rounded-rect gradient (deep indigo → sky blue)
// behind a simple white feather silhouette. Run with:
//
//     swift Scripts/make-icon.swift
//
// Renders all 10 standard iconset sizes into a temporary .iconset directory,
// converts it with `iconutil`, and writes only the resulting .icns into
// Resources/ (the intermediate .iconset is not committed).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

let deepIndigo = CGColor(red: 0x1A / 255, green: 0x14 / 255, blue: 0x5C / 255, alpha: 1)
let skyBlue = CGColor(red: 0x3F / 255, green: 0xA9 / 255, blue: 0xF5 / 255, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

// MARK: - Drawing

/// Draws the full icon (background + feather) into `context` for a canvas of
/// `size` × `size` points. All geometry is expressed as a fraction of `size`
/// so the same routine produces every resolution identically.
func drawIcon(in context: CGContext, size: CGFloat) {
    context.saveGState()

    // --- Background: rounded-rect diagonal gradient -----------------------
    let cornerRadius = size * 0.225
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let backgroundPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    context.addPath(backgroundPath)
    context.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [deepIndigo, skyBlue] as CFArray,
        locations: [0, 1]
    )!
    // Diagonal: top-left (indigo) to bottom-right (sky blue).
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )
    context.resetClip()

    // --- Foreground: white feather silhouette ------------------------------
    // Built in a local "feather space" of height 2 (tip at +1, base at -1,
    // centered on the origin), then scaled/rotated/translated onto the canvas.
    let feather = CGMutablePath()
    let halfWidth = 0.62 // bulge of the vesica sides, in feather-space units
    feather.move(to: CGPoint(x: 0, y: 1)) // tip
    feather.addCurve(
        to: CGPoint(x: 0, y: -1), // base
        control1: CGPoint(x: halfWidth, y: 0.45),
        control2: CGPoint(x: halfWidth, y: -0.55)
    )
    feather.addCurve(
        to: CGPoint(x: 0, y: 1),
        control1: CGPoint(x: -halfWidth, y: -0.55),
        control2: CGPoint(x: -halfWidth, y: 0.45)
    )
    feather.closeSubpath()

    // Map feather-space (height 2, centered) onto the canvas: scale so the
    // feather occupies ~58% of the canvas height, rotate for a dynamic
    // "in flight" tilt, then center.
    let featherScale = size * 0.29
    let rotation = -22.0 * .pi / 180
    var transform = CGAffineTransform(translationX: size / 2, y: size / 2)
    transform = transform.rotated(by: rotation)
    transform = transform.scaledBy(x: featherScale, y: featherScale)

    let transformedFeather = feather.copy(using: &transform)!

    context.addPath(transformedFeather)
    context.setFillColor(white)
    context.fillPath()

    // Quill: a single straight center line from tip to base, in the deep
    // indigo background color, so the feather doesn't read as a blank blob.
    let quill = CGMutablePath()
    quill.move(to: CGPoint(x: 0, y: 0.92))
    quill.addLine(to: CGPoint(x: 0, y: -0.92))
    let transformedQuill = quill.copy(using: &transform)!

    context.addPath(transformedQuill)
    context.setStrokeColor(deepIndigo)
    context.setLineWidth(max(1, size * 0.012))
    context.setLineCap(.round)
    context.strokePath()

    context.restoreGState()
}

/// Renders one PNG at `pixelSize` × `pixelSize` to `url`.
func renderPNG(pixelSize: Int, to url: URL) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create CGContext for size \(pixelSize)")
    }

    drawIcon(in: context, size: CGFloat(pixelSize))

    guard let image = context.makeImage() else {
        fatalError("Could not render image for size \(pixelSize)")
    }

    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        fatalError("Could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write PNG at \(url.path)")
    }
}

// MARK: - Iconset assembly

// Standard 10-entry macOS iconset: (filename, pixel size).
let iconsetEntries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repoRoot = scriptDir.deletingLastPathComponent()
let resourcesDir = repoRoot.appendingPathComponent("Resources")
let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")

let fm = FileManager.default
try? fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

let workDir = fm.temporaryDirectory.appendingPathComponent("SkylarkIcon-\(UUID().uuidString)")
let iconsetDir = workDir.appendingPathComponent("AppIcon.iconset")
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: workDir) }

print("→ Rendering \(iconsetEntries.count) iconset sizes…")
for entry in iconsetEntries {
    let url = iconsetDir.appendingPathComponent("\(entry.name).png")
    renderPNG(pixelSize: entry.pixels, to: url)
    print("  • \(entry.name).png (\(entry.pixels)×\(entry.pixels))")
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
