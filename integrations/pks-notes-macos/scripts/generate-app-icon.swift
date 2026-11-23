#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import CryptoKit

// Export a full-bleed opaque square. Apple owns the OUTER mask/corner radius;
// never add a rounded tile, transparent margin, border or canvas shadow here.
// The inner apricot notebook shape remains part of the selected artwork.
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
guard artwork.width == artwork.height else {
    fputs("Apple app icon source must be a full-bleed square.\n", stderr)
    exit(1)
}
let byteCount = artwork.width * artwork.height * 4
let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
defer { pixels.deallocate() }
pixels.initialize(repeating: 0, count: byteCount)
guard let opacityCheck = CGContext(
    data: pixels, width: artwork.width, height: artwork.height,
    bitsPerComponent: 8, bytesPerRow: artwork.width * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
) else { fatalError("Cannot validate app icon opacity") }
opacityCheck.draw(artwork, in: CGRect(x: 0, y: 0, width: artwork.width, height: artwork.height))
guard stride(from: 3, to: byteCount, by: 4).allSatisfy({ pixels[$0] == 255 }) else {
    fputs("Apple app icon source must be fully opaque, including all four corners. Do not bake in a rounded mask or transparent margin.\n", stderr)
    exit(1)
}
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let pixels = points * scale
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            fatalError("Cannot allocate icon bitmap \(pixels)")
        }
        context.interpolationQuality = .high
        context.draw(artwork, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let rendered = context.makeImage() else { fatalError("Cannot render icon bitmap") }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
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
