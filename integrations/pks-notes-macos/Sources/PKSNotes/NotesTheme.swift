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
