import Foundation

/// Read-only, version-bounded importer for MindNode binary-plist packages.
/// Real documents from the current MindNode 2026.7.1 library use schema
/// version 9; older library documents use the compatible version 7 tree.
/// Never write to the input package: Markdown remains Leafspan's only writer.
enum MindNodePackage {
    enum Failure: LocalizedError {
        case unsupported
        case malformed
        case tooLarge
        case tooDeep
        case notOutline
        case destinationExists
        case unsupportedAttachment

        var errorDescription: String? {
            switch self {
            case .unsupported: "Only verified MindNode package versions 7 and 9 are supported in this importer."
            case .malformed: "This is not a valid MindNode package with a readable node tree."
            case .tooLarge: "The MindNode node data is too large (maximum 12 MB)."
            case .tooDeep: "This MindNode outline is nested too deeply (maximum 64 levels)."
            case .notOutline: "Native MindNode export requires one root and only Markdown heading/list nodes. Use OPML to exchange a larger note."
            case .destinationExists: "The destination already exists; choose a new filename to avoid overwriting existing mind maps."
            case .unsupportedAttachment: "MindNode attachment is unavailable or not a supported PNG image. The import was not written."
            }
        }
    }

    struct ImportedImage {
        let marker: String
        let stem: String
        let png: Data
    }

    struct ImportedDocument {
        let markdown: String
        let images: [ImportedImage]
    }

    static func importOutline(from url: URL) throws -> String {
        try readDocument(from: url, includeImages: false).markdown
    }

    static func importDocument(from url: URL) throws -> ImportedDocument {
        try readDocument(from: url, includeImages: true)
    }

    private static func readDocument(from url: URL, includeImages: Bool) throws -> ImportedDocument {
        let document = try readSupportedPackage(from: url)
        guard let canvas = document["canvas"] as? [String: Any],
              let maps = canvas["mindMaps"] as? [[String: Any]],
              !maps.isEmpty else { throw Failure.malformed }

        let roots = try maps.map { map -> [String: Any] in
            guard let node = map["mainNode"] as? [String: Any] else { throw Failure.malformed }
            return node
        }

        struct ImportedTopic {
            let title: String
            let noteParagraphs: [String]
            let titleLinks: [(label: String, target: String)]
            let imageMarker: String?
            let children: [ImportedTopic]
        }

        var images: [ImportedImage] = []
        var seen = 0
        func attachedImage(_ node: [String: Any]) throws -> String? {
            guard includeImages, let attachment = node["attachment"] else { return nil }
            guard let info = attachment as? [String: Any],
                  let filename = info["fileName"] as? String,
                  filename.range(of: #"^[a-zA-Z0-9_-]+\.png$"#, options: .regularExpression) != nil,
                  images.count < 32 else { throw Failure.unsupportedAttachment }
            let source = url.appendingPathComponent("resources", isDirectory: true)
                .appendingPathComponent(filename)
            let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let size = attributes.fileSize, size > 0, size <= 5 * 1024 * 1024 else {
                throw Failure.unsupportedAttachment
            }
            let png = try Data(contentsOf: source)
            guard png.count == size,
                  png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw Failure.unsupportedAttachment
            }
            let marker = "__LEAFSPAN_MINDNODE_IMAGE_\(UUID().uuidString)__"
            let stem = "mindnode-" + String(filename.dropLast(4))
            images.append(ImportedImage(marker: marker, stem: stem, png: png))
            return marker
        }
        func visibleTopics(_ node: [String: Any], depth: Int) throws -> [ImportedTopic] {
            seen += 1
            guard seen <= 10_000, depth < 64 else { throw Failure.tooLarge }

            let children: [[String: Any]]
            if let value = node["subnodes"] {
                guard let nested = value as? [[String: Any]] else { throw Failure.malformed }
                children = nested
            } else {
                children = []
            }
            let visibleChildren = try children.flatMap { try visibleTopics($0, depth: depth + 1) }

            if let titleValue = node["title"] {
                guard let titleDictionary = titleValue as? [String: Any],
                      let html = titleDictionary["text"] as? String else { throw Failure.malformed }
                let title = plainTitle(html)
                if !title.isEmpty {
                    guard title.count <= 10_000 else { throw Failure.malformed }
                    let note = (node["note"] as? [String: Any])?["text"] as? String
                    return [ImportedTopic(
                        title: title,
                        noteParagraphs: note.map(noteParagraphs) ?? [],
                        titleLinks: titleLinks(html),
                        imageMarker: try attachedImage(node),
                        children: visibleChildren
                    )]
                }
            }

            // Untitled layout nodes do not become Markdown topics. Never
            // silently drop an attachment or note carried by such a node.
            guard node["note"] == nil, node["attachment"] == nil else {
                throw Failure.malformed
            }
            return visibleChildren
        }

        let topics = try roots.flatMap { try visibleTopics($0, depth: 0) }
        guard !topics.isEmpty else { throw Failure.malformed }

        var lines: [String] = []
        func emitNote(_ paragraphs: [String], indent: String) {
            guard !paragraphs.isEmpty else { return }
            for paragraph in paragraphs {
                // Blockquotes preserve the note as editable Markdown body text.
                // Nested notes are indented within their list item, so moving
                // that branch also moves its note without creating fake nodes.
                lines.append(indent + (paragraph.isEmpty ? ">" : "> " + paragraph))
            }
        }
        func emitImage(_ marker: String?, indent: String) {
            if let marker { lines.append(indent + "![MindNode image](" + marker + ")") }
        }
        func emitLinks(_ links: [(label: String, target: String)], indent: String) {
            for link in links {
                lines.append(indent + "[\(link.label)](\(link.target))")
            }
        }
        func emitChildren(_ children: [ImportedTopic], depth: Int) {
            for child in children {
                let indent = String(repeating: "  ", count: depth)
                lines.append(indent + "- " + child.title)
                emitNote(child.noteParagraphs, indent: indent + "  ")
                emitLinks(child.titleLinks, indent: indent + "  ")
                emitImage(child.imageMarker, indent: indent + "  ")
                emitChildren(child.children, depth: depth + 1)
            }
        }

        if roots.count == 1, topics.count == 1 {
            lines.append("# " + topics[0].title)
            emitNote(topics[0].noteParagraphs, indent: "")
            emitLinks(topics[0].titleLinks, indent: "")
            emitImage(topics[0].imageMarker, indent: "")
            emitChildren(topics[0].children, depth: 0)
        } else {
            lines.append("# Mind Maps")
            emitChildren(topics, depth: 0)
        }
        return ImportedDocument(markdown: lines.joined(separator: "\n") + "\n",
                                images: images)
    }

    private static func readSupportedPackage(from url: URL) throws -> [String: Any] {
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
        guard format == .binary,
              let version = document["version"] as? Int,
              [7, 9].contains(version) else { throw Failure.unsupported }
        return document
    }

    /// Create a new native package by cloning a user-selected compatible template.
    /// This is intentionally template-based: MindNode has undocumented required plist
    /// fields, print settings and package files. Never synthesize a fake native package.
    /// Unknown template metadata and style survive; old nodes/resources are replaced.
    static func exportOutline(_ markdown: String, usingTemplate template: URL, to destination: URL) throws {
        let topic = try exportTopic(markdown)
        let original = try readSupportedPackage(from: template)
        guard var canvas = original["canvas"] as? [String: Any],
              let maps = canvas["mindMaps"] as? [[String: Any]],
              let first = maps.first,
              let templateRoot = first["mainNode"] as? [String: Any] else { throw Failure.malformed }
        let fallbackChild = (templateRoot["subnodes"] as? [[String: Any]])?.first ?? templateRoot
        func node(for topic: ExportTopic, template style: [String: Any], isRoot: Bool) -> [String: Any] {
            let text = topic.title.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
            var result: [String: Any] = [
                "nodeID": UUID().uuidString.uppercased(),
                "title": ["text": "<p>\(text)</p>", "allowToShrinkWidth": true],
                "subnodes": topic.children.map { node(for: $0, template: fallbackChild, isRoot: false) },
                "hasFoldedSubnodes": false
            ]
            for key in ["shapeStyle", "pathStyle", "attachmentPosition", "styleChangedByUser"] {
                if let value = style[key] { result[key] = value }
            }
            if isRoot { result["location"] = style["location"] ?? "{0, 0}" }
            return result
        }
        var updatedMap = first
        updatedMap["mainNode"] = node(for: topic, template: templateRoot, isRoot: true)
        canvas["mindMaps"] = [updatedMap]
        canvas["crossConnections"] = [] // Old connection IDs cannot reference new nodes.
        canvas["tags"] = [] // No orphaned template tag definitions.
        var output = original
        output["canvas"] = canvas
        let bytes = try PropertyListSerialization.data(fromPropertyList: output, format: .binary, options: 0)
        guard bytes.count <= 12 * 1024 * 1024 else { throw Failure.tooLarge }

        let templatePath = template.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destination.pathExtension.lowercased() == "mindnode",
              templatePath != destinationPath,
              !destinationPath.hasPrefix(templatePath + "/") else { throw Failure.unsupported }
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else { throw Failure.destinationExists }
        // Reject symbolic links throughout the selected template before copying it.
        guard let enumerator = fileManager.enumerator(at: template, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]) else {
            throw Failure.malformed
        }
        var fileCount = 0
        var totalSize = 0
        for case let file as URL in enumerator {
            fileCount += 1
            guard fileCount <= 2048 else { throw Failure.tooLarge }
            let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
            guard info.isSymbolicLink != true else { throw Failure.malformed }
            if info.isDirectory != true { totalSize += info.fileSize ?? 0 }
            guard totalSize <= 96 * 1024 * 1024 else { throw Failure.tooLarge }
        }
        // Stage the complete package beside the destination. On an export
        // collision or write failure, remove ONLY our random staging directory.
        // Never delete a destination another app may have created concurrently.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".pks-notes-\(UUID().uuidString).mindnode", isDirectory: true)
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }
        try fileManager.copyItem(at: template, to: staging)
        try bytes.write(to: staging.appendingPathComponent("contents.xml"), options: .atomic)
        // The new outline contains no attachments; carrying forward the
        // template's private images and stale preview would leak unrelated data.
        for folder in ["resources", "QuickLook"] {
            let oldData = staging.appendingPathComponent(folder, isDirectory: true)
            if fileManager.fileExists(atPath: oldData.path) {
                try fileManager.removeItem(at: oldData)
            }
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw Failure.destinationExists
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    private struct ExportTopic {
        var title: String
        var children: [ExportTopic]
    }

    private static func exportTopic(_ markdown: String) throws -> ExportTopic {
        let lines = markdown.components(separatedBy: "\n")
        let topics = MindMapOutline.nodes(in: markdown)
        guard !topics.isEmpty, topics.first?.depth == 0, topics.count <= 10_000 else {
            throw Failure.notOutline
        }
        guard topics.allSatisfy({ $0.depth < 64 }) else { throw Failure.tooDeep }
        let topicLines = Set(topics.map(\.id))
        // Do not silently downgrade Markdown tasks, linked notes, or images
        // into plain textual node titles. OPML remains the interchange option.
        let richTitlePattern = #"(?:!\[[^\]]*\]\([^)]+\)|\[\[[^\]]+\]\]|\[[^\]]+\]\([^)]+\)|^\[[ xX]\](?:\s|$))"#
        guard topics.allSatisfy({ topic in
            topic.title.range(of: richTitlePattern, options: .regularExpression) == nil
        }) else { throw Failure.notOutline }
        // Native export is intentionally strict: never silently drop prose,
        // tasks, images, fenced code, or other content from a user document.
        for (index, line) in lines.enumerated() {
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !topicLines.contains(index) {
                throw Failure.notOutline
            }
        }
        var cursor = 0
        func parse() throws -> ExportTopic {
            let current = topics[cursor]
            cursor += 1
            var children: [ExportTopic] = []
            while cursor < topics.count && topics[cursor].depth > current.depth {
                guard topics[cursor].depth == current.depth + 1 else { throw Failure.notOutline }
                children.append(try parse())
            }
            return ExportTopic(title: current.title, children: children)
        }
        let root = try parse()
        guard cursor == topics.count else { throw Failure.notOutline }
        return root
    }

    /// Preserve source URLs attached to rich-text node titles. A link is emitted
    /// as body Markdown beside its visible title; the existing MindMapOutline
    /// link extractor then makes it available from that same node.
    /// Unsafe schemes remain plain title text and are not activated.
    private static func titleLinks(_ html: String) -> [(label: String, target: String)] {
        let pattern = #"(?is)<a\b([^>]*)>(.*?)</a\s*>"#
        let hrefPattern = #"(?i)\bhref\s*=\s*(['"])(.*?)\1"#
        guard let anchors = try? NSRegularExpression(pattern: pattern),
              let hrefs = try? NSRegularExpression(pattern: hrefPattern) else { return [] }
        let source = html as NSString
        return anchors.matches(in: html, range: NSRange(location: 0, length: source.length))
            .compactMap { match -> (label: String, target: String)? in
                guard match.range(at: 1).location != NSNotFound,
                      match.range(at: 2).location != NSNotFound else { return nil }
                let attrs = source.substring(with: match.range(at: 1))
                let attrsSource = attrs as NSString
                guard let href = hrefs.firstMatch(
                    in: attrs, range: NSRange(location: 0, length: attrsSource.length)
                ), href.range(at: 2).location != NSNotFound else { return nil }
                let originalURL = decodeHTMLEntities(attrsSource.substring(with: href.range(at: 2)))
                guard let parsed = URL(string: originalURL),
                      ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                      parsed.host != nil else { return nil }
                let label = plainTitle(source.substring(with: match.range(at: 2)))
                guard !label.isEmpty else { return nil }
                return (
                    label.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "[", with: "\\[")
                         .replacingOccurrences(of: "]", with: "\\]"),
                    originalURL.replacingOccurrences(of: "(", with: "%28")
                               .replacingOccurrences(of: ")", with: "%29")
                )
            }
    }

    private static func decodeHTMLEntities(_ string: String) -> String {
        let entities = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")
        ]
        return entities.reduce(string) { value, pair in
            value.replacingOccurrences(of: pair.0, with: pair.1)
        }
    }

    /// MindNode notes are HTML paragraphs, commonly with Cocoa font spans.
    /// Keep paragraph boundaries and all readable text rather than discarding
    /// the note. Formatting remains in the untouched source package.
    private static func noteParagraphs(_ html: String) -> [String] {
        let parts = html.replacingOccurrences(
            of: #"(?i)</p\s*>"#, with: "\n", options: .regularExpression
        ).components(separatedBy: "\n")
        let decoded = parts.map(plainTitle)
        if decoded.allSatisfy(\.isEmpty) { return [] }
        return decoded.last?.isEmpty == true ? Array(decoded.dropLast()) : decoded
    }

    /// MindNode stores small HTML fragments in titles and note paragraphs.
    /// Decode display text only; the native package retains rich styling.
    private static func plainTitle(_ html: String) -> String {
        let linebreaks = html.replacingOccurrences(
            of: #"(?i)<\s*(br\s*/?|/p|/div|/li)\s*>"#,
            with: " ", options: .regularExpression
        )
        let stripped = linebreaks.replacingOccurrences(
            of: "<[^>]*>", with: "", options: .regularExpression
        )
        let decoded = decodeHTMLEntities(stripped)
        return decoded.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
