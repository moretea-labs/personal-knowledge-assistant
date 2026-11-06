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
        case .bold: return wrap(text, range: range, prefix: "**", suffix: "**")
        case .italic: return wrap(text, range: range, prefix: "*", suffix: "*")
        case .inlineCode:
            let marker = String(Character(UnicodeScalar(96)!))
            return wrap(text, range: range, prefix: marker, suffix: marker)
        case .link:
            let selected = ns.substring(with: range)
            let replacement = selected.isEmpty ? "[title](url)" : "[\(selected)](url)"
            let updated = ns.replacingCharacters(in: range, with: replacement)
            let urlLocation = range.location + (selected.isEmpty ? 8 : selected.utf16.count + 3)
            return .init(text: updated, selection: NSRange(location: urlLocation, length: 3))
        case .heading(let level):
            return prefixLines(text, range: range, prefix: String(repeating: "#", count: min(6, max(1, level))) + " ")
        case .bullet:
            return prefixLines(text, range: range, prefix: "- ")
        case .task:
            return prefixLines(text, range: range, prefix: "- [ ] ")
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

    private static func prefixLines(_ text: String, range: NSRange, prefix: String) -> MarkdownEditResult {
        let ns = text as NSString
        let lineRange = ns.lineRange(for: range)
        let original = ns.substring(with: lineRange)
        let hasTrailingNewline = original.hasSuffix("\n")
        var lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hasTrailingNewline && lines.last == "" { lines.removeLast() }
        let replacement = lines.map { prefix + $0 }.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        let updated = ns.replacingCharacters(in: lineRange, with: replacement)
        return .init(text: updated, selection: NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }
}
