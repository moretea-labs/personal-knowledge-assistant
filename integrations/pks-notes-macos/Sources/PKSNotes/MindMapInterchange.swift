import Foundation

/// OPML is supported by MindNode Classic and MindNode Next.
/// Native .mindnode packages are a distinct, versioned format; never mislabel OPML.
enum MindMapInterchange {
    enum Failure: LocalizedError {
        case empty
        case invalid
        case tooLarge
        case tooDeep

        var errorDescription: String? {
            switch self {
            case .empty: "No headings or list nodes were found."
            case .invalid: "This is not a valid OPML mind map."
            case .tooLarge: "This OPML file is too large (maximum 5 MB)."
            case .tooDeep: "This mind map is nested too deeply (maximum 64 levels)."
            }
        }
    }

    static func exportOPML(_ markdown: String) throws -> Data {
        let nodes = MindMapOutline.nodes(in: markdown)
        guard !nodes.isEmpty else { throw Failure.empty }
        guard nodes.allSatisfy({ $0.depth < 64 }) else { throw Failure.tooDeep }
        var output = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>Leafspan Mind Map</title></head>
          <body>
        """
        output += "\n"
        var depthStack: [Int] = []
        for node in nodes {
            while let last = depthStack.last, last >= node.depth {
                depthStack.removeLast()
                output += String(repeating: "  ", count: depthStack.count + 2) + "</outline>\n"
            }
            output += String(repeating: "  ", count: depthStack.count + 2)
                + "<outline text=\"\(xmlAttribute(node.title))\">\n"
            depthStack.append(node.depth)
        }
        while !depthStack.isEmpty {
            depthStack.removeLast()
            output += String(repeating: "  ", count: depthStack.count + 2) + "</outline>\n"
        }
        output += "  </body>\n</opml>\n"
        return Data(output.utf8)
    }

    static func importOPML(_ data: Data) throws -> String {
        guard data.count <= 5 * 1024 * 1024 else { throw Failure.tooLarge }
        // OPML is plain XML; reject DTD/entity declarations rather than asking
        // XMLParser to expand untrusted internal/external entity definitions.
        let raw = String(decoding: data, as: UTF8.self).uppercased()
        guard !raw.contains("<!DOCTYPE"), !raw.contains("<!ENTITY") else { throw Failure.invalid }
        let collector = OutlineCollector()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse(), collector.sawOPML, collector.sawBody,
              !collector.invalid, !collector.entries.isEmpty
        else { throw Failure.invalid }

        let items = collector.entries
        // A forest gets one synthetic Markdown root so every OPML topic survives.
        let roots = items.filter { $0.depth == 0 }.count
        let prefix: String
        let indentAdjustment: Int
        if roots == 1 {
            prefix = "# \(items[0].text)\n"
            indentAdjustment = 1
        } else {
            prefix = "# Mind Map\n"
            indentAdjustment = 0
        }
        var lines = [prefix.trimmingCharacters(in: .newlines)]
        for item in items.dropFirst(roots == 1 ? 1 : 0) {
            let indentation = item.depth - indentAdjustment
            lines.append(String(repeating: "  ", count: indentation) + "- " + item.text)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func xmlAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class OutlineCollector: NSObject, XMLParserDelegate {
    struct Entry {
        let depth: Int
        let text: String
    }

    var entries: [Entry] = []
    var depth = 0
    var inBody = false
    var sawBody = false
    var sawOPML = false
    var invalid = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch name.lowercased() {
        case "opml": sawOPML = true
        case "body": inBody = true; sawBody = true
        case "outline" where inBody:
            let text = (attributes["text"] ?? attributes["title"] ?? "")
                .components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || entries.count >= 10_000 || depth >= 64 { invalid = true }
            else { entries.append(.init(depth: depth, text: text)) }
            depth += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch name.lowercased() {
        case "outline" where inBody: depth = max(0, depth - 1)
        case "body": inBody = false
        default: break
        }
    }
}
