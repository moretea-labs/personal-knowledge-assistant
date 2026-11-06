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
                return NoteItem(url: url, children: children)
            }
            return kind == mode_t(S_IFREG) ? NoteItem(url: url, children: nil) : nil
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

    /// Deterministic collision-safe suggestion; O_EXCL remains the final writer guard.
    static func nextUntitledName(in folder: URL) -> String? {
        for index in 0..<10_000 {
            let base = index == 0 ? "Untitled" : "Untitled \(index + 1)"
            let filename = base + ".md"
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(filename).path) {
                return filename
            }
        }
        return nil
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
    @Published private(set) var loadingNote = false
    @Published private(set) var selected: URL?
    @Published private(set) var previewPDF: URL?
    @Published var draft: String = "" {
        didSet { scheduleAutoSave() }
    }
    @Published private(set) var autoSavePending = false
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
    private var autoSaveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var noteLoadTask: Task<Void, Never>?
    private var requestedNote: URL?
    private var loadIdentity: UUID?
    private var pendingMatch: SearchHit?
    private var securityScopedFolder: URL?

    var isDirty: Bool { selected != nil && draft != baseline }
    var title: String { externalTitle ?? previewPDF?.lastPathComponent ?? selected?.lastPathComponent ?? "Select a note" }
    var body: String { externalBody ?? draft }
    var groupedHits: [SearchResultGroup] { SearchResultGroup.group(hits) }

    /// The Markdown file remains the only writer/authority; the task only schedules save().
    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        guard !loadingNote, isDirty, let note = selected else {
            autoSavePending = false
            return
        }
        autoSavePending = true
        let snapshot = draft
        autoSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) }
            catch { return }
            guard !Task.isCancelled, let self,
                  self.selected == note, self.draft == snapshot, self.isDirty else { return }
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
            message = "Folder opened, but macOS could not save permanent access. Choose it again next launch."
        }
    }

    @discardableResult
    func openWorkspace(_ url: URL, navigationDecision: UnsavedNoteDecision? = nil) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            message = "Choose an existing Markdown folder."; return false
        }
        if root == resolved { return true }
        guard confirmLeavingNote(decision: navigationDecision) else { return false }

        previewTask?.cancel()
        cancelNoteLoad()
        root = resolved
        message = nil
        UserDefaults.standard.set(resolved.path, forKey: "PKSNotesWorkspace")
        files = []
        refresh()
        selected = nil
        previewPDF = nil
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
        guard WorkspaceFiles.contains(url, in: root),
              ["md", "markdown"].contains(url.pathExtension.lowercased()) else { return }
        var info = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return }
        openNote(url)
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
            alert.messageText = "Unsaved Markdown changes"
            alert.informativeText = "Save changes to \(title) before leaving this note?"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Changes")
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
    func openFile(_ url: URL, navigationDecision: UnsavedNoteDecision? = nil) {
        guard let root, WorkspaceFiles.contains(url, in: root) else {
            message = "File is outside the selected workspace."; return
        }
        var info = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            message = "The original file is no longer available."; return
        }

        if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            openNote(url, navigationDecision: navigationDecision)
        } else if url.pathExtension.lowercased() == "pdf" {
            if previewPDF == url { return }
            guard confirmLeavingNote(decision: navigationDecision) else { return }
            cancelNoteLoad()
            previewTask?.cancel()
            selected = nil
            previewPDF = url
            baseline = ""
            draft = ""
            externalTitle = nil
            externalBody = nil
            previewSource = nil
            activeMatch = nil
            message = nil
        } else {
            // Do not replace the current note when handing a file to another app.
            openInDefaultApp(url)
        }
    }

    func openNote(_ url: URL, navigationDecision: UnsavedNoteDecision? = nil) {
        if requestedNote == url { return }
        if selected == url {
            cancelNoteLoad() // A re-selection wins over another pending file load.
            return
        }
        guard let root, WorkspaceFiles.contains(url, in: root),
              ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            message = "Only Markdown files inside the selected workspace can be edited."; return
        }
        guard confirmLeavingNote(decision: navigationDecision) else { return }
        loadNote(url)
    }

    private func cancelNoteLoad() {
        noteLoadTask?.cancel()
        noteLoadTask = nil
        requestedNote = nil
        loadIdentity = nil
        pendingMatch = nil
        loadingNote = false
    }

    private func loadNote(_ url: URL) {
        cancelNoteLoad()
        previewTask?.cancel()
        requestedNote = url
        let identity = UUID()
        loadIdentity = identity
        loadingNote = true
        message = nil

        // iCloud File Provider can block while hydrating files. Never read Markdown
        // on the main actor; only publish a successful, current request.
        noteLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let modification = attrs[.modificationDate] as? Date
                guard !Task.isCancelled else { return }
                await self?.finishOpeningNote(url, identity: identity,
                                              content: content, modification: modification)
            } catch {
                guard !Task.isCancelled else { return }
                await self?.failOpeningNote(url, identity: identity,
                                            reason: error.localizedDescription)
            }
        }
    }

    private func finishOpeningNote(_ url: URL, identity: UUID, content: String,
                                   modification: Date?) {
        guard requestedNote == url, loadIdentity == identity else { return }
        selected = url
        previewPDF = nil
        baseline = content
        draft = content
        savedModification = modification
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
        message = nil
    }

    private func failOpeningNote(_ url: URL, identity: UUID, reason: String) {
        guard requestedNote == url, loadIdentity == identity else { return }
        cancelNoteLoad()
        message = "Cannot open the note: \(reason)"
    }

    func save() {
        guard !loadingNote, isDirty, let root, let selected,
              WorkspaceFiles.contains(selected, in: root) else { return }
        defer { autoSavePending = false }
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
            // Successful saves are silent; the native toolbar only shows pending progress.
            if message?.hasPrefix("Save failed:") == true ||
               message?.hasPrefix("The file changed outside") == true {
                message = nil
            }
        } catch {
            message = "Save failed: \(error.localizedDescription)"
        }
    }

    /// A new note is immediately usable; the UI never asks for a filename.
    /// Explicit names and automatic Untitled names share this one safe writer.
    @discardableResult
    func newNote(named name: String? = nil, in parentFolder: URL? = nil,
                 navigationDecision: UnsavedNoteDecision? = nil) -> URL? {
        guard let root else {
            message = "Choose a notes folder before creating a note."; return nil
        }
        // An explicit folder action takes precedence over the currently open note.
        let folder = (parentFolder ?? selected?.deletingLastPathComponent() ?? root).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard (folder == root || WorkspaceFiles.contains(folder, in: root)),
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            message = "Choose a folder inside the Markdown workspace."; return nil
        }
        let filename: String
        if let name {
            guard let normalized = WorkspaceFiles.safeNewNoteName(name) else {
                message = "Enter a simple note name without slashes."; return nil
            }
            filename = normalized
        } else {
            guard let available = WorkspaceFiles.nextUntitledName(in: folder) else {
                message = "No available filename for a new note."; return nil
            }
            filename = available
        }
        let url = folder.appendingPathComponent(filename)
        guard WorkspaceFiles.contains(url, in: root) else {
            message = "Invalid note path."; return nil
        }
        guard confirmLeavingNote(decision: navigationDecision) else { return nil }

        // O_EXCL prevents overwriting an existing file even if another app
        // creates the same name between the availability check and the write.
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o644))
        }
        guard descriptor >= 0 else {
            message = "Cannot create note. The filename may already exist."; return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let content = name == nil ? "" : "# \(url.deletingPathExtension().lastPathComponent)\n\n"
            try handle.write(contentsOf: Data(content.utf8))
            try handle.close()
            refresh()
            loadNote(url)
            return url
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            message = "Cannot create note: \(error.localizedDescription)"
            return nil
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
        if resolved.pathExtension.isEmpty {
            let markdown = resolved.appendingPathExtension("md")
            if FileManager.default.fileExists(atPath: markdown.path) {
                openFile(markdown)
                return true
            }
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else { return false }
        openFile(resolved)
        return true
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
        if !NSWorkspace.shared.open(file) {
            message = "No application could open \(file.lastPathComponent)."
        }
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
        let sourceDraft = draft
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
                      draft == sourceDraft, root == sourceRoot else { return }
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
                message = "PKS preview failed: \(error.localizedDescription)"
            }
        }
    }
}
