import Foundation

/// Read-only outline projection; the Markdown file remains the source of truth.
struct MindMapNode: Equatable, Identifiable {
    let id: Int
    let depth: Int
    let title: String
}

enum MindMapOutline {
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
}

extension MindMapOutline {
    /// Create a usable map from an empty Markdown file without a secondary map store.
    static func createMap(title: String = "New Mind Map") -> String {
        "# \(title)\n"
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
        let parsed = nodes(in: source)
        guard let position = parsed.firstIndex(where: { $0.id == nodeID }) else { return nil }
        let node = parsed[position]
        if position + 1 < parsed.count && parsed[position + 1].depth > node.depth { return nil }
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID) else { return nil }
        // Only list items can be removed without potentially orphaning prose/sections.
        let trimmed = lines[nodeID].trimmingCharacters(in: .whitespaces)
        guard ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) else { return nil }
        // A Markdown list item can own paragraphs, task details, or fenced code
        // even without parsed child nodes. Do not orphan that content.
        let nextNode = position + 1 < parsed.count ? parsed[position + 1].id : lines.count
        guard !lines[(nodeID + 1)..<nextNode]
            .contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return nil }
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
        // Inserting ahead of attached prose would accidentally make that prose
        // part of the newly created child instead of the original parent.
        let nextParsedID = nodes(in: source).first(where: { $0.id > parentID })?.id ?? lines.count
        guard !lines[(parentID + 1)..<nextParsedID]
            .contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
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

extension MindMapOutline {
    static func links(in title: String) -> [MindMapLink] {
        let patterns = [#"\[\[([^\]\n]+)\]\]"#, #"\[([^\]\n]+)\]\(([^)\n]+)\)"#]
        var links: [MindMapLink] = []
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: title, range: range) {
                guard let labelRange = Range(match.range(at: 1), in: title) else { continue }
                let raw = String(title[labelRange])
                if index == 0 {
                    let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    let target = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    let label = parts.count == 2 ? String(parts[1]) : target
                    if !target.isEmpty { links.append(.init(label: label, target: target)) }
                } else if let targetRange = Range(match.range(at: 2), in: title) {
                    links.append(.init(label: raw, target: String(title[targetRange])))
                }
            }
        }
        return links
    }
}


extension MindMapOutline {
    /// Reparent a pure Markdown list subtree by one indentation level.
    /// Conservatively rejects prose/code inside the subtree to avoid corrupting Markdown.
    static func shiftListSubtree(in source: String, nodeID: Int, deeper: Bool) -> String? {
        let parsed = nodes(in: source)
        guard let position = parsed.firstIndex(where: { $0.id == nodeID }) else { return nil }
        let node = parsed[position]
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID) else { return nil }

        func isListLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) })
        }
        guard isListLine(lines[nodeID]) else { return nil }

        let endLine: Int = {
            guard position + 1 < parsed.count else { return lines.count }
            for candidate in parsed[(position + 1)...] where candidate.depth <= node.depth {
                return candidate.id
            }
            return lines.count
        }()

        for index in nodeID..<endLine {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !isListLine(lines[index]) { return nil }
        }

        if deeper {
            var previousStructural: MindMapNode?
            if position > 0 {
                for candidate in parsed[..<position].reversed() where candidate.depth <= node.depth {
                    previousStructural = candidate
                    break
                }
            }
            guard previousStructural?.depth == node.depth else { return nil }
        } else {
            let indent = lines[nodeID].prefix(while: { $0 == " " }).count
            guard indent >= 2 else { return nil }
        }

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
        return lines.joined(separator: "\n")
    }
}


extension MindMapOutline {
    /// Extract user-authored knowledge links from Markdown while ignoring fenced code.
    static func knowledgeLinks(in markdown: String) -> [MindMapLink] {
        var result: [MindMapLink] = []
        var seen: Set<String> = []
        var fenceMarker: Character?

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "\u{60}" || marker == "~",
               trimmed.prefix(while: { $0 == marker }).count >= 3 {
                if fenceMarker == nil { fenceMarker = marker }
                else if fenceMarker == marker { fenceMarker = nil }
                continue
            }
            guard fenceMarker == nil else { continue }

            for link in links(in: line) {
                let key = link.target + "\u{0}" + link.label
                if seen.insert(key).inserted { result.append(link) }
            }
        }
        return result
    }
}
