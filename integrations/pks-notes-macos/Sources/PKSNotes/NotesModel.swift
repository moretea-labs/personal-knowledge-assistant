import Foundation
import Darwin
import AppKit
import SwiftUI

struct SearchHit: Decodable, Identifiable {
    let documentId: String
    let chunkId: String?
    let title: String
    let uri: String
    let sourceType: String?
    let snippet: String?
    let score: Double?
    let headingPath: String?

    var id: String { chunkId ?? documentId }

    // PKS indexes both vault files (local) and other user-owned files (managed).
    // Never interpret network/opaque source URIs as local filesystem paths.
    var localFileURL: URL? {
        guard ["local", "managed"].contains(sourceType?.lowercased() ?? ""),
              uri.hasPrefix("/"), !uri.hasPrefix("//"), !uri.contains("\0") else { return nil }
        return URL(fileURLWithPath: uri).standardizedFileURL
    }

    var webURL: URL? {
        guard let url = URL(string: uri),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    var sourceLabel: String {
        if let file = localFileURL {
            return file.path.contains("/Mobile Documents/") ? "iCloud Drive" : "Local file"
        }
        if webURL != nil { return "Web page" }
        return sourceType?.capitalized ?? "PKS source"
    }

    var sourceLocation: String {
        if let file = localFileURL { return file.deletingLastPathComponent().lastPathComponent }
        if let url = webURL { return url.host ?? uri }
        return uri
    }
}

struct ReadResponse: Decodable {
    let content: String
    let truncated: Bool?
}

struct NoteItem: Identifiable, Hashable {
    let url: URL
    let children: [NoteItem]?

    var id: String { url.path }
    var isFolder: Bool { children != nil }
    var isMarkdown: Bool { !isFolder && ["md", "markdown"].contains(url.pathExtension.lowercased()) }
    var isPDF: Bool { !isFolder && url.pathExtension.lowercased() == "pdf" }
    var name: String { isFolder ? url.lastPathComponent : isMarkdown ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }
    var iconName: String { isFolder ? "folder" : isPDF ? "doc.richtext" : isMarkdown ? "doc.text" : "doc" }

    static func == (lhs: NoteItem, rhs: NoteItem) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

struct WorkspaceFileStamp: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

enum WorkspaceFiles {
    static func fileStamp(_ url: URL) -> WorkspaceFileStamp? {
        var info = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
        return WorkspaceFileStamp(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    /// NSTextView canonicalizes CRLF/CR into LF. Normalize once at the file/editor
    /// boundary so merely mounting the native editor never creates a false dirty draft.
    static func editorText(_ content: String) -> String {
        guard content.utf8.contains(13) else { return content }
        return content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func defaultVault() -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/学习笔记管理", isDirectory: true)
        return root
    }

    /// Only dataless placeholders require a File Provider download. Asking for a
    /// download of an already-materialized file can report a transient status and
    /// turn a perfectly readable first click into a false file-open failure.
    static func hydrateUbiquitousItemIfNeeded(_ url: URL) async throws {
        guard FileManager.default.isUbiquitousItem(at: url),
              isDataless(url) else { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<200 {
            try Task.checkCancellation()
            // On modern File Provider, the POSIX dataless flag is the actual
            // read-readiness authority; resourceValues can lag or be absent.
            if !isDataless(url) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CocoaError(.fileReadUnknown)
    }

    /// The file itself remains canonical. Read locally available Markdown on
    /// the first click without an unnecessary iCloud handshake. After hydration,
    /// allow a few short metadata-settling attempts instead of failing instantly
    /// when File Provider updates ctime during the read.
    static func readUTF8ForOpening(_ url: URL) async throws -> (content: String, stamp: WorkspaceFileStamp) {
        if isDataless(url) {
            try await hydrateUbiquitousItemIfNeeded(url)
        }

        for attempt in 0..<4 {
            try Task.checkCancellation()
            guard let before = fileStamp(url) else { throw CocoaError(.fileReadNoSuchFile) }
            let content = try String(contentsOf: url, encoding: .utf8)
            guard let after = fileStamp(url) else { throw CocoaError(.fileReadNoSuchFile) }
            if before == after { return (content, after) }
            if attempt < 3 {
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        // Do not accept an unstable document or disguise concurrent writes.
        throw CocoaError(.fileReadUnknown)
    }

    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = candidate.standardizedFileURL.path
        guard path.hasPrefix(canonicalRoot + "/") else { return false }

        // Check each path component with lstat: resolvingSymlinksInPath does not
        // reliably resolve a symlinked parent when the final file is missing.
        var cursor = URL(fileURLWithPath: canonicalRoot, isDirectory: true)
        for part in path.dropFirst(canonicalRoot.count + 1).split(separator: "/") {
            cursor.appendPathComponent(String(part))
            var info = stat()
            if lstat(cursor.path, &info) == 0,
               (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                return false
            }
        }
        return true
    }

    private static var scanCancelled: Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    private enum DirectoryEntryKind {
        case directory
        case regular
    }

    private struct DirectoryEntry {
        let url: URL
        let kind: DirectoryEntryKind
    }

    /// POSIX directory enumeration avoids one lstat syscall per normal APFS/
    /// File Provider entry. d_type is authoritative when available; unusual
    /// filesystems fall back to lstat only for DT_UNKNOWN.
    private static func directoryEntries(in folder: URL) -> [DirectoryEntry] {
        guard !scanCancelled, let directory = Darwin.opendir(folder.path) else { return [] }
        defer { Darwin.closedir(directory) }

        var result: [DirectoryEntry] = []
        while !scanCancelled, let entry = Darwin.readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            guard length > 0 else { continue }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", !name.hasPrefix(".") else { continue }

            let url = folder.appendingPathComponent(name)
            switch Int32(entry.pointee.d_type) {
            case DT_DIR:
                result.append(.init(url: url, kind: .directory))
            case DT_REG:
                result.append(.init(url: url, kind: .regular))
            case DT_LNK:
                continue
            case DT_UNKNOWN:
                var info = Darwin.stat()
                guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { continue }
                switch info.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFDIR):
                    result.append(.init(url: url, kind: .directory))
                case mode_t(S_IFREG):
                    result.append(.init(url: url, kind: .regular))
                default:
                    continue
                }
            default:
                continue
            }
        }
        return result
    }

    static func tree(in root: URL, recursive: Bool = true) -> [NoteItem] {
        directoryEntries(in: root).compactMap { entry -> NoteItem? in
            guard !scanCancelled else { return nil }
            switch entry.kind {
            case .directory:
                let children = recursive ? tree(in: entry.url, recursive: true) : []
                return NoteItem(url: entry.url, children: children)
            case .regular:
                return NoteItem(url: entry.url, children: nil)
            }
        }.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// One filesystem-authoritative flat traversal shared by all complete-vault
    /// transient projections. Callers decide which lightweight derived buffers to keep.
    static func visitFlatFiles(in root: URL, _ visit: (URL) -> Void) {
        var pending = [root]
        while let folder = pending.popLast() {
            guard !scanCancelled else { break }
            for entry in directoryEntries(in: folder) {
                guard !scanCancelled else { return }
                switch entry.kind {
                case .directory:
                    pending.append(entry.url)
                case .regular:
                    visit(entry.url)
                }
            }
        }
    }

    /// Flat, transient full-vault files for compatibility/fallback callers.
    static func flatFiles(in root: URL) -> [NoteItem] {
        var result: [NoteItem] = []
        visitFlatFiles(in: root) { url in
            result.append(NoteItem(url: url, children: nil))
        }
        return result
    }

    /// Reconcile one filesystem-authoritative shallow listing with already
    /// loaded descendants. Only a directory that still exists at the exact same
    /// path may retain its in-memory children.
    static func preservingLoadedChildren(
        _ fresh: [NoteItem],
        from previous: [NoteItem]
    ) -> [NoteItem] {
        let previousByPath = Dictionary(uniqueKeysWithValues: previous.map {
            ($0.url.standardizedFileURL.path, $0)
        })
        return fresh.map { item in
            guard item.isFolder,
                  let old = previousByPath[item.url.standardizedFileURL.path],
                  let loaded = old.children else { return item }
            return NoteItem(url: item.url, children: loaded)
        }
    }

    /// Replace one loaded folder while preserving every other loaded subtree and
    /// any already-loaded descendants whose direct directory path still exists.
    static func replacingChildren(
        in items: [NoteItem],
        folder: URL,
        with children: [NoteItem]
    ) -> [NoteItem] {
        let target = folder.standardizedFileURL.path
        return items.map { item in
            let itemPath = item.url.standardizedFileURL.path
            if itemPath == target, item.isFolder {
                return NoteItem(
                    url: item.url,
                    children: preservingLoadedChildren(children, from: item.children ?? [])
                )
            }
            guard target.hasPrefix(itemPath + "/"), let current = item.children else {
                return item
            }
            return NoteItem(
                url: item.url,
                children: replacingChildren(in: current, folder: folder, with: children)
            )
        }
    }

    /// Resolves links and attachment paths relative to the current note, without escaping the vault.
    static func resolve(_ value: URL, from note: URL, in root: URL) -> URL? {
        if let scheme = value.scheme, scheme != "file" { return nil }
        let candidate: URL
        if value.isFileURL {
            candidate = value
        } else if value.path.hasPrefix("/") {
            candidate = root.appendingPathComponent(String(value.path.dropFirst()))
        } else {
            candidate = note.deletingLastPathComponent().appendingPathComponent(value.path)
        }
        let normalized = candidate.standardizedFileURL.resolvingSymlinksInPath()
        return contains(normalized, in: root) ? normalized : nil
    }

    /// Build one deterministic root-relative WikiLink target for a Markdown file.
    /// The existing resolver treats a leading slash as workspace-root relative.
    static func canonicalWikiTarget(for target: URL, in root: URL) -> String? {
        let canonicalRoot = root.standardizedFileURL
        let canonicalTarget = target.standardizedFileURL
        guard contains(canonicalTarget, in: canonicalRoot),
              ["md", "markdown"].contains(canonicalTarget.pathExtension.lowercased())
        else { return nil }

        let prefix = canonicalRoot.path + "/"
        guard canonicalTarget.path.hasPrefix(prefix) else { return nil }
        var relative = String(canonicalTarget.path.dropFirst(prefix.count))
        let ext = canonicalTarget.pathExtension
        if !ext.isEmpty {
            relative.removeLast(ext.count + 1)
        }
        guard !relative.isEmpty else { return nil }

        var allowed = CharacterSet.urlPathAllowed
        // This canonical target is also reused when repairing ordinary
        // Markdown destinations, where raw parentheses terminate the URL.
        allowed.remove(charactersIn: "#?[]|%()")
        guard let encoded = relative.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else { return nil }
        return "/" + encoded
    }

    /// Canonical workspace-local target for a linkable file. Markdown keeps
    /// the existing extensionless Wiki target; PDFs and other regular files
    /// retain their extension. This is path canonicalization only—the caller
    /// decides whether the destination must already exist.
    static func canonicalLinkTarget(for target: URL, in root: URL) -> String? {
        let canonicalRoot = root.standardizedFileURL
        let canonicalTarget = target.standardizedFileURL
        guard contains(canonicalTarget, in: canonicalRoot) else { return nil }
        if ["md", "markdown"].contains(canonicalTarget.pathExtension.lowercased()) {
            return canonicalWikiTarget(for: canonicalTarget, in: canonicalRoot)
        }

        let prefix = canonicalRoot.path + "/"
        guard canonicalTarget.path.hasPrefix(prefix) else { return nil }
        let relative = String(canonicalTarget.path.dropFirst(prefix.count))
        guard !relative.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?[]|%()")
        guard let encoded = relative.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else { return nil }
        return "/" + encoded
    }

    static func canonicalWikiTarget(
        for target: URL,
        in root: URL,
        heading: String
    ) -> String? {
        guard let base = canonicalWikiTarget(for: target, in: root) else { return nil }
        let clean = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        var allowed = CharacterSet.urlFragmentAllowed
        allowed.remove(charactersIn: "#%[]|")
        guard let encoded = clean.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else { return nil }
        return "\(base)#\(encoded)"
    }

    static func linkableMarkdownHeadings(at target: URL, in root: URL) -> [MarkdownOutlineHeading]? {
        let file = target.standardizedFileURL
        guard contains(file, in: root),
              ["md", "markdown"].contains(file.pathExtension.lowercased())
        else { return nil }

        var info = Darwin.stat()
        guard file.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              let source = try? String(contentsOf: file, encoding: .utf8)
        else { return nil }
        return MarkdownOutline.linkableHeadings(in: source)
    }

    static func knowledgeFragment(in rawTarget: String) -> String? {
        guard let marker = rawTarget.firstIndex(of: "#") else { return nil }
        let raw = String(rawTarget[rawTarget.index(after: marker)...])
        let decoded = (raw.removingPercentEncoding ?? raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    /// Resolve a WikiLink/Markdown note target through one deterministic workspace path.
    /// Exact relative/root paths win; basename fallback is accepted only when unique.
    static func resolveKnowledgeTarget(
        _ rawTarget: String,
        from note: URL,
        in root: URL,
        candidates suppliedCandidates: [URL]? = nil,
        candidateBasenames suppliedCandidateBasenames: [String: [URL]]? = nil
    ) -> URL? {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pathPart = String(trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let decoded = pathPart.removingPercentEncoding ?? pathPart
        guard !decoded.isEmpty, URL(string: decoded)?.scheme == nil else { return nil }

        func markdownCandidates(_ base: URL) -> [URL] {
            if !base.pathExtension.isEmpty { return [base] }
            return [base.appendingPathExtension("md"), base.appendingPathExtension("markdown")]
        }

        let relative = note.deletingLastPathComponent().appendingPathComponent(decoded)
        let rooted = root.appendingPathComponent(decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded)
        var seen: Set<String> = []
        for candidate in (markdownCandidates(relative) + markdownCandidates(rooted)) {
            let normalized = candidate.standardizedFileURL
            guard seen.insert(normalized.path).inserted,
                  contains(normalized, in: root),
                  FileManager.default.fileExists(atPath: normalized.path),
                  ["md", "markdown"].contains(normalized.pathExtension.lowercased()) else { continue }
            return normalized
        }

        guard !decoded.contains("/") else { return nil }
        let wanted = URL(fileURLWithPath: decoded).deletingPathExtension().lastPathComponent
        let candidates = suppliedCandidates ?? flatFiles(in: root)
            .filter(\.isMarkdown)
            .map { $0.url.standardizedFileURL }
        let matches = suppliedCandidateBasenames?[wanted] ?? candidates.filter {
            $0.deletingPathExtension().lastPathComponent == wanted
        }
        return matches.count == 1 ? matches[0].standardizedFileURL : nil
    }

    /// One local-link resolver for Markdown notes and other workspace files such as PDFs.
    /// Markdown remains the link authority; fragments (for example #page=12) are navigation hints only.
    static func resolveLinkedTarget(
        _ rawTarget: String,
        from note: URL,
        in root: URL,
        candidates: [URL]? = nil,
        candidateBasenames: [String: [URL]]? = nil
    ) -> URL? {
        let value = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let markdown = resolveKnowledgeTarget(
            value,
            from: note,
            in: root,
            candidates: candidates,
            candidateBasenames: candidateBasenames
        ) {
            return markdown
        }

        guard let link = URL(string: value),
              link.scheme == nil || link.isFileURL,
              let resolved = resolve(link, from: note, in: root),
              FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
    }

    /// Target-specific backlink resolver. The target is validated once by the scan;
    /// complete Markdown candidates then let every outgoing link resolve in memory
    /// instead of repeating path-component lstat/fileExists work.
    static func linkedTargetMatches(
        _ rawTarget: String,
        from note: URL,
        target: URL,
        in root: URL,
        candidateBasenames: [String: [URL]]
    ) -> Bool {
        let value = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }

        let target = target.standardizedFileURL
        let pathPart = String(value.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first ?? "")
        let decoded = pathPart.removingPercentEncoding ?? pathPart
        guard !decoded.isEmpty, URL(string: decoded)?.scheme == nil else { return false }

        func markdownCandidates(_ base: URL) -> [URL] {
            if !base.pathExtension.isEmpty { return [base] }
            return [base.appendingPathExtension("md"), base.appendingPathExtension("markdown")]
        }

        let relative = note.deletingLastPathComponent().appendingPathComponent(decoded)
        let rooted = root.appendingPathComponent(decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded)
        var seen: Set<String> = []
        for candidate in markdownCandidates(relative) + markdownCandidates(rooted) {
            let normalized = candidate.standardizedFileURL
            guard seen.insert(normalized.path).inserted,
                  ["md", "markdown"].contains(normalized.pathExtension.lowercased())
            else { continue }

            let basename = normalized.deletingPathExtension().lastPathComponent
            if candidateBasenames[basename]?.contains(where: {
                $0.standardizedFileURL == normalized
            }) == true {
                // Exact relative/root Markdown paths keep the same precedence as
                // resolveKnowledgeTarget. If an exact file is another note,
                // basename fallback must not redirect the link.
                return normalized == target
            }
        }

        if !decoded.contains("/") {
            let wanted = URL(fileURLWithPath: decoded).deletingPathExtension().lastPathComponent
            if let matches = candidateBasenames[wanted], matches.count == 1 {
                return matches[0].standardizedFileURL == target
            }
        }

        // Non-Markdown workspace links (notably PDFs) still use exact local path
        // semantics. Comparing to the already-validated target keeps this path
        // filesystem-free per link and rejects symlink aliases automatically.
        guard let link = URL(string: value), link.scheme == nil || link.isFileURL else {
            return false
        }
        let candidate: URL
        if link.isFileURL {
            candidate = link
        } else if link.path.hasPrefix("/") {
            candidate = root.appendingPathComponent(String(link.path.dropFirst()))
        } else {
            candidate = note.deletingLastPathComponent().appendingPathComponent(link.path)
        }
        return candidate.standardizedFileURL == target
    }

    /// Deterministic collision-safe suggestion; O_EXCL remains the final writer guard.
    static func nextAvailableNoteName(basedOn name: String, in folder: URL) -> String? {
        guard let normalized = safeNewNoteName(name) else { return nil }
        let stem = String(normalized.dropLast(3))
        for index in 0..<10_000 {
            let base = index == 0 ? stem : "\(stem) \(index + 1)"
            let filename = base + ".md"
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(filename).path) {
                return filename
            }
        }
        return nil
    }

    static func nextUntitledName(in folder: URL) -> String? {
        nextAvailableNoteName(basedOn: "Untitled", in: folder)
    }

    static func storePastedPNG(_ data: Data, for note: URL, in root: URL, stem: String = "pasted-image") -> String? {
        guard contains(note, in: root), ["md", "markdown"].contains(note.pathExtension.lowercased()),
              !data.isEmpty else { return nil }
        let folder = note.deletingLastPathComponent().appendingPathComponent("attachments", isDirectory: true)
        guard contains(folder, in: root) else { return nil }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 1...10_000 {
                let suffix = index == 1 ? "" : "-\(index)"
                let filename = stem + suffix + ".png"
                let destination = folder.appendingPathComponent(filename)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try data.write(to: destination, options: .atomic)
                    return "attachments/" + filename
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    static func isDataless(_ url: URL) -> Bool {
        var info = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return false }
        return (info.st_flags & UInt32(SF_DATALESS)) != 0
    }

    static func safeNewNoteName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.hasPrefix("."),
              !trimmed.contains("\0") else { return nil }
        let base = trimmed.hasSuffix(".md") ? String(trimmed.dropLast(3)) : trimmed
        return base.isEmpty ? nil : base + ".md"
    }
}

struct NoteBacklinkLocation: Identifiable, Equatable {
    let lineIndex: Int
    let count: Int

    var id: Int { lineIndex }
}

struct NoteBacklink: Identifiable, Equatable {
    let source: URL
    let sourceStamp: WorkspaceFileStamp
    let locations: [NoteBacklinkLocation]

    var id: String { source.path }
    var title: String { source.deletingPathExtension().lastPathComponent }
    var count: Int { locations.reduce(0) { $0 + $1.count } }
}

struct BacklinkScanResult: Equatable {
    let backlinks: [NoteBacklink]
    let skippedDatalessFiles: Int
}

/// Transient projection of the complete vault file index for link resolution.
/// Markdown/filesystem data remains authoritative; this only removes repeated
/// O(N) filter/map/grouping work from every backlink scan and link activation.
struct WorkspaceLinkCandidateIndex: Sendable {
    let markdownFiles: [URL]
    let byBasename: [String: [URL]]

    init(markdownFiles: [URL]) {
        var standardized: [URL] = []
        standardized.reserveCapacity(markdownFiles.count)
        var grouped: [String: [URL]] = [:]
        grouped.reserveCapacity(markdownFiles.count)

        for url in markdownFiles {
            let normalized = url.standardizedFileURL
            standardized.append(normalized)
            grouped[normalized.deletingPathExtension().lastPathComponent, default: []].append(normalized)
        }

        self.markdownFiles = standardized
        self.byBasename = grouped
    }

    static let empty = WorkspaceLinkCandidateIndex(markdownFiles: [])
}

private struct GlobalFileIndexSnapshot {
    let quickOpenEntries: [NoteTreePresentation.QuickOpenEntry]
    let linkCandidates: WorkspaceLinkCandidateIndex
}

/// Session-only memoization of raw outgoing Markdown links. The file itself
/// remains authoritative: every lookup validates the existing POSIX stamp and
/// target-specific backlink resolution is still recomputed by WorkspaceBacklinks.
final class WorkspaceBacklinkParseCache: @unchecked Sendable {
    struct Lookup {
        let stamp: WorkspaceFileStamp
        let occurrences: [MarkdownLinkOccurrence]
        let hit: Bool

        var links: [MindMapLink] { occurrences.map(\.link) }
    }

    private final class Node {
        let key: String
        weak var previous: Node?
        var next: Node?

        init(key: String) {
            self.key = key
        }
    }

    private struct Entry {
        let stamp: WorkspaceFileStamp
        let occurrences: [MarkdownLinkOccurrence]
        let node: Node
    }

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var leastRecent: Node?
    private var mostRecent: Node?

    init(capacity: Int = 1_024) {
        self.capacity = max(1, capacity)
    }

    private func unlink(_ node: Node) {
        let previous = node.previous
        let next = node.next
        previous?.next = next
        next?.previous = previous
        if leastRecent === node { leastRecent = next }
        if mostRecent === node { mostRecent = previous }
        node.previous = nil
        node.next = nil
    }

    private func markMostRecent(_ node: Node) {
        guard mostRecent !== node else { return }
        unlink(node)
        node.previous = mostRecent
        mostRecent?.next = node
        mostRecent = node
        if leastRecent == nil { leastRecent = node }
    }

    private func removeEntry(forKey key: String) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        unlink(removed.node)
    }

    private func insertEntry(
        key: String,
        stamp: WorkspaceFileStamp,
        occurrences: [MarkdownLinkOccurrence]
    ) {
        if entries[key] == nil, entries.count >= capacity, let victim = leastRecent {
            removeEntry(forKey: victim.key)
        }
        if let existing = entries[key] {
            unlink(existing.node)
        }
        let node = Node(key: key)
        entries[key] = Entry(stamp: stamp, occurrences: occurrences, node: node)
        markMostRecent(node)
    }

    func lookup(_ source: URL) -> Lookup? {
        let url = source.standardizedFileURL
        let key = url.path
        guard let stamp = WorkspaceFiles.fileStamp(url) else { return nil }

        lock.lock()
        if let cached = entries[key] {
            if cached.stamp == stamp {
                markMostRecent(cached.node)
                let occurrences = cached.occurrences
                lock.unlock()
                return Lookup(stamp: stamp, occurrences: occurrences, hit: true)
            }
            removeEntry(forKey: key)
        }
        lock.unlock()

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let occurrences = MindMapOutline.linkOccurrences(in: content)

        // If another editor changed the file while it was being read, use this
        // parse for the current scan but do not memoize it under a stale stamp.
        guard WorkspaceFiles.fileStamp(url) == stamp else {
            return Lookup(stamp: stamp, occurrences: occurrences, hit: false)
        }

        lock.lock()
        insertEntry(key: key, stamp: stamp, occurrences: occurrences)
        lock.unlock()
        return Lookup(stamp: stamp, occurrences: occurrences, hit: false)
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        leastRecent = nil
        mostRecent = nil
        lock.unlock()
    }

    var entryCount: Int {
        lock.lock()
        let count = entries.count
        lock.unlock()
        return count
    }
}

enum WorkspaceBacklinks {
    static func markdownFiles(_ items: [NoteItem]) -> [URL] {
        var result: [URL] = []
        func collect(_ nodes: [NoteItem]) {
            for item in nodes {
                if let children = item.children {
                    collect(children)
                } else if item.isMarkdown {
                    result.append(item.url.standardizedFileURL)
                }
            }
        }
        collect(items)
        return result
    }

    static func scan(
        target: URL,
        root: URL,
        files: [NoteItem],
        candidateIndex suppliedCandidateIndex: WorkspaceLinkCandidateIndex? = nil,
        parseCache: WorkspaceBacklinkParseCache? = nil
    ) -> BacklinkScanResult {
        let target = target.standardizedFileURL
        guard WorkspaceFiles.contains(target, in: root),
              FileManager.default.fileExists(atPath: target.path) else {
            return .init(backlinks: [], skippedDatalessFiles: 0)
        }

        let candidateIndex = suppliedCandidateIndex
            ?? WorkspaceLinkCandidateIndex(markdownFiles: markdownFiles(files))
        let candidates = candidateIndex.markdownFiles
        let candidateBasenames = candidateIndex.byBasename
        var result: [NoteBacklink] = []
        var skippedDatalessFiles = 0

        for source in candidates where source != target {
            if WorkspaceFiles.isDataless(source) {
                skippedDatalessFiles += 1
                continue
            }
            let sourceStamp: WorkspaceFileStamp
            let occurrences: [MarkdownLinkOccurrence]
            if let parseCache {
                guard let cached = parseCache.lookup(source) else { continue }
                sourceStamp = cached.stamp
                occurrences = cached.occurrences
            } else {
                guard let stamp = WorkspaceFiles.fileStamp(source),
                      let content = try? String(contentsOf: source, encoding: .utf8)
                else { continue }
                let parsed = MindMapOutline.linkOccurrences(in: content)
                guard WorkspaceFiles.fileStamp(source) == stamp else { continue }
                sourceStamp = stamp
                occurrences = parsed
            }

            var lineCounts: [Int: Int] = [:]
            for occurrence in occurrences where WorkspaceFiles.linkedTargetMatches(
                occurrence.link.target,
                from: source,
                target: target,
                in: root,
                candidateBasenames: candidateBasenames
            ) {
                lineCounts[occurrence.lineIndex, default: 0] += 1
            }
            guard !lineCounts.isEmpty else { continue }
            let locations = lineCounts.keys.sorted().map {
                NoteBacklinkLocation(lineIndex: $0, count: lineCounts[$0] ?? 0)
            }
            result.append(.init(source: source, sourceStamp: sourceStamp, locations: locations))
        }

        let backlinks = result.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return .init(backlinks: backlinks, skippedDatalessFiles: skippedDatalessFiles)
    }

    static func find(target: URL, root: URL, files: [NoteItem]) -> [NoteBacklink] {
        scan(target: target, root: root, files: files).backlinks
    }
}

struct MarkdownAnchorRequest: Equatable {
    let note: URL
    let fragment: String
    let sequence: UInt64
}

@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var files: [NoteItem] = []
    @Published private(set) var loadingFiles = false
    @Published private(set) var globalQuickOpenEntries: [NoteTreePresentation.QuickOpenEntry] = []
    /// Compatibility/debug view only. The complete vault no longer retains a
    /// second NoteItem array beside globalQuickOpenEntries.
    var globalFiles: [NoteItem] { globalQuickOpenEntries.map(\.item) }
    @Published private(set) var indexingFiles = false
    @Published private(set) var globalFileIndexReady = false
    @Published private(set) var loadingNote = false
    @Published private(set) var selected: URL?
    @Published private(set) var previewPDF: URL?
    @Published private(set) var previewPDFPage: Int?
    @Published private(set) var previewPDFAnchor: PDFSourceAnchor?
    @Published var draft: String = "" {
        didSet {
            draftRevision &+= 1
            bodyRevision &+= 1
            scheduleAutoSave()
        }
    }
    @Published private(set) var autoSavePending = false
    /// UI-only ownership marker for the one async file-operation path.
    /// Filesystem state remains authoritative; this prevents overlapping
    /// rename/move/copy mutations while hydration/link preparation is awaiting.
    @Published private(set) var fileOperationInProgress: URL?
    @Published private(set) var baseline: String = ""
    @Published private(set) var externalTitle: String?
    @Published private(set) var externalBody: String? {
        didSet { bodyRevision &+= 1 }
    }
    @Published private(set) var previewSource: SearchHit?
    @Published private(set) var activeMatch: SearchHit?
    @Published private(set) var matchJumpSequence = 0
    @Published private(set) var matchedQuery = ""
    @Published private(set) var markdownAnchorRequest: MarkdownAnchorRequest?
    @Published var query = ""
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var searching = false
    @Published var message: String?
    @Published private(set) var searchStatus = "PKS search · 127.0.0.1:3217"
    @Published private(set) var searchFailed = false
    @Published private(set) var backlinks: [NoteBacklink] = []
    @Published private(set) var loadingBacklinks = false
    @Published private(set) var backlinkSkippedCloudFiles = 0
    @Published private(set) var relatedHits: [SearchHit] = []
    @Published private(set) var loadingRelated = false
    @Published private(set) var recentNotes: [URL] = []
    @Published private(set) var favoriteNotes: [URL] = []
    @Published private(set) var relatedError: String?

    // Lightweight render identities. They change with content mutations but never
    // become content authorities; views can invalidate derived work in O(1).
    private(set) var draftRevision: UInt64 = 0
    private(set) var bodyRevision: UInt64 = 0

    private struct CachedNote: Sendable {
        let content: String
        let stamp: WorkspaceFileStamp
    }

    private var savedFileStamp: WorkspaceFileStamp?
    private var autoSaveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var noteLoadTask: Task<Void, Never>?
    @Published private(set) var requestedNote: URL?
    private var loadIdentity: UUID?
    private var pendingMatch: SearchHit?
    private var noteCache: [String: CachedNote] = [:]
    private var noteCacheOrder: [String] = []
    private var filePrefetchTask: Task<Void, Never>?
    private var filePrefetchPath: String?
    private var securityScopedFolder: URL?
    private var backlinkTask: Task<Void, Never>?
    private var backlinkParseCache = WorkspaceBacklinkParseCache()
    private var cloudBacklinkCursor = 0
    private var relatedTask: Task<Void, Never>?
    private var fileRefreshTask: Task<Void, Never>?
    private var folderLoadTask: Task<Void, Never>?
    private var pendingFolderPaths: Set<String> = []
    private var pendingFolderQueue: [String] = []
    private var preferredFolderPath: String?
    private var loadedFolderPaths: Set<String> = []
    private var mutationRefreshTask: Task<Void, Never>?
    private var pendingMutationParentPaths: Set<String> = []
    private var mutationRefreshGeneration: UInt64 = 0
    private var globalFileScanTask: Task<GlobalFileIndexSnapshot, Never>?
    private var globalFileScanGeneration: UInt64 = 0
    private var globalFileIndexGeneration: UInt64 = 0
    private var globalLinkCandidates = WorkspaceLinkCandidateIndex.empty
    private var knowledgeLinkTask: Task<Void, Never>?
    private var markdownAnchorSequence: UInt64 = 0
    private var fileRefreshGeneration: UInt64 = 0

    var isDirty: Bool { selected != nil && draft != baseline }
    var title: String { externalTitle ?? previewPDF?.lastPathComponent ?? selected?.lastPathComponent ?? "Select a note" }
    var body: String { externalBody ?? draft }
    var openingNoteName: String? {
        guard loadingNote, let requestedNote else { return nil }
        return requestedNote.deletingPathExtension().lastPathComponent
    }
    var groupedHits: [SearchResultGroup] { SearchResultGroup.group(hits) }
    var selectedIsFavorite: Bool {
        guard let selected else { return false }
        return favoriteNotes.contains(selected.standardizedFileURL)
    }

    func toggleFavorite(_ note: URL? = nil) {
        guard let root, let target = (note ?? selected)?.standardizedFileURL,
              WorkspaceFiles.contains(target, in: root) else { return }
        favoriteNotes = NoteNavigationStore.toggleFavorite(target, in: root)
    }

    private func reloadNavigationPreferences() {
        guard let root else {
            recentNotes = []
            favoriteNotes = []
            return
        }
        recentNotes = NoteNavigationStore.recent(in: root)
        favoriteNotes = NoteNavigationStore.favorites(in: root)
    }

    /// The Markdown file remains the only writer/authority; the task only schedules save().
    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        guard !loadingNote, let note = selected else {
            autoSavePending = false
            return
        }
        autoSavePending = true
        let revision = draftRevision
        autoSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) }
            catch { return }
            guard !Task.isCancelled, let self,
                  self.selected == note, self.draftRevision == revision else { return }
            // Exact draft/baseline comparison is intentionally deferred until
            // typing has gone idle, avoiding an O(document-size) comparison per key.
            guard self.isDirty else {
                self.autoSavePending = false
                return
            }
            self.save()
        }
    }

    init() {
        let preferences = UserDefaults.standard
        if let bookmark = preferences.data(forKey: "PKSNotesWorkspaceBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale), !stale {
                if url.startAccessingSecurityScopedResource() { securityScopedFolder = url }
                openWorkspace(url)
                return
            }
        }
        if let configured = preferences.string(forKey: "PKSNotesWorkspace") {
            if configured.contains("/Mobile Documents/") {
                message = AppLanguage.current.text("Select the existing iCloud folder once to grant macOS access.")
            } else {
                let url = URL(fileURLWithPath: configured, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) { openWorkspace(url) }
            }
        } else {
            message = AppLanguage.current.text("Choose your existing Markdown folder once. No account is required.")
        }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.message = AppLanguage.current.text("Choose the existing Markdown directory (no import or duplication)")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = (root ?? WorkspaceFiles.defaultVault()).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Keep the old scope and bookmark until the user accepts the navigation.
        let acquiredScope = url.startAccessingSecurityScopedResource()
        guard openWorkspace(url) else {
            if acquiredScope { url.stopAccessingSecurityScopedResource() }
            return
        }
        if let previous = securityScopedFolder { previous.stopAccessingSecurityScopedResource() }
        securityScopedFolder = acquiredScope ? url : nil
        // Store only the one user-selected folder grant, never note contents.
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "PKSNotesWorkspaceBookmark")
        } else {
            // An old bookmark must never silently reopen a different workspace.
            UserDefaults.standard.removeObject(forKey: "PKSNotesWorkspaceBookmark")
            message = AppLanguage.current.text("Folder opened, but macOS could not save permanent access. Choose it again next launch.")
        }
    }

    @discardableResult
    func openWorkspace(_ url: URL, navigationDecision: UnsavedNoteDecision? = nil) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            message = AppLanguage.current.text("Choose an existing Markdown folder."); return false
        }
        if root == resolved { return true }
        guard confirmLeavingNote(decision: navigationDecision) else { return false }

        previewTask?.cancel()
        cancelNoteLoad()
        cancelFilePrefetch()
        backlinkTask?.cancel()
        // A detached scan may still finish after cancellation. Swapping the
        // cache object isolates any late writes to the old workspace instance.
        backlinkParseCache = WorkspaceBacklinkParseCache()
        root = resolved
        message = nil
        UserDefaults.standard.set(resolved.path, forKey: "PKSNotesWorkspace")
        reloadNavigationPreferences()
        files = []
        backlinks = []
        loadingBacklinks = false
        relatedHits = []
        relatedTask?.cancel()
        loadingRelated = false
        relatedError = nil
        refresh()
        selected = nil
        previewPDF = nil
        previewPDFPage = nil
        previewPDFAnchor = nil
        markdownAnchorRequest = nil
        externalTitle = nil
        externalBody = nil
        previewSource = nil
        activeMatch = nil
        draft = ""
        baseline = ""
        restoreLastOpenedNote(in: resolved)
        return true
    }

    /// Reopen only a previously selected Markdown file inside this exact workspace.
    /// The original file remains authoritative and reading still happens off-main.
    private func restoreLastOpenedNote(in root: URL) {
        guard let path = UserDefaults.standard.string(forKey: "PKSNotesLastOpenedMarkdown") else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard WorkspaceFiles.contains(url, in: root) else { return }
        guard ["md", "markdown"].contains(url.pathExtension.lowercased()) else { return }
        var info = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            UserDefaults.standard.removeObject(forKey: "PKSNotesLastOpenedMarkdown")
            message = AppLanguage.current.text("Last opened note is no longer available. Choose another note.")
            return
        }
        openNote(url, reportFailure: false)
    }

    private func invalidateGlobalFileIndex() {
        globalFileScanTask?.cancel()
        globalFileScanTask = nil
        globalFileIndexGeneration &+= 1
        globalFileIndexReady = false
        globalQuickOpenEntries = []
        globalLinkCandidates = .empty
        indexingFiles = false
    }

    func refresh() {
        guard let root else { return }
        fileRefreshTask?.cancel()
        folderLoadTask?.cancel()
        mutationRefreshTask?.cancel()
        folderLoadTask = nil
        mutationRefreshTask = nil
        mutationRefreshGeneration &+= 1
        pendingFolderPaths.removeAll()
        pendingFolderQueue.removeAll(keepingCapacity: true)
        pendingMutationParentPaths.removeAll()
        preferredFolderPath = nil
        loadedFolderPaths.removeAll()
        invalidateGlobalFileIndex()

        fileRefreshGeneration &+= 1
        let generation = fileRefreshGeneration
        loadingFiles = true

        // The sidebar only needs the current directory. Descendants are loaded
        // after disclosure, so a collapsed vault never pays recursive I/O.
        fileRefreshTask = Task.detached(priority: .userInitiated) { [weak self] in
            let shallow = WorkspaceFiles.tree(in: root, recursive: false)
            guard !Task.isCancelled else { return }
            await self?.publishFiles(shallow, root: root, generation: generation)
        }
    }

    private func publishFiles(_ scanned: [NoteItem], root: URL, generation: UInt64) {
        guard self.root == root, fileRefreshGeneration == generation else { return }
        files = scanned
        loadingFiles = false
        fileRefreshTask = nil
        startPendingFolderLoad()
    }

    /// A local filesystem mutation only invalidates the global derived index and
    /// re-reads parent directories that are currently materialized in the UI.
    /// Directory membership still comes exclusively from a fresh filesystem scan.
    private func scheduleFilesystemMutationRefresh(parentFolders: [URL]) {
        guard let root else { return }
        invalidateGlobalFileIndex()

        let canonicalRoot = root.standardizedFileURL
        let rootPath = canonicalRoot.path
        for parent in parentFolders {
            let normalized = parent.standardizedFileURL.path
            guard normalized == rootPath || normalized.hasPrefix(rootPath + "/") else { continue }
            if normalized == rootPath || loadedFolderPaths.contains(normalized) {
                pendingMutationParentPaths.insert(normalized)
            }
        }
        startPendingMutationRefresh()
    }

    private func discardLoadedSubtree(_ item: URL) {
        let target = item.standardizedFileURL.path
        func outside(_ path: String) -> Bool {
            path != target && !path.hasPrefix(target + "/")
        }
        loadedFolderPaths = Set(loadedFolderPaths.filter(outside))
        pendingFolderPaths = Set(pendingFolderPaths.filter(outside))
        pendingFolderQueue.removeAll { !outside($0) }
        pendingMutationParentPaths = Set(pendingMutationParentPaths.filter(outside))
        if let preferredFolderPath, !outside(preferredFolderPath) {
            self.preferredFolderPath = nil
        }
    }

    private func startPendingMutationRefresh() {
        guard mutationRefreshTask == nil, let root,
              !pendingMutationParentPaths.isEmpty else { return }

        let rootPath = root.standardizedFileURL.path
        let target = pendingMutationParentPaths.min {
            let lhsDepth = $0.split(separator: "/").count
            let rhsDepth = $1.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }!
        pendingMutationParentPaths.remove(target)
        let generation = mutationRefreshGeneration

        mutationRefreshTask = Task { [weak self] in
            let scanner = Task.detached(priority: .userInitiated) {
                let folder = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
                return (folder, WorkspaceFiles.tree(in: folder, recursive: false))
            }
            let refreshed = await withTaskCancellationHandler {
                await scanner.value
            } onCancel: {
                scanner.cancel()
            }

            guard let self, self.mutationRefreshGeneration == generation else { return }
            self.mutationRefreshTask = nil
            guard !Task.isCancelled, self.root == root else { return }

            if refreshed.0.path == rootPath {
                self.files = WorkspaceFiles.preservingLoadedChildren(
                    refreshed.1,
                    from: self.files
                )
            } else if self.loadedFolderPaths.contains(refreshed.0.path) {
                self.files = WorkspaceFiles.replacingChildren(
                    in: self.files,
                    folder: refreshed.0,
                    with: refreshed.1
                )
            }
            self.startPendingMutationRefresh()
        }
    }

    private func rebuildPendingFolderQueue(rootPath: String) {
        let ranked = pendingFolderPaths.compactMap { path -> (path: String, depth: Int)? in
            guard path.hasPrefix(rootPath + "/"),
                  !loadedFolderPaths.contains(path) else { return nil }
            return (path, path.split(separator: "/").count)
        }
        pendingFolderPaths = Set(ranked.map(\.path))
        // Reverse priority order so popLast() returns shallowest, then lexical.
        // Sorting happens only when the expanded set changes, not after every load.
        pendingFolderQueue = ranked.sorted {
            if $0.depth != $1.depth { return $0.depth > $1.depth }
            return $0.path.localizedStandardCompare($1.path) == .orderedDescending
        }.map(\.path)
    }

    /// Pick the next materializable directory on one preferred deep path.
    /// The existing pending set remains the only queue authority: this is merely
    /// a priority hint that walks the path shallow-to-deep so each child can be
    /// published into an already materialized parent.
    static func preferredPendingFolder(in pending: Set<String>, toward preferredLeaf: String) -> String? {
        var selected: String?
        var selectedDepth = Int.max
        for candidate in pending
        where candidate == preferredLeaf || preferredLeaf.hasPrefix(candidate + "/") {
            let depth = candidate.split(separator: "/").count
            if depth < selectedDepth {
                selected = candidate
                selectedDepth = depth
            }
        }
        return selected
    }

    func loadExpandedFolders(_ paths: Set<String>) {
        guard let root else { return }
        let rootPath = root.standardizedFileURL.path
        let expanded = Set(paths.compactMap { path -> String? in
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            return normalized.hasPrefix(rootPath + "/") ? normalized : nil
        })

        // A folder collapsed before its queued read starts should consume no I/O.
        // Already-loaded children stay as a presentation cache for cheap reopen.
        pendingFolderPaths.formIntersection(expanded)
        pendingFolderPaths.formUnion(expanded.filter { !loadedFolderPaths.contains($0) })
        rebuildPendingFolderQueue(rootPath: rootPath)
        if let preferredFolderPath, !expanded.contains(preferredFolderPath) {
            self.preferredFolderPath = nil
        }
        startPendingFolderLoad()
    }

    /// Prioritize one already-expanded deep path (for example the active note)
    /// without introducing another tree/index. The scheduler derives each next
    /// ancestor from the same pending set used by normal disclosure loading.
    func prioritizeExpandedPath(_ paths: Set<String>, toward targetFolder: URL) {
        guard let root else { return }
        let rootPath = root.standardizedFileURL.path
        let target = targetFolder.standardizedFileURL.path
        guard target.hasPrefix(rootPath + "/") else { return }

        let expanded = Set(paths.compactMap { path -> String? in
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            return normalized.hasPrefix(rootPath + "/") ? normalized : nil
        })
        guard expanded.contains(target) else { return }

        pendingFolderPaths.formUnion(expanded.filter { !loadedFolderPaths.contains($0) })
        preferredFolderPath = target
        rebuildPendingFolderQueue(rootPath: rootPath)
        startPendingFolderLoad()
    }

    /// Direct user expansion outranks restored/background disclosure work.
    func loadExpandedFolder(_ folder: URL) {
        guard let root else { return }
        let rootPath = root.standardizedFileURL.path
        let normalized = folder.standardizedFileURL.path
        guard normalized.hasPrefix(rootPath + "/"),
              !loadedFolderPaths.contains(normalized) else { return }
        preferredFolderPath = normalized
        if pendingFolderPaths.insert(normalized).inserted {
            // Direct user disclosure is immediately eligible even before the
            // SwiftUI expanded-set callback rebuilds the background queue.
            pendingFolderQueue.append(normalized)
        }
        startPendingFolderLoad()
    }

    private func startPendingFolderLoad() {
        guard folderLoadTask == nil, !loadingFiles, let root,
              !pendingFolderPaths.isEmpty else { return }

        let rootPath = root.standardizedFileURL.path
        var target: String?
        if let preferred = preferredFolderPath,
           preferred.hasPrefix(rootPath + "/"),
           let next = Self.preferredPendingFolder(in: pendingFolderPaths, toward: preferred),
           !loadedFolderPaths.contains(next) {
            pendingFolderPaths.remove(next)
            target = next
            if next == preferred {
                preferredFolderPath = nil
            }
        } else if let preferred = preferredFolderPath,
                  !preferred.hasPrefix(rootPath + "/") || loadedFolderPaths.contains(preferred) {
            preferredFolderPath = nil
        }

        while target == nil, let candidate = pendingFolderQueue.popLast() {
            guard pendingFolderPaths.remove(candidate) != nil,
                  candidate.hasPrefix(rootPath + "/"),
                  !loadedFolderPaths.contains(candidate) else { continue }
            target = candidate
        }

        guard let target else {
            pendingFolderPaths.removeAll()
            pendingFolderQueue.removeAll(keepingCapacity: true)
            preferredFolderPath = nil
            return
        }

        let generation = fileRefreshGeneration
        folderLoadTask = Task { [weak self] in
            let loader = Task.detached(priority: .userInitiated) {
                let folder = URL(fileURLWithPath: target, isDirectory: true).standardizedFileURL
                return (folder, WorkspaceFiles.tree(in: folder, recursive: false))
            }
            let loaded = await withTaskCancellationHandler {
                await loader.value
            } onCancel: {
                loader.cancel()
            }

            guard let self, self.fileRefreshGeneration == generation else { return }
            self.folderLoadTask = nil
            guard !Task.isCancelled, self.root == root else { return }

            // Mark loaded before publishing @Published files so the synchronous
            // SwiftUI receive path cannot enqueue the same folder again.
            self.loadedFolderPaths.insert(loaded.0.path)
            self.files = WorkspaceFiles.replacingChildren(
                in: self.files,
                folder: loaded.0,
                with: loaded.1
            )
            self.startPendingFolderLoad()
        }
    }

    private func ensureGlobalFileIndex() async -> Bool {
        guard let root else { return false }
        if globalFileIndexReady { return true }

        let generation = globalFileIndexGeneration
        let scan: Task<GlobalFileIndexSnapshot, Never>
        if let current = globalFileScanTask, globalFileScanGeneration == generation {
            scan = current
        } else {
            indexingFiles = true
            let task = Task.detached(priority: .utility) {
                var quickOpenEntries: [NoteTreePresentation.QuickOpenEntry] = []
                var markdownFiles: [URL] = []
                var insertionOrder = 0

                WorkspaceFiles.visitFlatFiles(in: root) { url in
                    let item = NoteItem(url: url, children: nil)
                    quickOpenEntries.append(.init(item: item, insertionOrder: insertionOrder))
                    insertionOrder += 1
                    if item.isMarkdown {
                        markdownFiles.append(url)
                    }
                }

                guard !Task.isCancelled else {
                    return GlobalFileIndexSnapshot(
                        quickOpenEntries: [],
                        linkCandidates: .empty
                    )
                }

                NoteTreePresentation.sortQuickOpenEntries(&quickOpenEntries)
                return GlobalFileIndexSnapshot(
                    quickOpenEntries: quickOpenEntries,
                    linkCandidates: WorkspaceLinkCandidateIndex(markdownFiles: markdownFiles)
                )
            }
            globalFileScanTask = task
            globalFileScanGeneration = generation
            scan = task
        }

        let snapshot = await scan.value
        guard self.root == root, globalFileIndexGeneration == generation else { return false }
        // Publish readiness before the derived entries so the SwiftUI receive path
        // can swap from shallow/local results to the complete index immediately.
        globalFileIndexReady = true
        globalQuickOpenEntries = snapshot.quickOpenEntries
        globalLinkCandidates = snapshot.linkCandidates
        indexingFiles = false
        if globalFileScanGeneration == generation {
            globalFileScanTask = nil
        }
        return true
    }

    func prepareGlobalFileIndex() {
        guard root != nil, !globalFileIndexReady else { return }
        Task { [weak self] in
            _ = await self?.ensureGlobalFileIndex()
        }
    }

    /// Quick Open keeps a complete-vault snapshot for performance, but iCloud or
    /// external tools can add files without going through this model's mutation path.
    /// Callers use this only as a bounded fallback after a cached query returns no hits.
    func refreshGlobalFileIndex() {
        guard root != nil else { return }
        invalidateGlobalFileIndex()
        prepareGlobalFileIndex()
    }

    enum UnsavedNoteDecision {
        case save, discard, cancel
    }

    /// Shared for quit, note switching, cross-source previews and workspace changes.
    /// Discard only authorizes the destination; the old draft is kept if opening fails.
    func confirmLeavingNote(decision: UnsavedNoteDecision? = nil) -> Bool {
        guard isDirty else { return true }
        // Ordinary navigation flushes pending autosave without a modal confirmation.
        // On an external edit conflict, keep the existing Save/Discard/Cancel guard.
        if decision == nil {
            save()
            if !isDirty { return true }
        }
        let selectedDecision: UnsavedNoteDecision
        if let decision {
            selectedDecision = decision
        } else {
            let alert = NSAlert()
            let language = AppLanguage.current
            alert.messageText = language.text("Unsaved Markdown changes")
            alert.informativeText = language.resolved == .simplifiedChinese
                ? "离开此笔记前保存对「\(title)」的更改？"
                : "Save changes to \(title) before leaving this note?"
            alert.addButton(withTitle: language.text("Save"))
            alert.addButton(withTitle: language.text("Cancel"))
            alert.addButton(withTitle: language.text("Discard Changes"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: selectedDecision = .save
            case .alertThirdButtonReturn: selectedDecision = .discard
            default: selectedDecision = .cancel
            }
        }
        switch selectedDecision {
        case .save:
            save()
            return !isDirty // Never navigate after a save or external-conflict failure.
        case .discard: return true
        case .cancel: return false
        }
    }

    /// The one local-file dispatch path shared by the tree, Markdown links and search.
    func openFile(
        _ url: URL,
        navigationDecision: UnsavedNoteDecision? = nil,
        pdfPage: Int? = nil,
        pdfAnchor: PDFSourceAnchor? = nil
    ) {
        markdownAnchorRequest = nil
        guard let root, WorkspaceFiles.contains(url, in: root) else {
            message = AppLanguage.current.text("File is outside the selected workspace."); return
        }
        var info = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            message = AppLanguage.current.text("The original file is no longer available."); return
        }

        if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            // openFile already proved workspace containment and regular-file type.
            // Do not repeat the full symlink/lstat chain on the main actor.
            openValidatedNote(url, navigationDecision: navigationDecision, preservePDFPreview: false)
        } else if url.pathExtension.lowercased() == "pdf" {
            // The actual reader becomes the sole waiter. Cancelling this task does not
            // cancel a File Provider download already requested during hover warmup.
            cancelFilePrefetch()
            if previewPDF == url {
                if let pdfAnchor {
                    previewPDFAnchor = pdfAnchor
                    previewPDFPage = pdfAnchor.page
                } else if let pdfPage {
                    previewPDFAnchor = nil
                    previewPDFPage = pdfPage
                }
                return
            }
            let preservesActiveNote = navigationDecision == nil && selected != nil && externalBody == nil
            if !preservesActiveNote {
                guard confirmLeavingNote(decision: navigationDecision) else { return }
            }
            cancelNoteLoad()
            previewTask?.cancel()
            if !preservesActiveNote {
                selected = nil
                baseline = ""
                draft = ""
            }
            previewPDF = url
            previewPDFAnchor = pdfAnchor
            previewPDFPage = pdfAnchor?.page ?? pdfPage
            externalTitle = nil
            externalBody = nil
            previewSource = nil
            activeMatch = nil
            backlinks = []
            backlinkTask?.cancel()
            loadingBacklinks = false
            relatedHits = []
            relatedTask?.cancel()
            loadingRelated = false
            relatedError = nil
            message = nil
        } else {
            // Do not replace the current note when handing a file to another app.
            openInDefaultApp(url)
        }
    }

    func openNote(_ url: URL, navigationDecision: UnsavedNoteDecision? = nil,
                  reportFailure: Bool = true) {
        guard let root, WorkspaceFiles.contains(url, in: root),
              ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            if reportFailure {
                message = AppLanguage.current.text("Only Markdown files inside the selected workspace can be edited.")
            }
            return
        }
        openValidatedNote(url, navigationDecision: navigationDecision,
                          preservePDFPreview: false, reportFailure: reportFailure)
    }

    /// Loads one Markdown note beside the active PDF while keeping the canonical
    /// selected/draft/baseline/save session as the only editable document authority.
    func openStudyNote(_ url: URL, navigationDecision: UnsavedNoteDecision? = nil) {
        guard previewPDF != nil else {
            openNote(url, navigationDecision: navigationDecision)
            return
        }
        guard let root, WorkspaceFiles.contains(url, in: root),
              ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            message = AppLanguage.current.text("Only Markdown files inside the selected workspace can be edited.")
            return
        }
        openValidatedNote(url, navigationDecision: navigationDecision, preservePDFPreview: true)
    }

    private func openValidatedNote(
        _ url: URL,
        navigationDecision: UnsavedNoteDecision?,
        preservePDFPreview: Bool,
        reportFailure: Bool = true
    ) {
        if requestedNote == url { return }
        if selected == url {
            cancelNoteLoad() // A re-selection wins over another pending file load.
            if !preservePDFPreview, previewPDF != nil { closePDFPreview() }
            return
        }
        guard confirmLeavingNote(decision: navigationDecision) else { return }
        loadNote(url, preservePDFPreview: preservePDFPreview, reportFailure: reportFailure)
    }

    private func cancelNoteLoad() {
        noteLoadTask?.cancel()
        noteLoadTask = nil
        requestedNote = nil
        loadIdentity = nil
        pendingMatch = nil
        loadingNote = false
    }

    /// Warm exactly one strongly signalled local target (for example a hovered row).
    /// Measurements show local reads are already cheap; warmup does no content IO and
    /// exists only to start expensive File Provider hydration for Markdown or PDF.
    func prefetchFile(_ url: URL) {
        let candidate = url.standardizedFileURL
        let ext = candidate.pathExtension.lowercased()
        guard let root,
              selected?.standardizedFileURL != candidate,
              previewPDF?.standardizedFileURL != candidate,
              ["md", "markdown", "pdf"].contains(ext) else { return }

        let canonicalRoot = root.standardizedFileURL
        let key = candidate.path
        // Keep pointer/keyboard transit cheap. The dwell lets a newer target cancel
        // before containment or File Provider metadata work begins.
        guard key.hasPrefix(canonicalRoot.path + "/") else { return }
        if filePrefetchPath == key { return }

        filePrefetchTask?.cancel()
        filePrefetchPath = key
        filePrefetchTask = Task.detached(priority: .utility) {
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            guard !Task.isCancelled,
                  WorkspaceFiles.contains(candidate, in: canonicalRoot),
                  FileManager.default.isUbiquitousItem(at: candidate) else { return }
            try? await WorkspaceFiles.hydrateUbiquitousItemIfNeeded(candidate)
        }
    }

    private func cancelFilePrefetch() {
        filePrefetchTask?.cancel()
        filePrefetchTask = nil
        filePrefetchPath = nil
    }

    private func loadNote(_ url: URL, preservePDFPreview: Bool = false,
                          reportFailure: Bool = true) {
        cancelNoteLoad()
        previewTask?.cancel()
        requestedNote = url
        let identity = UUID()
        loadIdentity = identity
        loadingNote = true
        message = nil

        // Warmup never owns content. An actual click cancels any remaining debounce
        // and immediately enters the canonical user-initiated hydration/read path.
        cancelFilePrefetch()

        // iCloud File Provider can block while hydrating files. Never read Markdown
        // on the main actor; only publish a successful, current request. A small
        // POSIX-stamp-validated cache avoids decoding unchanged contents and also
        // detects atomic replacement / same-mtime external writes.
        let cached = noteCache[url.path]
        noteLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                guard let initialStamp = WorkspaceFiles.fileStamp(url) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                let content: String
                let resolvedStamp: WorkspaceFileStamp
                if let cached, cached.stamp == initialStamp {
                    content = cached.content
                    resolvedStamp = initialStamp
                } else {
                    let loaded = try await WorkspaceFiles.readUTF8ForOpening(url)
                    content = loaded.content
                    resolvedStamp = loaded.stamp
                }
                guard !Task.isCancelled else { return }
                await self?.finishOpeningNote(
                    url,
                    identity: identity,
                    content: content,
                    stamp: resolvedStamp,
                    preservePDFPreview: preservePDFPreview
                )
            } catch {
                guard !Task.isCancelled else { return }
                await self?.failOpeningNote(url, identity: identity,
                                            reason: error.localizedDescription,
                                            reportFailure: reportFailure)
            }
        }
    }

    private func finishOpeningNote(_ url: URL, identity: UUID, content: String,
                                   stamp: WorkspaceFileStamp, preservePDFPreview: Bool = false) {
        guard requestedNote == url, loadIdentity == identity else { return }
        selected = url
        if !preservePDFPreview {
            previewPDF = nil
            previewPDFPage = nil
        }
        let editorContent = WorkspaceFiles.editorText(content)
        baseline = editorContent
        draft = editorContent
        savedFileStamp = stamp
        cacheNote(url, content: editorContent, stamp: stamp)
        externalBody = nil
        externalTitle = nil
        previewSource = nil
        activeMatch = pendingMatch
        if pendingMatch != nil {
            matchedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            matchJumpSequence &+= 1
        }
        cancelNoteLoad()
        UserDefaults.standard.set(url.path, forKey: "PKSNotesLastOpenedMarkdown")
        if let root {
            recentNotes = NoteNavigationStore.recordRecent(url, in: root)
            requestRecentHydration(excluding: url, in: root)
        }
        backlinkTask?.cancel()
        backlinks = []
        backlinkSkippedCloudFiles = 0
        loadingBacklinks = false
        relatedTask?.cancel()
        relatedHits = []
        loadingRelated = false
        relatedError = nil
        message = nil
    }

    private func cacheNote(_ url: URL, content: String, stamp: WorkspaceFileStamp) {
        let key = url.path
        noteCache[key] = CachedNote(content: content, stamp: stamp)
        noteCacheOrder.removeAll { $0 == key }
        noteCacheOrder.append(key)
        while noteCacheOrder.count > 10 {
            let evicted = noteCacheOrder.removeFirst()
            noteCache.removeValue(forKey: evicted)
        }
    }

    /// Recent history is the strongest cheap signal for the next navigation target.
    /// Request hydration for only two neighbors and never read their contents here;
    /// File Provider remains the storage owner and loadNote remains the sole reader.
    private func requestRecentHydration(excluding active: URL, in root: URL) {
        let candidates = Array(recentNotes.lazy
            .filter { $0.standardizedFileURL != active.standardizedFileURL }
            .prefix(2))
        guard !candidates.isEmpty else { return }

        Task.detached(priority: .utility) {
            for candidate in candidates {
                guard !Task.isCancelled,
                      ["md", "markdown"].contains(candidate.pathExtension.lowercased()),
                      WorkspaceFiles.contains(candidate, in: root),
                      FileManager.default.isUbiquitousItem(at: candidate) else { continue }
                let status = try? candidate.resourceValues(
                    forKeys: [.ubiquitousItemDownloadingStatusKey]
                ).ubiquitousItemDownloadingStatus
                if status != .current {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: candidate)
                }
            }
        }
    }

    func closePDFPreview() {
        previewPDF = nil
        previewPDFPage = nil
        previewPDFAnchor = nil
        backlinkTask?.cancel()
        backlinks = []
        loadingBacklinks = false
    }

    func loadRelationships() {
        if let previewPDF {
            refreshBacklinks(for: previewPDF)
        } else if let selected {
            refreshBacklinks(for: selected)
            loadRelatedNotes(for: selected)
        }
    }

    func loadBacklinks() {
        guard let target = previewPDF ?? selected else { return }
        refreshBacklinks(for: target)
    }

    private func loadRelatedNotes(for note: URL) {
        relatedTask?.cancel()
        relatedHits = []
        relatedError = nil
        loadingRelated = true
        let queryText = note.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queryText.isEmpty else {
            loadingRelated = false
            return
        }

        relatedTask = Task { [weak self] in
            do {
                var parts = URLComponents(string: "http://127.0.0.1:3217/api/search")!
                parts.queryItems = [
                    URLQueryItem(name: "q", value: queryText),
                    URLQueryItem(name: "limit", value: "8")
                ]
                var request = URLRequest(url: parts.url!)
                request.timeoutInterval = 6
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let results = try JSONDecoder().decode([SearchHit].self, from: data)
                guard !Task.isCancelled, let self, self.selected == note else { return }

                var seen: Set<String> = []
                self.relatedHits = results.filter { hit in
                    if hit.localFileURL?.standardizedFileURL == note.standardizedFileURL { return false }
                    return seen.insert(hit.documentId).inserted
                }
                self.loadingRelated = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, self.selected == note else { return }
                self.relatedHits = []
                self.relatedError = "PKS related search unavailable."
                self.loadingRelated = false
            }
        }
    }

    /// Cloud-only backlinks remain excluded by default: opt in to a bounded
    /// download batch instead of silently hydrating an entire large vault.
    func loadMoreCloudBacklinks() {
        guard !loadingBacklinks, backlinkSkippedCloudFiles > 0,
              let target = previewPDF ?? selected else { return }
        refreshBacklinks(for: target, hydrateCloudLimit: 6)
    }

    private func refreshBacklinks(
        for note: URL,
        files suppliedFiles: [NoteItem]? = nil,
        hydrateCloudLimit: Int = 0
    ) {
        guard let root else { return }
        backlinkTask?.cancel()
        if hydrateCloudLimit == 0 {
            backlinks = []
            backlinkSkippedCloudFiles = 0
            cloudBacklinkCursor = 0
        }
        let startCursor = cloudBacklinkCursor
        loadingBacklinks = true
        backlinkTask = Task { [weak self] in
            guard let self else { return }
            let snapshot: [NoteItem]
            let candidateIndex: WorkspaceLinkCandidateIndex?
            if let suppliedFiles {
                snapshot = suppliedFiles
                candidateIndex = nil
            } else {
                guard await self.ensureGlobalFileIndex() else {
                    self.loadingBacklinks = false
                    return
                }
                snapshot = []
                candidateIndex = self.globalLinkCandidates
            }
            guard !Task.isCancelled, self.root == root else { return }

            let parseCache = self.backlinkParseCache
            let scanTask = Task.detached(priority: .utility) {
                var nextCursor = startCursor
                if hydrateCloudLimit > 0 {
                    let sources = candidateIndex?.markdownFiles
                        ?? WorkspaceBacklinks.markdownFiles(snapshot)
                    var attempted = 0
                    while nextCursor < sources.count && attempted < hydrateCloudLimit {
                        guard !Task.isCancelled else { break }
                        let source = sources[nextCursor]
                        nextCursor += 1
                        guard source != note, WorkspaceFiles.isDataless(source) else { continue }
                        attempted += 1
                        // One click attempts at most six downloads; a failure
                        // stays visibly skipped, but the next click advances.
                        try? await WorkspaceFiles.hydrateUbiquitousItemIfNeeded(source)
                    }
                    if nextCursor == sources.count { nextCursor = 0 }
                }
                let scan = WorkspaceBacklinks.scan(
                    target: note,
                    root: root,
                    files: snapshot,
                    candidateIndex: candidateIndex,
                    parseCache: parseCache
                )
                return (scan, nextCursor)
            }
            let (scan, nextCursor) = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled,
                  (self.selected == note || self.previewPDF == note),
                  self.root == root else { return }
            self.cloudBacklinkCursor = nextCursor
            self.backlinks = scan.backlinks
            self.backlinkSkippedCloudFiles = scan.skippedDatalessFiles
            self.loadingBacklinks = false
        }
    }

    private func failOpeningNote(_ url: URL, identity: UUID, reason: String,
                                 reportFailure: Bool = true) {
        guard requestedNote == url, loadIdentity == identity else { return }
        cancelNoteLoad()
        if reportFailure {
            message = "\(AppLanguage.current.text("Cannot open the note")): \(reason)"
        } else {
            // Automatic restore must not silently leave a blank workspace.
            // Preserve the path so transient iCloud failures remain retryable.
            message = AppLanguage.current.text("Could not reopen the last note. Select it again to retry.")
        }
    }

    func save() {
        guard !loadingNote, isDirty, let root, let selected,
              WorkspaceFiles.contains(selected, in: root) else { return }
        defer { autoSavePending = false }
        do {
            // POSIX ctime/inode/size/mtime together detect ordinary writes and atomic
            // replacement without rereading the whole Markdown file on every autosave.
            guard let actualStamp = WorkspaceFiles.fileStamp(selected) else {
                message = AppLanguage.current.text("The file changed outside PKS Notes. Reopen it before saving to avoid overwriting edits.")
                return
            }
            if actualStamp != savedFileStamp {
                // File Provider hydration/metadata updates may change ctime without
                // changing Markdown. Verify the single authoritative file content
                // before classifying the stamp drift as an external edit.
                guard let diskContent = try? String(contentsOf: selected, encoding: .utf8),
                      WorkspaceFiles.editorText(diskContent) == baseline else {
                    message = AppLanguage.current.text("The file changed outside PKS Notes. Reopen it before saving to avoid overwriting edits.")
                    return
                }
                savedFileStamp = actualStamp
                cacheNote(selected, content: baseline, stamp: actualStamp)
            }
            try draft.write(to: selected, atomically: true, encoding: .utf8)
            baseline = draft
            guard let updatedStamp = WorkspaceFiles.fileStamp(selected) else {
                throw CocoaError(.fileReadUnknown)
            }
            savedFileStamp = updatedStamp
            cacheNote(selected, content: draft, stamp: updatedStamp)
            // Successful saves are silent. Existing notices are user-dismissed;
            // localized presentation text is never used as save-state authority.
        } catch {
            message = "\(AppLanguage.current.text("Save failed")): \(error.localizedDescription)"
        }
    }

    /// Appends a portable PDF page reference without replacing the target note.
    /// O_APPEND keeps this capture path additive even if another process writes the file.
    @discardableResult
    func appendPDFReference(
        pdf: URL,
        page: Int,
        commentary: String? = nil,
        selectedText: String? = nil,
        anchor: PDFSourceAnchor? = nil,
        to note: URL
    ) -> Bool {
        guard let root,
              ["md", "markdown"].contains(note.pathExtension.lowercased()),
              WorkspaceFiles.contains(note, in: root),
              WorkspaceFiles.contains(pdf, in: root),
              let snippet = PDFPageReference.noteSnippet(
                for: pdf,
                page: page,
                root: root,
                commentary: commentary,
                selectedText: selectedText,
                anchor: anchor
              )
        else {
            message = AppLanguage.current.text("Could not add PDF page to note.")
            return false
        }

        var info = Darwin.stat()
        guard note.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            message = AppLanguage.current.text("The original file is no longer available.")
            return false
        }

        if selected?.standardizedFileURL == note.standardizedFileURL {
            draft += "\n\n\(snippet)\n"
            save()
            guard !isDirty else { return false }
            // Content changed, but the filesystem tree did not. Avoid a full recursive
            // workspace rescan on the study-capture hot path.
            message = "\(AppLanguage.current.text("Added PDF page to note")): \(note.deletingPathExtension().lastPathComponent)"
            return true
        }

        let descriptor = note.path.withCString {
            Darwin.open($0, O_WRONLY | O_APPEND)
        }
        guard descriptor >= 0 else {
            message = AppLanguage.current.text("Could not add PDF page to note.")
            return false
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data("\n\n\(snippet)\n".utf8))
            try handle.close()
            // Appending to an existing note does not alter file-tree shape.
            message = "\(AppLanguage.current.text("Added PDF page to note")): \(note.deletingPathExtension().lastPathComponent)"
            return true
        } catch {
            try? handle.close()
            message = "\(AppLanguage.current.text("Could not add PDF page to note.")) \(error.localizedDescription)"
            return false
        }
    }

    /// A new note is immediately usable; the UI never asks for a filename.
    /// Explicit names and automatic Untitled names share this one safe writer.
    @discardableResult
    func newNote(named name: String? = nil, in parentFolder: URL? = nil,
                 navigationDecision: UnsavedNoteDecision? = nil,
                 initialContent: String? = nil,
                 preservePDFPreview: Bool = false,
                 activateAfterCreation: Bool = true) -> URL? {
        guard let root else {
            message = AppLanguage.current.text("Choose a notes folder before creating a note."); return nil
        }
        // An explicit folder action takes precedence over the currently open note.
        let folder = (parentFolder ?? selected?.deletingLastPathComponent() ?? root).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard (folder == root || WorkspaceFiles.contains(folder, in: root)),
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            message = AppLanguage.current.text("Choose a folder inside the Markdown workspace."); return nil
        }
        let filename: String
        if let name {
            guard let normalized = WorkspaceFiles.safeNewNoteName(name) else {
                message = AppLanguage.current.text("Enter a simple note name without slashes."); return nil
            }
            filename = normalized
        } else {
            guard let available = WorkspaceFiles.nextUntitledName(in: folder) else {
                message = AppLanguage.current.text("No available filename for a new note."); return nil
            }
            filename = available
        }
        let url = folder.appendingPathComponent(filename)
        guard WorkspaceFiles.contains(url, in: root) else {
            message = AppLanguage.current.text("Invalid note path."); return nil
        }
        if activateAfterCreation {
            guard confirmLeavingNote(decision: navigationDecision) else { return nil }
        }

        // O_EXCL prevents overwriting an existing file even if another app
        // creates the same name between the availability check and the write.
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o644))
        }
        guard descriptor >= 0 else {
            message = AppLanguage.current.text("Cannot create note. The filename may already exist."); return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let content = initialContent ?? (name == nil ? "" : "# \(url.deletingPathExtension().lastPathComponent)\n\n")
            try handle.write(contentsOf: Data(content.utf8))
            try handle.close()
            scheduleFilesystemMutationRefresh(parentFolders: [folder])
            if activateAfterCreation {
                loadNote(url, preservePDFPreview: preservePDFPreview)
            }
            return url
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            message = "\(AppLanguage.current.text("Cannot create note")): \(error.localizedDescription)"
            return nil
        }
    }

    /// Roll back a file created by this process only when it is still exactly
    /// the content we created. This is not a general delete path and never
    /// removes an existing/user-modified note.
    @discardableResult
    func rollbackNewNoteIfUnchanged(_ note: URL, expectedContent: String) -> Bool {
        guard let root,
              WorkspaceFiles.contains(note, in: root),
              ["md", "markdown"].contains(note.pathExtension.lowercased()),
              let current = try? String(contentsOf: note, encoding: .utf8),
              current == expectedContent else { return false }
        var info = Darwin.stat()
        guard note.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return false }
        do {
            try FileManager.default.removeItem(at: note)
            scheduleFilesystemMutationRefresh(parentFolders: [note.deletingLastPathComponent()])
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func newFolder(named enteredName: String, in parentFolder: URL? = nil) -> URL? {
        guard let root else {
            message = AppLanguage.current.text("Choose a notes folder before creating a folder.")
            return nil
        }

        let parent = (parentFolder ?? selected?.deletingLastPathComponent() ?? root).standardizedFileURL
        var parentInfo = Darwin.stat()
        guard (parent == root.standardizedFileURL || WorkspaceFiles.contains(parent, in: root)),
              parent.path.withCString({ Darwin.lstat($0, &parentInfo) }) == 0,
              (parentInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            message = AppLanguage.current.text("Choose a folder inside the Markdown workspace.")
            return nil
        }

        let name = enteredName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.contains("\0") else {
            message = AppLanguage.current.text("Enter a folder name without slashes or special path characters.")
            return nil
        }

        let destination = parent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard WorkspaceFiles.contains(destination, in: root) else {
            message = AppLanguage.current.text("Invalid folder path.")
            return nil
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            message = AppLanguage.current.text("A file or folder with this name already exists.")
            return nil
        }

        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false
            )
            scheduleFilesystemMutationRefresh(parentFolders: [parent])
            message = nil
            return destination
        } catch {
            message = "\(AppLanguage.current.text("Cannot create folder")): \(error.localizedDescription)"
            return nil
        }
    }

    func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hits = []
            searching = false
            searchFailed = false
            searchStatus = "PKS search · 127.0.0.1:3217"
            return
        }
        searching = true
        searchFailed = false
        searchStatus = AppLanguage.current.text("Searching PKS…")
        Task {
            do {
                var parts = URLComponents(string: "http://127.0.0.1:3217/api/search")!
                parts.queryItems = [URLQueryItem(name: "q", value: text),
                                    URLQueryItem(name: "limit", value: "30")]
                var request = URLRequest(url: parts.url!)
                request.timeoutInterval = 8
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let results = try JSONDecoder().decode([SearchHit].self, from: data)
                guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                hits = results
                searchFailed = false
                searchStatus = String(
                    format: "%d %@ · %d %@ · PKS",
                    hits.count, AppLanguage.current.text("matches"),
                    groupedHits.count, AppLanguage.current.text("documents")
                )
            } catch {
                guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                hits = []
                searchFailed = true
                searchStatus = AppLanguage.current.text("PKS offline · no fallback index")
                message = "\(AppLanguage.current.text("PKS search failed")): \(error.localizedDescription)"
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                searching = false
            }
        }
    }

    private func requestMarkdownAnchor(_ fragment: String, note: URL) {
        let clean = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        markdownAnchorSequence &+= 1
        markdownAnchorRequest = MarkdownAnchorRequest(
            note: note.standardizedFileURL,
            fragment: clean,
            sequence: markdownAnchorSequence
        )
    }

    private func requestMarkdownAnchorIfNavigationStarted(_ fragment: String?, note: URL) {
        guard let fragment else { return }
        let target = note.standardizedFileURL
        guard selected?.standardizedFileURL == target
                || requestedNote?.standardizedFileURL == target
        else { return }
        requestMarkdownAnchor(fragment, note: target)
    }

    @discardableResult
    func openKnowledgeLink(
        _ target: String,
        onUnresolved: (() -> Void)? = nil
    ) -> Bool {
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }

        knowledgeLinkTask?.cancel()
        if let external = URL(string: value),
           ["http", "https"].contains(external.scheme?.lowercased() ?? "") {
            openSourceLink(external)
            return true
        }
        guard let root, let selected else {
            if let onUnresolved { onUnresolved() }
            else { message = AppLanguage.current.text("Link target not available or is ambiguous in this workspace.") }
            return false
        }

        if value.hasPrefix("#"),
           ["md", "markdown"].contains(selected.pathExtension.lowercased()),
           let fragment = WorkspaceFiles.knowledgeFragment(in: value) {
            requestMarkdownAnchor(fragment, note: selected)
            message = nil
            return true
        }

        // Exact relative/root paths remain immediate. Basename fallback must only
        // use a complete vault candidate set; a partially expanded sidebar can
        // otherwise make an ambiguous basename look unique.
        let candidates = globalFileIndexReady ? globalLinkCandidates.markdownFiles : []
        let candidateBasenames = globalFileIndexReady ? globalLinkCandidates.byBasename : [:]
        if let resolved = WorkspaceFiles.resolveLinkedTarget(
            value,
            from: selected,
            in: root,
            candidates: candidates,
            candidateBasenames: candidateBasenames
        ) {
            openResolvedKnowledgeLink(value, resolved: resolved)
            return true
        }

        guard !globalFileIndexReady else {
            if let onUnresolved { onUnresolved() }
            else { message = AppLanguage.current.text("Link target not available or is ambiguous in this workspace.") }
            return false
        }

        let sourceNote = selected
        message = AppLanguage.current.text("Scanning files…")
        knowledgeLinkTask = Task { [weak self] in
            guard let self else { return }
            let indexReady = await self.ensureGlobalFileIndex()
            guard !Task.isCancelled,
                  self.root == root,
                  self.selected == sourceNote else { return }
            guard indexReady else {
                if let onUnresolved { onUnresolved() }
                else { self.message = AppLanguage.current.text("Link target not available or is ambiguous in this workspace.") }
                return
            }

            let candidateIndex = self.globalLinkCandidates
            guard let resolved = WorkspaceFiles.resolveLinkedTarget(
                value,
                from: sourceNote,
                in: root,
                candidates: candidateIndex.markdownFiles,
                candidateBasenames: candidateIndex.byBasename
            ) else {
                if let onUnresolved { onUnresolved() }
                else { self.message = AppLanguage.current.text("Link target not available or is ambiguous in this workspace.") }
                return
            }

            self.message = nil
            self.openResolvedKnowledgeLink(value, resolved: resolved)
        }
        return true
    }

    private func openResolvedKnowledgeLink(_ value: String, resolved: URL) {
        let linkURL = URL(string: value)
        let isPDF = resolved.pathExtension.lowercased() == "pdf"
        let anchor = isPDF ? linkURL.flatMap(PDFPageReference.anchor(from:)) : nil
        let page = isPDF ? anchor?.page ?? linkURL.flatMap(PDFPageReference.page(from:)) : nil
        let fragment = isPDF ? nil : WorkspaceFiles.knowledgeFragment(in: value)
        openFile(resolved, pdfPage: page, pdfAnchor: anchor)
        requestMarkdownAnchorIfNavigationStarted(fragment, note: resolved)
    }

    /// Markdown preview and relationship panels use the same resolver, fallback
    /// index, Markdown heading navigation and PDF anchor handling.
    func openInternalLink(
        _ url: URL,
        onUnresolved: (() -> Void)? = nil
    ) -> Bool {
        guard url.scheme == nil || url.isFileURL else { return false }
        return openKnowledgeLink(url.relativeString, onUnresolved: onUnresolved)
    }

    /// Only owned regular files and real directories inside the active vault
    /// may be renamed or moved to Finder Trash.
    func canManage(_ item: URL) -> Bool {
        guard let root, WorkspaceFiles.contains(item, in: root) else { return false }
        var info = Darwin.stat()
        guard item.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return false }
        return [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(info.st_mode & mode_t(S_IFMT))
    }

    private func isInside(_ url: URL?, item: URL) -> Bool {
        guard let url else { return false }
        return url == item || url.path.hasPrefix(item.path + "/")
    }

    /// Returns the actual macOS Trash destination, which can be restored by
    /// Finder. Never call removeItem for user-owned documents.
    @discardableResult
    func moveToTrash(_ item: URL, navigationDecision: UnsavedNoteDecision? = nil) -> URL? {
        let target = item.standardizedFileURL
        guard canManage(target) else {
            message = AppLanguage.current.text("Only existing files inside the notes folder can be moved to Trash.")
            return nil
        }
        var targetInfo = Darwin.stat()
        guard target.path.withCString({ Darwin.lstat($0, &targetInfo) }) == 0 else {
            message = AppLanguage.current.text("The original file is no longer available.")
            return nil
        }
        let targetIsDirectory = (targetInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        let affectsCurrent = isInside(selected, item: target) || isInside(previewPDF, item: target)
        if affectsCurrent && !confirmLeavingNote(decision: navigationDecision) { return nil }

        do {
            var destination: NSURL?
            try FileManager.default.trashItem(at: target, resultingItemURL: &destination)
            if affectsCurrent || isInside(requestedNote, item: target) {
                cancelNoteLoad()
                previewTask?.cancel()
                autoSaveTask?.cancel()
                autoSavePending = false
                selected = nil
                previewPDF = nil
                draft = ""
                baseline = ""
                savedFileStamp = nil
                externalTitle = nil
                externalBody = nil
                previewSource = nil
                activeMatch = nil
            }
            if let previous = UserDefaults.standard.string(forKey: "PKSNotesLastOpenedMarkdown"),
               isInside(URL(fileURLWithPath: previous), item: target) {
                UserDefaults.standard.removeObject(forKey: "PKSNotesLastOpenedMarkdown")
            }
            if let root {
                NoteNavigationStore.removePath(target, in: root)
                reloadNavigationPreferences()
            }
            if targetIsDirectory { discardLoadedSubtree(target) }
            scheduleFilesystemMutationRefresh(
                parentFolders: [target.deletingLastPathComponent()]
            )
            message = nil
            return destination as URL?
        } catch {
            message = "\(AppLanguage.current.text("Could not move to Trash")): \(error.localizedDescription)"
            return nil
        }
    }

    /// Rename in-place without changing the original file type or moving it
    /// outside the selected workspace. For folders, rebase an open descendant.
    @discardableResult
    func renameItem(_ item: URL, to enteredName: String,
                    navigationDecision: UnsavedNoteDecision? = nil) async -> URL? {
        let target = item.standardizedFileURL
        guard canManage(target) else {
            message = AppLanguage.current.text("Only existing files inside the notes folder can be renamed.")
            return nil
        }
        let stem = enteredName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty, stem != ".", stem != "..", !stem.hasPrefix("."),
              !stem.contains("/"), !stem.contains("\\"), !stem.contains(":"),
              !stem.contains("\0") else {
            message = AppLanguage.current.text("Enter a filename without slashes or special path characters.")
            return nil
        }
        let isFolder = (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let suffix = isFolder || target.pathExtension.isEmpty ? "" : "." + target.pathExtension
        let bareName = !suffix.isEmpty && stem.lowercased().hasSuffix(suffix.lowercased())
            ? String(stem.dropLast(suffix.count)) : stem
        guard !bareName.isEmpty else { message = AppLanguage.current.text("Enter a valid filename."); return nil }
        let destination = target.deletingLastPathComponent()
            .appendingPathComponent(bareName + suffix).standardizedFileURL
        guard let root, WorkspaceFiles.contains(destination, in: root) else {
            message = AppLanguage.current.text("The new name is outside the notes folder."); return nil
        }
        if destination == target { return target }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            message = AppLanguage.current.text("A file or folder with this name already exists."); return nil
        }
        let oldSelected = selected
        let oldPDF = previewPDF
        let oldRequested = requestedNote
        let oldDraftRevision = draftRevision
        let affected = isInside(oldSelected, item: target)
            || isInside(oldPDF, item: target) || isInside(oldRequested, item: target)
        if affected && !confirmLeavingNote(decision: navigationDecision) { return nil }
        if !affected && isDirty {
            save()
            guard !isDirty else { return nil }
        }
        guard fileOperationInProgress == nil else {
            message = AppLanguage.current.text("Another file operation is still in progress.")
            return nil
        }
        fileOperationInProgress = target
        defer {
            if fileOperationInProgress?.standardizedFileURL == target {
                fileOperationInProgress = nil
            }
        }
        invalidateGlobalFileIndex()
        guard await ensureGlobalFileIndex(), self.root == root else {
            message = AppLanguage.current.text("The file changed while preparing the path change. Try again.")
            return nil
        }
        let candidateFiles = globalLinkCandidates.markdownFiles
        let candidateBasenames = globalLinkCandidates.byBasename
        let ownLinkRepair: WorkspaceLinkRelocation.Prepared?
        do {
            ownLinkRepair = isFolder ? nil
                : try await WorkspaceLinkRelocation.prepare(
                    from: target,
                    to: destination,
                    root: root,
                    markdownFiles: candidateFiles,
                    candidateBasenames: candidateBasenames
                )
        } catch {
            message = "\(AppLanguage.current.text("Could not prepare path change")): \(error.localizedDescription)"
            return nil
        }
        let relatedLinkRepair = await WorkspaceLinkRelocation.prepareRelatedSources(
            from: target,
            to: destination,
            movingIsDirectory: isFolder,
            root: root,
            markdownFiles: candidateFiles,
            candidateBasenames: candidateBasenames
        )
        let selectedRelatedEdit = oldSelected.flatMap { selected in
            relatedLinkRepair.edits.first {
                $0.source.standardizedFileURL == selected.standardizedFileURL
            }
        }
        guard selected == oldSelected, previewPDF == oldPDF, requestedNote == oldRequested,
              (!affected || draftRevision == oldDraftRevision),
              (selectedRelatedEdit == nil || (!isDirty && draftRevision == oldDraftRevision)),
              ownLinkRepair.map({ WorkspaceLinkRelocation.sourceIsCurrent($0, at: target) }) ?? true,
              WorkspaceLinkRelocation.relatedSourcesAreCurrent(relatedLinkRepair) else {
            message = selectedRelatedEdit != nil && isDirty
                ? AppLanguage.current.text("Save or resolve the current note before changing this path because one of its links must be updated.")
                : AppLanguage.current.text("The file changed while preparing the path change. Try again.")
            return nil
        }

        func rebased(_ url: URL?) -> URL? {
            guard let url, isInside(url, item: target) else { return nil }
            if url == target { return destination }
            return destination.appendingPathComponent(String(url.path.dropFirst(target.path.count + 1)))
        }

        do {
            try FileManager.default.moveItem(at: target, to: destination)
            let repaired = ownLinkRepair.map { WorkspaceLinkRelocation.apply($0, to: destination) }
            let relatedRepaired = WorkspaceLinkRelocation.apply(relatedLinkRepair)
            if relatedRepaired, !affected, let edit = selectedRelatedEdit,
               selected?.standardizedFileURL == edit.source.standardizedFileURL,
               draft == edit.original, baseline == edit.original {
                autoSaveTask?.cancel()
                baseline = edit.updated
                draft = edit.updated
                autoSaveTask?.cancel()
                autoSavePending = false
                savedFileStamp = WorkspaceFiles.fileStamp(edit.destination)
            }
            if let newSelected = rebased(oldSelected) ?? rebased(oldRequested) {
                loadNote(newSelected)
            } else if let newPDF = rebased(oldPDF) {
                previewPDF = newPDF
            }
            if let previous = UserDefaults.standard.string(forKey: "PKSNotesLastOpenedMarkdown"),
               let renamed = rebased(URL(fileURLWithPath: previous)) {
                UserDefaults.standard.set(renamed.path, forKey: "PKSNotesLastOpenedMarkdown")
            }
            NoteNavigationStore.replacePath(target, with: destination, in: root)
            reloadNavigationPreferences()
            if isFolder {
                // Directory rename rebases every descendant identity, so retain
                // the conservative full refresh for correctness.
                refresh()
            } else {
                scheduleFilesystemMutationRefresh(
                    parentFolders: [target.deletingLastPathComponent()]
                )
            }
            let skippedLinkSources = relatedLinkRepair.skippedCloudFiles
                + relatedLinkRepair.skippedUnavailableFiles
            if repaired == false || !relatedRepaired {
                message = AppLanguage.current.text("Path changed, but some related links could not be preserved. Review affected notes.")
            } else if skippedLinkSources > 0 {
                message = "\(AppLanguage.current.text("Path changed. Some cloud-only or unavailable notes were not checked for links.")) (\(skippedLinkSources))"
            } else if ownLinkRepair != nil || !relatedLinkRepair.edits.isEmpty {
                message = AppLanguage.current.text("Path changed and related links were updated.")
            } else {
                message = nil
            }
            return destination
        } catch {
            message = "\(AppLanguage.current.text("Could not rename file")): \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func copyItem(_ item: URL, to directory: URL) async -> URL? {
        let target = item.standardizedFileURL
        let folder = directory.standardizedFileURL
        guard canManage(target), let root,
              (folder == root.standardizedFileURL || WorkspaceFiles.contains(folder, in: root)) else {
            message = AppLanguage.current.text("Choose a destination inside the notes folder."); return nil
        }
        var info = Darwin.stat()
        guard folder.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            message = AppLanguage.current.text("Choose an existing destination folder."); return nil
        }
        var targetInfo = Darwin.stat()
        guard target.path.withCString({ Darwin.lstat($0, &targetInfo) }) == 0 else {
            message = AppLanguage.current.text("The original item is no longer available."); return nil
        }
        let targetIsDirectory = (targetInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        if targetIsDirectory && (folder == target || folder.path.hasPrefix(target.path + "/")) {
            message = AppLanguage.current.text("A folder cannot be copied inside itself."); return nil
        }

        let destination = folder.appendingPathComponent(target.lastPathComponent).standardizedFileURL
        guard destination != target, !FileManager.default.fileExists(atPath: destination.path) else {
            message = AppLanguage.current.text("The destination already contains an item with this name."); return nil
        }

        let selectedInsideCopy = isInside(selected, item: target)
        if selectedInsideCopy && isDirty {
            save()
            guard !isDirty else { return nil }
        }
        guard fileOperationInProgress == nil else {
            message = AppLanguage.current.text("Another file operation is still in progress.")
            return nil
        }
        fileOperationInProgress = target
        defer {
            if fileOperationInProgress?.standardizedFileURL == target {
                fileOperationInProgress = nil
            }
        }

        let selectedBeforeCopy = selected
        let draftRevisionBeforeCopy = draftRevision
        let isMarkdown = ["md", "markdown"].contains(target.pathExtension.lowercased())
        var directRepair: WorkspaceLinkRelocation.Prepared?
        var folderRepair: WorkspaceLinkRelocation.RelatedPlan?

        if targetIsDirectory || isMarkdown {
            invalidateGlobalFileIndex()
            guard await ensureGlobalFileIndex(), self.root == root else {
                message = AppLanguage.current.text("The file changed while preparing the file operation. Try again.")
                return nil
            }
            let candidateFiles = globalLinkCandidates.markdownFiles
            let candidateBasenames = globalLinkCandidates.byBasename
            if targetIsDirectory {
                folderRepair = await WorkspaceLinkRelocation.prepareCopiedSources(
                    from: target,
                    to: destination,
                    root: root,
                    markdownFiles: candidateFiles,
                    candidateBasenames: candidateBasenames
                )
            } else {
                do {
                    directRepair = try await WorkspaceLinkRelocation.prepare(
                        from: target,
                        to: destination,
                        root: root,
                        markdownFiles: candidateFiles,
                        candidateBasenames: candidateBasenames
                    )
                } catch {
                    message = "\(AppLanguage.current.text("Could not prepare file operation")): \(error.localizedDescription)"
                    return nil
                }
            }
        }

        guard selected == selectedBeforeCopy,
              (!selectedInsideCopy || draftRevision == draftRevisionBeforeCopy),
              directRepair.map({ WorkspaceLinkRelocation.sourceIsCurrent($0, at: target) }) ?? true,
              folderRepair.map(WorkspaceLinkRelocation.relatedSourcesAreCurrent) ?? true else {
            message = AppLanguage.current.text("The file changed while preparing the file operation. Try again.")
            return nil
        }

        let copyError = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try FileManager.default.copyItem(at: target, to: destination)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let copyError {
            message = "\(AppLanguage.current.text("Could not copy item")): \(copyError)"
            return nil
        }

        let directRepaired = directRepair.map { WorkspaceLinkRelocation.apply($0, to: destination) }
        let folderRepaired = folderRepair.map(WorkspaceLinkRelocation.apply)
        scheduleFilesystemMutationRefresh(parentFolders: [folder])

        let skippedLinkSources = (folderRepair?.skippedCloudFiles ?? 0)
            + (folderRepair?.skippedUnavailableFiles ?? 0)
        if directRepaired == false || folderRepaired == false {
            message = AppLanguage.current.text("Copied, but some links could not be preserved. Review the copy.")
        } else if skippedLinkSources > 0 {
            message = "\(AppLanguage.current.text("Copied. Some cloud-only or unavailable notes were not checked for relative links.")) (\(skippedLinkSources))"
        } else if directRepair != nil || !(folderRepair?.edits.isEmpty ?? true) {
            message = AppLanguage.current.text("Copied and related links were updated.")
        } else {
            message = nil
        }
        return destination
    }

    @discardableResult
    func moveItem(_ item: URL, to directory: URL,
                  navigationDecision: UnsavedNoteDecision? = nil) async -> URL? {
        let target = item.standardizedFileURL
        let folder = directory.standardizedFileURL
        guard canManage(target), let root,
              (folder == root.standardizedFileURL || WorkspaceFiles.contains(folder, in: root)) else {
            message = AppLanguage.current.text("Choose a destination inside the notes folder."); return nil
        }
        var info = Darwin.stat()
        guard folder.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            message = AppLanguage.current.text("Choose an existing destination folder."); return nil
        }
        var targetInfo = Darwin.stat()
        guard target.path.withCString({ Darwin.lstat($0, &targetInfo) }) == 0 else {
            message = AppLanguage.current.text("The original item is no longer available."); return nil
        }
        let targetIsDirectory = (targetInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        if targetIsDirectory && (folder == target || folder.path.hasPrefix(target.path + "/")) {
            message = AppLanguage.current.text("A folder cannot be moved inside itself."); return nil
        }

        let destination = folder.appendingPathComponent(target.lastPathComponent).standardizedFileURL
        if destination == target { return target }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            message = AppLanguage.current.text("The destination already contains an item with this name."); return nil
        }

        let oldSelected = selected
        let oldPDF = previewPDF
        let oldRequested = requestedNote
        let oldDraftRevision = draftRevision
        let affected = isInside(oldSelected, item: target)
            || isInside(oldPDF, item: target) || isInside(oldRequested, item: target)
        if affected && !confirmLeavingNote(decision: navigationDecision) { return nil }
        if !affected && isDirty {
            save()
            guard !isDirty else { return nil }
        }
        guard fileOperationInProgress == nil else {
            message = AppLanguage.current.text("Another file operation is still in progress.")
            return nil
        }
        fileOperationInProgress = target
        defer {
            if fileOperationInProgress?.standardizedFileURL == target {
                fileOperationInProgress = nil
            }
        }
        invalidateGlobalFileIndex()
        guard await ensureGlobalFileIndex(), self.root == root else {
            message = AppLanguage.current.text("The file changed while preparing the path change. Try again.")
            return nil
        }
        let candidateFiles = globalLinkCandidates.markdownFiles
        let candidateBasenames = globalLinkCandidates.byBasename
        let ownLinkRepair: WorkspaceLinkRelocation.Prepared?
        do {
            ownLinkRepair = targetIsDirectory ? nil
                : try await WorkspaceLinkRelocation.prepare(
                    from: target,
                    to: destination,
                    root: root,
                    markdownFiles: candidateFiles,
                    candidateBasenames: candidateBasenames
                )
        } catch {
            message = "\(AppLanguage.current.text("Could not prepare path change")): \(error.localizedDescription)"
            return nil
        }
        let relatedLinkRepair = await WorkspaceLinkRelocation.prepareRelatedSources(
            from: target,
            to: destination,
            movingIsDirectory: targetIsDirectory,
            root: root,
            markdownFiles: candidateFiles,
            candidateBasenames: candidateBasenames
        )
        let selectedRelatedEdit = oldSelected.flatMap { selected in
            relatedLinkRepair.edits.first {
                $0.source.standardizedFileURL == selected.standardizedFileURL
            }
        }
        guard selected == oldSelected, previewPDF == oldPDF, requestedNote == oldRequested,
              (!affected || draftRevision == oldDraftRevision),
              (selectedRelatedEdit == nil || (!isDirty && draftRevision == oldDraftRevision)),
              ownLinkRepair.map({ WorkspaceLinkRelocation.sourceIsCurrent($0, at: target) }) ?? true,
              WorkspaceLinkRelocation.relatedSourcesAreCurrent(relatedLinkRepair) else {
            message = selectedRelatedEdit != nil && isDirty
                ? AppLanguage.current.text("Save or resolve the current note before changing this path because one of its links must be updated.")
                : AppLanguage.current.text("The file changed while preparing the path change. Try again.")
            return nil
        }

        func rebased(_ url: URL?) -> URL? {
            guard let url, isInside(url, item: target) else { return nil }
            if url == target { return destination }
            return destination.appendingPathComponent(String(url.path.dropFirst(target.path.count + 1)))
        }

        do {
            try FileManager.default.moveItem(at: target, to: destination)
            let repaired = ownLinkRepair.map { WorkspaceLinkRelocation.apply($0, to: destination) }
            let relatedRepaired = WorkspaceLinkRelocation.apply(relatedLinkRepair)
            if relatedRepaired, !affected, let edit = selectedRelatedEdit,
               selected?.standardizedFileURL == edit.source.standardizedFileURL,
               draft == edit.original, baseline == edit.original {
                autoSaveTask?.cancel()
                baseline = edit.updated
                draft = edit.updated
                autoSaveTask?.cancel()
                autoSavePending = false
                savedFileStamp = WorkspaceFiles.fileStamp(edit.destination)
            }
            if let newSelected = rebased(oldSelected) ?? rebased(oldRequested) {
                loadNote(newSelected)
            } else if let newPDF = rebased(oldPDF) {
                previewPDF = newPDF
            }
            if let previous = UserDefaults.standard.string(forKey: "PKSNotesLastOpenedMarkdown"),
               let moved = rebased(URL(fileURLWithPath: previous)) {
                UserDefaults.standard.set(moved.path, forKey: "PKSNotesLastOpenedMarkdown")
            }
            NoteNavigationStore.replacePath(target, with: destination, in: root)
            reloadNavigationPreferences()
            if targetIsDirectory {
                // Directory moves recursively rebase descendant paths; do not
                // maintain a second in-memory path authority for that case.
                refresh()
            } else {
                scheduleFilesystemMutationRefresh(
                    parentFolders: [target.deletingLastPathComponent(), folder]
                )
            }
            let skippedLinkSources = relatedLinkRepair.skippedCloudFiles
                + relatedLinkRepair.skippedUnavailableFiles
            if repaired == false || !relatedRepaired {
                message = AppLanguage.current.text("Path changed, but some related links could not be preserved. Review affected notes.")
            } else if skippedLinkSources > 0 {
                message = "\(AppLanguage.current.text("Path changed. Some cloud-only or unavailable notes were not checked for links.")) (\(skippedLinkSources))"
            } else if ownLinkRepair != nil || !relatedLinkRepair.edits.isEmpty {
                message = AppLanguage.current.text("Path changed and related links were updated.")
            } else {
                message = nil
            }
            return destination
        } catch {
            message = "\(AppLanguage.current.text("Could not move item")): \(error.localizedDescription)"
            return nil
        }
    }

    func revealInFinder(_ file: URL) {
        guard file.isFileURL, FileManager.default.fileExists(atPath: file.path) else {
            message = AppLanguage.current.text("The original file is not available locally.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func openInDefaultApp(_ file: URL) {
        guard file.isFileURL, FileManager.default.fileExists(atPath: file.path) else {
            message = AppLanguage.current.text("The original file is not available locally.")
            return
        }
        if !NSWorkspace.shared.open(file) {
            message = "\(AppLanguage.current.text("No application could open")) \(file.lastPathComponent)."
        }
    }

    func openSourceLink(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func importClipboardImage() -> String? {
        guard let root, let selected else { return nil }
        let pasteboard = NSPasteboard.general
        let image: NSImage?
        if let data = pasteboard.data(forType: .png) {
            image = NSImage(data: data)
        } else {
            image = NSImage(pasteboard: pasteboard)
        }

        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              let relative = WorkspaceFiles.storePastedPNG(png, for: selected, in: root) else {
            return nil
        }
        return "![Pasted image](\(relative))"
    }

    func copySource(_ value: String) {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(value, forType: .string) {
            message = AppLanguage.current.text("Unable to copy source location.")
        }
    }

    func openResult(_ hit: SearchHit) {
        if let file = hit.localFileURL {
            if let root, WorkspaceFiles.contains(file, in: root) {
                if ["md", "markdown"].contains(file.pathExtension.lowercased()) {
                    if selected != file || requestedNote != nil {
                        openFile(file)
                        if requestedNote == file { pendingMatch = hit }
                    } else {
                        activeMatch = hit
                        matchedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        matchJumpSequence &+= 1
                    }
                } else {
                    openFile(file)
                }
            } else {
                // Keep outside-workspace local sources in their original default app.
                openInDefaultApp(file)
            }
            return
        }
        guard confirmLeavingNote() else { return }
        // This request becomes the newest navigation intent, including after Discard.
        cancelNoteLoad()
        previewTask?.cancel()
        let sourceNote = selected
        let sourceDraftRevision = draftRevision
        let sourceRoot = root
        previewTask = Task {
            do {
                let encoded = hit.documentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
                let url = URL(string: "http://127.0.0.1:3217/api/read/\(encoded)?maxChars=30000")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let result = try JSONDecoder().decode(ReadResponse.self, from: data)
                // Discard means the old draft may still be dirty until this preview
                // commits. Only reject a stale response if context changed since launch.
                guard !Task.isCancelled, selected == sourceNote,
                      draftRevision == sourceDraftRevision, root == sourceRoot else { return }
                selected = nil
                previewPDF = nil
                externalTitle = hit.title + " · read-only PKS result"
                externalBody = result.content
                previewSource = hit
                activeMatch = hit
                matchedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                matchJumpSequence &+= 1
                message = result.truncated == true ? "Preview truncated at 30,000 characters." : nil
            } catch is CancellationError {
                // The user opened a different note or preview while the request was in flight.
            } catch {
                guard !Task.isCancelled else { return }
                message = "\(AppLanguage.current.text("PKS preview failed")): \(error.localizedDescription)"
            }
        }
    }
}
