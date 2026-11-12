#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Leafspan's sole macOS icon source: warm ivory paper with a tactile lowercase p.
// All icon resolutions are derived from these same paths; no embedded raster artwork.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = root.appendingPathComponent(".build/PKSNotes.iconset", isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func shade(
    _ context: CGContext, colors: [CGColor],
    start: CGPoint, end: CGPoint
) {
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: colors as CFArray,
        locations: nil
    ) else { fatalError("Cannot create icon gradient") }
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
}

func draw(_ context: CGContext, pixels: Int) {
    context.saveGState()
    defer { context.restoreGState() }
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let tile = CGPath(
        roundedRect: CGRect(x: 70, y: 74, width: 884, height: 884),
        cornerWidth: 198, cornerHeight: 198, transform: nil
    )
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -19), blur: 36,
                      color: rgb(0.32, 0.24, 0.19, 0.19))
    context.addPath(tile)
    context.setFillColor(rgb(0.99, 0.96, 0.90))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    shade(context,
          colors: [rgb(1.0, 0.997, 0.982), rgb(1.0, 0.972, 0.920), rgb(0.995, 0.932, 0.822)],
          start: CGPoint(x: 240, y: 956), end: CGPoint(x: 850, y: 86))

    // Folded paper corners: broad, quiet curves rather than decorative outlines.
    let lowerFold = CGMutablePath()
    lowerFold.move(to: CGPoint(x: 493, y: 74))
    lowerFold.addCurve(to: CGPoint(x: 958, y: 530),
                       control1: CGPoint(x: 655, y: 219),
                       control2: CGPoint(x: 926, y: 321))
    lowerFold.addLine(to: CGPoint(x: 958, y: 74))
    lowerFold.closeSubpath()
    context.saveGState()
    context.addPath(lowerFold)
    context.clip()
    shade(context, colors: [rgb(1.0, 0.77, 0.34), rgb(1.0, 0.67, 0.12)],
          start: CGPoint(x: 510, y: 510), end: CGPoint(x: 900, y: 74))
    context.restoreGState()

    let upperFold = CGMutablePath()
    upperFold.move(to: CGPoint(x: 488, y: 74))
    upperFold.addCurve(to: CGPoint(x: 956, y: 424),
                       control1: CGPoint(x: 655, y: 250),
                       control2: CGPoint(x: 926, y: 257))
    upperFold.addLine(to: CGPoint(x: 956, y: 558))
    upperFold.addCurve(to: CGPoint(x: 488, y: 74),
                       control1: CGPoint(x: 935, y: 330),
                       control2: CGPoint(x: 645, y: 206))
    upperFold.closeSubpath()
    context.saveGState()
    context.addPath(upperFold)
    context.clip()
    shade(context, colors: [rgb(1.0, 0.995, 0.959), rgb(1.0, 0.948, 0.810)],
          start: CGPoint(x: 560, y: 350), end: CGPoint(x: 932, y: 142))
    context.restoreGState()
    context.restoreGState()

    // A custom lowercase p, with a genuine transparent counter and soft extruded edge.
    // The shape remains distinct at 16pt, unlike thin page/paragraph ornamentation.
    let letter = CGMutablePath()
    letter.move(to: CGPoint(x: 303, y: 240))
    letter.addCurve(to: CGPoint(x: 373, y: 301),
                    control1: CGPoint(x: 338, y: 232), control2: CGPoint(x: 367, y: 260))
    letter.addLine(to: CGPoint(x: 399, y: 439))
    letter.addCurve(to: CGPoint(x: 647, y: 436),
                    control1: CGPoint(x: 476, y: 398), control2: CGPoint(x: 581, y: 400))
    letter.addCurve(to: CGPoint(x: 749, y: 674),
                    control1: CGPoint(x: 751, y: 496), control2: CGPoint(x: 786, y: 576))
    letter.addCurve(to: CGPoint(x: 508, y: 799),
                    control1: CGPoint(x: 717, y: 771), control2: CGPoint(x: 613, y: 818))
    letter.addCurve(to: CGPoint(x: 329, y: 576),
                    control1: CGPoint(x: 396, y: 776), control2: CGPoint(x: 324, y: 689))
    letter.addLine(to: CGPoint(x: 264, y: 339))
    letter.addCurve(to: CGPoint(x: 303, y: 240),
                    control1: CGPoint(x: 254, y: 289), control2: CGPoint(x: 270, y: 249))
    letter.closeSubpath()
    let counter = CGPath(
        ellipseIn: CGRect(x: 467, y: 533, width: 178, height: 150),
        transform: nil
    )
    let glyph = CGMutablePath()
    glyph.addPath(letter)
    glyph.addPath(counter)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -15), blur: 21,
                      color: rgb(0.59, 0.25, 0.09, 0.21))
    context.addPath(glyph)
    context.setFillColor(rgb(0.99, 0.48, 0.14))
    context.drawPath(using: .eoFill)
    context.restoreGState()

    context.saveGState()
    context.addPath(glyph)
    context.clip(using: .evenOdd)
    shade(context,
          colors: [rgb(0.96, 0.32, 0.10), rgb(1.0, 0.54, 0.16), rgb(1.0, 0.78, 0.25)],
          start: CGPoint(x: 280, y: 230), end: CGPoint(x: 715, y: 804))
    context.restoreGState()
}

for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Cannot allocate icon bitmap \(pixels)")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        draw(graphics.cgContext, pixels: pixels)
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode icon bitmap \(pixels)")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
let icon = resources.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icon.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated \(icon.path)")
