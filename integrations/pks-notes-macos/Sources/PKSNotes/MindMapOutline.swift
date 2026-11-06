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
        lines.remove(at: nodeID)
        return lines.joined(separator: "\n")
    }

    static func addChild(in source: String, parentID: Int, title: String = "New idea") -> String? {
        var lines = source.components(separatedBy: "\n")
        guard nodes(in: source).contains(where: { $0.id == parentID }), lines.indices.contains(parentID) else { return nil }
        let line = lines[parentID]
        let indent = line.prefix(while: { $0 == " " }).count
        let isList = ["- ", "* ", "+ "].contains(where: { line.trimmingCharacters(in: .whitespaces).hasPrefix($0) })
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
