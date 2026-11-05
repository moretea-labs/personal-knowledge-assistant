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
    var name: String { isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }

    static func == (lhs: NoteItem, rhs: NoteItem) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

enum WorkspaceFiles {
    static func defaultVault() -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/学习笔记管理", isDirectory: true)
        return root
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

    static func tree(in root: URL) -> [NoteItem] {
        let fm = FileManager.default
        // File Provider can block on contentsOfDirectory(at:includingPropertiesForKeys:).
        // Plain names plus lstat are enough to classify entries without hydrating iCloud files.
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.compactMap { name -> NoteItem? in
            guard !name.hasPrefix(".") else { return nil }
            let url = root.appendingPathComponent(name)
            var info = Darwin.stat()
            guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
            let kind = info.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) { return nil }
            if kind == mode_t(S_IFDIR) {
                let children = tree(in: url)
                return children.isEmpty ? nil : NoteItem(url: url, children: children)
            }
            let ext = url.pathExtension.lowercased()
            return ["md", "markdown"].contains(ext) ? NoteItem(url: url, children: nil) : nil
        }.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
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

    static func safeNewNoteName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.hasPrefix("."),
              !trimmed.contains("\0") else { return nil }
        let base = trimmed.hasSuffix(".md") ? String(trimmed.dropLast(3)) : trimmed
        return base.isEmpty ? nil : base + ".md"
    }
}

@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var files: [NoteItem] = []
    @Published private(set) var loadingFiles = false
    @Published private(set) var selected: URL?
    @Published var draft: String = ""
    @Published private(set) var baseline: String = ""
    @Published private(set) var externalTitle: String?
    @Published private(set) var externalBody: String?
    @Published private(set) var previewSource: SearchHit?
    @Published private(set) var activeMatch: SearchHit?
    @Published private(set) var matchJumpSequence = 0
    @Published private(set) var matchedQuery = ""
    @Published var query = ""
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var searching = false
    @Published var message: String?
    @Published private(set) var searchStatus = "PKS search · 127.0.0.1:3217"
    private var savedModification: Date?
    private var previewTask: Task<Void, Never>?
    private var securityScopedFolder: URL?

    var isDirty: Bool { selected != nil && draft != baseline }
    var title: String { externalTitle ?? selected?.lastPathComponent ?? "Select a note" }
    var body: String { externalBody ?? draft }
    var groupedHits: [SearchResultGroup] { SearchResultGroup.group(hits) }

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
                message = "Select the existing iCloud folder once to grant macOS access."
            } else {
                let url = URL(fileURLWithPath: configured, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) { openWorkspace(url) }
            }
        } else {
            message = "Choose your existing Markdown folder once. No account is required."
        }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.message = "Choose the existing Markdown directory (no import or duplication)"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = (root ?? WorkspaceFiles.defaultVault()).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            if let previous = securityScopedFolder { previous.stopAccessingSecurityScopedResource() }
            securityScopedFolder = url.startAccessingSecurityScopedResource() ? url : nil
            // Store the one macOS user-selected folder grant, never note contents.
            let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
            if let bookmark { UserDefaults.standard.set(bookmark, forKey: "PKSNotesWorkspaceBookmark") }
            openWorkspace(url)
        }
    }

    func openWorkspace(_ url: URL) {
        guard !isDirty else { message = "Save or discard your changes before changing folders."; return }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            message = "Choose an existing Markdown folder."; return
        }
        previewTask?.cancel()
        root = resolved
        message = nil
        UserDefaults.standard.set(resolved.path, forKey: "PKSNotesWorkspace")
        files = []
        refresh()
        selected = nil
        externalTitle = nil
        externalBody = nil
        previewSource = nil
        activeMatch = nil
        draft = ""
        baseline = ""
    }

    func refresh() {
        guard let root else { return }
        loadingFiles = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = WorkspaceFiles.tree(in: root)
            guard let model = self else { return }
            await MainActor.run {
                guard model.root == root else { return }
                model.files = scanned
                model.loadingFiles = false
            }
        }
    }

    func openNote(_ url: URL) {
        guard !isDirty else { message = "Save this note before opening another."; return }
        guard let root, WorkspaceFiles.contains(url, in: root),
              ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            message = "Only Markdown files inside the selected workspace can be edited."; return
        }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            savedModification = attrs[.modificationDate] as? Date
            previewTask?.cancel()
            selected = url
            baseline = content
            draft = content
            externalBody = nil
            externalTitle = nil
            previewSource = nil
            activeMatch = nil
            message = nil
        } catch {
            message = "Cannot open the note: \(error.localizedDescription)"
        }
    }

    func save() {
        guard isDirty, let root, let selected, WorkspaceFiles.contains(selected, in: root) else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: selected.path)
            let actual = attrs[.modificationDate] as? Date
            // Avoid overwriting iCloud or other editor changes without review.
            guard actual == savedModification,
                  try String(contentsOf: selected, encoding: .utf8) == baseline else {
                message = "The file changed outside PKS Notes. Reopen it before saving to avoid overwriting edits."
                return
            }
            try draft.write(to: selected, atomically: true, encoding: .utf8)
            baseline = draft
            let updated = try FileManager.default.attributesOfItem(atPath: selected.path)
            savedModification = updated[.modificationDate] as? Date
            message = selected.path.contains("/Mobile Documents/")
                ? "Saved to iCloud Markdown file." : "Saved to Markdown file."
        } catch {
            message = "Save failed: \(error.localizedDescription)"
        }
    }

    func newNote(named name: String) {
        guard let root, let filename = WorkspaceFiles.safeNewNoteName(name) else {
            message = "Enter a simple note name without slashes."; return
        }
        guard !isDirty else { message = "Save your current note first."; return }
        // New notes belong beside the selected note; without a selection, use the vault root.
        let folder = selected?.deletingLastPathComponent() ?? root
        let url = folder.appendingPathComponent(filename)
        guard WorkspaceFiles.contains(url, in: root) else { message = "Invalid note path."; return }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            message = "The note already exists."; return
        }
        do {
            try "# \(url.deletingPathExtension().lastPathComponent)\n\n".write(to: url, atomically: true, encoding: .utf8)
            refresh()
            openNote(url)
        } catch {
            message = "Cannot create note: \(error.localizedDescription)"
        }
    }

    func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            hits = []
            searching = false
            searchStatus = "PKS search · 127.0.0.1:3217"
            return
        }
        searching = true
        searchStatus = "Searching PKS…"
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
                searchStatus = "\(hits.count) matches · \(groupedHits.count) documents · PKS"
            } catch {
                guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                hits = []
                searchStatus = "PKS offline · no fallback index"
                message = "PKS search failed: \(error.localizedDescription)"
            }
            if query.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                searching = false
            }
        }
    }

    func openInternalLink(_ url: URL) -> Bool {
        guard let root, let selected,
              let resolved = WorkspaceFiles.resolve(url, from: selected, in: root) else { return false }
        if ["md", "markdown"].contains(resolved.pathExtension.lowercased()) {
            openNote(resolved)
            return true
        }
        if resolved.pathExtension.isEmpty {
            let markdown = resolved.appendingPathExtension("md")
            if FileManager.default.fileExists(atPath: markdown.path) {
                openNote(markdown)
                return true
            }
        }
        return false
    }

    func revealInFinder(_ file: URL) {
        guard file.isFileURL, FileManager.default.fileExists(atPath: file.path) else {
            message = "The original file is not available locally."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    func openInDefaultApp(_ file: URL) {
        guard file.isFileURL, FileManager.default.fileExists(atPath: file.path) else {
            message = "The original file is not available locally."
            return
        }
        NSWorkspace.shared.open(file)
    }

    func openSourceLink(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    func copySource(_ value: String) {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(value, forType: .string) {
            message = "Unable to copy source location."
        }
    }

    func openResult(_ hit: SearchHit) {
        if hit.sourceType == "local", let url = hit.localFileURL, let root,
           WorkspaceFiles.contains(url, in: root),
           ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            // Repeated hits in the currently edited file can navigate without
            // reopening it or losing unsaved Markdown changes.
            if selected != url { openNote(url) }
            if selected == url {
                activeMatch = hit
                matchedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                matchJumpSequence &+= 1
            }
            return
        }
        guard !isDirty else { message = "Save the current note before opening another result."; return }
        // Cancel previous previews so delayed network results cannot replace another note.
        previewTask?.cancel()
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
                guard !Task.isCancelled, !isDirty else { return }
                selected = nil
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
                message = "PKS preview failed: \(error.localizedDescription)"
            }
        }
    }
}
