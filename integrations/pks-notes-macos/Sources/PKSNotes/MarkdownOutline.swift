import Foundation

struct MarkdownOutlineHeading: Identifiable, Equatable {
    let id: Int
    let level: Int
    let title: String
    let utf16Offset: Int
    let sectionID: Int
}

enum MarkdownHeadingScanner {
    /// Shared ATX-heading scanner used by preview sectioning and the clickable outline.
    /// Fenced code is ignored so a single syntax rule owns heading recognition.
    static func heading<S: StringProtocol>(
        in line: S,
        fence: inout Character?
    ) -> (level: Int, title: String)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.starts(with: "~~~") {
            if fence == nil { fence = "~" }
            else if fence == "~" { fence = nil }
            return nil
        }

        let tick = Character(UnicodeScalar(96)!)
        if trimmed.first == tick,
           trimmed.prefix(3).count == 3,
           trimmed.prefix(3).allSatisfy({ $0 == tick }) {
            if fence == nil { fence = tick }
            else if fence == tick { fence = nil }
            return nil
        }
        guard fence == nil else { return nil }

        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        let title = String(line.dropFirst(level + 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return (level, title)
    }
}

enum MarkdownOutline {
    static func headings(in source: String) -> [MarkdownOutlineHeading] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var fence: Character?
        var headings: [MarkdownOutlineHeading] = []
        var utf16Offset = 0
        var sectionID = 0
        var currentSectionHasLines = false

        for (index, line) in lines.enumerated() {
            if let heading = MarkdownHeadingScanner.heading(in: line, fence: &fence) {
                if currentSectionHasLines { sectionID += 1 }
                headings.append(MarkdownOutlineHeading(
                    id: headings.count,
                    level: heading.level,
                    title: heading.title,
                    utf16Offset: utf16Offset,
                    sectionID: sectionID
                ))
            }
            currentSectionHasLines = true
            utf16Offset += line.utf16.count
            if index < lines.count - 1 { utf16Offset += 1 }
        }
        return headings
    }
}
