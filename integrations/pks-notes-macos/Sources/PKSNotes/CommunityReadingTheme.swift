import Foundation
import AppKit
import SwiftUI

/// A community reading theme is data, not executable code or a second Markdown renderer.
struct CommunityReadingTheme: Codable, Hashable, Identifiable {
    let formatVersion: Int
    let id: String
    let name: String
    let colors: Palette
    let typography: Typography
    let blocks: Blocks

    struct ColorPair: Codable, Hashable {
        let light: String
        let dark: String

        func color() -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return Self.nsColor(hex)
            })
        }

        static func nsColor(_ hex: String) -> NSColor {
            let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }

        static func luminance(_ hex: String) -> Double {
            let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
            let channels = [Double((value >> 16) & 255),
                            Double((value >> 8) & 255), Double(value & 255)]
            let linear = channels.map { raw -> Double in
                let unit = raw / 255
                return unit <= 0.04045 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
            }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }

        static func contrast(_ a: String, _ b: String) -> Double {
            let light = max(luminance(a), luminance(b))
            let dark = min(luminance(a), luminance(b))
            return (light + 0.05) / (dark + 0.05)
        }

        var isValid: Bool {
            [light, dark].allSatisfy {
                $0.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
            }
        }
    }

    struct Palette: Codable, Hashable {
        let canvas: ColorPair
        let ink: ColorPair
        let codeBackground: ColorPair
        let link: ColorPair

        var isValid: Bool {
            guard [canvas, ink, codeBackground, link].allSatisfy(\.isValid),
                  ColorPair.luminance(canvas.light) > 0.6,
                  ColorPair.luminance(canvas.dark) < 0.25 else { return false }
            for dark in [false, true] {
                let canvasColor = dark ? canvas.dark : canvas.light
                let inkColor = dark ? ink.dark : ink.light
                let codeColor = dark ? codeBackground.dark : codeBackground.light
                let linkColor = dark ? link.dark : link.light
                guard ColorPair.contrast(canvasColor, inkColor) >= 4.5,
                      ColorPair.contrast(codeColor, inkColor) >= 4.5,
                      ColorPair.contrast(canvasColor, linkColor) >= 3 else { return false }
            }
            return true
        }
    }

    struct Typography: Codable, Hashable {
        let fontDesign: String
        let bodySize: Double
        let heading1: Double
        let heading2: Double
        let heading3: Double
        let headingWeight: String
        let lineSpacing: Double
        let paragraphSpacing: Double
        let headingSpacing: Double
        let pageWidth: Double
        let quoteInset: Double
        let codePadding: Double
        let codeCorner: Double
        let listSpacing: Double

        var isValid: Bool {
            ["default", "serif", "rounded", "monospaced"].contains(fontDesign)
                && ["regular", "medium", "semibold", "bold"].contains(headingWeight)
                && (14...24).contains(bodySize)
                && (1.5...3.0).contains(heading1)
                && (1.2...2.3).contains(heading2)
                && (1.05...1.8).contains(heading3)
                && heading1 > heading2 && heading2 > heading3
                && (0.08...0.8).contains(lineSpacing)
                && (0.6...2.5).contains(paragraphSpacing)
                && (0.6...3.0).contains(headingSpacing)
                && (560...1100).contains(pageWidth)
                && (4...28).contains(quoteInset)
                && (6...30).contains(codePadding)
                && (0...16).contains(codeCorner)
                && (0.08...0.8).contains(listSpacing)
        }

        var design: Font.Design {
            switch fontDesign {
            case "serif": .serif
            case "rounded": .rounded
            case "monospaced": .monospaced
            default: .default
            }
        }

        var weight: Font.Weight {
            switch headingWeight {
            case "bold": .bold
            case "semibold": .semibold
            case "regular": .regular
            default: .medium
            }
        }

        var reading: ReadingTypography {
            ReadingTypography(
                design: design, bodySize: bodySize,
                heading1: heading1, heading2: heading2, heading3: heading3,
                headingWeight: weight, lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing, headingSpacing: headingSpacing,
                pageWidth: CGFloat(pageWidth), quoteInset: CGFloat(quoteInset),
                codePadding: CGFloat(codePadding), codeCorner: CGFloat(codeCorner),
                listSpacing: listSpacing
            )
        }
    }

    struct Blocks: Codable, Hashable {
        let quoteRuleWidth: Double
        let quoteOpacity: Double
        let quoteItalic: Bool
        let inlineCodeScale: Double
        let codeBlockScale: Double

        var isValid: Bool {
            (1...5).contains(quoteRuleWidth)
                && (0.55...1).contains(quoteOpacity)
                && (0.75...1.1).contains(inlineCodeScale)
                && (0.75...1.1).contains(codeBlockScale)
        }
    }

    var isValid: Bool {
        formatVersion == 1
            && id.range(of: "^[a-z][a-z0-9-]{0,39}$", options: .regularExpression) != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= 50
            && name.rangeOfCharacter(from: .controlCharacters) == nil
            && colors.isValid && typography.isValid && blocks.isValid
    }
}

enum CommunityThemeError: LocalizedError {
    case invalidFile
    case invalidTheme
    case duplicate
    case missing

    var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose a regular .leafspan-theme file smaller than 64 KB."
        case .invalidTheme: "This theme package is invalid, incompatible or has unreadable colors."
        case .duplicate: "A theme with this identifier is already imported."
        case .missing: "This theme is no longer available."
        }
    }
}

/// Application Support package files are the only imported-token authority.
/// The existing PKSNotesReadingTheme key is still the only selection preference.
struct CommunityThemeStore {
    let directory: URL

    static var application: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(directory: root.appendingPathComponent("Leafspan/Themes", isDirectory: true))
    }

    static func validIdentifier(_ id: String) -> Bool {
        id.range(of: "^[a-z][a-z0-9-]{0,39}$", options: .regularExpression) != nil
    }

    static func decode(_ data: Data) throws -> CommunityReadingTheme {
        guard !data.isEmpty, data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["formatVersion", "id", "name", "colors", "typography", "blocks"]),
              let theme = try? JSONDecoder().decode(CommunityReadingTheme.self, from: data),
              theme.isValid else { throw CommunityThemeError.invalidTheme }
        return theme
    }

    private func file(for id: String) -> URL? {
        guard Self.validIdentifier(id) else { return nil }
        return directory.appendingPathComponent(id, isDirectory: false)
            .appendingPathExtension("leafspan-theme")
    }

    private func read(_ url: URL) throws -> Data {
        guard url.pathExtension.lowercased() == "leafspan-theme",
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 65_536
        else { throw CommunityThemeError.invalidFile }
        return try Data(contentsOf: url)
    }

    func installed() -> [CommunityReadingTheme] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )) ?? []
        return urls.compactMap { url -> CommunityReadingTheme? in
            guard let data = try? read(url),
                  let theme = try? Self.decode(data),
                  url.deletingPathExtension().lastPathComponent == theme.id
            else { return nil }
            return theme
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func load(id: String) -> CommunityReadingTheme? {
        guard let url = file(for: id),
              let data = try? read(url),
              let theme = try? Self.decode(data), theme.id == id else { return nil }
        return theme
    }

    @discardableResult
    func importFile(_ url: URL) throws -> CommunityReadingTheme {
        let data = try read(url)
        let theme = try Self.decode(data)
        guard let target = file(for: theme.id) else { throw CommunityThemeError.invalidTheme }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw CommunityThemeError.duplicate }
        try data.write(to: target, options: .atomic)
        return theme
    }

    func export(_ theme: CommunityReadingTheme, to url: URL) throws {
        guard let source = file(for: theme.id),
              let data = try? read(source),
              let verified = try? Self.decode(data),
              verified.id == theme.id else { throw CommunityThemeError.missing }
        try data.write(to: url, options: .atomic)
    }

    func delete(id: String) throws {
        guard let url = file(for: id),
              FileManager.default.fileExists(atPath: url.path) else { throw CommunityThemeError.missing }
        try FileManager.default.removeItem(at: url)
    }
}
