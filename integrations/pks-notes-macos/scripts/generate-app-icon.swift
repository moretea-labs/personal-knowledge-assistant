#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Reproducible, monochrome macOS icon. Keep one vector source for all icon sizes.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let iconset = root.appendingPathComponent(".build/PKSNotes.iconset", isDirectory: true)
let fm = FileManager.default
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

func gray(_ value: CGFloat, alpha: CGFloat = 1) -> CGColor {
    CGColor(gray: value, alpha: alpha)
}

func draw(_ context: CGContext, pixels: Int) {
    context.saveGState()
    let factor = CGFloat(pixels) / 1024
    context.scaleBy(x: factor, y: factor)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let tile = CGPath(
        roundedRect: CGRect(x: 70, y: 72, width: 884, height: 884),
        cornerWidth: 196, cornerHeight: 196, transform: nil
    )
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -19), blur: 31, color: gray(0.23, alpha: 0.18))
    context.addPath(tile)
    context.setFillColor(gray(0.992))
    context.fillPath()
    context.restoreGState()
    context.addPath(tile)
    context.setStrokeColor(gray(0.86))
    context.setLineWidth(9)
    context.strokePath()

    // Two offset note sheets communicate a knowledge library without small lettering.
    let rear = CGPath(
        roundedRect: CGRect(x: 362, y: 312, width: 412, height: 494),
        cornerWidth: 48, cornerHeight: 48, transform: nil
    )
    context.addPath(rear)
    context.setFillColor(gray(0.95))
    context.fillPath()
    context.addPath(rear)
    context.setStrokeColor(gray(0.63))
    context.setLineWidth(23)
    context.strokePath()

    let front = CGPath(
        roundedRect: CGRect(x: 247, y: 214, width: 475, height: 566),
        cornerWidth: 52, cornerHeight: 52, transform: nil
    )
    context.saveGState()
    context.setShadow(offset: CGSize(width: 8, height: -12), blur: 17, color: gray(0.2, alpha: 0.11))
    context.addPath(front)
    context.setFillColor(gray(1))
    context.fillPath()
    context.restoreGState()
    context.addPath(front)
    context.setStrokeColor(gray(0.24))
    context.setLineWidth(26)
    context.strokePath()

    context.setLineCap(.round)
    context.setStrokeColor(gray(0.27))
    context.setLineWidth(25)
    for (y, end) in [(620.0, 606.0), (547.0, 614.0), (474.0, 526.0)] {
        context.move(to: CGPoint(x: 344, y: y))
        context.addLine(to: CGPoint(x: end, y: y))
        context.strokePath()
    }

    context.setFillColor(gray(0.28))
    context.fillEllipse(in: CGRect(x: 338, y: 325, width: 36, height: 36))
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
