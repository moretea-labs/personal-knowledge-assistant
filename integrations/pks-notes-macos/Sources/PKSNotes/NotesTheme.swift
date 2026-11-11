import SwiftUI
import AppKit

/// One persisted presentation preference; notes remain plain Markdown on disk.
enum NotesTheme: String, CaseIterable, Identifiable {
    case system
    case paper
    case warm
    case midnight
    case graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: "System"
        case .paper: "Paper"
        case .warm: "Warm"
        case .midnight: "Midnight"
        case .graphite: "Graphite"
        }
    }

    var symbol: String {
        switch self {
        case .system: "laptopcomputer"
        case .paper: "doc.text"
        case .warm: "sun.max"
        case .midnight: "moon.stars"
        case .graphite: "circle.lefthalf.filled"
        }
    }

    /// App appearance owns light/dark. Reading themes can tint the page, but must
    /// never force a dark document inside Light mode or a light document inside Dark mode.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    var canvas: Color {
        switch self {
        case .system:
            Color(nsColor: .textBackgroundColor)
        case .paper:
            Self.adaptive(
                light: Self.rgb(0.998, 0.998, 0.997),
                dark: Self.rgb(0.105, 0.114, 0.126)
            )
        case .warm:
            Self.adaptive(
                light: Self.rgb(0.974, 0.951, 0.903),
                dark: Self.rgb(0.135, 0.116, 0.092)
            )
        case .midnight:
            Self.adaptive(
                light: Self.rgb(0.965, 0.973, 0.980),
                dark: Self.rgb(0.111, 0.125, 0.143)
            )
        case .graphite:
            Self.adaptive(
                light: Self.rgb(0.962, 0.964, 0.958),
                dark: Self.rgb(0.125, 0.129, 0.137)
            )
        }
    }

    var ink: Color {
        switch self {
        case .system:
            .primary
        case .paper:
            Self.adaptive(
                light: Self.rgb(0.16, 0.19, 0.23),
                dark: Self.rgb(0.91, 0.92, 0.94)
            )
        case .warm:
            Self.adaptive(
                light: Self.rgb(0.28, 0.25, 0.21),
                dark: Self.rgb(0.93, 0.88, 0.79)
            )
        case .midnight:
            Self.adaptive(
                light: Self.rgb(0.13, 0.18, 0.22),
                dark: Self.rgb(0.88, 0.90, 0.91)
            )
        case .graphite:
            Self.adaptive(
                light: Self.rgb(0.15, 0.16, 0.15),
                dark: Self.rgb(0.915, 0.916, 0.902)
            )
        }
    }

    var codeBackground: Color {
        switch self {
        case .system:
            Color(nsColor: .controlBackgroundColor)
        case .paper:
            Self.adaptive(
                light: Self.rgb(0.954, 0.961, 0.969),
                dark: Self.rgb(0.155, 0.168, 0.187)
            )
        case .warm:
            Self.adaptive(
                light: Self.rgb(0.922, 0.887, 0.829),
                dark: Self.rgb(0.205, 0.171, 0.132)
            )
        case .midnight:
            Self.adaptive(
                light: Self.rgb(0.900, 0.922, 0.940),
                dark: Self.rgb(0.17, 0.19, 0.22)
            )
        case .graphite:
            Self.adaptive(
                light: Self.rgb(0.900, 0.910, 0.890),
                dark: Self.rgb(0.173, 0.18, 0.192)
            )
        }
    }

    var readingFont: Font.Design {
        switch self {
        case .warm: .serif
        case .system, .paper, .midnight, .graphite: .default
        }
    }

    static func restored(_ value: String) -> NotesTheme {
        NotesTheme(rawValue: value) ?? .system
    }
}

/// Complete typography decisions live with the preset, independent of its color scheme.
/// Users adjust relative offsets rather than creating another persistent style authority.
struct ReadingTypography {
    let design: Font.Design
    let bodySize: Double
    let heading1: Double
    let heading2: Double
    let heading3: Double
    let headingWeight: Font.Weight
    let lineSpacing: Double
    let paragraphSpacing: Double
    let headingSpacing: Double
    let pageWidth: CGFloat
    let quoteInset: CGFloat
    let codePadding: CGFloat
    let codeCorner: CGFloat
    let listSpacing: Double
}

extension NotesTheme {
    var typography: ReadingTypography {
        switch self {
        case .system:
            ReadingTypography(
                design: .default, bodySize: 17,
                heading1: 2.16, heading2: 1.52, heading3: 1.17,
                headingWeight: .medium, lineSpacing: 0.38,
                paragraphSpacing: 1.24, headingSpacing: 1.72,
                pageWidth: 735, quoteInset: 12, codePadding: 16,
                codeCorner: 7, listSpacing: 0.34
            )
        case .paper:
            ReadingTypography(
                design: .rounded, bodySize: 16.5,
                heading1: 2.22, heading2: 1.58, heading3: 1.24,
                headingWeight: .bold, lineSpacing: 0.40,
                paragraphSpacing: 1.35, headingSpacing: 1.65,
                pageWidth: 715, quoteInset: 14, codePadding: 20,
                codeCorner: 3, listSpacing: 0.34
            )
        case .warm:
            ReadingTypography(
                design: .serif, bodySize: 18,
                heading1: 2.08, heading2: 1.47, heading3: 1.20,
                headingWeight: .medium, lineSpacing: 0.43,
                paragraphSpacing: 1.48, headingSpacing: 1.90,
                pageWidth: 675, quoteInset: 18, codePadding: 20,
                codeCorner: 2, listSpacing: 0.38
            )
        case .midnight:
            ReadingTypography(
                design: .monospaced, bodySize: 15.5,
                heading1: 1.80, heading2: 1.36, heading3: 1.12,
                headingWeight: .semibold, lineSpacing: 0.23,
                paragraphSpacing: 0.96, headingSpacing: 1.23,
                pageWidth: 800, quoteInset: 10, codePadding: 14,
                codeCorner: 5, listSpacing: 0.20
            )
        case .graphite:
            ReadingTypography(
                design: .default, bodySize: 16,
                heading1: 1.94, heading2: 1.42, heading3: 1.15,
                headingWeight: .semibold, lineSpacing: 0.31,
                paragraphSpacing: 1.29, headingSpacing: 1.54,
                pageWidth: 755, quoteInset: 15, codePadding: 17,
                codeCorner: 6, listSpacing: 0.28
            )
        }
    }

    var linkColor: Color {
        switch self {
        case .system:
            .accentColor
        case .paper:
            Self.adaptive(
                light: Self.rgb(0.18, 0.36, 0.58),
                dark: Self.rgb(0.47, 0.70, 0.96)
            )
        case .warm:
            Self.adaptive(
                light: Self.rgb(0.48, 0.29, 0.14),
                dark: Self.rgb(0.85, 0.60, 0.32)
            )
        case .midnight:
            Self.adaptive(
                light: Self.rgb(0.10, 0.42, 0.56),
                dark: Self.rgb(0.47, 0.73, 0.82)
            )
        case .graphite:
            Self.adaptive(
                light: Self.rgb(0.49, 0.33, 0.09),
                dark: Self.rgb(0.92, 0.72, 0.39)
            )
        }
    }
}
