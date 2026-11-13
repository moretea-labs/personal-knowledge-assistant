import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Read-only XMind import from a bounded single ZIP entry. The original .xmind
/// archive is never extracted to disk or modified. Content remains a Markdown
/// outline once the user chooses to import it into Leafspan.
enum XMindPackage {
    enum Failure: LocalizedError {
        case unsupported, malformed, missingEntry, tooLarge, tooDeep, failedToRead, unsupportedAttachment

        var errorDescription: String? {
            switch self {
            case .unsupported: "This is not an XMind archive with a supported content.json or content.xml."
            case .malformed: "This XMind document has no readable topic hierarchy."
            case .missingEntry: "The requested entry is missing from this XMind archive."
            case .tooLarge: "The XMind archive or its topic data exceeds the safe import limit."
            case .tooDeep: "This XMind map is nested too deeply (maximum 64 levels)."
            case .failedToRead: "The XMind archive could not be read. Try exporting it as OPML from XMind."
            case .unsupportedAttachment: "An embedded XMind image is missing, unsafe, or not a supported PNG, JPEG, or TIFF. The import was not written."
            }
        }
    }

    private struct Topic {
        let title: String
        let noteParagraphs: [String]
        let imageMarkers: [String]
        let children: [Topic]
    }

    struct ImportedDocument {
        let markdown: String
        let images: [MindNodePackage.ImportedImage]
    }

    static func importOutline(from url: URL) throws -> String {
        try readDocument(from: url, includeImages: false).markdown
    }

    static func importDocument(from url: URL) throws -> ImportedDocument {
        try readDocument(from: url, includeImages: true)
    }

    private static func readDocument(from url: URL, includeImages: Bool) throws -> ImportedDocument {
        guard url.pathExtension.lowercased() == "xmind" else { throw Failure.unsupported }
        guard let location = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ), location.isRegularFile == true, location.isSymbolicLink != true else {
            throw Failure.malformed
        }
        guard let fileSize = location.fileSize,
              fileSize <= 64 * 1_024 * 1_024,
              let archive = try? Data(contentsOf: url, options: .mappedIfSafe),
              archive.count <= 64 * 1_024 * 1_024 else { throw Failure.tooLarge }

        let data: Data
        let legacy: Bool
        do {
            data = try readZipEntry("content.json", from: archive)
            legacy = false
        } catch Failure.missingEntry {
            do {
                data = try readZipEntry("content.xml", from: archive)
                legacy = true
            } catch Failure.missingEntry {
                throw Failure.unsupported
            }
        }

        let imageImporter = EmbeddedImageImporter(archive: archive, includeImages: includeImages)
        if legacy {
            let sheets = try LegacyContentParser(imageImporter: imageImporter).parse(data)
            guard !sheets.isEmpty else { throw Failure.malformed }
            return ImportedDocument(markdown: makeOutline(sheets), images: imageImporter.images)
        }

        let sheets = try readJSON(data, imageImporter: imageImporter)
        guard !sheets.isEmpty else { throw Failure.malformed }
        return ImportedDocument(markdown: makeOutline(sheets), images: imageImporter.images)
    }

    /// Preserve XMind-specific error reporting while sharing the bounded ZIP reader.
    private static func readZipEntry(_ name: String, from bytes: Data) throws -> Data {
        do {
            return try BoundedZipArchive.readEntry(name, from: bytes)
        } catch BoundedZipArchive.Failure.tooLarge {
            throw Failure.tooLarge
        } catch BoundedZipArchive.Failure.unsupported {
            throw Failure.unsupported
        } catch BoundedZipArchive.Failure.notFound {
            throw Failure.missingEntry
        } catch BoundedZipArchive.Failure.failedToRead {
            throw Failure.failedToRead
        } catch {
            throw Failure.malformed
        }
    }

    private static func embeddedResourcePath(from source: String) throws -> String? {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = value.hasPrefix("xap:") ? String(value.dropFirst(4)) : value
        guard path.hasPrefix("resources/") || path.hasPrefix("attachments/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == "resources" || components[0] == "attachments",
              components[1].range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
                options: .regularExpression
              ) != nil else { throw Failure.unsupportedAttachment }
        return path
    }

    /// Preserve PNG bytes; normalize bounded single-frame JPEG/TIFF resources to
    /// PNG so the existing Markdown attachment writer remains the sole file writer.
    private static func normalizedPNG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let sourceType = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier].contains(sourceType),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= 10_000, height <= 10_000,
              width <= 16_000_000 / height,
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
              ) else { return nil }

        if sourceType == UTType.png.identifier { return data }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              output.length > 0, output.length <= 5 * 1024 * 1024 else { return nil }
        return output as Data
    }

    /// One bounded importer owns archive image validation, normalization and deduplication
    /// for both current JSON and legacy XML package formats.
    private final class EmbeddedImageImporter {
        let archive: Data
        let includeImages: Bool
        private(set) var images: [MindNodePackage.ImportedImage] = []
        private var markersByPath: [String: String] = [:]
        private var totalImageBytes = 0

        init(archive: Data, includeImages: Bool) {
            self.archive = archive
            self.includeImages = includeImages
        }

        func marker(for source: String) throws -> String? {
            guard includeImages,
                  let path = try XMindPackage.embeddedResourcePath(from: source) else { return nil }
            if let existing = markersByPath[path] { return existing }
            guard images.count < 64 else { throw Failure.tooLarge }

            let sourceImage: Data
            do {
                sourceImage = try XMindPackage.readZipEntry(path, from: archive)
            } catch Failure.tooLarge {
                throw Failure.tooLarge
            } catch {
                throw Failure.unsupportedAttachment
            }
            guard sourceImage.count <= 5 * 1024 * 1024,
                  let png = XMindPackage.normalizedPNG(from: sourceImage) else {
                throw Failure.unsupportedAttachment
            }
            guard png.count <= 20 * 1024 * 1024 - totalImageBytes else {
                throw Failure.tooLarge
            }

            let marker = "__LEAFSPAN_XMIND_IMAGE_\(UUID().uuidString)__"
            images.append(MindNodePackage.ImportedImage(
                marker: marker,
                stem: "xmind-image-\(images.count + 1)",
                png: png
            ))
            markersByPath[path] = marker
            totalImageBytes += png.count
            return marker
        }
    }

    private static func readJSON(
        _ data: Data,
        imageImporter: EmbeddedImageImporter
    ) throws -> [Topic] {
        guard let sheets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw Failure.malformed }
        var count = 0

        func oneLine(_ value: String) -> String {
            value.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func hrefParagraph(_ href: String) -> String {
            let value = oneLine(href)
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
                return MindMapOutline.escapeInlineText("Link reference: \(value)")
            }
            if scheme == "http" || scheme == "https" {
                let target = value.replacingOccurrences(of: " ", with: "%20")
                    .replacingOccurrences(of: ")", with: "%29")
                return "[Open link](\(target))"
            }
            if scheme == "xmind" {
                return MindMapOutline.escapeInlineText("XMind topic reference: \(url.fragment ?? value)")
            }
            if scheme == "xap" {
                return MindMapOutline.escapeInlineText("Attachment reference: \(value)")
            }
            return MindMapOutline.escapeInlineText("Link reference: \(value)")
        }

        func walk(
            _ object: [String: Any],
            depth: Int,
            topicTitles: inout [String: String]
        ) throws -> Topic {
            guard depth < 64 else { throw Failure.tooDeep }
            count += 1
            guard count <= 10_000,
                  let title = object["title"] as? String else { throw Failure.malformed }
            if let id = object["id"] as? String, !id.isEmpty {
                topicTitles[id] = oneLine(title)
            }

            let plainNote = ((object["notes"] as? [String: Any])?["plain"] as? [String: Any])?["content"] as? String
            var paragraphs = plainNote?.components(separatedBy: .newlines)
                .map { MindMapOutline.escapeInlineText($0) } ?? []
            var imageMarkers: [String] = []
            if let labels = object["labels"] as? String, !oneLine(labels).isEmpty {
                paragraphs.append(MindMapOutline.escapeInlineText("Labels: \(oneLine(labels))"))
            }
            if let markers = object["markers"] as? [[String: Any]] {
                let markerIDs = markers.compactMap { $0["markerId"] as? String }
                    .map(oneLine).filter { !$0.isEmpty }
                if !markerIDs.isEmpty {
                    paragraphs.append(MindMapOutline.escapeInlineText("Markers: \(markerIDs.joined(separator: ", "))"))
                }
            }
            if let href = object["href"] as? String, !oneLine(href).isEmpty {
                paragraphs.append(hrefParagraph(href))
            }
            if let image = object["image"] as? [String: Any],
               let source = image["src"] as? String, !oneLine(source).isEmpty {
                if let marker = try imageImporter.marker(for: source) {
                    imageMarkers.append(marker)
                } else {
                    paragraphs.append(MindMapOutline.escapeInlineText("Image reference: \(oneLine(source))"))
                }
            }

            let childGroups = object["children"] as? [String: Any] ?? [:]
            var parsedChildren: [Topic] = []
            for kind in ["attached", "detached", "summary", "callout"] {
                for child in (childGroups[kind] as? [[String: Any]] ?? []) {
                    let parsed = try walk(child, depth: depth + 1, topicTitles: &topicTitles)
                    if kind == "summary" {
                        parsedChildren.append(Topic(
                            title: "[Summary] \(parsed.title)",
                            noteParagraphs: parsed.noteParagraphs,
                            imageMarkers: parsed.imageMarkers,
                            children: parsed.children
                        ))
                    } else if kind == "callout" {
                        parsedChildren.append(Topic(
                            title: "[Callout] \(parsed.title)",
                            noteParagraphs: parsed.noteParagraphs,
                            imageMarkers: parsed.imageMarkers,
                            children: parsed.children
                        ))
                    } else {
                        parsedChildren.append(parsed)
                    }
                }
            }
            return Topic(
                title: title, noteParagraphs: paragraphs,
                imageMarkers: imageMarkers, children: parsedChildren
            )
        }

        return try sheets.map { sheet in
            guard let root = sheet["rootTopic"] as? [String: Any] else { throw Failure.malformed }
            var topicTitles: [String: String] = [:]
            let parsedRoot = try walk(root, depth: 0, topicTitles: &topicTitles)
            var paragraphs = parsedRoot.noteParagraphs
            if let title = sheet["title"] as? String, !oneLine(title).isEmpty {
                paragraphs.insert(MindMapOutline.escapeInlineText("Sheet: \(oneLine(title))"), at: 0)
            }
            let relationships = sheet["relationships"] as? [[String: Any]] ?? []
            guard relationships.count <= 10_000 else { throw Failure.tooLarge }
            for relationship in relationships {
                guard let firstID = relationship["end1Id"] as? String,
                      let secondID = relationship["end2Id"] as? String else { continue }
                let first = topicTitles[firstID] ?? firstID
                let second = topicTitles[secondID] ?? secondID
                let title = (relationship["title"] as? String).map(oneLine) ?? ""
                let suffix = title.isEmpty ? "" : " — \(title)"
                paragraphs.append(MindMapOutline.escapeInlineText("Relationship: \(first) ↔ \(second)\(suffix)"))
            }
            return Topic(
                title: parsedRoot.title,
                noteParagraphs: paragraphs,
                imageMarkers: parsedRoot.imageMarkers,
                children: parsedRoot.children
            )
        }
    }

    private static func makeOutline(_ roots: [Topic]) -> String {
        var lines: [String] = []
        func emitNote(_ paragraphs: [String], indent: String) {
            for paragraph in paragraphs {
                lines.append(indent + (paragraph.isEmpty ? ">" : "> " + paragraph))
            }
        }
        func emitImages(_ markers: [String], indent: String) {
            for marker in markers {
                lines.append(indent + "![XMind image](" + marker + ")")
            }
        }
        func emit(_ topic: Topic, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            lines.append(indent + "- " + MindMapOutline.escapeInlineText(topic.title))
            emitNote(topic.noteParagraphs, indent: indent + "  ")
            emitImages(topic.imageMarkers, indent: indent + "  ")
            for child in topic.children { emit(child, depth: depth + 1) }
        }
        if roots.count == 1 {
            lines.append("# " + MindMapOutline.escapeInlineText(roots[0].title))
            emitNote(roots[0].noteParagraphs, indent: "")
            emitImages(roots[0].imageMarkers, indent: "")
            for child in roots[0].children { emit(child, depth: 0) }
        } else {
            lines.append("# Mind Maps")
            for topic in roots { emit(topic, depth: 0) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// XMind legacy content.xml. Plain notes and embedded xap:attachments are
    /// imported; styling and relationships remain in the untouched source archive.
    private final class LegacyContentParser: NSObject, XMLParserDelegate {
        private final class MutableTopic {
            var title = ""
            var note = ""
            var imageReferences: [String] = []
            var imageMarkers: [String] = []
            var children: [MutableTopic] = []
        }

        private let imageImporter: EmbeddedImageImporter
        private var roots: [MutableTopic] = []
        private var stack: [MutableTopic] = []
        private var titleBuffer: String?
        private var noteBuffer: String?
        private var count = 0
        private var failure: Failure?

        init(imageImporter: EmbeddedImageImporter) {
            self.imageImporter = imageImporter
        }

        func parse(_ data: Data) throws -> [Topic] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldResolveExternalEntities = false
            guard parser.parse(), failure == nil else { throw failure ?? .malformed }
            func freeze(_ node: MutableTopic) -> Topic {
                var paragraphs = node.note.isEmpty
                    ? []
                    : node.note.components(separatedBy: .newlines).map { MindMapOutline.escapeInlineText($0) }
                paragraphs.append(contentsOf: node.imageReferences.map { MindMapOutline.escapeInlineText($0) })
                return Topic(
                    title: node.title,
                    noteParagraphs: paragraphs,
                    imageMarkers: node.imageMarkers,
                    children: node.children.map(freeze)
                )
            }
            return roots.map(freeze)
        }

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let key = name.split(separator: ":").last.map(String.init) ?? name
            switch key {
            case "topic":
                guard stack.count < 64 else { failure = .tooDeep; parser.abortParsing(); return }
                count += 1
                guard count <= 10_000 else { failure = .tooLarge; parser.abortParsing(); return }
                let topic = MutableTopic()
                if let parent = stack.last { parent.children.append(topic) }
                else { roots.append(topic) }
                stack.append(topic)
            case "title":
                if !stack.isEmpty { titleBuffer = "" }
            case "plain":
                if !stack.isEmpty { noteBuffer = "" }
            case "img":
                guard let topic = stack.last else { return }
                let source = attributes["xhtml:src"] ?? attributes["src"]
                    ?? attributes["xlink:href"] ?? attributes["href"]
                guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                do {
                    if let marker = try imageImporter.marker(for: source) {
                        topic.imageMarkers.append(marker)
                    } else {
                        topic.imageReferences.append("Image reference: \(source)")
                    }
                } catch {
                    failure = error as? Failure ?? .unsupportedAttachment
                    parser.abortParsing()
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters value: String) {
            if titleBuffer != nil { titleBuffer! += value }
            if noteBuffer != nil { noteBuffer! += value }
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let key = name.split(separator: ":").last.map(String.init) ?? name
            if key == "title", let titleBuffer, let last = stack.last {
                last.title = titleBuffer
                self.titleBuffer = nil
            } else if key == "plain", let noteBuffer, let last = stack.last {
                last.note = noteBuffer
                self.noteBuffer = nil
            } else if key == "topic", !stack.isEmpty {
                stack.removeLast()
            }
        }
    }
}
