#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import CryptoKit

// Leafspan's 2026-11-12 icon: an ivory tile, muted apricot folded cover and
// a legible note page. Derive every shipped size from this one master.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let resources = root.appendingPathComponent("Resources", isDirectory: true)
let master = resources.appendingPathComponent("LeafspanIcon-master.png")
let iconset = root.appendingPathComponent(".build/PKSNotes.iconset", isDirectory: true)
let manifest = try String(contentsOf: resources.appendingPathComponent("AppIcon.sha256"), encoding: .utf8)
let approvedHash = manifest.split(separator: "\n").compactMap { line -> String? in
    let fields = line.split(whereSeparator: \.isWhitespace)
    return fields.count == 2 && fields[1] == "Resources/LeafspanIcon-master.png" ? String(fields[0]) : nil
}.first
let masterData = try Data(contentsOf: master)
let actualHash = SHA256.hash(data: masterData).map { String(format: "%02x", $0) }.joined()
guard let approvedHash, actualHash == approvedHash else {
    fputs("Leafspan icon master differs from the user-selected artwork. Restore it from Git; change AppIcon.sha256 only for an explicit user-approved redesign.\n", stderr)
    exit(1)
}
guard let source = CGImageSourceCreateWithData(masterData as CFData, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Cannot read Leafspan icon master: \(master.path)")
}
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
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
        graphics.cgContext.interpolationQuality = .high
        graphics.cgContext.draw(artwork, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        graphics.flushGraphics()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot encode icon bitmap \(pixels)")
        }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        if pixels == 1024 {
            try data.write(to: resources.appendingPathComponent("AppIcon-1024.png"))
        }
    }
}
let icon = resources.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icon.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Generated \(icon.path) from LeafspanIcon-master.png")
