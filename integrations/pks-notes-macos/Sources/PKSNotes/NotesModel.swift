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

    /// Resolve a WikiLink/Markdown note target through one deterministic workspace path.
    /// Exact relative/root paths win; basename fallback is accepted only when unique.
    static func resolveKnowledgeTarget(
        _ rawTarget: String,
        from note: URL,
        in root: URL,
        candidates suppliedCandidates: [URL]? = nil
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
        let candidates = suppliedCandidates ?? WorkspaceBacklinks.markdownFiles(tree(in: root))
        let matches = candidates.filter {
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
        candidates: [URL]? = nil
    ) -> URL? {
        let value = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let markdown = resolveKnowledgeTarget(
            value,
            from: note,
            in: root,
            candidates: candidates
        ) {
            return markdown
        }

        guard let link = URL(string: value),
              link.scheme == nil || link.isFileURL,
              let resolved = resolve(link, from: note, in: root),
              FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return resolved
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

    static func safeNewNoteName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.hasPrefix("."),
              !trimmed.contains("\0") else { return nil }
        let base = trimmed.hasSuffix(".md") ? String(trimmed.dropLast(3)) : trimmed
        return base.isEmpty ? nil : base + ".md"
    }
}

struct NoteBacklink: Identifiable, Equatable {
    let source: URL
    let count: Int

    var id: String { source.path }
    var title: String { source.deletingPathExtension().lastPathComponent }
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

    static func find(target: URL, root: URL, files: [NoteItem]) -> [NoteBacklink] {
        let target = target.standardizedFileURL
        let candidates = markdownFiles(files)
        var result: [NoteBacklink] = []

        for source in candidates where source != target {
            guard let content = try? String(contentsOf: source, encoding: .utf8) else { continue }
            var count = 0
            for line in content.components(separatedBy: .newlines) {
                for link in MindMapOutline.links(in: line) {
                    guard let resolved = WorkspaceFiles.resolveLinkedTarget(
                        link.target, from: source, in: root, candidates: candidates
                    ) else { continue }
                    if resolved.standardizedFileURL == target { count += 1 }
                }
            }
            if count > 0 { result.append(.init(source: source, count: count)) }
        }

        return result.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
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
    @Published private(set) var previewPDFPage: Int?
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
    @Published private(set) var searchFailed = false
    @Published private(set) var backlinks: [NoteBacklink] = []
    @Published private(set) var loadingBacklinks = false
    @Published private(set) var relatedHits: [SearchHit] = []
    @Published private(set) var loadingRelated = false
    @Published private(set) var recentNotes: [URL] = []
    @Published private(set) var favoriteNotes: [URL] = []
    @Published private(set) var relatedError: String?
    private var savedModification: Date?
    private var autoSaveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var noteLoadTask: Task<Void, Never>?
    private var requestedNote: URL?
    private var loadIdentity: UUID?
    private var pendingMatch: SearchHit?
    private var securityScopedFolder: URL?
    private var backlinkTask: Task<Void, Never>?
    private var relatedTask: Task<Void, Never>?

    var isDirty: Bool { selected != nil && draft != baseline }
    var title: String { externalTitle ?? previewPDF?.lastPathComponent ?? selected?.lastPathComponent ?? "Select a note" }
    var body: String { externalBody ?? draft }
    var groupedHits: [SearchResultGroup] { SearchResultGroup.group(hits) }
    var outgoingLinks: [MindMapLink] { MindMapOutline.knowledgeLinks(in: draft) }
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
        root = resolved
        message = nil
        UserDefaults.standard.set(resolved.path, forKey: "PKSNotesWorkspace")
        reloadNavigationPreferences()
        files = []
        backlinks = []
        backlinkTask?.cancel()
        loadingBacklinks = false
        relatedHits = []
        relatedTask?.cancel()
        loadingRelated = false
        relatedError = nil
        refresh()
        selected = nil
        previewPDF = nil
        previewPDFPage = nil
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
        pdfPage: Int? = nil
    ) {
        guard let root, WorkspaceFiles.contains(url, in: root) else {
            message = AppLanguage.current.text("File is outside the selected workspace."); return
        }
        var info = Darwin.stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            message = AppLanguage.current.text("The original file is no longer available."); return
        }

        if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            openNote(url, navigationDecision: navigationDecision)
        } else if url.pathExtension.lowercased() == "pdf" {
            if previewPDF == url {
                if let pdfPage { previewPDFPage = pdfPage }
                return
            }
            guard confirmLeavingNote(decision: navigationDecision) else { return }
            cancelNoteLoad()
            previewTask?.cancel()
            selected = nil
            previewPDF = url
            previewPDFPage = pdfPage
            baseline = ""
            draft = ""
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

    func openNote(_ url: URL, navigationDecision: UnsavedNoteDecision? = nil) {
        if requestedNote == url { return }
        if selected == url {
            cancelNoteLoad() // A re-selection wins over another pending file load.
            return
        }
        guard let root, WorkspaceFiles.contains(url, in: root),
              ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            message = AppLanguage.current.text("Only Markdown files inside the selected workspace can be edited."); return
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
        previewPDFPage = nil
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
        if let root {
            recentNotes = NoteNavigationStore.recordRecent(url, in: root)
        }
        backlinkTask?.cancel()
        backlinks = []
        loadingBacklinks = false
        relatedTask?.cancel()
        relatedHits = []
        loadingRelated = false
        relatedError = nil
        message = nil
    }

    func loadRelationships() {
        if let selected {
            refreshBacklinks(for: selected)
            loadRelatedNotes(for: selected)
        } else if let previewPDF {
            refreshBacklinks(for: previewPDF)
        }
    }

    func loadBacklinks() {
        guard let target = selected ?? previewPDF else { return }
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

    private func refreshBacklinks(for note: URL, files suppliedFiles: [NoteItem]? = nil) {
        guard let root else { return }
        backlinkTask?.cancel()
        backlinks = []
        loadingBacklinks = true
        let snapshot = suppliedFiles ?? files
        backlinkTask = Task.detached(priority: .utility) { [weak self] in
            let found = WorkspaceBacklinks.find(target: note, root: root, files: snapshot)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard (self.selected == note || self.previewPDF == note),
                      self.root == root else { return }
                self.backlinks = found
                self.loadingBacklinks = false
            }
        }
    }

    private func failOpeningNote(_ url: URL, identity: UUID, reason: String) {
        guard requestedNote == url, loadIdentity == identity else { return }
        cancelNoteLoad()
        message = "\(AppLanguage.current.text("Cannot open the note")): \(reason)"
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
                message = AppLanguage.current.text("The file changed outside PKS Notes. Reopen it before saving to avoid overwriting edits.")
                return
            }
            try draft.write(to: selected, atomically: true, encoding: .utf8)
            baseline = draft
            let updated = try FileManager.default.attributesOfItem(atPath: selected.path)
            savedModification = updated[.modificationDate] as? Date
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
                selectedText: selectedText
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
            refresh()
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
                 initialContent: String? = nil) -> URL? {
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
        guard confirmLeavingNote(decision: navigationDecision) else { return nil }

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
            refresh()
            loadNote(url)
            return url
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            message = "\(AppLanguage.current.text("Cannot create note")): \(error.localizedDescription)"
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

    @discardableResult
    func openKnowledgeLink(_ target: String) -> Bool {
        let value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if let external = URL(string: value),
           ["http", "https"].contains(external.scheme?.lowercased() ?? "") {
            openSourceLink(external)
            return true
        }
        guard let root, let selected,
              let resolved = WorkspaceFiles.resolveLinkedTarget(value, from: selected, in: root) else {
            message = AppLanguage.current.text("Link target not available or is ambiguous in this workspace.")
            return false
        }
        let page = resolved.pathExtension.lowercased() == "pdf"
            ? URL(string: value).flatMap(PDFPageReference.page(from:))
            : nil
        openFile(resolved, pdfPage: page)
        return true
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
        let page = resolved.pathExtension.lowercased() == "pdf"
            ? PDFPageReference.page(from: url)
            : nil
        openFile(resolved, pdfPage: page)
        return true
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
                savedModification = nil
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
            refresh()
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
                    navigationDecision: UnsavedNoteDecision? = nil) -> URL? {
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
        let affected = isInside(oldSelected, item: target)
            || isInside(oldPDF, item: target) || isInside(oldRequested, item: target)
        if affected && !confirmLeavingNote(decision: navigationDecision) { return nil }

        func rebased(_ url: URL?) -> URL? {
            guard let url, isInside(url, item: target) else { return nil }
            if url == target { return destination }
            return destination.appendingPathComponent(String(url.path.dropFirst(target.path.count + 1)))
        }

        do {
            try FileManager.default.moveItem(at: target, to: destination)
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
            refresh()
            message = nil
            return destination
        } catch {
            message = "\(AppLanguage.current.text("Could not rename file")): \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func copyItem(_ item: URL, to directory: URL) -> URL? {
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

        do {
            try FileManager.default.copyItem(at: target, to: destination)
            refresh()
            message = nil
            return destination
        } catch {
            message = "\(AppLanguage.current.text("Could not copy item")): \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func moveItem(_ item: URL, to directory: URL,
                  navigationDecision: UnsavedNoteDecision? = nil) -> URL? {
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
        let affected = isInside(oldSelected, item: target)
            || isInside(oldPDF, item: target) || isInside(oldRequested, item: target)
        if affected && !confirmLeavingNote(decision: navigationDecision) { return nil }

        func rebased(_ url: URL?) -> URL? {
            guard let url, isInside(url, item: target) else { return nil }
            if url == target { return destination }
            return destination.appendingPathComponent(String(url.path.dropFirst(target.path.count + 1)))
        }

        do {
            try FileManager.default.moveItem(at: target, to: destination)
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
            refresh()
            message = nil
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
                message = "\(AppLanguage.current.text("PKS preview failed")): \(error.localizedDescription)"
            }
        }
    }
}
