import Foundation

struct MarkdownEditResult: Equatable {
    let text: String
    let selection: NSRange
}

enum MarkdownEditCommand {
    case bold
    case italic
    case inlineCode
    case codeBlock
    case link
    case heading(Int)
    case bullet
    case task
    case ordered
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
        // NSString offsets are UTF-16 code units. A common high surrogate
        // is not a safe replacement boundary when the following low surrogate differs.
        while prefix > 0 &&
                (splitsSurrogatePair(before, at: prefix) || splitsSurrogatePair(after, at: prefix)) {
            prefix -= 1
        }
        if prefix == before.length && prefix == after.length { return nil }

        var suffix = 0
        while suffix < before.length - prefix && suffix < after.length - prefix,
              before.character(at: before.length - suffix - 1)
                == after.character(at: after.length - suffix - 1) {
            suffix += 1
        }
        // The same applies when a shared low surrogate was counted as suffix.
        while suffix > 0 &&
                (splitsSurrogatePair(before, at: before.length - suffix)
                    || splitsSurrogatePair(after, at: after.length - suffix)) {
            suffix -= 1
        }
        return MarkdownReplacement(
            range: NSRange(location: prefix, length: before.length - prefix - suffix),
            text: after.substring(
                with: NSRange(location: prefix, length: after.length - prefix - suffix)
            )
        )
    }

    private static func splitsSurrogatePair(_ text: NSString, at offset: Int) -> Bool {
        guard offset > 0, offset < text.length else { return false }
        let previous = text.character(at: offset - 1)
        let current = text.character(at: offset)
        return previous >= 0xD800 && previous <= 0xDBFF
            && current >= 0xDC00 && current <= 0xDFFF
    }

    static func apply(_ command: MarkdownEditCommand, to text: String, selection: NSRange) -> MarkdownEditResult {
        let ns = text as NSString
        let safeLocation = min(max(0, selection.location), ns.length)
        let safeLength = min(max(0, selection.length), ns.length - safeLocation)
        let range = NSRange(location: safeLocation, length: safeLength)

        switch command {
        case .bold: return toggleEmphasis(text, range: range, delimiterLength: 2)
        case .italic: return toggleEmphasis(text, range: range, delimiterLength: 1)
        case .inlineCode: return toggleInlineCode(text, range: range)
        case .codeBlock: return insertCodeBlock(text, range: range)
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
            return toggleListLines(text, range: range, kind: .bullet)
        case .task:
            return toggleListLines(text, range: range, kind: .task)
        case .ordered:
            return toggleListLines(text, range: range, kind: .ordered)
        case .quote:
            return toggleQuoteLines(text, range: range)
        case .table:
            let selected = ns.substring(with: range)
            let before = ns.substring(to: range.location)
            let after = ns.substring(from: NSMaxRange(range))
            let (leading, trailing, lineEnding) = blockSeparators(
                before: before, selected: selected, after: after
            )
            let table = [
                "| Column 1 | Column 2 |",
                "| --- | --- |",
                "| Cell | Cell |"
            ].joined(separator: lineEnding)
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

    private static func insertCodeBlock(_ text: String, range: NSRange) -> MarkdownEditResult {
        let ns = text as NSString
        let selected = ns.substring(with: range)
        let before = ns.substring(to: range.location)
        let after = ns.substring(from: NSMaxRange(range))
        let (leading, trailing, lineEnding) = blockSeparators(
            before: before, selected: selected, after: after
        )
        // A fence longer than every backtick run in the selection cannot close
        // early, even when the selected code already contains fenced examples.
        let delimiter = String(
            repeating: "`",
            count: max(3, inlineCodeDelimiter(for: selected).count)
        )
        let closingLineBreak = selected.hasSuffix("\n") || selected.hasSuffix("\r")
            ? ""
            : lineEnding
        let block = delimiter + lineEnding + selected + closingLineBreak + delimiter
        let insertion = leading + block + trailing
        let updated = ns.replacingCharacters(in: range, with: insertion)
        let contentStart = range.location + (leading as NSString).length
            + (delimiter as NSString).length + 1
        return .init(
            text: updated,
            selection: NSRange(location: contentStart, length: (selected as NSString).length)
        )
    }

    private static func blockSeparators(
        before: String, selected: String, after: String
    ) -> (String, String, String) {
        let lineEnding: String
        if before.hasSuffix("\r\n") || after.hasPrefix("\r\n") {
            lineEnding = "\r\n"
        } else if before.hasSuffix("\n") || after.hasPrefix("\n") {
            lineEnding = "\n"
        } else if before.hasSuffix("\r") || after.hasPrefix("\r") {
            lineEnding = "\r"
        } else {
            let surrounding = before + selected + after
            if surrounding.contains("\r\n") {
                lineEnding = "\r\n"
            } else if surrounding.contains("\r") {
                lineEnding = "\r"
            } else {
                lineEnding = "\n"
            }
        }

        let doubleLineEnding = lineEnding + lineEnding
        let leading = before.isEmpty || before.hasSuffix(doubleLineEnding)
            ? ""
            : (before.hasSuffix(lineEnding) ? lineEnding : doubleLineEnding)
        let trailing = after.isEmpty || after.hasPrefix(doubleLineEnding)
            ? ""
            : (after.hasPrefix(lineEnding) ? lineEnding : doubleLineEnding)
        return (leading, trailing, lineEnding)
    }

    private enum ListLineKind {
        case bullet
        case task(checked: String)
        case ordered
    }

    private enum ListOutputKind {
        case bullet
        case task
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
        kind: ListOutputKind
    ) -> MarkdownEditResult {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: range)
        let original = ns.substring(with: lineRange)
        let hasTrailingNewline = original.hasSuffix("\n")
        var lines = original.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }

        let firstLine = ns.substring(to: lineRange.location).reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        let codeLines = MindMapOutline.blockCodeLineFlags(in: text)
        let contentLines = lines.enumerated().compactMap { offset, line -> String? in
            let absoluteLine = firstLine + offset
            guard !codeLines[absoluteLine],
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return line
        }
        let hasExistingList = contentLines.contains { parseListLine($0) != nil }
        let removesExistingList = !contentLines.isEmpty && contentLines.allSatisfy { line in
            guard let parsed = parseListLine(line) else { return false }
            switch kind {
            case .bullet:
                if case .bullet = parsed.kind { return true }
            case .task:
                if case .task = parsed.kind { return true }
            case .ordered:
                if case .ordered = parsed.kind { return true }
            }
            return false
        }

        var orderedIndexByIndentation: [String: Int] = [:]
        let formattedLines = lines.enumerated().map { offset, line -> String in
            let absoluteLine = firstLine + offset
            if codeLines[absoluteLine] {
                if removesExistingList {
                    return line.hasPrefix("  ") ? String(line.dropFirst(2)) : line
                }
                return hasExistingList ? line : "  " + line
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lines.count > 1 { return line }

            let parsed = parseListLine(line)
            let indentation = parsed?.indentation
                ?? String(line.prefix { $0 == " " || $0 == "\t" })
            let content = parsed?.content ?? String(line.dropFirst(indentation.count))
            if removesExistingList {
                return indentation + content
            }
            switch kind {
            case .bullet:
                return indentation + "- " + content
            case .task:
                if let parsed, case let .task(checked) = parsed.kind {
                    return indentation + "- [\(checked)] " + parsed.content
                }
                return indentation + "- [ ] " + content
            case .ordered:
                let number = orderedIndexByIndentation[indentation, default: 1]
                orderedIndexByIndentation[indentation] = number + 1
                return indentation + "\(number). " + content
            }
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
        if selected.isEmpty {
            var start = range.location
            var end = range.location
            while start > 0 && ns.character(at: start - 1) == 42 { start -= 1 }
            while end < ns.length && ns.character(at: end) == 42 { end += 1 }
            let leading = range.location - start
            let trailing = end - range.location
            let removeCount: Int
            if leading == trailing {
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
            let replacement = String(repeating: "*", count: remaining * 2)
            let target = NSRange(location: start, length: end - start)
            let updated = ns.replacingCharacters(in: target, with: replacement)
            return .init(text: updated, selection: NSRange(location: start + remaining, length: 0))
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

    private static func toggleInlineCode(_ text: String, range: NSRange) -> MarkdownEditResult {
        let ns = text as NSString
        let selected = ns.substring(with: range)
        if let unwrapped = unwrapInlineCode(ns, range: range, selected: selected) {
            return unwrapped
        }
        return wrapInlineCode(text, range: range)
    }

    private static func unwrapInlineCode(
        _ text: NSString,
        range: NSRange,
        selected: String
    ) -> MarkdownEditResult? {
        var openingBoundary = range.location
        var leftPadding = 0
        if openingBoundary > 0 && text.character(at: openingBoundary - 1) == 32 {
            leftPadding = 1
            openingBoundary -= 1
        }
        var openingStart = openingBoundary
        while openingStart > 0 && text.character(at: openingStart - 1) == 96 {
            openingStart -= 1
        }
        let openingLength = openingBoundary - openingStart
        guard openingLength > 0 else { return nil }

        var closingBoundary = NSMaxRange(range)
        var rightPadding = 0
        if closingBoundary < text.length && text.character(at: closingBoundary) == 32 {
            rightPadding = 1
            closingBoundary += 1
        }
        var closingEnd = closingBoundary
        while closingEnd < text.length && text.character(at: closingEnd) == 96 {
            closingEnd += 1
        }
        let closingLength = closingEnd - closingBoundary
        let longestContentRun = inlineCodeDelimiter(for: selected).count - 1
        guard openingLength == closingLength,
              leftPadding == rightPadding,
              openingLength > longestContentRun else {
            return nil
        }

        let target = NSRange(location: openingStart, length: closingEnd - openingStart)
        let updated = text.replacingCharacters(in: target, with: selected)
        return .init(
            text: updated,
            selection: NSRange(location: openingStart, length: (selected as NSString).length)
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
        let preservesBoundarySpaces = normalized.hasPrefix(" ") && normalized.hasSuffix(" ")
            && normalized.contains(where: { $0 != " " })
        let separatesBoundaryBackticks = selected.hasPrefix("`") || selected.hasSuffix("`")
        let padding = preservesBoundarySpaces || separatesBoundaryBackticks ? " " : ""
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
        let firstLine = ns.substring(to: lineRange.location).reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        let codeLines = MindMapOutline.blockCodeLineFlags(in: text)
        let prefix = String(repeating: "#", count: min(6, max(1, level))) + " "

        let formatted = lines.enumerated().map { offset, line -> String in
            if codeLines[firstLine + offset] { return line }
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
