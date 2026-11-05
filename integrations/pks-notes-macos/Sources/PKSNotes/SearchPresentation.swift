import Foundation

/// Presentation only: PKS owns retrieval order, scores and chunks.
struct SearchResultGroup: Identifiable {
    let id: String
    let hits: [SearchHit]
    var primary: SearchHit { hits[0] }

    static func group(_ hits: [SearchHit]) -> [SearchResultGroup] {
        var ordered: [(key: String, matches: [SearchHit])] = []
        var indices: [String: Int] = [:]
        for hit in hits {
            let key = hit.documentId + "|" + hit.uri
            if let index = indices[key] {
                ordered[index].matches.append(hit)
            } else {
                indices[key] = ordered.count
                ordered.append((key, [hit]))
            }
        }
        return ordered.map { SearchResultGroup(id: $0.key, hits: $0.matches) }
    }
}

struct HighlightedPiece: Equatable {
    let text: String
    let matched: Bool
}

enum MatchHighlighter {
    /// Literal Unicode/case-insensitive match: no regex interpretation.
    static func pieces(in source: String, query: String) -> [HighlightedPiece] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [HighlightedPiece(text: source, matched: false)] }
        var remaining = source[...]
        var result: [HighlightedPiece] = []
        while let match = remaining.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            if match.lowerBound > remaining.startIndex {
                result.append(HighlightedPiece(text: String(remaining[..<match.lowerBound]), matched: false))
            }
            result.append(HighlightedPiece(text: String(remaining[match]), matched: true))
            remaining = remaining[match.upperBound...]
        }
        if !remaining.isEmpty {
            result.append(HighlightedPiece(text: String(remaining), matched: false))
        }
        return result.isEmpty ? [HighlightedPiece(text: source, matched: false)] : result
    }
}

struct MarkdownSection: Identifiable {
    let id: Int
    let heading: String?
    let markdown: String

    static func sections(in source: String) -> [MarkdownSection] {
        let lines = source.components(separatedBy: "\n")
        var result: [MarkdownSection] = []
        var currentLines: [String] = []
        var currentHeading: String?
        var fence: Character?

        func flush() {
            if !currentLines.isEmpty {
                result.append(MarkdownSection(id: result.count,
                                              heading: currentHeading,
                                              markdown: currentLines.joined(separator: "\n")))
            }
            currentLines = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("~~~") {
                if fence == nil { fence = "~" }
                else if fence == "~" { fence = nil }
            } else if trimmed.hasPrefix("~~~") == false &&
                      trimmed.first == Character(UnicodeScalar(96)!) &&
                      trimmed.prefix(3).count == 3 &&
                      trimmed.prefix(3).allSatisfy({ $0 == Character(UnicodeScalar(96)!) }) {
                if fence == nil { fence = Character(UnicodeScalar(96)!) }
                else if fence == Character(UnicodeScalar(96)!) { fence = nil }
            }
            var foundHeading: String?
            if fence == nil {
                let hashes = line.prefix { $0 == "#" }.count
                if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                    foundHeading = String(line.dropFirst(hashes + 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let heading = foundHeading {
                flush()
                currentHeading = heading
            }
            currentLines.append(line)
        }
        flush()
        return result
    }

    static func targetIndex(in sections: [MarkdownSection],
                            headingPath: String?,
                            snippet: String?,
                            query: String) -> Int? {
        if let headingPath, !headingPath.isEmpty {
            let target = headingPath.components(separatedBy: " > ").last!
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = sections.first(where: {
                $0.heading?.localizedCaseInsensitiveCompare(target) == .orderedSame
            }) { return match.id }
            if let match = sections.first(where: {
                $0.heading?.localizedCaseInsensitiveContains(target) == true
            }) { return match.id }
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty, let match = sections.first(where: {
            $0.markdown.localizedCaseInsensitiveContains(term)
        }) { return match.id }
        if let snippet, !snippet.isEmpty {
            let excerpt = String(snippet.prefix(32)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !excerpt.isEmpty, let match = sections.first(where: {
                $0.markdown.localizedCaseInsensitiveContains(excerpt)
            }) { return match.id }
        }
        return sections.first?.id
    }
}
