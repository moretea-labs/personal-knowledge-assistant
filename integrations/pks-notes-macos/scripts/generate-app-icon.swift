#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO

// AppIcon-master.png is the approved artwork. All sizes derive from this source.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let master = resources.appendingPathComponent("AppIcon-master.png")
let iconset = root.appendingPathComponent(".build/PKSNotes.iconset", isDirectory: true)
guard let source = CGImageSourceCreateWithURL(master as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot read approved icon artwork: \(master.path)")
}
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let pixels = points * scale
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            fatalError("Cannot allocate icon bitmap \(pixels)")
        }
        let context = graphics.cgContext
        context.interpolationQuality = .high
        context.draw(artwork, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        graphics.flushGraphics()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode icon bitmap \(pixels)")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        if pixels == 1024 { try data.write(to: resources.appendingPathComponent("AppIcon-1024.png")) }
    }
}
let icon = resources.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icon.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated \(icon.path) from approved AppIcon-master.png")
