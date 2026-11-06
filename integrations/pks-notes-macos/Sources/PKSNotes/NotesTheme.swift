import SwiftUI

/// One persisted presentation preference; notes remain plain Markdown on disk.
enum NotesTheme: String, CaseIterable, Identifiable {
    case system
    case paper
    case warm
    case midnight

    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: "System"
        case .paper: "Paper"
        case .warm: "Warm"
        case .midnight: "Midnight"
        }
    }

    var symbol: String {
        switch self {
        case .system: "laptopcomputer"
        case .paper: "doc.text"
        case .warm: "sun.max"
        case .midnight: "moon.stars"
        }
    }

    var appearance: ColorScheme? {
        switch self {
        case .system: nil
        case .paper, .warm: .light
        case .midnight: .dark
        }
    }

    var canvas: Color {
        switch self {
        case .system: Color(nsColor: .textBackgroundColor)
        case .paper: Color(red: 0.998, green: 0.998, blue: 0.997)
        case .warm: Color(red: 0.974, green: 0.951, blue: 0.903)
        case .midnight: Color(red: 0.111, green: 0.125, blue: 0.143)
        }
    }

    var ink: Color {
        switch self {
        case .system: .primary
        case .paper: Color(red: 0.16, green: 0.19, blue: 0.23)
        case .warm: Color(red: 0.28, green: 0.25, blue: 0.21)
        case .midnight: Color(red: 0.88, green: 0.90, blue: 0.91)
        }
    }

    var codeBackground: Color {
        switch self {
        case .system: Color(nsColor: .controlBackgroundColor)
        case .paper: Color(red: 0.954, green: 0.961, blue: 0.969)
        case .warm: Color(red: 0.922, green: 0.887, blue: 0.829)
        case .midnight: Color(red: 0.17, green: 0.19, blue: 0.22)
        }
    }

    var readingFont: Font.Design {
        switch self {
        case .warm: .serif
        case .system, .paper, .midnight: .default
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
                design: .default, bodySize: 16,
                heading1: 1.85, heading2: 1.40, heading3: 1.16,
                headingWeight: .semibold, lineSpacing: 0.27,
                paragraphSpacing: 1.08, headingSpacing: 1.35,
                pageWidth: 740, quoteInset: 12, codePadding: 16,
                codeCorner: 7, listSpacing: 0.25
            )
        case .paper:
            ReadingTypography(
                design: .rounded, bodySize: 17,
                heading1: 2.22, heading2: 1.58, heading3: 1.24,
                headingWeight: .bold, lineSpacing: 0.38,
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
        }
    }

    var linkColor: Color {
        switch self {
        case .system: .accentColor
        case .paper: Color(red: 0.18, green: 0.36, blue: 0.58)
        case .warm: Color(red: 0.48, green: 0.29, blue: 0.14)
        case .midnight: Color(red: 0.47, green: 0.73, blue: 0.82)
        }
    }
}
