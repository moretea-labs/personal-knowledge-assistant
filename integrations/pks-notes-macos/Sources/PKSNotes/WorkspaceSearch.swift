import Foundation
import Darwin

/// An on-demand read of the existing workspace directory projection. No database,
/// background hydration, or second document authority is introduced.
enum WorkspaceSearch {
    struct Entry: Sendable {
        let url: URL
        let name: String
        let isMarkdown: Bool

        init(_ entry: NoteTreePresentation.QuickOpenEntry) {
            url = entry.item.url
            name = entry.item.name
            isMarkdown = entry.item.isMarkdown
        }
    }

    struct Coverage: Sendable {
        var readFiles = 0
        var skippedFiles = 0
        var limited = false
    }

    struct Result: Sendable {
        var hits: [SearchHit] = []
        var coverage = Coverage()
    }

    struct Limits: Sendable {
        var files = 2_000
        var bytesPerFile = 512 * 1_024
        var totalBytes = 32 * 1_024 * 1_024
        var results = 50
    }

    static func search(
        entries: [Entry], root: URL, query: String,
        draftURL: URL? = nil, draft: String? = nil, limits: Limits = Limits()
    ) -> Result {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty, limits.results > 0 else { return Result() }
        var result = Result()
        var ranked: [(hit: SearchHit, rank: Int, order: Int)] = []
        var remainingBytes = max(0, limits.totalBytes)
        var attemptedFiles = 0

        for (order, entry) in entries.enumerated() {
            if Task.isCancelled { break }
            let item = entry
            guard WorkspaceFiles.contains(item.url, in: root),
                  WorkspaceFiles.fileStamp(item.url) != nil else { continue }
            let path = String(item.url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            let nameMatch = terms.allSatisfy { contains(path, $0) }
            var content: String?
            if item.isMarkdown {
                if item.url == draftURL, let draft {
                    content = draft
                } else if WorkspaceFiles.isDataless(item.url) {
                    result.coverage.skippedFiles += 1
                } else if attemptedFiles >= limits.files || remainingBytes <= 0 {
                    result.coverage.limited = true
                    result.coverage.skippedFiles += 1
                } else {
                    attemptedFiles += 1
                    let budget = min(max(0, limits.bytesPerFile), remainingBytes)
                    if let read = readLocalMarkdown(item.url, maxBytes: budget) {
                        remainingBytes -= read.bytes
                        result.coverage.readFiles += 1
                        content = read.text
                    } else {
                        result.coverage.skippedFiles += 1
                    }
                }
            }
            let contentMatch = content.map { body in
                terms.allSatisfy { contains(path, $0) || contains(body, $0) }
            } ?? false
            guard nameMatch || contentMatch else { continue }
            let rank = contains(item.name, query) ? 0 : nameMatch ? 1 : 2
            let hit = SearchHit(
                documentId: "workspace:" + item.url.path, chunkId: nil,
                title: item.name, uri: item.url.path, sourceType: "local",
                snippet: content.map { excerpt($0, terms: terms) }, score: nil, headingPath: nil
            )
            ranked.append((hit, rank, order))
        }
        ranked.sort { $0.rank == $1.rank ? $0.order < $1.order : $0.rank < $1.rank }
        result.coverage.limited = result.coverage.limited || ranked.count > limits.results
        result.hits = ranked.prefix(limits.results).map(\.hit)
        return result
    }

    static func merging(local: [SearchHit], remote: [SearchHit]) -> [SearchHit] {
        let localPaths = Set(local.map(\.uri))
        let remoteByPath = Dictionary(grouping: remote.compactMap { hit -> SearchHit? in
            guard let path = hit.localFileURL?.path, localPaths.contains(path) else { return nil }
            return hit
        }, by: { $0.localFileURL!.path })
        return local.flatMap { remoteByPath[$0.uri] ?? [$0] }
            + remote.filter { hit in
                guard let path = hit.localFileURL?.path else { return true }
                return !localPaths.contains(path)
            }
    }

    private static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func excerpt(_ text: String, terms: [String]) -> String {
        let match = terms.compactMap {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound
        }.min() ?? text.startIndex
        let start = text.index(match, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 240, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + String(text[start..<end])
            + (end < text.endIndex ? "…" : "")
    }

    private static func readLocalMarkdown(_ url: URL, maxBytes: Int) -> (text: String, bytes: Int)? {
        guard maxBytes > 0 else { return nil }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_flags & UInt32(SF_DATALESS) == 0,
              info.st_size <= maxBytes,
              let data = try? file.read(upToCount: maxBytes + 1), data.count <= maxBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, data.count)
    }
}
