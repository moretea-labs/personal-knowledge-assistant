import Foundation
import zlib

/// Read-only XMind import from a bounded single ZIP entry. The original .xmind
/// archive is never extracted to disk or modified. Content remains a Markdown
/// outline once the user chooses to import it into Leafspan.
enum XMindPackage {
    enum Failure: LocalizedError {
        case unsupported, malformed, tooLarge, tooDeep, failedToRead

        var errorDescription: String? {
            switch self {
            case .unsupported: "This is not an XMind archive with a supported content.json or content.xml."
            case .malformed: "This XMind document has no readable topic hierarchy."
            case .tooLarge: "The XMind archive or its topic data exceeds the safe import limit."
            case .tooDeep: "This XMind map is nested too deeply (maximum 64 levels)."
            case .failedToRead: "The XMind archive could not be read. Try exporting it as OPML from XMind."
            }
        }
    }

    private struct Topic {
        let title: String
        let noteParagraphs: [String]
        let children: [Topic]
    }

    static func importOutline(from url: URL) throws -> String {
        guard url.pathExtension.lowercased() == "xmind",
              let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              fileSize <= 64 * 1_024 * 1_024 else { throw Failure.tooLarge }
        let data: Data
        let legacy: Bool
        if let json = try? readZipEntry("content.json", from: url) {
            data = json
            legacy = false
        } else if let xml = try? readZipEntry("content.xml", from: url) {
            data = xml
            legacy = true
        } else {
            throw Failure.unsupported
        }
        let sheets: [Topic]
        if legacy {
            let collector = LegacyContentParser()
            sheets = try collector.parse(data)
        } else {
            sheets = try readJSON(data)
        }
        guard !sheets.isEmpty else { throw Failure.malformed }
        return makeOutline(sheets)
    }

    /// Read a bounded ZIP entry inside the app sandbox. Never launch a subprocess
    /// or extract archive paths into the user's workspace.
    private static func readZipEntry(_ name: String, from url: URL) throws -> Data {
        guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe),
              bytes.count <= 64 * 1024 * 1024 else { throw Failure.failedToRead }

        func u16(_ i: Int) -> Int? {
            guard i >= 0, i + 2 <= bytes.count else { return nil }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8
        }
        func u32(_ i: Int) -> Int? {
            guard i >= 0, i + 4 <= bytes.count else { return nil }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8
                | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        guard bytes.count >= 22 else { throw Failure.unsupported }
        // A ZIP comment may add up to 65535 bytes after the directory trailer.
        let searchStart = max(0, bytes.count - 22 - 65_535)
        guard let eocd = stride(from: bytes.count - 22, through: searchStart, by: -1).first(where: { index in
            u32(index) == 0x06054b50 &&
                u16(index + 20).map { length in index + 22 + length == bytes.count } == true
        }), let commentLength = u16(eocd + 20),
              eocd + 22 + commentLength == bytes.count,
              u16(eocd + 4) == 0, u16(eocd + 6) == 0,
              let count = u16(eocd + 10), u16(eocd + 8) == count,
              count <= 10_000,
              let centralSize = u32(eocd + 12),
              let centralOffset = u32(eocd + 16),
              centralOffset + centralSize <= eocd else {
            throw Failure.unsupported
        }

        var cursor = centralOffset
        let centralEnd = centralOffset + centralSize
        var selection: (method: Int, compressed: Int, inflated: Int, crc: Int, local: Int)?
        for _ in 0..<count {
            guard cursor + 46 <= centralEnd, u32(cursor) == 0x02014b50,
                  let flags = u16(cursor + 8),
                  let method = u16(cursor + 10),
                  let crc = u32(cursor + 16),
                  let compressed = u32(cursor + 20),
                  let inflated = u32(cursor + 24),
                  let nameLength = u16(cursor + 28),
                  let extras = u16(cursor + 30),
                  let comment = u16(cursor + 32),
                  let local = u32(cursor + 42),
                  cursor + 46 + nameLength + extras + comment <= centralEnd
            else { throw Failure.malformed }

            let rawName = bytes.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            if String(data: rawName, encoding: .utf8) == name {
                guard selection == nil, flags & 1 == 0,
                      method == 0 || method == 8,
                      inflated <= 12 * 1024 * 1024,
                      local + 30 <= bytes.count else { throw Failure.tooLarge }
                selection = (method, compressed, inflated, crc, local)
            }
            cursor += 46 + nameLength + extras + comment
        }
        guard let entry = selection,
              u32(entry.local) == 0x04034b50,
              let filenameLength = u16(entry.local + 26),
              let extraLength = u16(entry.local + 28) else {
            throw Failure.failedToRead
        }
        let start = entry.local + 30 + filenameLength + extraLength
        guard start <= centralOffset,
              entry.compressed <= centralOffset - start else { throw Failure.malformed }
        let compressed = bytes.subdata(in: start..<(start + entry.compressed))
        let inflated: Data
        if entry.method == 0 {
            guard entry.compressed == entry.inflated else { throw Failure.malformed }
            inflated = compressed
        } else {
            guard entry.inflated > 0 else { throw Failure.malformed }
            var result = Data(count: entry.inflated)
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                                Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw Failure.failedToRead
            }
            defer { inflateEnd(&stream) }
            let success = compressed.withUnsafeBytes { input in
                result.withUnsafeMutableBytes { output -> Bool in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_FINISH) == Z_STREAM_END &&
                        Int(stream.total_in) == entry.compressed &&
                        Int(stream.total_out) == entry.inflated
                }
            }
            guard success else { throw Failure.malformed }
            inflated = result
        }
        let checksum = inflated.withUnsafeBytes { buffer in
            crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
        }
        guard checksum == uLong(entry.crc) else { throw Failure.malformed }
        return inflated
    }

    private static func readJSON(_ data: Data) throws -> [Topic] {
        guard let sheets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw Failure.malformed }
        var count = 0
        func walk(_ object: [String: Any], depth: Int) throws -> Topic {
            guard depth < 64 else { throw Failure.tooDeep }
            count += 1
            guard count <= 10_000,
                  let title = object["title"] as? String else { throw Failure.malformed }
            let children = object["children"] as? [String: Any] ?? [:]
            let branches = ["attached", "detached", "summary"].flatMap {
                children[$0] as? [[String: Any]] ?? []
            }
            let plainNote = ((object["notes"] as? [String: Any])?["plain"] as? [String: Any])?["content"] as? String
            let paragraphs = plainNote?.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            return Topic(title: title, noteParagraphs: paragraphs,
                         children: try branches.map { try walk($0, depth: depth + 1) })
        }
        return try sheets.map { sheet in
            guard let root = sheet["rootTopic"] as? [String: Any] else { throw Failure.malformed }
            return try walk(root, depth: 0)
        }
    }

    private static func makeOutline(_ roots: [Topic]) -> String {
        func singleLine(_ title: String) -> String {
            title.components(separatedBy: .newlines)
                .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "#", with: "\\#")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
        }
        var lines: [String] = []
        func emitNote(_ paragraphs: [String], indent: String) {
            for paragraph in paragraphs {
                lines.append(indent + (paragraph.isEmpty ? ">" : "> " + paragraph))
            }
        }
        func emit(_ topic: Topic, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            lines.append(indent + "- " + singleLine(topic.title))
            emitNote(topic.noteParagraphs, indent: indent + "  ")
            for child in topic.children { emit(child, depth: depth + 1) }
        }
        if roots.count == 1 {
            lines.append("# " + singleLine(roots[0].title))
            emitNote(roots[0].noteParagraphs, indent: "")
            for child in roots[0].children { emit(child, depth: 0) }
        } else {
            lines.append("# Mind Maps")
            for topic in roots { emit(topic, depth: 0) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// XMind legacy (pre-2017) content.xml. Each sheet has one topic tree.
    /// Other XML content (style, relationships, notes) is intentionally left
    /// with the untouched .xmind source, not silently labelled as migrated.
    private final class LegacyContentParser: NSObject, XMLParserDelegate {
        private final class MutableTopic {
            var title = ""
            var note = ""
            var children: [MutableTopic] = []
        }
        private var roots: [MutableTopic] = []
        private var stack: [MutableTopic] = []
        private var titleBuffer: String?
        private var noteBuffer: String?
        private var count = 0
        private var failure: Failure?

        func parse(_ data: Data) throws -> [Topic] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldResolveExternalEntities = false
            guard parser.parse(), failure == nil else { throw failure ?? .malformed }
            func freeze(_ node: MutableTopic) -> Topic {
                Topic(title: node.title, noteParagraphs: node.note.isEmpty ? [] : node.note.components(separatedBy: .newlines),
                      children: node.children.map(freeze))
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
