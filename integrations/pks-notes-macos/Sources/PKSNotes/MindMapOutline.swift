import Foundation

/// Read-only outline projection; the Markdown file remains the source of truth.
struct MindMapNode: Equatable, Identifiable, Sendable {
    let id: Int
    let depth: Int
    let title: String
    let attachedBodyFingerprint: Int

    init(id: Int, depth: Int, title: String, attachedBodyFingerprint: Int = 0) {
        self.id = id
        self.depth = depth
        self.title = title
        self.attachedBodyFingerprint = attachedBodyFingerprint
    }
}

enum MindMapDropPlacement: Equatable {
    case before
    case child
    case after
}

struct MindMapMoveOutcome: Equatable {
    let source: String
    let movedNodeID: Int
}

struct MindMapActionAvailability: Equatable {
    let canPromote: Bool
    let canDemote: Bool
    let canDeleteLeaf: Bool
}

enum MindMapOutline {
    /// Escape plain text before embedding it in Markdown structure.
    static func escapeInlineText(_ text: String) -> String {
        let flattened = text.components(separatedBy: .newlines)
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let entitySafe = flattened.replacingOccurrences(
            of: #"&(?=[A-Za-z#][A-Za-z0-9#xX]*;)"#,
            with: "&amp;", options: .regularExpression
        )
        let startsOrderedList = flattened.range(
            of: #"^\d{1,9}[.)]\s"#,
            options: .regularExpression
        ) != nil
        let markdownPunctuation: Set<Character> = [
            "\\", "`", "*", "_", "{", "}", "[", "]",
            "#", "+", "-", "!", "|", "~"
        ]
        var escaped = ""
        for character in entitySafe {
            switch character {
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            default:
                let orderedListMarker = startsOrderedList && (character == "." || character == ")")
                if markdownPunctuation.contains(character) || orderedListMarker {
                    escaped.append("\\")
                }
                escaped.append(character)
            }
        }
        return escaped
    }


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

    private struct MarkdownFence {
        let marker: Character
        let length: Int
    }

    private static func openingFence(in line: String) -> MarkdownFence? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        if marker == "`", trimmed.dropFirst(length).contains(marker) { return nil }
        return MarkdownFence(marker: marker, length: length)
    }

    private static func closesFence(_ line: String, matching fence: MarkdownFence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == fence.marker else { return false }
        let length = trimmed.prefix(while: { $0 == fence.marker }).count
        guard length >= fence.length else { return false }
        return trimmed.dropFirst(length).allSatisfy(\.isWhitespace)
    }

    private static func isListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) })
    }

    private static func indentedCodeThreshold(
        after previousNode: MindMapNode?,
        in lines: [String],
        baseIndent: Int
    ) -> Int {
        guard let previousNode, lines.indices.contains(previousNode.id),
              isListLine(lines[previousNode.id]) else { return baseIndent + 4 }
        let parentIndent = lines[previousNode.id].prefix(while: { $0 == " " }).count
        return parentIndent + 6
    }

    private static func isIndentedCodeLine(
        _ line: String,
        after previousNode: MindMapNode?,
        in lines: [String],
        baseIndent: Int = 0
    ) -> Bool {
        let indent = line.prefix(while: { $0 == " " }).count
        return indent >= indentedCodeThreshold(
            after: previousNode, in: lines, baseIndent: baseIndent
        )
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

    private static func canShiftNodeSubtree(_ context: EditContext, deeper: Bool) -> Bool {
        let nodeID = context.node.id
        let endLine = shiftSubtreeEndLine(context)

        if isListLine(context.lines[nodeID]) {
            let indent = context.lines[nodeID].prefix(while: { $0 == " " }).count
            guard hasSafelyIndentedListContent(
                context.lines, from: nodeID + 1, to: endLine, baseIndent: indent
            ) else { return false }

            if deeper {
                guard context.position > 0 else { return false }
                let previousStructural = context.parsed[..<context.position].reversed()
                    .first(where: { $0.depth <= context.node.depth })
                return previousStructural?.depth == context.node.depth
            }
            return indent >= 2
        }

        guard let level = headingLevel(in: context.lines[nodeID]) else { return false }
        let delta = deeper ? 1 : -1
        for candidate in context.parsed where candidate.id >= nodeID && candidate.id < endLine {
            guard let candidateLevel = headingLevel(in: context.lines[candidate.id]) else { continue }
            guard (1...6).contains(candidateLevel + delta) else { return false }
        }

        if deeper {
            guard context.position > 0,
                  let previousStructural = context.parsed[..<context.position].reversed()
                    .first(where: { $0.depth <= context.node.depth }),
                  previousStructural.depth == context.node.depth,
                  headingLevel(in: context.lines[previousStructural.id]) != nil else { return false }
            return true
        }
        return level > 1
    }

    private static func canDeleteLeaf(_ context: EditContext) -> Bool {
        if context.position + 1 < context.parsed.count,
           context.parsed[context.position + 1].depth > context.node.depth {
            return false
        }
        let nodeID = context.node.id
        // A heading is a structural map node too. Keep another node when deleting
        // a heading so a heading-only map cannot become an empty canvas.
        guard isListLine(context.lines[nodeID]) || context.parsed.count > 1 else { return false }
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
            canPromote: canShiftNodeSubtree(context, deeper: false),
            canDemote: canShiftNodeSubtree(context, deeper: true),
            canDeleteLeaf: canDeleteLeaf(context)
        )
    }
    /// Fingerprint the Markdown body owned by one structural line. Strip only
    /// common continuation indentation so a safe subtree reparent keeps the
    /// same derived identity; preserve internal spacing, blank lines and syntax.
    private static func attachedBodyFingerprint(
        in lines: [String], from start: Int, to end: Int
    ) -> Int? {
        var lower = min(max(0, start), lines.count)
        var upper = min(max(lower, end), lines.count)
        func isBlank(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        while lower < upper && isBlank(lines[lower]) { lower += 1 }
        while upper > lower && isBlank(lines[upper - 1]) { upper -= 1 }

        var commonIndent: Int?
        for index in lower..<upper {
            if index.isMultiple(of: 128), Task.isCancelled { return nil }
            let line = lines[index]
            guard !isBlank(line) else { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            commonIndent = min(commonIndent ?? indent, indent)
        }

        var hasher = Hasher()
        hasher.combine(upper - lower)
        for index in lower..<upper {
            if (index - lower).isMultiple(of: 128), Task.isCancelled { return nil }
            let line = lines[index]
            let indent = line.prefix(while: { $0 == " " }).count
            hasher.combine(String(line.dropFirst(min(indent, commonIndent ?? 0))))
        }
        return hasher.finalize()
    }

    static func nodes(in markdown: String, baseIndent: Int = 0) -> [MindMapNode] {
        guard !Task.isCancelled else { return [] }
        var result: [MindMapNode] = []
        var headingDepth = 0
        var activeFence: MarkdownFence?
        let lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index.isMultiple(of: 128), Task.isCancelled { return [] }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = activeFence {
                if closesFence(line, matching: fence) { activeFence = nil }
                continue
            }
            if let opening = openingFence(in: line) {
                activeFence = opening
                continue
            }
            if trimmed.isEmpty
                || isIndentedCodeLine(line, after: result.last, in: lines, baseIndent: baseIndent) {
                continue
            }
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

        // The node's own attached Markdown body is part of its transient
        // identity. Descendant bodies are included recursively by lineIndexMap.
        var projected: [MindMapNode] = []
        projected.reserveCapacity(result.count)
        for (position, node) in result.enumerated() {
            if position.isMultiple(of: 64), Task.isCancelled { return [] }
            let bodyEnd = position + 1 < result.count ? result[position + 1].id : lines.count
            guard let bodyFingerprint = attachedBodyFingerprint(
                in: lines, from: node.id + 1, to: bodyEnd
            ) else { return [] }
            projected.append(.init(
                id: node.id, depth: node.depth, title: node.title,
                attachedBodyFingerprint: bodyFingerprint
            ))
        }
        return projected
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

    /// PDF citations must remain active Markdown links, never code literals.
    /// Match the outline parser's fenced-block rules and the link parser's
    /// escaped-backtick handling at the editor's UTF-16 insertion boundary.
    static func isInsideCode(in markdown: String, at offset: Int) -> Bool {
        let source = markdown as NSString
        let safeOffset = min(max(0, offset), source.length)
        let lines = markdown.components(separatedBy: "\n")
        let lineIndex = source.substring(to: safeOffset).reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        let previousNode = nodes(in: markdown).last(where: { $0.id < lineIndex })
        let indentedCode = lines.indices.contains(lineIndex)
            && isIndentedCodeLine(lines[lineIndex], after: previousNode, in: lines)
        var lineStart = 0
        var activeFence: MarkdownFence?

        for line in lines {
            let lineLength = (line as NSString).length
            let lineEnd = lineStart + lineLength
            let containsOffset = safeOffset >= lineStart && safeOffset <= lineEnd
            let opening = openingFence(in: line)
            let closesActiveFence = activeFence.map { closesFence(line, matching: $0) } ?? false

            if containsOffset {
                if opening != nil || activeFence != nil || indentedCode { return true }
                let lineOffset = safeOffset - lineStart
                return inlineCodeRanges(in: line).contains {
                    lineOffset >= $0.location && lineOffset < NSMaxRange($0)
                }
            }

            if activeFence != nil {
                if closesActiveFence { activeFence = nil }
            } else if let opening {
                activeFence = opening
            }
            lineStart = lineEnd + 1
        }
        return false
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

    /// Map transient collapsed-node IDs from one parsed Markdown projection
    /// to the next. The Markdown text remains the only identity authority.
    /// Node titles survive indentation changes, so reparented subtrees keep
    /// their collapsed state; same-position title edits retain the current node.
    static func lineIndexMap(
        from oldNodes: [MindMapNode],
        to newNodes: [MindMapNode]
    ) -> [Int: Int] {
        guard !oldNodes.isEmpty, !newNodes.isEmpty else { return [:] }

        if oldNodes.count == newNodes.count,
           oldNodes.enumerated().allSatisfy({ index, node in
               node.title == newNodes[index].title
                   && node.depth == newNodes[index].depth
                   && node.attachedBodyFingerprint == newNodes[index].attachedBodyFingerprint
           }) {
            return Dictionary(uniqueKeysWithValues: zip(oldNodes, newNodes).map {
                ($0.id, $1.id)
            })
        }

        let changes = newNodes.map(\.title)
            .difference(from: oldNodes.map(\.title))
            .inferringMoves()
        var removedOffsets: Set<Int> = []
        var insertedOffsets: Set<Int> = []
        var movedOffsets: [Int: Int] = [:]

        for change in changes {
            switch change {
            case let .remove(offset, _, associatedWith):
                removedOffsets.insert(offset)
                if let associatedWith { movedOffsets[offset] = associatedWith }
            case let .insert(offset, _, associatedWith):
                insertedOffsets.insert(offset)
                if let associatedWith { movedOffsets[associatedWith] = offset }
            }
        }

        let removed = removedOffsets.sorted()
        let inserted = insertedOffsets.sorted()
        var result: [Int: Int] = [:]
        result.reserveCapacity(oldNodes.count)

        for (oldPosition, node) in oldNodes.enumerated() {
            let newPosition: Int
            if let moved = movedOffsets[oldPosition] {
                newPosition = moved
            } else if removedOffsets.contains(oldPosition) {
                // A same-position replacement is a rename/edit, not a deletion.
                guard insertedOffsets.contains(oldPosition) else { continue }
                newPosition = oldPosition
            } else {
                var shifted = oldPosition
                for offset in removed where offset < oldPosition { shifted -= 1 }
                for offset in inserted where offset <= shifted { shifted += 1 }
                newPosition = shifted
            }

            guard newNodes.indices.contains(newPosition) else { continue }
            result[node.id] = newNodes[newPosition].id
        }

        let oldTitleCounts = Dictionary(grouping: oldNodes, by: \.title).mapValues(\.count)
        let newTitleCounts = Dictionary(grouping: newNodes, by: \.title).mapValues(\.count)
        let ambiguousTitles = Set(oldTitleCounts.compactMap { $0.value > 1 ? $0.key : nil })
            .union(newTitleCounts.compactMap { $0.value > 1 ? $0.key : nil })
        guard !ambiguousTitles.isEmpty else { return result }

        struct ParentTitleKey: Hashable {
            let parentID: Int?
            let title: String
        }
        struct TitleFingerprintKey: Hashable {
            let title: String
            let fingerprint: Int
        }
        func parentIDs(for nodes: [MindMapNode]) -> [Int: Int] {
            var parents: [Int: Int] = [:]
            var ancestors: [MindMapNode] = []
            for node in nodes {
                while let last = ancestors.last, last.depth >= node.depth { ancestors.removeLast() }
                if let parent = ancestors.last { parents[node.id] = parent.id }
                ancestors.append(node)
            }
            return parents
        }
        func siblingGroups(_ nodes: [MindMapNode], parents: [Int: Int]) -> [ParentTitleKey: [MindMapNode]] {
            Dictionary(grouping: nodes) { ParentTitleKey(parentID: parents[$0.id], title: $0.title) }
        }

        let oldParents = parentIDs(for: oldNodes)
        let newParents = parentIDs(for: newNodes)
        let ambiguousOldIDs = Set(oldNodes.filter { ambiguousTitles.contains($0.title) }.map(\.id))
        let ambiguousNewIDs = Set(newNodes.filter { ambiguousTitles.contains($0.title) }.map(\.id))
        let invalidatedMappings = result.compactMap { oldID, newID in
            ambiguousOldIDs.contains(oldID) || ambiguousNewIDs.contains(newID) ? oldID : nil
        }
        for oldID in invalidatedMappings { result.removeValue(forKey: oldID) }

        func subtreeFingerprints(for nodes: [MindMapNode]) -> [Int: Int] {
            var childrenByID: [Int: [Int]] = [:]
            var ancestors: [MindMapNode] = []
            for node in nodes {
                while let last = ancestors.last, last.depth >= node.depth { ancestors.removeLast() }
                if let parent = ancestors.last {
                    childrenByID[parent.id, default: []].append(node.id)
                }
                ancestors.append(node)
            }

            var fingerprints: [Int: Int] = [:]
            fingerprints.reserveCapacity(nodes.count)
            for node in nodes.reversed() {
                // A transient, order-independent subtree fingerprint distinguishes
                // same-title siblings without persisting a second node identity.
                let children = (childrenByID[node.id] ?? [])
                    .compactMap { fingerprints[$0] }
                    .sorted()
                var hasher = Hasher()
                hasher.combine(node.title)
                hasher.combine(node.attachedBodyFingerprint)
                hasher.combine(children.count)
                for child in children { hasher.combine(child) }
                fingerprints[node.id] = hasher.finalize()
            }
            return fingerprints
        }

        // Duplicate titles are identities only within a parent already mapped from Markdown.
        let oldGroups = siblingGroups(oldNodes, parents: oldParents)
        let newGroups = siblingGroups(newNodes, parents: newParents)
        let oldFingerprints = subtreeFingerprints(for: oldNodes)
        let newFingerprints = subtreeFingerprints(for: newNodes)
        var mappedNewIDs = Set(result.values)
        for oldNode in oldNodes where ambiguousTitles.contains(oldNode.title) && result[oldNode.id] == nil {
            let oldParentID = oldParents[oldNode.id]
            let newParentID = oldParentID.flatMap { result[$0] }
            if oldParentID != nil && newParentID == nil { continue }
            let key = ParentTitleKey(parentID: oldParentID, title: oldNode.title)
            let oldSiblings = oldGroups[key] ?? []
            let newSiblings = newGroups[ParentTitleKey(parentID: newParentID, title: oldNode.title)] ?? []
            guard oldSiblings.count == newSiblings.count,
                  let occurrence = oldSiblings.firstIndex(where: { $0.id == oldNode.id }),
                  newSiblings.indices.contains(occurrence) else { continue }

            let fingerprint = oldFingerprints[oldNode.id]
            let oldMatches = oldSiblings.filter { oldFingerprints[$0.id] == fingerprint }
            let newMatches = newSiblings.filter { newFingerprints[$0.id] == fingerprint }
            let newID = oldMatches.count == 1 && newMatches.count == 1
                ? newMatches[0].id
                : newSiblings[occurrence].id
            guard !mappedNewIDs.contains(newID) else { continue }
            result[oldNode.id] = newID
            mappedNewIDs.insert(newID)
        }

        // A node can be moved independently of its former parent. If its
        // complete Markdown-derived subtree is unique for that title across
        // both projections, retain its transient identity across the reparent.
        // Identical duplicate subtrees remain deliberately unresolved.
        let oldFingerprintGroups = Dictionary(grouping: oldNodes) {
            TitleFingerprintKey(title: $0.title, fingerprint: oldFingerprints[$0.id] ?? 0)
        }
        let newFingerprintGroups = Dictionary(grouping: newNodes) {
            TitleFingerprintKey(title: $0.title, fingerprint: newFingerprints[$0.id] ?? 0)
        }
        for oldNode in oldNodes where ambiguousTitles.contains(oldNode.title) && result[oldNode.id] == nil {
            guard let fingerprint = oldFingerprints[oldNode.id] else { continue }
            let key = TitleFingerprintKey(title: oldNode.title, fingerprint: fingerprint)
            let oldMatches = oldFingerprintGroups[key] ?? []
            let newMatches = newFingerprintGroups[key] ?? []
            guard oldMatches.count == 1, newMatches.count == 1,
                  let newNode = newMatches.first,
                  !mappedNewIDs.contains(newNode.id) else { continue }
            result[oldNode.id] = newNode.id
            mappedNewIDs.insert(newNode.id)
        }

        // A unique moved parent may have become resolvable only in the pass
        // above. Revisit its descendants within their now-mapped parent group.
        for oldNode in oldNodes where ambiguousTitles.contains(oldNode.title) && result[oldNode.id] == nil {
            let oldParentID = oldParents[oldNode.id]
            let newParentID = oldParentID.flatMap { result[$0] }
            if oldParentID != nil && newParentID == nil { continue }
            let key = ParentTitleKey(parentID: oldParentID, title: oldNode.title)
            let oldSiblings = oldGroups[key] ?? []
            let newSiblings = newGroups[ParentTitleKey(parentID: newParentID, title: oldNode.title)] ?? []
            guard oldSiblings.count == newSiblings.count,
                  let occurrence = oldSiblings.firstIndex(where: { $0.id == oldNode.id }),
                  newSiblings.indices.contains(occurrence) else { continue }
            let fingerprint = oldFingerprints[oldNode.id]
            let oldMatches = oldSiblings.filter { oldFingerprints[$0.id] == fingerprint }
            let newMatches = newSiblings.filter { newFingerprints[$0.id] == fingerprint }
            let newID = oldMatches.count == 1 && newMatches.count == 1
                ? newMatches[0].id : newSiblings[occurrence].id
            guard !mappedNewIDs.contains(newID) else { continue }
            result[oldNode.id] = newID
            mappedNewIDs.insert(newID)
        }
        return result
    }

    /// One branch-deletion entry point for the Markdown-backed map.
    /// Heading deletion is an explicit destructive section operation; list deletion
    /// retains its stricter list-only safety rule.
    static func deleteNodeSubtree(in source: String, nodeID: Int) -> String? {
        guard let context = editContext(in: source, nodeID: nodeID),
              context.lines.indices.contains(nodeID) else { return nil }
        if isListLine(context.lines[nodeID]) {
            return deleteListSubtree(in: source, nodeID: nodeID)
        }
        guard headingLevel(in: context.lines[nodeID]) != nil else { return nil }

        let contentLineCount = context.lines.count - (source.hasSuffix("\n") ? 1 : 0)
        let endLine = subtreeEndLine(
            at: context.position, nodes: context.parsed, lineCount: contentLineCount
        )
        let nextNode = context.position + 1 < context.parsed.count
            ? context.parsed[context.position + 1] : nil
        let hasDescendants = nextNode.map { $0.depth > context.node.depth } ?? false
        let attachedContentEnd = nextNode?.id ?? contentLineCount
        let hasAttachedContent = context.lines[(nodeID + 1)..<attachedContentEnd]
            .contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard hasDescendants || hasAttachedContent else { return nil }

        // A destructive section removal must never leave the map without a node.
        let remainingNodes = context.parsed.filter { !($0.id >= nodeID && $0.id < endLine) }
        guard !remainingNodes.isEmpty else { return nil }

        var lines = context.lines
        lines.removeSubrange(nodeID..<endLine)
        return lines.joined(separator: "\n")
    }

    /// List branches remain removable only when every nonempty line is a list node.
    /// This prevents a graph action from silently deleting attached prose or files.
    private static func deleteListSubtree(in source: String, nodeID: Int) -> String? {
        let parsed = nodes(in: source)
        guard let position = parsed.firstIndex(where: { $0.id == nodeID }) else { return nil }
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID), isListLine(lines[nodeID]) else { return nil }

        let contentLineCount = lines.count - (source.hasSuffix("\n") ? 1 : 0)
        let endID = subtreeEndLine(at: position, nodes: parsed, lineCount: contentLineCount)
        let knownNodeIDs = Set(parsed.map(\.id))
        for index in nodeID..<endID {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard knownNodeIDs.contains(index), isListLine(trimmed) else { return nil }
        }
        let remainingNodes = parsed.filter { !($0.id >= nodeID && $0.id < endID) }
        guard !remainingNodes.isEmpty else { return nil }
        lines.removeSubrange(nodeID..<endID)
        return lines.joined(separator: "\n")
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
    // Derived once with the links from the same canonical Markdown segment.
    // The inspector must not split the entire document during pan/pinch redraw.
    let body: String

    init(title: String, links: [MindMapLink], body: String = "") {
        self.title = title
        self.links = links
        self.body = body
    }
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
    /// Fenced and indented code blocks are skipped so example markup never
    /// reports as a real backlink.
    static func linkOccurrences(
        in markdown: String,
        includeImages: Bool = false,
        baseIndent: Int = 0
    ) -> [MarkdownLinkOccurrence] {
        guard !Task.isCancelled else { return [] }
        let lines = markdown.components(separatedBy: "\n")
        let parsedNodes = nodes(in: markdown, baseIndent: baseIndent)
        var nodeCursor = 0
        var previousNode: MindMapNode?
        var result: [MarkdownLinkOccurrence] = []
        var activeFence: MarkdownFence?
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex.isMultiple(of: 128), Task.isCancelled { return result }
            while nodeCursor < parsedNodes.count && parsedNodes[nodeCursor].id < lineIndex {
                previousNode = parsedNodes[nodeCursor]
                nodeCursor += 1
            }
            if let fence = activeFence {
                if closesFence(line, matching: fence) { activeFence = nil }
                continue
            }
            if let opening = openingFence(in: line) {
                activeFence = opening
                continue
            }
            guard !isIndentedCodeLine(line, after: previousNode, in: lines, baseIndent: baseIndent),
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
        guard !Task.isCancelled else { return [:] }
        let lines = markdown.components(separatedBy: "\n")
        var result: [Int: MindMapNodePresentation] = [:]
        result.reserveCapacity(nodes.count)

        for (position, node) in nodes.enumerated() {
            if position.isMultiple(of: 64), Task.isCancelled { return [:] }
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

            let nodeLine = lines[node.id]
            let baseIndent = isListLine(nodeLine)
                ? nodeLine.prefix(while: { $0 == " " }).count + 2
                : 0
            var links = title.links
            var seen = Set(links.map { $0.target + "\u{0}" + $0.label })
            let occurrences = linkOccurrences(in: body, baseIndent: baseIndent)
            guard !Task.isCancelled else { return [:] }
            for link in occurrences.map(\.link) {
                let key = link.target + "\u{0}" + link.label
                if seen.insert(key).inserted {
                    links.append(link)
                }
            }
            result[node.id] = .init(
                title: title.title, links: links,
                body: body.trimmingCharacters(in: .whitespacesAndNewlines)
            )
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
    /// Change one structural node's hierarchy using the canonical Markdown outline.
    /// List subtrees move by indentation; heading sections move by changing their heading levels.
    static func shiftNodeSubtree(in source: String, nodeID: Int, deeper: Bool) -> String? {
        guard let context = editContext(in: source, nodeID: nodeID),
              canShiftNodeSubtree(context, deeper: deeper) else { return nil }
        var lines = context.lines
        let endLine = shiftSubtreeEndLine(context)

        if isListLine(lines[nodeID]) {
            let delta = deeper ? 2 : -2
            for index in nodeID..<endLine where !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let currentIndent = lines[index].prefix(while: { $0 == " " }).count
                let nextIndent = currentIndent + delta
                guard nextIndent >= 0 else { return nil }
                lines[index] = String(repeating: " ", count: nextIndent) + lines[index].dropFirst(currentIndent)
            }
            return lines.joined(separator: "\n")
        }

        let delta = deeper ? 1 : -1
        for candidate in context.parsed where candidate.id >= nodeID && candidate.id < endLine {
            guard let level = headingLevel(in: lines[candidate.id]),
                  let updated = replacingHeadingLevel(in: lines[candidate.id], with: level + delta) else {
                continue
            }
            lines[candidate.id] = updated
        }
        return lines.joined(separator: "\n")
    }
}

extension MindMapOutline {
    /// Move any structural Markdown node without introducing a second graph authority.
    static func moveNodeSubtree(in source: String, nodeID: Int, asChildOf targetID: Int) -> String? {
        moveNodeSubtreeWithOutcome(in: source, nodeID: nodeID, asChildOf: targetID)?.source
    }

    static func moveNodeSubtreeWithOutcome(
        in source: String, nodeID: Int, asChildOf targetID: Int
    ) -> MindMapMoveOutcome? {
        moveNodeSubtreeWithOutcome(
            in: source, nodeID: nodeID, relativeTo: targetID, placement: .child
        )
    }

    /// Dispatch list indentation and heading-section moves through one public writer.
    static func moveNodeSubtreeWithOutcome(
        in source: String,
        nodeID: Int,
        relativeTo targetID: Int,
        placement: MindMapDropPlacement
    ) -> MindMapMoveOutcome? {
        guard nodeID != targetID else { return nil }
        let lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID), lines.indices.contains(targetID) else { return nil }
        if isListLine(lines[nodeID]) {
            return moveListSubtreeWithOutcome(
                in: source, nodeID: nodeID, relativeTo: targetID, placement: placement
            )
        }
        return moveHeadingSubtreeWithOutcome(
            in: source, nodeID: nodeID, relativeTo: targetID, placement: placement
        )
    }

    /// Reparent a list subtree by indentation while preserving its attached Markdown.
    private static func moveListSubtreeWithOutcome(
        in source: String,
        nodeID: Int,
        relativeTo targetID: Int,
        placement: MindMapDropPlacement
    ) -> MindMapMoveOutcome? {
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
        return MindMapMoveOutcome(
            source: lines.joined(separator: "\n"),
            movedNodeID: adjustedInsertion
        )
    }

    private static func headingLevel(in line: String) -> Int? {
        let leadingCount = line.prefix(while: \.isWhitespace).count
        let content = line.dropFirst(leadingCount)
        let level = content.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level), content.dropFirst(level).first == " " else { return nil }
        return level
    }

    private static func replacingHeadingLevel(in line: String, with level: Int) -> String? {
        guard (1...6).contains(level) else { return nil }
        let leading = String(line.prefix(while: \.isWhitespace))
        let content = line.dropFirst(leading.count)
        let current = content.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(current), content.dropFirst(current).first == " " else { return nil }
        return leading + String(repeating: "#", count: level) + String(content.dropFirst(current))
    }

    /// Move an entire heading section, including its Markdown body and descendants.
    /// Relevel every heading in the section by one shared delta so its internal hierarchy survives.
    private static func moveHeadingSubtreeWithOutcome(
        in source: String,
        nodeID: Int,
        relativeTo targetID: Int,
        placement: MindMapDropPlacement
    ) -> MindMapMoveOutcome? {
        let parsed = nodes(in: source)
        guard let sourcePosition = parsed.firstIndex(where: { $0.id == nodeID }),
              let targetPosition = parsed.firstIndex(where: { $0.id == targetID }) else { return nil }
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID), lines.indices.contains(targetID),
              let sourceLevel = headingLevel(in: lines[nodeID]),
              let targetLevel = headingLevel(in: lines[targetID]) else { return nil }

        let contentLineCount = lines.count - (source.hasSuffix("\n") ? 1 : 0)
        let sourceEnd = subtreeEndLine(at: sourcePosition, nodes: parsed, lineCount: contentLineCount)
        guard !(nodeID..<sourceEnd).contains(targetID) else { return nil }
        let targetEnd = subtreeEndLine(at: targetPosition, nodes: parsed, lineCount: contentLineCount)
        let targetFirstChild = firstDescendantLine(
            at: targetPosition, nodes: parsed, fallback: targetEnd
        )

        let insertionLine: Int
        let desiredLevel: Int
        switch placement {
        case .child:
            desiredLevel = targetLevel + 1
            guard desiredLevel <= 6 else { return nil }
            insertionLine = targetFirstChild
        case .before:
            desiredLevel = targetLevel
            insertionLine = targetID
        case .after:
            desiredLevel = targetLevel
            insertionLine = targetEnd
        }

        let delta = desiredLevel - sourceLevel
        var moved = Array(lines[nodeID..<sourceEnd])
        for candidate in parsed where candidate.id >= nodeID && candidate.id < sourceEnd {
            let offset = candidate.id - nodeID
            guard moved.indices.contains(offset),
                  let currentLevel = headingLevel(in: moved[offset]) else { continue }
            guard let updated = replacingHeadingLevel(in: moved[offset], with: currentLevel + delta) else {
                return nil
            }
            moved[offset] = updated
        }

        let removedCount = sourceEnd - nodeID
        lines.removeSubrange(nodeID..<sourceEnd)
        let adjustedInsertion = insertionLine > nodeID ? insertionLine - removedCount : insertionLine
        guard adjustedInsertion >= 0, adjustedInsertion <= lines.count else { return nil }
        lines.insert(contentsOf: moved, at: adjustedInsertion)
        return MindMapMoveOutcome(
            source: lines.joined(separator: "\n"),
            movedNodeID: adjustedInsertion
        )
    }
}


extension MindMapOutline {
    /// Extract distinct user-authored links through the canonical occurrence parser.
    static func knowledgeLinks(in markdown: String) -> [MindMapLink] {
        var seen: Set<String> = []
        return linkOccurrences(in: markdown).compactMap { occurrence in
            let link = occurrence.link
            let key = link.target + "\u{0}" + link.label
            return seen.insert(key).inserted ? link : nil
        }
    }
}
