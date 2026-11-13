import Foundation

/// Read-only importer for MindNode Classic binary-plist and Next Contents.data packages.
/// Classic schemas are version 7/9; Next's verified Metadata.json fileFormatVersion is 1.
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
            case .unsupported: "Only verified MindNode Classic versions 7/9 and Next file format 1 are supported."
            case .malformed: "This is not a valid MindNode package with a readable node tree."
            case .tooLarge: "The MindNode node data is too large (maximum 12 MB)."
            case .tooDeep: "This MindNode outline is nested too deeply (maximum 64 levels)."
            case .notOutline: "Native MindNode export requires one root and only Markdown heading/list nodes. Use OPML to exchange a larger note."
            case .destinationExists: "The destination already exists; choose a new filename to avoid overwriting existing mind maps."
            case .unsupportedAttachment: "MindNode attachment is unavailable or unsupported. The import was not written."
            }
        }
    }

    struct ImportedImage {
        let marker: String
        let stem: String
        let png: Data
    }

    struct ImportedPDF {
        let marker: String
        let stem: String
        let data: Data
    }

    struct ImportedDocument {
        let markdown: String
        let images: [ImportedImage]
        let pdfs: [ImportedPDF]
    }

    static func importOutline(from url: URL) throws -> String {
        try readDocument(from: url, includeAttachments: false).markdown
    }

    static func importDocument(from url: URL) throws -> ImportedDocument {
        try readDocument(from: url, includeAttachments: true)
    }

    private static func readDocument(from url: URL, includeAttachments: Bool) throws -> ImportedDocument {
        let location = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard location.isSymbolicLink != true else { throw Failure.malformed }
        if location.isDirectory == true {
            let nextContents = url.appendingPathComponent("Contents.data")
            let nextMetadata = url.appendingPathComponent("Metadata.json")
            if FileManager.default.fileExists(atPath: nextContents.path),
               FileManager.default.fileExists(atPath: nextMetadata.path) {
                return try readNextDocument(from: url, includeAttachments: includeAttachments)
            }
        }

        let archiveData: Data?
        let document: [String: Any]
        if location.isDirectory == true {
            archiveData = nil
            document = try readSupportedPackage(from: url)
        } else {
            guard location.isRegularFile == true else { throw Failure.malformed }
            let archive = try readSingleFileArchive(from: url, fileSize: location.fileSize)
            let contents = try readArchiveEntry("contents.xml", from: archive)
            archiveData = archive
            document = try readSupportedPackage(contentsData: contents)
        }
        // Classic directory packages may contain a resources folder symlink.
        // Validate the parent before inspecting any attachment file: checking only
        // the final file would follow a symlinked directory into an external path.
        if includeAttachments, archiveData == nil {
            let resources = url.appendingPathComponent("resources", isDirectory: true)
            if FileManager.default.fileExists(atPath: resources.path) {
                let values = try resources.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw Failure.unsupportedAttachment
                }
            }
        }

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
            let taskMarker: String?
            let children: [ImportedTopic]
        }

        var images: [ImportedImage] = []
        func isBuiltInSticker(_ attachment: Any?) -> Bool {
            guard let info = attachment as? [String: Any],
                  info["type"] as? Int == 3,
                  let filename = info["fileName"] as? String,
                  filename.range(
                    of: #"^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}\.pdf$"#,
                    options: .regularExpression
                  ) != nil,
                  let clipArtName = info["clipArtName"] as? String,
                  clipArtName.range(
                    of: #"^[A-Za-z0-9_-]+\.pdf$"#,
                    options: .regularExpression
                  ) != nil else { return false }
            return true
        }
        var seen = 0
        func attachedImage(_ node: [String: Any]) throws -> String? {
            guard includeAttachments, let attachment = node["attachment"] else { return nil }
            // Classic stores built-in PDF stickers as type-3 clip art. They are
            // presentation metadata, not user documents; keep the source intact
            // and omit them from Markdown instead of rejecting the whole map.
            if isBuiltInSticker(attachment) { return nil }
            guard let info = attachment as? [String: Any],
                  let filename = info["fileName"] as? String,
                  filename.range(of: #"^[a-zA-Z0-9_-]+\.png$"#, options: .regularExpression) != nil,
                  images.count < 32 else { throw Failure.unsupportedAttachment }
            let png: Data
            if let archiveData {
                do {
                    png = try readArchiveEntry("resources/\(filename)", from: archiveData)
                } catch Failure.tooLarge {
                    throw Failure.tooLarge
                } catch {
                    throw Failure.unsupportedAttachment
                }
                guard !png.isEmpty, png.count <= 5 * 1024 * 1024 else {
                    throw Failure.unsupportedAttachment
                }
            } else {
                let source = url.appendingPathComponent("resources", isDirectory: true)
                    .appendingPathComponent(filename)
                let attributes = try source.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      let size = attributes.fileSize, size > 0, size <= 5 * 1024 * 1024 else {
                    throw Failure.unsupportedAttachment
                }
                png = try Data(contentsOf: source)
                guard png.count == size else { throw Failure.unsupportedAttachment }
            }
            guard png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
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

            // MindNode Classic stores task status in node.task.state:
            // 1 = open, 2 = completed. The uuids map is Reminders sync metadata,
            // not part of the Markdown task's canonical state.
            let taskMarker: String?
            if let rawTask = node["task"] {
                guard let task = rawTask as? [String: Any],
                      let state = task["state"] as? Int else { throw Failure.malformed }
                switch state {
                case 0: taskMarker = nil
                case 1: taskMarker = "[ ]"
                case 2: taskMarker = "[x]"
                default: throw Failure.malformed
                }
            } else {
                taskMarker = nil
            }

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
                        taskMarker: taskMarker,
                        children: visibleChildren
                    )]
                }
            }

            // Untitled layout nodes do not become Markdown topics. Never
            // silently drop an attachment or note carried by such a node.
            let hasUnsupportedAttachment = node["attachment"] != nil
                && !isBuiltInSticker(node["attachment"])
            guard node["note"] == nil, !hasUnsupportedAttachment, node["task"] == nil else {
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
                // Notes are imported as plain text, so Markdown syntax must remain literal.
                // Nested notes stay inside their list item when the branch moves.
                let escaped = MindMapOutline.escapeInlineText(paragraph)
                lines.append(indent + (escaped.isEmpty ? ">" : "> " + escaped))
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
        func emitTopic(_ topic: ImportedTopic, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let taskPrefix = topic.taskMarker.map { $0 + " " } ?? ""
            lines.append(indent + "- " + taskPrefix + MindMapOutline.escapeInlineText(topic.title))
            emitNote(topic.noteParagraphs, indent: indent + "  ")
            emitLinks(topic.titleLinks, indent: indent + "  ")
            emitImage(topic.imageMarker, indent: indent + "  ")
            emitChildren(topic.children, depth: depth + 1)
        }
        func emitChildren(_ children: [ImportedTopic], depth: Int) {
            for child in children {
                emitTopic(child, depth: depth)
            }
        }

        if roots.count == 1, topics.count == 1 {
            let root = topics[0]
            if let taskMarker = root.taskMarker {
                // A task root is a Markdown list root; headings cannot carry
                // CommonMark task-list semantics.
                lines.append("- " + taskMarker + " " + MindMapOutline.escapeInlineText(root.title))
                emitNote(root.noteParagraphs, indent: "  ")
                emitLinks(root.titleLinks, indent: "  ")
                emitImage(root.imageMarker, indent: "  ")
                emitChildren(root.children, depth: 1)
            } else {
                lines.append("# " + MindMapOutline.escapeInlineText(root.title))
                emitNote(root.noteParagraphs, indent: "")
                emitLinks(root.titleLinks, indent: "")
                emitImage(root.imageMarker, indent: "")
                emitChildren(root.children, depth: 0)
            }
        } else {
            lines.append("# Mind Maps")
            emitChildren(topics, depth: 0)
        }
        return ImportedDocument(markdown: lines.joined(separator: "\n") + "\n",
                                images: images, pdfs: [])
    }

    private struct NextField {
        let tag: Int
        let number: UInt64?
        let bytes: Data?
    }

    private struct NextMessage {
        private let fields: [NextField]

        init(_ data: Data, budget: inout Int) throws {
            var result: [NextField] = []
            var offset = 0
            while offset < data.count {
                budget -= 1
                guard budget >= 0 else { throw Failure.tooLarge }
                let key = try Self.varint(data, offset: &offset)
                guard key >= 8, key <= UInt64(UInt32.max) else { throw Failure.malformed }
                let tag = Int(key >> 3)
                switch Int(key & 7) {
                case 0:
                    result.append(NextField(tag: tag, number: try Self.varint(data, offset: &offset), bytes: nil))
                case 1:
                    guard data.count - offset >= 8 else { throw Failure.malformed }
                    offset += 8
                case 2:
                    let length = try Self.varint(data, offset: &offset)
                    guard length <= UInt64(data.count - offset) else { throw Failure.malformed }
                    let end = offset + Int(length)
                    result.append(NextField(tag: tag, number: nil, bytes: data.subdata(in: offset..<end)))
                    offset = end
                case 5:
                    guard data.count - offset >= 4 else { throw Failure.malformed }
                    offset += 4
                default:
                    throw Failure.malformed
                }
            }
            fields = result
        }

        func data(_ tag: Int) -> Data? { fields.first { $0.tag == tag }?.bytes }
        func allData(_ tag: Int) -> [Data] { fields.compactMap { $0.tag == tag ? $0.bytes : nil } }
        func number(_ tag: Int) -> UInt64? { fields.first { $0.tag == tag }?.number }

        private static func varint(_ data: Data, offset: inout Int) throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < data.count else { throw Failure.malformed }
                let byte = data[offset]
                offset += 1
                if shift == 63, byte > 1 { throw Failure.malformed }
                value |= UInt64(byte & 0x7f) << UInt64(shift)
                if byte & 0x80 == 0 { return value }
            }
            throw Failure.malformed
        }
    }

    private struct NextTopic {
        let title: String
        let note: String?
        let order: UInt64
        var children: [String]
        let pdfs: [ImportedPDF]
    }

    private struct VisibleNextTopic {
        let title: String
        let note: String?
        let children: [VisibleNextTopic]
        let pdfs: [ImportedPDF]
    }

    private static func readNextDocument(from url: URL, includeAttachments: Bool) throws -> ImportedDocument {
        guard url.pathExtension.lowercased() == "mindnode" else { throw Failure.unsupported }
        let package = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard package.isDirectory == true, package.isSymbolicLink != true else { throw Failure.malformed }

        func readFile(_ name: String, limit: Int) throws -> Data {
            let file = url.appendingPathComponent(name)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.malformed }
            guard let size = values.fileSize, size > 0, size <= limit else { throw Failure.tooLarge }
            let data = try Data(contentsOf: file)
            guard data.count == size else { throw Failure.malformed }
            return data
        }

        let metadataData = try readFile("Metadata.json", limit: 64 * 1024)
        guard let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              metadata["fileFormatVersion"] as? Int == 1,
              let minimumVersion = metadata["minFileFormatVersionForReading"] as? Int,
              minimumVersion == 1 else { throw Failure.unsupported }

        let assetsURL = url.appendingPathComponent("Assets", isDirectory: true)
        if includeAttachments, FileManager.default.fileExists(atPath: assetsURL.path) {
            let values = try assetsURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw Failure.unsupportedAttachment
            }
        }

        let contents = try readFile("Contents.data", limit: 12 * 1024 * 1024)
        var budget = 300_000
        func message(_ data: Data) throws -> NextMessage { try NextMessage(data, budget: &budget) }
        func identifier(_ data: Data?) -> String? {
            guard let data, data.count == 16 else { return nil }
            return data.map { String(format: "%02x", $0) }.joined()
        }
        func label(_ data: Data) throws -> String {
            let text = try message(data)
            var value = ""
            for spanData in text.allData(1) {
                let span = try message(spanData)
                for runData in span.allData(4) {
                    let run = try message(runData)
                    guard let raw = run.data(1) else { continue }
                    guard let part = String(data: raw, encoding: .utf8), Data(part.utf8) == raw else {
                        throw Failure.malformed
                    }
                    guard part.count <= 10_000 - value.count else { throw Failure.tooLarge }
                    value += part
                }
            }
            return value
        }

        func plainNote(from data: Data) throws -> String? {
            let note = try message(data)
            guard let bodyData = note.data(1) else { throw Failure.malformed }
            let body = try message(bodyData)
            var runs: [String] = []
            var characterCount = 0
            for runData in body.allData(4) {
                let run = try message(runData)
                guard let raw = run.data(1),
                      let part = String(data: raw, encoding: .utf8),
                      Data(part.utf8) == raw else { throw Failure.malformed }
                guard part.count <= 10_000 - characterCount else { throw Failure.tooLarge }
                characterCount += part.count
                runs.append(part)
            }
            let trimmed = runs.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        var importedPDFs: [ImportedPDF] = []
        var referencedAssetNames = Set<String>()
        var totalPDFBytes = 0
        func importedPDF(from attachmentData: Data) throws -> ImportedPDF? {
            let attachment = try message(attachmentData)
            guard let attachmentID = attachment.data(1), identifier(attachmentID) != nil else {
                throw Failure.malformed
            }
            guard let payloadData = attachment.data(2) else {
                // Built-in symbol stickers (field 3) and emoji stickers (field 4)
                // are presentation metadata, not user file attachments.
                if let symbolData = attachment.data(3) {
                    guard attachment.data(4) == nil else { throw Failure.unsupportedAttachment }
                    let sticker = try message(symbolData)
                    guard let rawName = sticker.data(1),
                          let name = String(data: rawName, encoding: .utf8),
                          Data(name.utf8) == rawName,
                          name.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
                          let placementData = sticker.data(3) else {
                        throw Failure.unsupportedAttachment
                    }
                    let placement = try message(placementData)
                    guard placement.data(1)?.count == 18 else { throw Failure.unsupportedAttachment }
                    return nil
                }
                if let emojiData = attachment.data(4) {
                    let sticker = try message(emojiData)
                    guard let rawEmoji = sticker.data(1),
                          let emoji = String(data: rawEmoji, encoding: .utf8),
                          Data(emoji.utf8) == rawEmoji,
                          emoji.count == 1,
                          emoji.unicodeScalars.contains(where: { $0.properties.isEmoji }),
                          let placementData = sticker.data(2) else {
                        throw Failure.unsupportedAttachment
                    }
                    let placement = try message(placementData)
                    guard placement.data(1)?.count == 18 else { throw Failure.unsupportedAttachment }
                    return nil
                }
                throw Failure.unsupportedAttachment
            }
            guard attachment.data(3) == nil, attachment.data(4) == nil else {
                throw Failure.unsupportedAttachment
            }
            let payload = try message(payloadData)
            guard let rawName = payload.data(1),
                  let filename = String(data: rawName, encoding: .utf8),
                  Data(filename.utf8) == rawName,
                  filename.range(
                    of: #"^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}_image\.pdf$"#,
                    options: .regularExpression
                  ) != nil,
                  referencedAssetNames.insert(filename).inserted,
                  importedPDFs.count < 32 else {
                throw Failure.unsupportedAttachment
            }

            let source = assetsURL.appendingPathComponent(filename)
            let values = try source.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 5 * 1024 * 1024 else {
                throw Failure.unsupportedAttachment
            }
            let data = try Data(contentsOf: source)
            guard data.count == size, data.starts(with: Data("%PDF-".utf8)) else {
                throw Failure.unsupportedAttachment
            }
            totalPDFBytes += data.count
            guard totalPDFBytes <= 32 * 1024 * 1024 else { throw Failure.tooLarge }

            let stem = "mindnode-" + String(filename.dropLast("_image.pdf".count))
            let imported = ImportedPDF(
                marker: "__LEAFSPAN_MINDNODE_PDF_\(UUID().uuidString)__",
                stem: stem,
                data: data
            )
            importedPDFs.append(imported)
            return imported
        }

        let archive = try message(contents)
        guard let snapshotData = archive.data(1) else { throw Failure.malformed }
        let snapshot = try message(snapshotData)
        guard let treeIDData = snapshot.data(1), let treeID = identifier(treeIDData),
              let contentData = snapshot.data(2) else { throw Failure.malformed }
        let content = try message(contentData)
        guard let documentData = content.data(1) else { throw Failure.malformed }
        let document = try message(documentData)
        guard let treeData = document.data(3) else { throw Failure.malformed }
        let tree = try message(treeData)
        guard tree.data(1) == treeIDData else { throw Failure.malformed }

        let records = document.allData(2)
        guard !records.isEmpty, records.count <= 10_000 else { throw Failure.tooLarge }
        var topics: [String: NextTopic] = [:]
        for recordData in records {
            let record = try message(recordData)
            guard let nodeID = identifier(record.data(1)), nodeID != treeID,
                  let propertiesData = record.data(2), topics[nodeID] == nil else {
                throw Failure.malformed
            }
            let properties = try message(propertiesData)
            let title = try properties.data(11).map { try label($0) } ?? ""
            let noteData = properties.allData(12).filter { !$0.isEmpty }
            guard noteData.count <= 1 else { throw Failure.malformed }
            let note: String?
            if let data = noteData.first {
                note = try plainNote(from: data)
            } else {
                note = nil
            }
            let pdfs: [ImportedPDF]
            if includeAttachments {
                pdfs = try properties.allData(8).compactMap { try importedPDF(from: $0) }
            } else {
                pdfs = []
            }
            topics[nodeID] = NextTopic(
                title: title, note: note, order: properties.number(7) ?? 0,
                children: [], pdfs: pdfs
            )
        }

        if includeAttachments {
            let assetFiles = FileManager.default.fileExists(atPath: assetsURL.path)
                ? try FileManager.default.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: nil)
                : []
            guard assetFiles.count <= 32,
                  Set(assetFiles.map(\.lastPathComponent)) == referencedAssetNames else {
                throw Failure.unsupportedAttachment
            }
        }

        var roots: [String] = []
        var linked = Set<String>()
        for relationData in tree.allData(2) {
            let relation = try message(relationData)
            guard let nodeData = relation.data(1), let nodeID = identifier(nodeData) else {
                throw Failure.malformed
            }
            if nodeData == treeIDData { continue }
            guard let parentData = relation.data(2), let parentID = identifier(parentData),
                  topics[nodeID] != nil, linked.insert(nodeID).inserted else {
                throw Failure.malformed
            }
            if parentData == treeIDData {
                roots.append(nodeID)
            } else {
                guard topics[parentID] != nil else { throw Failure.malformed }
                topics[parentID]?.children.append(nodeID)
            }
        }
        guard linked.count == topics.count, !roots.isEmpty else { throw Failure.malformed }

        let topicOrders = topics.mapValues(\.order)
        func ordered(_ ids: [String]) -> [String] {
            ids.enumerated().sorted { left, right in
                let a = topicOrders[left.element] ?? 0
                let b = topicOrders[right.element] ?? 0
                return a == b ? left.offset < right.offset : a < b
            }.map(\.element)
        }
        roots = ordered(roots)
        for id in Array(topics.keys) {
            guard var topic = topics[id] else { continue }
            topic.children = ordered(topic.children)
            topics[id] = topic
        }

        var visited = Set<String>()
        func visible(_ id: String, depth: Int) throws -> [VisibleNextTopic] {
            guard depth <= 64 else { throw Failure.tooDeep }
            guard visited.insert(id).inserted, let topic = topics[id] else { throw Failure.malformed }
            let children = try topic.children.flatMap { try visible($0, depth: depth + 1) }
            let title = MindMapOutline.escapeInlineText(topic.title)
            guard !title.isEmpty || (topic.pdfs.isEmpty && topic.note == nil) else {
                throw Failure.malformed
            }
            return title.isEmpty ? children : [
                VisibleNextTopic(title: title, note: topic.note, children: children, pdfs: topic.pdfs)
            ]
        }
        let visibleRoots = try roots.flatMap { try visible($0, depth: 0) }
        guard visited.count == topics.count, !visibleRoots.isEmpty else { throw Failure.malformed }

        var lines: [String] = []
        func emit(_ topics: [VisibleNextTopic], depth: Int) {
            for topic in topics {
                let indent = String(repeating: "  ", count: depth)
                lines.append(indent + "- " + topic.title)
                if let note = topic.note {
                    lines.append(indent + "  > " + MindMapOutline.escapeInlineText(note))
                }
                for pdf in topic.pdfs {
                    lines.append(indent + "  [PDF attachment](\(pdf.marker))")
                }
                emit(topic.children, depth: depth + 1)
            }
        }
        if visibleRoots.count == 1 {
            lines.append("# " + visibleRoots[0].title)
            if let note = visibleRoots[0].note {
                lines.append("> " + MindMapOutline.escapeInlineText(note))
            }
            for pdf in visibleRoots[0].pdfs {
                lines.append("[PDF attachment](\(pdf.marker))")
            }
            emit(visibleRoots[0].children, depth: 0)
        } else {
            let title = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            lines.append("# " + MindMapOutline.escapeInlineText(title))
            emit(visibleRoots, depth: 0)
        }
        return ImportedDocument(
            markdown: lines.joined(separator: "\n") + "\n", images: [], pdfs: importedPDFs
        )
    }

    private static func readSingleFileArchive(from url: URL, fileSize: Int?) throws -> Data {
        guard url.pathExtension.lowercased() == "mindnode" else { throw Failure.unsupported }
        guard let fileSize, fileSize > 0, fileSize <= 64 * 1024 * 1024 else {
            throw Failure.tooLarge
        }
        let archive = try Data(contentsOf: url, options: .mappedIfSafe)
        guard archive.count == fileSize else { throw Failure.malformed }
        return archive
    }

    private static func readArchiveEntry(_ name: String, from archive: Data) throws -> Data {
        do {
            return try BoundedZipArchive.readEntry(name, from: archive)
        } catch BoundedZipArchive.Failure.tooLarge {
            throw Failure.tooLarge
        } catch BoundedZipArchive.Failure.unsupported {
            throw Failure.unsupported
        } catch BoundedZipArchive.Failure.notFound {
            throw Failure.malformed
        } catch BoundedZipArchive.Failure.failedToRead {
            throw Failure.malformed
        } catch {
            throw Failure.malformed
        }
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
        return try readSupportedPackage(contentsData: data)
    }

    private static func readSupportedPackage(contentsData data: Data) throws -> [String: Any] {
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
