import Foundation

/// Read-only, version-bounded importer for MindNode Classic v9 packages.
/// Schema reference: masamitsu-konya/mindnode-mcp (MIT), document.py.
/// Never write to the input package: Markdown remains PKS Notes' only writer.
enum MindNodePackage {
    enum Failure: LocalizedError {
        case unsupported
        case malformed
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unsupported: "Only MindNode v9 package documents are supported in this importer."
            case .malformed: "This is not a valid MindNode package with a readable node tree."
            case .tooLarge: "The MindNode node data is too large (maximum 12 MB)."
            }
        }
    }

    static func importOutline(from url: URL) throws -> String {
        guard url.pathExtension.lowercased() == "mindnode" else { throw Failure.unsupported }
        let package = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard package.isDirectory == true, package.isSymbolicLink != true else { throw Failure.malformed }
        let file = url.appendingPathComponent("contents.xml")
        let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw Failure.malformed }
        guard (attributes.fileSize ?? 0) <= 12 * 1024 * 1024 else { throw Failure.tooLarge }
        let data = try Data(contentsOf: file)
        guard data.count <= 12 * 1024 * 1024 else { throw Failure.tooLarge }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let document = try PropertyListSerialization.propertyList(
            from: data, options: [], format: &format
        ) as? [String: Any] else { throw Failure.malformed }
        guard format == .binary, document["version"] as? Int == 9 else { throw Failure.unsupported }
        guard let canvas = document["canvas"] as? [String: Any],
              let maps = canvas["mindMaps"] as? [[String: Any]],
              !maps.isEmpty else { throw Failure.malformed }

        let roots = try maps.map { map -> [String: Any] in
            guard let node = map["mainNode"] as? [String: Any] else { throw Failure.malformed }
            return node
        }
        var lines: [String] = roots.count == 1 ? [] : ["# Mind Maps"]
        var seen = 0
        func traverse(_ node: [String: Any], depth: Int) throws {
            seen += 1
            guard seen <= 10_000, depth < 64 else { throw Failure.tooLarge }
            let html = (node["title"] as? [String: Any])?["text"] as? String
            guard let html, !html.isEmpty else { throw Failure.malformed }
            let title = plainTitle(html)
            guard !title.isEmpty, title.count <= 10_000 else { throw Failure.malformed }
            if depth == 0 && roots.count == 1 {
                lines.append("# " + title)
            } else {
                let listDepth = roots.count == 1 ? depth - 1 : depth
                lines.append(String(repeating: "  ", count: max(0, listDepth)) + "- " + title)
            }
            let children: [[String: Any]]
            if let value = node["subnodes"] {
                guard let nested = value as? [[String: Any]] else { throw Failure.malformed }
                children = nested
            } else {
                children = []
            }
            for child in children { try traverse(child, depth: depth + 1) }
        }
        for node in roots { try traverse(node, depth: 0) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// MindNode stores node titles as small HTML fragments; decode plain
    /// text only. Notes, images, tasks, positions, and style are not imported.
    private static func plainTitle(_ html: String) -> String {
        let linebreaks = html.replacingOccurrences(
            of: #"(?i)<\s*(br\s*/?|/p|/div|/li)\s*>"#,
            with: " ", options: .regularExpression
        )
        let stripped = linebreaks.replacingOccurrences(
            of: "<[^>]*>", with: "", options: .regularExpression
        )
        let entities = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")
        ]
        let decoded = entities.reduce(stripped) { value, entity in
            value.replacingOccurrences(of: entity.0, with: entity.1)
        }
        return decoded.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
