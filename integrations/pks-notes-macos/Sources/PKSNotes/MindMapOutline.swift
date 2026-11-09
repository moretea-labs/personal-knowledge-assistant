import Foundation

/// Read-only outline projection; the Markdown file remains the source of truth.
struct MindMapNode: Equatable, Identifiable {
    let id: Int
    let depth: Int
    let title: String
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
        for index in nodeID..<endLine {
            let trimmed = context.lines[index].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !isListLine(context.lines[index]) { return false }
        }

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

    /// Both Add Child and drag-to-reparent insert immediately after the
    /// target node. Reject attached prose/code at that boundary, otherwise
    /// it silently becomes part of the newly inserted child.
    private static func canInsertChild(
        after parentID: Int, in lines: [String], nodes parsed: [MindMapNode]
    ) -> Bool {
        guard lines.indices.contains(parentID) else { return false }
        let nextNodeLine = parsed.first(where: { $0.id > parentID })?.id ?? lines.count
        return !lines[(parentID + 1)..<nextNodeLine].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Return/Enter creates a list sibling after the whole selected subtree.
    /// Headings are structural anchors, so Return on a heading creates its first child.
    static func addSibling(in source: String, nodeID: Int, title: String = "New idea") -> String? {
        let parsed = nodes(in: source)
        guard let position = parsed.firstIndex(where: { $0.id == nodeID }) else { return nil }
        let node = parsed[position]
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID) else { return nil }
        let line = lines[nodeID]
        let prefix = line.trimmingCharacters(in: .whitespaces)
        guard ["- ", "* ", "+ "].contains(where: { prefix.hasPrefix($0) }) else {
            return addChild(in: source, parentID: nodeID, title: title)
        }
        // The end of a list subtree is its next same-or-higher-depth node.
        let insertion = parsed.dropFirst(position + 1).first(where: { $0.depth <= node.depth })?.id ?? lines.count
        // Prose/code inside a subtree must not be moved or implicitly consumed.
        let indent = line.prefix(while: { $0 == " " }).count
        lines.insert(String(repeating: " ", count: indent) + "- " + title, at: insertion)
        return lines.joined(separator: "\n")
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
        var lines = source.components(separatedBy: "\n")
        guard nodes(in: source).contains(where: { $0.id == parentID }), lines.indices.contains(parentID) else { return nil }
        let line = lines[parentID]
        let indent = line.prefix(while: { $0 == " " }).count
        let isList = ["- ", "* ", "+ "].contains(where: { line.trimmingCharacters(in: .whitespaces).hasPrefix($0) })
        guard canInsertChild(after: parentID, in: lines, nodes: nodes(in: source))
        else { return nil }
        lines.insert(String(repeating: " ", count: indent + (isList ? 2 : 0)) + "- " + title, at: parentID + 1)
        return lines.joined(separator: "\n")
    }
}


/// A note relationship extracted from existing Markdown syntax; no second graph database.
struct MindMapLink: Equatable {
    let label: String
    let target: String
}

struct MarkdownLinkOccurrence: Equatable {
    let link: MindMapLink
    let lineIndex: Int
}

struct MindMapNodePresentation: Equatable {
    let title: String
    let links: [MindMapLink]
}

extension MindMapOutline {
    private struct ParsedLink {
        let range: NSRange
        let targetRange: NSRange
        let link: MindMapLink
    }

    private static func parsedLinks(in title: String) -> [ParsedLink] {
        var parsed: [ParsedLink] = []
        let fullRange = NSRange(title.startIndex..<title.endIndex, in: title)

        for match in wikiLinkRegex.matches(in: title, range: fullRange) {
            guard let labelRange = Range(match.range(at: 1), in: title) else { continue }
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

        let nsTitle = title as NSString
        for match in markdownLinkRegex.matches(in: title, range: fullRange) {
            // Markdown image embeds are content, not knowledge relationships.
            // Keep their syntax intact in node presentation and backlink scans.
            guard match.range.location == 0
                    || nsTitle.character(at: match.range.location - 1) != 33 else { continue }
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

    /// Explicit repair using the existing canonical link parser and Markdown writer.
    /// Link labels, images, fenced code and unrelated text remain unchanged.
    static func retargetLinks(in source: String, from oldTarget: String, to newTarget: String) -> String? {
        guard !oldTarget.isEmpty, !newTarget.isEmpty,
              !newTarget.contains("]"), !newTarget.contains(")"),
              !newTarget.contains("|"), !newTarget.contains("\n"),
              !newTarget.contains("\r") else { return nil }
        let touched = Set(linkOccurrences(in: source)
            .filter { $0.link.target == oldTarget }
            .map(\.lineIndex))
        guard !touched.isEmpty else { return nil }
        var lines = source.components(separatedBy: "\n")
        for lineIndex in touched {
            let changed = NSMutableString(string: lines[lineIndex])
            let matches = parsedLinks(in: lines[lineIndex])
                .filter { $0.link.target == oldTarget }
                .sorted { $0.targetRange.location > $1.targetRange.location }
            for match in matches {
                changed.replaceCharacters(in: match.targetRange, with: newTarget)
            }
            lines[lineIndex] = changed as String
        }
        return lines.joined(separator: "\n")
    }

    /// Preserve every Markdown link occurrence and its canonical source line.
    /// Backlinks reuse this parse result; there is no second occurrence index.
    /// Fenced code blocks are skipped so example markup never reports as a
    /// real backlink — matching the outgoing-link parser's fence handling.
    static func linkOccurrences(in markdown: String) -> [MarkdownLinkOccurrence] {
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
            for link in links(in: line) {
                result.append(.init(link: link, lineIndex: lineIndex))
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
    /// Move a pure Markdown list subtree under another structural node.
    /// The moved list remains canonical Markdown; headings are anchors, not movable nodes.
    static func moveListSubtree(in source: String, nodeID: Int, asChildOf targetID: Int) -> String? {
        moveListSubtreeWithOutcome(in: source, nodeID: nodeID, asChildOf: targetID)?.source
    }

    /// Same move, but also reports the moved root's new canonical line index so
    /// callers can keep the moved node selected instead of dropping selection.
    static func moveListSubtreeWithOutcome(
        in source: String, nodeID: Int, asChildOf targetID: Int
    ) -> (source: String, movedNodeID: Int)? {
        guard nodeID != targetID else { return nil }
        let parsed = nodes(in: source)
        guard let sourcePosition = parsed.firstIndex(where: { $0.id == nodeID }),
              parsed.contains(where: { $0.id == targetID }) else { return nil }

        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID), lines.indices.contains(targetID) else { return nil }

        func listPrefix(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) })
        }

        guard listPrefix(lines[nodeID]) else { return nil }

        let sourceNode = parsed[sourcePosition]
        let endLine: Int = {
            guard sourcePosition + 1 < parsed.count else { return lines.count }
            for candidate in parsed[(sourcePosition + 1)...] where candidate.depth <= sourceNode.depth {
                return candidate.id
            }
            return lines.count
        }()

        guard !(nodeID..<endLine).contains(targetID) else { return nil }
        for index in nodeID..<endLine {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !listPrefix(lines[index]) { return nil }
        }

        let targetLine = lines[targetID]
        let targetTrimmed = targetLine.trimmingCharacters(in: .whitespaces)
        let targetIsList = listPrefix(targetLine)
        let targetHashes = targetTrimmed.prefix(while: { $0 == "#" }).count
        guard targetIsList || ((1...6).contains(targetHashes) && targetTrimmed.dropFirst(targetHashes).first == " ") else {
            return nil
        }
        // Use the same target-side protection as Add Child. The dragged
        // subtree may be pure list markup even when its destination has prose
        // or code that would become attached to the newly inserted child.
        guard canInsertChild(after: targetID, in: lines, nodes: parsed) else { return nil }

        let sourceIndent = lines[nodeID].prefix(while: { $0 == " " }).count
        let targetIndent = targetLine.prefix(while: { $0 == " " }).count
        let desiredIndent = targetIsList ? targetIndent + 2 : 0
        let delta = desiredIndent - sourceIndent

        var moved = Array(lines[nodeID..<endLine])
        for index in moved.indices where !moved[index].trimmingCharacters(in: .whitespaces).isEmpty {
            let currentIndent = moved[index].prefix(while: { $0 == " " }).count
            let nextIndent = currentIndent + delta
            guard nextIndent >= 0 else { return nil }
            moved[index] = String(repeating: " ", count: nextIndent) + moved[index].dropFirst(currentIndent)
        }

        lines.removeSubrange(nodeID..<endLine)
        let removedCount = endLine - nodeID
        let adjustedTarget = targetID > nodeID ? targetID - removedCount : targetID
        guard lines.indices.contains(adjustedTarget) else { return nil }
        lines.insert(contentsOf: moved, at: adjustedTarget + 1)
        return (lines.joined(separator: "\n"), adjustedTarget + 1)
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
