import Foundation

/// Read-only outline projection; the Markdown file remains the source of truth.
struct MindMapNode: Equatable, Identifiable, Sendable {
    let id: Int
    let depth: Int
    let title: String
}

enum MindMapDropPlacement: Equatable {
    case before
    case child
    case after
}

struct MindMapActionAvailability: Equatable {
    let canPromote: Bool
    let canDemote: Bool
    let canDeleteLeaf: Bool
}

enum MindMapOutline {
    private static let wikiLinkRegex = try! NSRegularExpression(pattern: #"\[\[([^\]\n]+)\]\]"#)
    private static let markdownLinkRegex = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\(([^)\n]+)\)"#)

    private struct EditContext {
        let parsed: [MindMapNode]
        let position: Int
        let node: MindMapNode
        let lines: [String]
    }

    private static func editContext(in source: String, nodeID: Int) -> EditContext? {
        let parsed = nodes(in: source)
        guard let position = parsed.firstIndex(where: { $0.id == nodeID }) else { return nil }
        let lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID) else { return nil }
        return EditContext(parsed: parsed, position: position, node: parsed[position], lines: lines)
    }

    private static func isListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) })
    }

    /// List bodies move with their node only when every nonempty line is
    /// indented inside that item. This preserves citations, quotes and code.
    private static func hasSafelyIndentedListContent(
        _ lines: [String], from start: Int, to end: Int, baseIndent: Int
    ) -> Bool {
        guard start >= 0, start <= end, end <= lines.count else { return false }
        for line in lines[start..<end] {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            guard indent >= baseIndent + 2 else { return false }
        }
        return true
    }

    private static func shiftSubtreeEndLine(_ context: EditContext) -> Int {
        guard context.position + 1 < context.parsed.count else { return context.lines.count }
        for candidate in context.parsed[(context.position + 1)...] where candidate.depth <= context.node.depth {
            return candidate.id
        }
        return context.lines.count
    }

    private static func canShiftListSubtree(_ context: EditContext, deeper: Bool) -> Bool {
        let nodeID = context.node.id
        guard isListLine(context.lines[nodeID]) else { return false }
        let endLine = shiftSubtreeEndLine(context)
        let indent = context.lines[nodeID].prefix(while: { $0 == " " }).count
        guard hasSafelyIndentedListContent(
            context.lines, from: nodeID + 1, to: endLine, baseIndent: indent
        ) else { return false }

        if deeper {
            guard context.position > 0 else { return false }
            var previousStructural: MindMapNode?
            for candidate in context.parsed[..<context.position].reversed() where candidate.depth <= context.node.depth {
                previousStructural = candidate
                break
            }
            return previousStructural?.depth == context.node.depth
        }

        return context.lines[nodeID].prefix(while: { $0 == " " }).count >= 2
    }

    private static func canDeleteLeaf(_ context: EditContext) -> Bool {
        if context.position + 1 < context.parsed.count,
           context.parsed[context.position + 1].depth > context.node.depth {
            return false
        }
        let nodeID = context.node.id
        guard isListLine(context.lines[nodeID]) else { return false }
        let nextNode = context.position + 1 < context.parsed.count
            ? context.parsed[context.position + 1].id
            : context.lines.count
        return !context.lines[(nodeID + 1)..<nextNode]
            .contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    static func actionAvailability(in source: String, nodeID: Int) -> MindMapActionAvailability {
        guard let context = editContext(in: source, nodeID: nodeID) else {
            return .init(canPromote: false, canDemote: false, canDeleteLeaf: false)
        }
        return .init(
            canPromote: canShiftListSubtree(context, deeper: false),
            canDemote: canShiftListSubtree(context, deeper: true),
            canDeleteLeaf: canDeleteLeaf(context)
        )
    }
    static func nodes(in markdown: String) -> [MindMapNode] {
        var result: [MindMapNode] = []
        var headingDepth = 0
        var fenceMarker: Character?
        for (index, line) in markdown.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "`" || marker == "~",
               trimmed.prefix(while: { $0 == marker }).count >= 3 {
                if fenceMarker == nil { fenceMarker = marker }
                else if fenceMarker == marker { fenceMarker = nil }
                continue
            }
            if fenceMarker != nil || trimmed.isEmpty { continue }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                headingDepth = hashes
                let title = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { result.append(.init(id: index, depth: hashes - 1, title: title)) }
                continue
            }
            let indent = line.prefix(while: { $0 == " " }).count
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { result.append(.init(id: index, depth: headingDepth + indent / 2, title: title)) }
            }
        }
        return result
    }

    /// Node IDs are canonical Markdown line indexes. Convert them to native UTF-16
    /// ranges only at the editor boundary so Mind Map never owns a second position model.
    static func sourceLineRange(in markdown: String, nodeID: Int) -> NSRange? {
        guard nodes(in: markdown).contains(where: { $0.id == nodeID }) else { return nil }
        return MarkdownOutline.lineRange(in: markdown, lineIndex: nodeID)
    }

    /// Resolve an editor caret/selection position to the nearest preceding outline node.
    /// Prose below a heading/list item therefore stays associated with its structural parent.
    static func nodeID(atUTF16Offset offset: Int, in markdown: String) -> Int? {
        let length = (markdown as NSString).length
        let clamped = min(max(0, offset), length)
        let prefix = (markdown as NSString).substring(to: clamped)
        let lineIndex = prefix.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        return nodes(in: markdown).last(where: { $0.id <= lineIndex })?.id
    }
}

extension MindMapOutline {
    /// Create a usable map from an empty Markdown file without a secondary map store.
    static func createMap(title: String = "New Mind Map") -> String {
        "# \(title)\n"
    }

    private static func subtreeEndLine(
        at position: Int, nodes parsed: [MindMapNode], lineCount: Int
    ) -> Int {
        let node = parsed[position]
        return parsed.dropFirst(position + 1)
            .first(where: { $0.depth <= node.depth })?.id ?? lineCount
    }

    private static func firstDescendantLine(
        at position: Int, nodes parsed: [MindMapNode], fallback: Int
    ) -> Int {
        let node = parsed[position]
        return parsed.dropFirst(position + 1)
            .first(where: { $0.depth > node.depth })?.id ?? fallback
    }

    static func isListNode(in source: String, nodeID: Int) -> Bool {
        let lines = source.components(separatedBy: "\n")
        return lines.indices.contains(nodeID) && isListLine(lines[nodeID])
    }

    /// Return/Enter creates a list sibling after the whole selected subtree.
    /// On a heading it creates a child after section text and before descendants.
    static func addSibling(in source: String, nodeID: Int, title: String = "New idea") -> String? {
        addSiblingWithOutcome(in: source, nodeID: nodeID, title: title)?.source
    }

    static func addSiblingWithOutcome(
        in source: String, nodeID: Int, title: String = "New idea"
    ) -> (source: String, nodeID: Int)? {
        let parsed = nodes(in: source)
        guard let position = parsed.firstIndex(where: { $0.id == nodeID }) else { return nil }
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID) else { return nil }
        let line = lines[nodeID]
        guard isListLine(line) else {
            return addChildWithOutcome(in: source, parentID: nodeID, title: title)
        }

        let contentLineCount = lines.count - (source.hasSuffix("\n") ? 1 : 0)
        let insertion = subtreeEndLine(at: position, nodes: parsed, lineCount: contentLineCount)
        let indent = line.prefix(while: { $0 == " " }).count
        lines.insert(String(repeating: " ", count: indent) + "- " + title, at: insertion)
        return (lines.joined(separator: "\n"), insertion)
    }

    static func rename(in source: String, nodeID: Int, to name: String) -> String? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.contains("\n"), !title.contains("\r") else { return nil }
        var lines = source.components(separatedBy: "\n")
        guard nodes(in: source).contains(where: { $0.id == nodeID }), lines.indices.contains(nodeID) else { return nil }
        let line = lines[nodeID]
        let leading = line.prefix(while: { $0 == " " }).count
        let trimmed = String(line.dropFirst(leading))
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        let prefix = hashes > 0 ? String(repeating: "#", count: hashes) + " " : String(trimmed.prefix(2))
        lines[nodeID] = String(repeating: " ", count: leading) + prefix + title
        return lines.joined(separator: "\n")
    }

    /// Delete a leaf only: never silently discard child nodes or prose attached to a heading.
    static func deleteLeaf(in source: String, nodeID: Int) -> String? {
        guard let context = editContext(in: source, nodeID: nodeID),
              canDeleteLeaf(context) else { return nil }
        var lines = context.lines
        lines.remove(at: nodeID)
        return lines.joined(separator: "\n")
    }

    /// Node IDs are Markdown line indexes. Rebase transient view state after a
    /// single-line leaf deletion so collapsed branches remain attached to their nodes.
    static func rebasedLineIndexes(_ indexes: Set<Int>, afterDeletingLine lineIndex: Int) -> Set<Int> {
        Set(indexes.compactMap { index in
            guard index != lineIndex else { return nil }
            return index > lineIndex ? index - 1 : index
        })
    }

    /// Explicit branch deletion: only a complete, list-only subtree may be
    /// deleted. Never remove Markdown paragraphs, headings, code or attachments
    /// as a side effect of a graph edit.
    static func deleteListSubtree(in source: String, nodeID: Int) -> String? {
        let parsed = nodes(in: source)
        guard let position = parsed.firstIndex(where: { $0.id == nodeID }) else { return nil }
        let selected = parsed[position]
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID),
              ["- ", "* ", "+ "].contains(where: {
                  lines[nodeID].trimmingCharacters(in: .whitespaces).hasPrefix($0)
              }) else { return nil }

        let endID = parsed.dropFirst(position + 1)
            .first(where: { $0.depth <= selected.depth })?.id ?? lines.count
        let knownNodeIDs = Set(parsed.map(\.id))
        for index in nodeID..<endID {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard knownNodeIDs.contains(index),
                  ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) else {
                return nil
            }
        }
        lines.removeSubrange(nodeID..<endID)
        var result = lines.joined(separator: "\n")
        if source.hasSuffix("\n") && !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    static func addChild(in source: String, parentID: Int, title: String = "New idea") -> String? {
        addChildWithOutcome(in: source, parentID: parentID, title: title)?.source
    }

    static func addChildWithOutcome(
        in source: String, parentID: Int, title: String = "New idea"
    ) -> (source: String, nodeID: Int)? {
        let parsed = nodes(in: source)
        guard let position = parsed.firstIndex(where: { $0.id == parentID }) else { return nil }
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(parentID) else { return nil }

        let parentLine = lines[parentID]
        let isList = isListLine(parentLine)
        let indent = parentLine.prefix(while: { $0 == " " }).count
        let contentLineCount = lines.count - (source.hasSuffix("\n") ? 1 : 0)
        let endLine = subtreeEndLine(at: position, nodes: parsed, lineCount: contentLineCount)
        let insertion = firstDescendantLine(at: position, nodes: parsed, fallback: endLine)

        if isList && !hasSafelyIndentedListContent(
            lines, from: parentID + 1, to: insertion, baseIndent: indent
        ) {
            return nil
        }

        let childIndent = isList ? indent + 2 : 0
        lines.insert(String(repeating: " ", count: childIndent) + "- " + title, at: insertion)
        return (lines.joined(separator: "\n"), insertion)
    }
}


/// A note relationship extracted from existing Markdown syntax; no second graph database.
struct MindMapLink: Equatable, Sendable {
    let label: String
    let target: String
}

struct MarkdownLinkOccurrence: Equatable {
    let link: MindMapLink
    let lineIndex: Int
}

struct MindMapNodePresentation: Equatable, Sendable {
    let title: String
    let links: [MindMapLink]
}

extension MindMapOutline {
    private struct ParsedLink {
        let range: NSRange
        let targetRange: NSRange
        let link: MindMapLink
    }

    private static func inlineCodeRanges(in text: String) -> [NSRange] {
        let units = Array(text.utf16)
        var ranges: [NSRange] = []
        var opening: (start: Int, width: Int)?
        var i = 0
        while i < units.count {
            guard units[i] == 96, i == 0 || units[i - 1] != 92 else { i += 1; continue }
            let start = i
            while i < units.count && units[i] == 96 { i += 1 }
            let width = i - start
            if let prior = opening {
                if prior.width == width {
                    ranges.append(NSRange(location: prior.start, length: i - prior.start))
                    opening = nil
                }
            } else { opening = (start, width) }
        }
        return ranges
    }

    private static func parsedLinks(
        in title: String,
        includeImages: Bool = false
    ) -> [ParsedLink] {
        var parsed: [ParsedLink] = []
        let fullRange = NSRange(title.startIndex..<title.endIndex, in: title)
        let nsTitle = title as NSString
        let codeRanges = inlineCodeRanges(in: title)

        for match in wikiLinkRegex.matches(in: title, range: fullRange) {
            let start = match.range.location
            guard (start == 0 || (nsTitle.character(at: start - 1) != 92
                                   && (includeImages || nsTitle.character(at: start - 1) != 33))),
                  !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let labelRange = Range(match.range(at: 1), in: title) else { continue }
            let raw = String(title[labelRange])
            let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            let target = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let label = parts.count == 2 ? String(parts[1]) : target
            guard !target.isEmpty else { continue }
            let leading = String(parts[0]).prefix(while: { $0.isWhitespace }).utf16.count
            let targetRange = NSRange(
                location: match.range(at: 1).location + leading,
                length: target.utf16.count
            )
            parsed.append(.init(
                range: match.range(at: 0),
                targetRange: targetRange,
                link: .init(label: label, target: target)
            ))
        }

        for match in markdownLinkRegex.matches(in: title, range: fullRange) {
            let start = match.range.location
            guard (start == 0 || (nsTitle.character(at: start - 1) != 92
                                   && (includeImages || nsTitle.character(at: start - 1) != 33))),
                  !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
            else { continue }
            guard let labelRange = Range(match.range(at: 1), in: title),
                  let targetRange = Range(match.range(at: 2), in: title) else { continue }
            parsed.append(.init(
                range: match.range(at: 0),
                targetRange: match.range(at: 2),
                link: .init(
                    label: String(title[labelRange]),
                    target: String(title[targetRange])
                )
            ))
        }

        return parsed
    }

    static func links(in title: String) -> [MindMapLink] {
        parsedLinks(in: title).map(\.link)
    }

    /// Display-only WikiLink conversion; Markdown source is never changed.
    static func previewMarkdown(in source: String) -> String {
        let linkedLines = Set(linkOccurrences(in: source).map(\.lineIndex))
        guard !linkedLines.isEmpty else { return source }
        var lines = source.components(separatedBy: "\n")
        for index in linkedLines {
            let original = lines[index] as NSString
            let converted = NSMutableString(string: lines[index])
            let links = parsedLinks(in: lines[index])
                .filter { $0.range.length >= 4
                    && original.substring(with: NSRange(location: $0.range.location, length: 2)) == "[[" }
                .sorted { $0.range.location > $1.range.location }
            for item in links {
                let label = item.link.label
                    .replacingOccurrences(of: "[", with: "\\[")
                    .replacingOccurrences(of: "]", with: "\\]")
                let target = item.link.target
                    .replacingOccurrences(of: " ", with: "%20")
                    .replacingOccurrences(of: "(", with: "%28")
                    .replacingOccurrences(of: ")", with: "%29")
                converted.replaceCharacters(in: item.range, with: "[\(label)](\(target))")
            }
            lines[index] = converted as String
        }
        return lines.joined(separator: "\n")
    }

    /// Explicit repair using the existing canonical link parser and Markdown writer.
    /// Images stay outside knowledge-link semantics by default; path relocation
    /// explicitly opts them in so attachment references survive file moves.
    static func retargetLinks(
        in source: String,
        from oldTarget: String,
        to newTarget: String,
        includeImages: Bool = false
    ) -> String? {
        guard !oldTarget.isEmpty, !newTarget.isEmpty,
              !newTarget.contains("]"), !newTarget.contains(")"),
              !newTarget.contains("|"), !newTarget.contains("\n"),
              !newTarget.contains("\r") else { return nil }
        let touched = Set(linkOccurrences(in: source, includeImages: includeImages)
            .filter { $0.link.target == oldTarget }
            .map(\.lineIndex))
        guard !touched.isEmpty else { return nil }
        var lines = source.components(separatedBy: "\n")
        for lineIndex in touched {
            let changed = NSMutableString(string: lines[lineIndex])
            let matches = parsedLinks(in: lines[lineIndex], includeImages: includeImages)
                .filter { $0.link.target == oldTarget }
                .sorted { $0.targetRange.location > $1.targetRange.location }
            for match in matches {
                let full = changed.substring(with: match.range)
                let isWiki = full.hasPrefix("[[") && full.hasSuffix("]]")
                let hasAlias = isWiki && full.dropFirst(2).dropLast(2).contains("|")
                let isImage = match.range.location > 0
                    && changed.character(at: match.range.location - 1) == 33
                if isWiki && !hasAlias && !isImage {
                    changed.replaceCharacters(
                        in: match.range,
                        with: "[[\(newTarget)|\(match.link.label)]]"
                    )
                } else {
                    changed.replaceCharacters(in: match.targetRange, with: newTarget)
                }
            }
            lines[lineIndex] = changed as String
        }
        return lines.joined(separator: "\n")
    }

    /// Preserve every Markdown link occurrence and its canonical source line.
    /// Backlinks reuse this parse result; there is no second occurrence index.
    /// Fenced code blocks are skipped so example markup never reports as a
    /// real backlink — matching the outgoing-link parser's fence handling.
    static func linkOccurrences(
        in markdown: String,
        includeImages: Bool = false
    ) -> [MarkdownLinkOccurrence] {
        var result: [MarkdownLinkOccurrence] = []
        var fenceMarker: Character?
        for (lineIndex, line) in markdown.components(separatedBy: "\n").enumerated() {
            let trimmed = line.drop(while: { $0.isWhitespace })
            if let marker = trimmed.first, marker == "\u{60}" || marker == "~",
               trimmed.prefix(while: { $0 == marker }).count >= 3 {
                if fenceMarker == nil { fenceMarker = marker }
                else if fenceMarker == marker { fenceMarker = nil }
                continue
            }
            guard fenceMarker == nil,
                  line.contains("["), line.contains("]") else { continue }
            for item in parsedLinks(in: line, includeImages: includeImages) {
                result.append(.init(link: item.link, lineIndex: lineIndex))
            }
        }
        return result
    }

    /// Derive display-only node text from canonical Markdown. Links remain stored
    /// only in the source line; the Mind Map replaces markup with human labels.
    static func presentation(for title: String) -> MindMapNodePresentation {
        let parsed = parsedLinks(in: title).sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.range.length > rhs.range.length
        }
        guard !parsed.isEmpty else {
            return .init(title: title, links: [])
        }

        let nsTitle = title as NSString
        var rendered = ""
        var cursor = 0
        for item in parsed where item.range.location >= cursor {
            if item.range.location > cursor {
                rendered += nsTitle.substring(
                    with: NSRange(location: cursor, length: item.range.location - cursor)
                )
            }
            rendered += item.link.label
            cursor = NSMaxRange(item.range)
        }
        if cursor < nsTitle.length {
            rendered += nsTitle.substring(from: cursor)
        }

        let clean = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(title: clean.isEmpty ? title : clean, links: parsed.map(\.link))
    }

    /// Derive each node's links from its title plus the Markdown body attached
    /// to that structural line. Body ownership ends at the next heading/list node,
    /// matching nodeID(atUTF16Offset); descendants never leak citations upward.
    /// Markdown remains the only source of truth and each body line is scanned once.
    static func presentations(
        in markdown: String,
        nodes: [MindMapNode]
    ) -> [Int: MindMapNodePresentation] {
        let lines = markdown.components(separatedBy: "\n")
        var result: [Int: MindMapNodePresentation] = [:]
        result.reserveCapacity(nodes.count)

        for (position, node) in nodes.enumerated() {
            let title = presentation(for: node.title)
            guard lines.indices.contains(node.id) else {
                result[node.id] = title
                continue
            }

            let bodyStart = node.id + 1
            let nextNodeLine = position + 1 < nodes.count
                ? nodes[position + 1].id
                : lines.count
            let bodyEnd = min(lines.count, max(bodyStart, nextNodeLine))
            let body = bodyStart < bodyEnd
                ? lines[bodyStart..<bodyEnd].joined(separator: "\n")
                : ""

            var links = title.links
            var seen = Set(links.map { $0.target + "\u{0}" + $0.label })
            for link in linkOccurrences(in: body).map(\.link) {
                let key = link.target + "\u{0}" + link.label
                if seen.insert(key).inserted {
                    links.append(link)
                }
            }
            result[node.id] = .init(title: title.title, links: links)
        }
        return result
    }

    /// Add one canonical WikiLink to an existing structural node. The source
    /// Markdown line remains the only persistence authority.
    static func appendWikiLink(
        in source: String,
        nodeID: Int,
        target: String,
        label: String
    ) -> String? {
        let cleanTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTarget.isEmpty,
              !cleanTarget.contains("|"),
              !cleanTarget.contains("]"),
              !cleanTarget.contains("\n"),
              !cleanTarget.contains("\r"),
              let context = editContext(in: source, nodeID: nodeID)
        else { return nil }

        if links(in: context.node.title).contains(where: { $0.target == cleanTarget }) {
            return source
        }

        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelIsSafe = !cleanLabel.isEmpty
            && !cleanLabel.contains("|")
            && !cleanLabel.contains("]")
            && !cleanLabel.contains("\n")
            && !cleanLabel.contains("\r")
        let markup = labelIsSafe
            ? "[[\(cleanTarget)|\(cleanLabel)]]"
            : "[[\(cleanTarget)]]"

        var lines = context.lines
        let separator = lines[nodeID].hasSuffix(" ") ? "" : " "
        lines[nodeID] += separator + markup
        return lines.joined(separator: "\n")
    }
}


extension MindMapOutline {
    /// Reparent a pure Markdown list subtree by one indentation level.
    /// Conservatively rejects prose/code inside the subtree to avoid corrupting Markdown.
    static func shiftListSubtree(in source: String, nodeID: Int, deeper: Bool) -> String? {
        guard let context = editContext(in: source, nodeID: nodeID),
              canShiftListSubtree(context, deeper: deeper) else { return nil }
        var lines = context.lines
        let endLine = shiftSubtreeEndLine(context)
        let delta = deeper ? 2 : -2
        for index in nodeID..<endLine where !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            let currentIndent = lines[index].prefix(while: { $0 == " " }).count
            let nextIndent = currentIndent + delta
            guard nextIndent >= 0 else { return nil }
            lines[index] = String(repeating: " ", count: nextIndent) + lines[index].dropFirst(currentIndent)
        }
        return lines.joined(separator: "\n")
    }
}

extension MindMapOutline {
    /// Move a list subtree under another structural node or reorder it beside a sibling.
    static func moveListSubtree(in source: String, nodeID: Int, asChildOf targetID: Int) -> String? {
        moveListSubtreeWithOutcome(in: source, nodeID: nodeID, asChildOf: targetID)?.source
    }

    /// Backwards-compatible child placement for existing callers.
    static func moveListSubtreeWithOutcome(
        in source: String, nodeID: Int, asChildOf targetID: Int
    ) -> (source: String, movedNodeID: Int)? {
        moveListSubtreeWithOutcome(
            in: source, nodeID: nodeID, relativeTo: targetID, placement: .child
        )
    }

    /// Move before/after a sibling or make the dragged node a child of its target.
    /// The whole source body moves with it; Markdown remains the sole authority.
    static func moveListSubtreeWithOutcome(
        in source: String,
        nodeID: Int,
        relativeTo targetID: Int,
        placement: MindMapDropPlacement
    ) -> (source: String, movedNodeID: Int)? {
        guard nodeID != targetID else { return nil }
        let parsed = nodes(in: source)
        guard let sourcePosition = parsed.firstIndex(where: { $0.id == nodeID }),
              let targetPosition = parsed.firstIndex(where: { $0.id == targetID }) else { return nil }

        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID), lines.indices.contains(targetID),
              isListLine(lines[nodeID]) else { return nil }

        let contentLineCount = lines.count - (source.hasSuffix("\n") ? 1 : 0)
        let sourceEnd = subtreeEndLine(at: sourcePosition, nodes: parsed, lineCount: contentLineCount)
        guard !(nodeID..<sourceEnd).contains(targetID) else { return nil }

        let sourceIndent = lines[nodeID].prefix(while: { $0 == " " }).count
        guard hasSafelyIndentedListContent(
            lines, from: nodeID + 1, to: sourceEnd, baseIndent: sourceIndent
        ) else { return nil }

        let targetLine = lines[targetID]
        let targetIsList = isListLine(targetLine)
        let targetIndent = targetLine.prefix(while: { $0 == " " }).count
        let targetEnd = subtreeEndLine(at: targetPosition, nodes: parsed, lineCount: contentLineCount)
        let targetFirstChild = firstDescendantLine(
            at: targetPosition, nodes: parsed, fallback: targetEnd
        )

        let insertionLine: Int
        let desiredIndent: Int
        switch placement {
        case .child:
            if targetIsList {
                guard hasSafelyIndentedListContent(
                    lines, from: targetID + 1, to: targetFirstChild, baseIndent: targetIndent
                ) else { return nil }
                desiredIndent = targetIndent + 2
            } else {
                desiredIndent = 0
            }
            insertionLine = targetFirstChild

        case .before:
            guard targetIsList else { return nil }
            desiredIndent = targetIndent
            insertionLine = targetID

        case .after:
            guard targetIsList,
                  hasSafelyIndentedListContent(
                    lines, from: targetID + 1, to: targetEnd, baseIndent: targetIndent
                  ) else { return nil }
            desiredIndent = targetIndent
            insertionLine = targetEnd
        }

        let delta = desiredIndent - sourceIndent
        var moved = Array(lines[nodeID..<sourceEnd])
        for index in moved.indices where !moved[index].trimmingCharacters(in: .whitespaces).isEmpty {
            let currentIndent = moved[index].prefix(while: { $0 == " " }).count
            let nextIndent = currentIndent + delta
            guard nextIndent >= 0 else { return nil }
            moved[index] = String(repeating: " ", count: nextIndent) + moved[index].dropFirst(currentIndent)
        }

        let removedCount = sourceEnd - nodeID
        lines.removeSubrange(nodeID..<sourceEnd)
        let adjustedInsertion = insertionLine > nodeID ? insertionLine - removedCount : insertionLine
        guard adjustedInsertion >= 0, adjustedInsertion <= lines.count else { return nil }
        lines.insert(contentsOf: moved, at: adjustedInsertion)
        return (lines.joined(separator: "\n"), adjustedInsertion)
    }
}


extension MindMapOutline {
    /// Extract user-authored knowledge links from Markdown while ignoring fenced code.
    static func knowledgeLinks(in markdown: String) -> [MindMapLink] {
        var result: [MindMapLink] = []
        var seen: Set<String> = []
        var fenceMarker: Character?

        for line in markdown.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let trimmed = line.drop(while: { $0.isWhitespace })
            if let marker = trimmed.first, marker == "\u{60}" || marker == "~",
               trimmed.prefix(while: { $0 == marker }).count >= 3 {
                if fenceMarker == nil { fenceMarker = marker }
                else if fenceMarker == marker { fenceMarker = nil }
                continue
            }
            guard fenceMarker == nil,
                  line.contains("["), line.contains("]") else { continue }

            // Convert only candidate lines. Most prose lines never allocate a
            // standalone String and never enter either link regex.
            for link in links(in: String(line)) {
                let key = link.target + "\u{0}" + link.label
                if seen.insert(key).inserted { result.append(link) }
            }
        }
        return result
    }
}
