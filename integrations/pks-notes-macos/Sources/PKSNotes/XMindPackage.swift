import Foundation

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

    private static func readZipEntry(_ entry: String, from url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { throw Failure.failedToRead }

        var bytes = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024),
                  !chunk.isEmpty {
                if bytes.count + chunk.count > 12 * 1_024 * 1_024 {
                    process.terminate()
                    process.waitUntilExit()
                    throw Failure.tooLarge
                }
                bytes.append(chunk)
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, !bytes.isEmpty else { throw Failure.failedToRead }
        return bytes
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
            return Topic(title: title, children: try branches.map { try walk($0, depth: depth + 1) })
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
        func emit(_ topic: Topic, depth: Int) {
            lines.append(String(repeating: "  ", count: depth) + "- " + singleLine(topic.title))
            for child in topic.children { emit(child, depth: depth + 1) }
        }
        if roots.count == 1 {
            lines.append("# " + singleLine(roots[0].title))
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
            var children: [MutableTopic] = []
        }
        private var roots: [MutableTopic] = []
        private var stack: [MutableTopic] = []
        private var titleBuffer: String?
        private var count = 0
        private var failure: Failure?

        func parse(_ data: Data) throws -> [Topic] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldResolveExternalEntities = false
            guard parser.parse(), failure == nil else { throw failure ?? .malformed }
            func freeze(_ node: MutableTopic) -> Topic {
                Topic(title: node.title, children: node.children.map(freeze))
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
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters value: String) {
            if titleBuffer != nil { titleBuffer! += value }
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let key = name.split(separator: ":").last.map(String.init) ?? name
            if key == "title", let titleBuffer, let last = stack.last {
                last.title = titleBuffer
                self.titleBuffer = nil
            } else if key == "topic", !stack.isEmpty {
                stack.removeLast()
            }
        }
    }
}
