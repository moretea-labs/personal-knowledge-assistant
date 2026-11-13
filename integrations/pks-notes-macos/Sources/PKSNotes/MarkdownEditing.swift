import Foundation

struct MarkdownEditResult: Equatable {
    let text: String
    let selection: NSRange
}

enum MarkdownEditCommand {
    case bold
    case italic
    case inlineCode
    case link
    case heading(Int)
    case bullet
    case task
    case quote
    case table
}

struct MarkdownReplacement: Equatable {
    let range: NSRange
    let text: String
}

enum MarkdownEditing {
    /// Replace only the changed UTF-16 range in NSTextView so AppKit owns undo/redo.
    static func minimalChange(from original: String, to updated: String) -> MarkdownReplacement? {
        let before = original as NSString
        let after = updated as NSString
        var prefix = 0
        while prefix < min(before.length, after.length),
              before.character(at: prefix) == after.character(at: prefix) {
            prefix += 1
        }
        if prefix == before.length && prefix == after.length { return nil }

        var suffix = 0
        while suffix < before.length - prefix && suffix < after.length - prefix,
              before.character(at: before.length - suffix - 1)
                == after.character(at: after.length - suffix - 1) {
            suffix += 1
        }
        return MarkdownReplacement(
            range: NSRange(location: prefix, length: before.length - prefix - suffix),
            text: after.substring(
                with: NSRange(location: prefix, length: after.length - prefix - suffix)
            )
        )
    }

    static func apply(_ command: MarkdownEditCommand, to text: String, selection: NSRange) -> MarkdownEditResult {
        let ns = text as NSString
        let safeLocation = min(max(0, selection.location), ns.length)
        let safeLength = min(max(0, selection.length), ns.length - safeLocation)
        let range = NSRange(location: safeLocation, length: safeLength)

        switch command {
        case .bold: return toggleEmphasis(text, range: range, delimiterLength: 2)
        case .italic: return toggleEmphasis(text, range: range, delimiterLength: 1)
        case .inlineCode: return wrapInlineCode(text, range: range)
        case .link:
            let selected = ns.substring(with: range)
            let label = escapedLinkLabel(selected)
            let replacement = selected.isEmpty ? "[title](url)" : "[\(label)](url)"
            let updated = ns.replacingCharacters(in: range, with: replacement)
            let urlLocation = range.location + (selected.isEmpty ? 8 : label.utf16.count + 3)
            return .init(text: updated, selection: NSRange(location: urlLocation, length: 3))
        case .heading(let level):
            return setHeadingLevel(text, range: range, level: level)
        case .bullet:
            return toggleListLines(text, range: range, asTask: false)
        case .task:
            return toggleListLines(text, range: range, asTask: true)
        case .quote:
            return toggleQuoteLines(text, range: range)
        case .table:
            let table = "| Column 1 | Column 2 |\n| --- | --- |\n| Cell | Cell |"
            let before = ns.substring(to: range.location)
            let after = ns.substring(from: NSMaxRange(range))
            let leading = before.isEmpty || before.hasSuffix("\n\n")
                ? ""
                : (before.hasSuffix("\n") ? "\n" : "\n\n")
            let trailing = after.isEmpty || after.hasPrefix("\n\n")
                ? ""
                : (after.hasPrefix("\n") ? "\n" : "\n\n")
            let insertion = leading + table + trailing
            let updated = ns.replacingCharacters(in: range, with: insertion)
            let header = (table as NSString).range(of: "Column 1")
            return .init(
                text: updated,
                selection: NSRange(
                    location: range.location + (leading as NSString).length + header.location,
                    length: header.length
                )
            )
        }
    }

    static func insert(_ value: String, into text: String, selection: NSRange) -> MarkdownEditResult {
        let ns = text as NSString
        let location = min(max(0, selection.location), ns.length)
        let length = min(max(0, selection.length), ns.length - location)
        let range = NSRange(location: location, length: length)
        let updated = ns.replacingCharacters(in: range, with: value)
        let cursor = location + (value as NSString).length
        return .init(text: updated, selection: NSRange(location: cursor, length: 0))
    }

    private enum ListLineKind {
        case bullet
        case task(checked: String)
        case ordered
    }

    private struct ParsedListLine {
        let indentation: String
        let kind: ListLineKind
        let content: String
    }

    private static func toggleListLines(
        _ text: String,
        range: NSRange,
        asTask: Bool
    ) -> MarkdownEditResult {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: range)
        let original = ns.substring(with: lineRange)
        let hasTrailingNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }

        let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let removesExistingList = !contentLines.isEmpty && contentLines.allSatisfy { line in
            guard let parsed = parseListLine(line) else { return false }
            if asTask, case .task(_) = parsed.kind { return true }
            if !asTask, case .bullet = parsed.kind { return true }
            return false
        }

        let formattedLines = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty && lines.count > 1 { return line }

            let parsed = parseListLine(line)
            let indentation = parsed?.indentation ?? ""
            let content = parsed?.content ?? line
            if removesExistingList {
                return indentation + content
            }
            if asTask {
                if let parsed, case let .task(checked) = parsed.kind {
                    return indentation + "- [\(checked)] " + parsed.content
                }
                return indentation + "- [ ] " + content
            }
            return indentation + "- " + content
        }

        let replacement = formattedLines.joined(separator: "\n")
            + (hasTrailingNewline ? "\n" : "")
        let updated = ns.replacingCharacters(in: lineRange, with: replacement)
        return .init(
            text: updated,
            selection: NSRange(
                location: lineRange.location,
                length: (replacement as NSString).length
            )
        )
    }

    private static func parseListLine(_ line: String) -> ParsedListLine? {
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        let value = String(line.dropFirst(indentation.count))

        if let marker = value.first, "-*+".contains(marker), value.dropFirst().hasPrefix(" ") {
            let body = String(value.dropFirst(2))
            if body == "[ ]" || body.hasPrefix("[ ] ") {
                return ParsedListLine(
                    indentation: indentation,
                    kind: .task(checked: " "),
                    content: body == "[ ]" ? "" : String(body.dropFirst(4))
                )
            }
            if body == "[x]" || body.hasPrefix("[x] ") || body == "[X]" || body.hasPrefix("[X] ") {
                let checked = String(body.dropFirst(1).prefix(1))
                return ParsedListLine(
                    indentation: indentation,
                    kind: .task(checked: checked),
                    content: body.count == 3 ? "" : String(body.dropFirst(4))
                )
            }
            return ParsedListLine(indentation: indentation, kind: .bullet, content: body)
        }

        let digits = value.prefix { $0.isNumber }
        let suffix = value.dropFirst(digits.count)
        if !digits.isEmpty && (suffix.hasPrefix(". ") || suffix.hasPrefix(") ")) {
            return ParsedListLine(
                indentation: indentation,
                kind: .ordered,
                content: String(suffix.dropFirst(2))
            )
        }
        return nil
    }

    private static func toggleEmphasis(
        _ text: String,
        range: NSRange,
        delimiterLength: Int
    ) -> MarkdownEditResult {
        let ns = text as NSString
        let selected = ns.substring(with: range)
        let marker = String(repeating: "*", count: delimiterLength)
        guard !selected.isEmpty else {
            return wrap(text, range: range, prefix: marker, suffix: marker)
        }

        let insideLeading = selected.prefix { $0 == "*" }.count
        let insideTrailing = selected.reversed().prefix { $0 == "*" }.count
        var start = range.location
        var end = NSMaxRange(range)
        var leading = insideLeading
        var trailing = insideTrailing
        while start > 0 && ns.character(at: start - 1) == 42 {
            leading += 1
            start -= 1
        }
        while end < ns.length && ns.character(at: end) == 42 {
            trailing += 1
            end += 1
        }

        let content = String(selected.dropFirst(insideLeading).dropLast(insideTrailing))
        let removeCount: Int
        if !content.isEmpty && leading == trailing {
            removeCount = delimiterLength == 2
                ? (leading >= 2 ? 2 : 0)
                : (leading == 1 || leading >= 3 ? 1 : 0)
        } else {
            removeCount = 0
        }
        guard removeCount > 0 else {
            return wrap(text, range: range, prefix: marker, suffix: marker)
        }

        let remaining = leading - removeCount
        let replacement = String(repeating: "*", count: remaining)
            + content + String(repeating: "*", count: remaining)
        let target = NSRange(location: start, length: end - start)
        let updated = ns.replacingCharacters(in: target, with: replacement)
        return .init(
            text: updated,
            selection: NSRange(
                location: start + remaining,
                length: (content as NSString).length
            )
        )
    }

    private static func wrapInlineCode(_ text: String, range: NSRange) -> MarkdownEditResult {
        let ns = text as NSString
        let selected = ns.substring(with: range)
        let delimiter = inlineCodeDelimiter(for: selected)
        let normalized = selected
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let padding = normalized.hasPrefix(" ") && normalized.hasSuffix(" ")
            && normalized.contains(where: { $0 != " " }) ? " " : ""
        let replacement = delimiter + padding + selected + padding + delimiter
        let updated = ns.replacingCharacters(in: range, with: replacement)
        let selectionLocation = range.location + ((delimiter + padding) as NSString).length
        return .init(
            text: updated,
            selection: NSRange(location: selectionLocation, length: range.length)
        )
    }

    private static func inlineCodeDelimiter(for selected: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for byte in selected.utf8 {
            if byte == 0x60 {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: longestRun + 1)
    }

    private static func escapedLinkLabel(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\\", with: "&#92;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "[", with: "&#91;")
            .replacingOccurrences(of: "]", with: "&#93;")
    }

    private static func wrap(_ text: String, range: NSRange, prefix: String, suffix: String) -> MarkdownEditResult {
        let ns = text as NSString
        let selected = ns.substring(with: range)
        let replacement = prefix + selected + suffix
        let updated = ns.replacingCharacters(in: range, with: replacement)
        if selected.isEmpty {
            return .init(text: updated, selection: NSRange(location: range.location + (prefix as NSString).length, length: 0))
        }
        return .init(
            text: updated,
            selection: NSRange(location: range.location + (prefix as NSString).length, length: (selected as NSString).length)
        )
    }

    private static func setHeadingLevel(
        _ text: String,
        range: NSRange,
        level: Int
    ) -> MarkdownEditResult {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: range)
        let original = ns.substring(with: lineRange)
        let hasTrailingNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }
        let prefix = String(repeating: "#", count: min(6, max(1, level))) + " "

        let formatted = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lines.count > 1 {
                return line
            }
            let indentation = String(line.prefix { $0 == " " })
            guard indentation.count <= 3 else { return prefix + line }
            let content = String(line.dropFirst(indentation.count))
            let hashes = content.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes) else { return prefix + line }
            let remainder = content.dropFirst(hashes)
            if remainder.isEmpty {
                return indentation + prefix
            }
            guard remainder.first == " " || remainder.first == "\t" else {
                return prefix + line
            }
            let headingContent = remainder.drop(while: { $0 == " " || $0 == "\t" })
            return indentation + prefix + headingContent
        }

        let replacement = formatted.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        let updated = ns.replacingCharacters(in: lineRange, with: replacement)
        return .init(
            text: updated,
            selection: NSRange(location: lineRange.location, length: (replacement as NSString).length)
        )
    }

    private static func toggleQuoteLines(_ text: String, range: NSRange) -> MarkdownEditResult {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: range)
        let original = ns.substring(with: lineRange)
        let hasTrailingNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }

        let contentLines = lines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let removesQuote = !contentLines.isEmpty && contentLines.allSatisfy {
            quoteLineContent($0) != nil
        }

        let formatted = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lines.count > 1 {
                return line
            }
            if let content = quoteLineContent(line) {
                let indentation = String(line.prefix { $0 == " " })
                return removesQuote ? indentation + content : line
            }
            return "> " + line
        }

        let replacement = formatted.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        let updated = ns.replacingCharacters(in: lineRange, with: replacement)
        return .init(
            text: updated,
            selection: NSRange(location: lineRange.location, length: (replacement as NSString).length)
        )
    }

    private static func quoteLineContent(_ line: String) -> String? {
        let indentation = line.prefix { $0 == " " }.count
        guard indentation <= 3 else { return nil }
        let content = line.dropFirst(indentation)
        guard content.first == ">" else { return nil }
        let remainder = content.dropFirst()
        if remainder.first == " " || remainder.first == "\t" {
            return String(remainder.dropFirst())
        }
        return String(remainder)
    }
}
