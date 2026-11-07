import AppKit
import SwiftUI
import MarkdownUI
import PDFKit

@MainActor
final class PKSNotesAppDelegate: NSObject, NSApplicationDelegate {
    weak var notesModel: NotesModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = notesModel else { return .terminateNow }
        return model.confirmLeavingNote() ? .terminateNow : .terminateCancel
    }
}

@main
struct PKSNotesApp: App {
    @NSApplicationDelegateAdaptor(PKSNotesAppDelegate.self) private var appDelegate
    @StateObject private var model = NotesModel()
    @AppStorage(AppAppearance.defaultsKey) private var appearanceID = AppAppearance.system.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var languageID = AppLanguage.system.rawValue

    private var appearance: AppAppearance { AppAppearance.restored(appearanceID) }
    private var language: AppLanguage { AppLanguage.restored(languageID) }

    var body: some Scene {
        WindowGroup {
            NotesWindow()
                .environmentObject(model)
                .environment(\.notesLanguage, language)
                .environment(\.locale, language.locale)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear { appDelegate.notesModel = model }
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1220, height: 780)

        Settings {
            NotesAppearanceSettings()
                .environment(\.notesLanguage, language)
                .environment(\.locale, language.locale)
                .preferredColorScheme(appearance.colorScheme)
        }
        .commands {
            // This single-window editor uses Cmd+N for a note, not another app window.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .pasteboard) {
                Button(language.text("Cut")) { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x", modifiers: .command)
                Button(language.text("Copy")) { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: .command)
                Button(language.text("Paste")) {
                    NotificationCenter.default.post(name: NotesMenuEvent.paste, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
            }
            CommandMenu("Markdown") {
                Button(language.text("Bold")) { NotesMenuEvent.postFormat("bold") }
                    .keyboardShortcut("b", modifiers: .command)
                Button(language.text("Italic")) { NotesMenuEvent.postFormat("italic") }
                    .keyboardShortcut("i", modifiers: .command)
                Button(language.text("Inline Code")) { NotesMenuEvent.postFormat("code") }
                    .keyboardShortcut("e", modifiers: .command)
                Button(language.text("Link")) { NotesMenuEvent.postFormat("link") }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button(language.text("Heading 1")) { NotesMenuEvent.postFormat("h1") }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button(language.text("Heading 2")) { NotesMenuEvent.postFormat("h2") }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button(language.text("Heading 3")) { NotesMenuEvent.postFormat("h3") }
                    .keyboardShortcut("3", modifiers: [.command, .shift])
                Divider()
                Button(language.text("Bullet List")) { NotesMenuEvent.postFormat("bullet") }
                    .keyboardShortcut("8", modifiers: [.command, .shift])
                Button(language.text("Task")) { NotesMenuEvent.postFormat("task") }
                    .keyboardShortcut("9", modifiers: [.command, .shift])
            }
            CommandMenu("PKS") {
                Button(language.text("New Markdown Note")) {
                    NotificationCenter.default.post(name: NotesMenuEvent.newNote, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button(language.text("Quick Open…")) {
                    NotificationCenter.default.post(name: NotesMenuEvent.quickOpen, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
                Divider()
                Button(language.text("Toggle Edit / Preview")) {
                    NotificationCenter.default.post(name: NotesMenuEvent.toggleEdit, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)
                Divider()
                Button(language.text("Save Markdown")) { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button(language.text("Find in PKS")) {
                    NotificationCenter.default.post(name: NotesMenuEvent.search, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Button(language.text("Run PKS Search")) { model.search() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Divider()
                Button(language.text("Refresh Files")) { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button(language.text("Choose Folder…")) { model.chooseWorkspace() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

/// Local geometry authority for the native toolbar and folder/file tree.
enum NotesGeometry {
    static let disclosureWidth: CGFloat = 16
    static let treeIconWidth: CGFloat = 18
    static let treeTextGap: CGFloat = 8
    static let treeIndent: CGFloat = 16
    static let treeRowHeight: CGFloat = 32
    static let sidebarInset: CGFloat = 14
    static let symbolSize: CGFloat = 14
    static let toolbarTarget: CGFloat = 28
    static let selectionCorner: CGFloat = 9

    static func workspaceTitle(_ root: URL?, language: AppLanguage) -> String {
        guard let root else { return language.text("PKS Library") }
        let name = root.lastPathComponent
        return name == "com~apple~CloudDocs" ? language.text("iCloud Drive") : name
    }
}

private enum NotesMenuEvent {
    static let quickOpen = Notification.Name("PKSNotesMenuQuickOpen")
    static let newNote = Notification.Name("PKSNotesMenuNewNote")
    static let search = Notification.Name("PKSNotesMenuSearch")
    static let toggleEdit = Notification.Name("PKSNotesToggleEditPreview")
    static let paste = Notification.Name("PKSNotesPaste")
    static let markdownFormat = Notification.Name("PKSNotesMarkdownFormat")

    static func postFormat(_ value: String) {
        NotificationCenter.default.post(name: markdownFormat, object: value)
    }
}

private enum SidebarTab: String, CaseIterable {
    case notes = "Notes"
    case recent = "Recent"
    case favorites = "Favorites"
    case search = "Search"
}

enum ReadingMode: String, CaseIterable {
    case edit = "Edit"
    case split = "Split"
    case read = "Read"

    var symbol: String {
        switch self {
        case .edit: "square.and.pencil"
        case .split: "rectangle.split.2x1"
        case .read: "book"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .edit: "1"
        case .split: "2"
        case .read: "3"
        }
    }
}

private struct PreviewWarmupKey: Hashable {
    let identity: String
    let source: String
    let enabled: Bool
}

struct NotesWindow: View {
    @EnvironmentObject private var model: NotesModel
    @Environment(\.notesLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: ReadingMode = .read
    @State private var showingMindMap = false
    @AppStorage("PKSNotesReadingTheme") private var themeID = NotesTheme.system.rawValue
    @AppStorage("PKSNotesFontAdjustment") private var fontAdjustment = 0.0
    @AppStorage("PKSNotesLineAdjustment") private var lineAdjustment = 0.0
    @AppStorage("PKSNotesWidthAdjustment") private var widthAdjustment = 0.0
    @State private var previewCache: MarkdownPreviewSnapshot?
    @State private var visibleTreeRows: [NoteTreePresentation.Row] = []
    @State private var allOpenableFiles: [NoteItem] = []
    @State private var showingQuickOpen = false
    @State private var showingBacklinks = false
    @State private var showingOutline = false
    @State private var quickOpenQuery = ""
    @State private var quickOpenIndex = 0

    private var quickOpenMatches: [NoteItem] {
        NoteTreePresentation.quickOpen(allOpenableFiles, query: quickOpenQuery)
    }

    private var outlineHeadings: [MarkdownOutlineHeading] {
        MarkdownOutline.headings(in: model.draft)
    }

    private var sidebarSectionTitleKey: String {
        switch sidebarTab {
        case .notes: "FOLDERS"
        case .recent: "RECENT NOTES"
        case .favorites: "FAVORITES"
        case .search: "SEARCH RESULTS"
        }
    }

    private var theme: NotesTheme { NotesTheme.restored(themeID) }
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarTab: SidebarTab = .notes
    @State private var pendingEditorFocus: URL?
    @State private var pendingMindMapOpen: URL?
    @State private var renameCandidate: URL?
    @State private var renameValue = ""
    @State private var showingRename = false
    @State private var folderTrashCandidate: URL?
    @State private var confirmingFolderTrash = false
    @State private var expandedFolderPaths: Set<String> = []
    @State private var treeCursorPath: String?
    @State private var fileDropTargetPath: String?
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var treeFocused: Bool
    @FocusState private var quickOpenFocused: Bool
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 205, ideal: 242, max: 325)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.selected != nil && model.externalBody == nil && model.previewPDF == nil {
                    HStack(spacing: 2) {
                        ForEach(ReadingMode.allCases, id: \.self) { choice in
                            Button {
                                switchReadingMode(to: choice)
                            } label: {
                                Image(systemName: choice.symbol)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(mode == choice ? theme.linkColor : Color.secondary)
                                    .frame(width: 29, height: 27)
                                    .background(mode == choice ? theme.linkColor.opacity(0.14) : .clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(choice.shortcut, modifiers: .command)
                            .help("\(language.text(choice.rawValue)) Markdown")
                            .accessibilityIdentifier("pks-mode-\(choice.rawValue.lowercased())")
                        }
                    }
                    .padding(3)
                    .background(Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.045),
                                in: RoundedRectangle(cornerRadius: 9))
                }

                if model.selected != nil && model.externalBody == nil && model.previewPDF == nil {
                    Button {
                        showingMindMap.toggle()
                    } label: {
                        toolbarSymbol(showingMindMap ? "doc.text" : "point.3.connected.trianglepath.dotted")
                    }
                    .help(language.text(showingMindMap ? "Return to Markdown" : "Mind Map"))
                    .accessibilityIdentifier("pks-mind-map-toggle")
                }
                if model.selected != nil && model.externalBody == nil && model.previewPDF == nil {
                    Button {
                        showingOutline.toggle()
                    } label: {
                        toolbarSymbol("list.bullet.indent")
                    }
                    .buttonStyle(.plain)
                    .disabled(outlineHeadings.isEmpty)
                    .help(language.text("Document Outline"))
                    .accessibilityIdentifier("pks-outline-menu")
                    .popover(isPresented: $showingOutline, arrowEdge: .bottom) {
                        outlinePopover
                    }

                    Button {
                        model.toggleFavorite()
                    } label: {
                        toolbarSymbol(model.selectedIsFavorite ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .help(language.text(model.selectedIsFavorite ? "Remove from Favorites" : "Add to Favorites"))
                    .accessibilityIdentifier("pks-favorite-toggle")
                }

                if model.selected != nil && model.externalBody == nil && model.previewPDF == nil {
                    Button {
                        showingBacklinks.toggle()
                        if showingBacklinks { model.loadRelationships() }
                    } label: {
                        HStack(spacing: 4) {
                            toolbarSymbol("link")
                            if !model.backlinks.isEmpty {
                                Text("\(model.backlinks.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(language.text("Links and related notes"))
                    .accessibilityIdentifier("pks-relationships-menu")
                    .popover(isPresented: $showingBacklinks, arrowEdge: .bottom) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text(language.text("Relationships")).font(.headline)
                                    Spacer()
                                    if model.loadingBacklinks || model.loadingRelated {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)

                                Divider()

                                relationshipSectionTitle(language.text("Outgoing"))
                                if model.outgoingLinks.isEmpty {
                                    relationshipEmpty(language.text("No links from this note."))
                                } else {
                                    ForEach(Array(model.outgoingLinks.enumerated()), id: \.offset) { _, link in
                                        relationshipButton(
                                            title: link.label,
                                            detail: link.target,
                                            symbol: "arrow.up.right"
                                        ) {
                                            showingBacklinks = false
                                            _ = model.openKnowledgeLink(link.target)
                                        }
                                    }
                                }

                                Divider().padding(.vertical, 4)
                                relationshipSectionTitle(language.text("Backlinks"))
                                if model.loadingBacklinks {
                                    relationshipEmpty(language.text("Finding notes that link here…"))
                                } else if model.backlinks.isEmpty {
                                    relationshipEmpty(language.text("No backlinks in this workspace."))
                                } else {
                                    ForEach(model.backlinks) { backlink in
                                        relationshipButton(
                                            title: backlink.title,
                                            detail: backlink.count > 1
                                                ? "\(backlink.count) \(language.text("references"))"
                                                : language.text("1 reference"),
                                            symbol: "arrow.turn.up.left"
                                        ) {
                                            showingBacklinks = false
                                            model.openFile(backlink.source)
                                        }
                                    }
                                }

                                Divider().padding(.vertical, 4)
                                relationshipSectionTitle(language.text("Related · PKS"))
                                if model.loadingRelated {
                                    relationshipEmpty(language.text("Finding related knowledge…"))
                                } else if let error = model.relatedError {
                                    relationshipEmpty(error)
                                } else if model.relatedHits.isEmpty {
                                    relationshipEmpty(language.text("No related PKS results."))
                                } else {
                                    ForEach(model.relatedHits.prefix(6)) { hit in
                                        relationshipButton(
                                            title: hit.title,
                                            detail: language.text(hit.sourceLabel),
                                            symbol: "sparkles"
                                        ) {
                                            showingBacklinks = false
                                            model.openResult(hit)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(width: 340, height: 430)
                    }
                }

                if model.autoSavePending && model.selected != nil {
                    ProgressView()
                        .controlSize(.small)
                        .help(language.text("Saving Markdown automatically…"))
                        .accessibilityIdentifier("pks-autosave-progress")
                }

                Menu {
                    Button(language.text("Quick Open Note…"), systemImage: "doc.text.magnifyingglass") {
                        openQuickPicker()
                    }
                    Button(language.text("New Mind Map"), systemImage: "point.3.connected.trianglepath.dotted") {
                        beginNewMindMap()
                    }
                    Divider()
                    if let file = model.selected ?? model.previewPDF ?? model.previewSource?.localFileURL {
                        fileActions(file)
                        Divider()
                    } else if let link = model.previewSource?.webURL {
                        Button(language.text("Open Source in Browser"), systemImage: "globe") { model.openSourceLink(link) }
                        Button(language.text("Copy Source Link"), systemImage: "link") { model.copySource(link.absoluteString) }
                        Divider()
                    }
                    Button(language.text("Refresh Files"), systemImage: "arrow.clockwise") { model.refresh() }
                    Button(language.text("Choose Folder…"), systemImage: "folder") { model.chooseWorkspace() }
                } label: {
                    toolbarSymbol("ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .accessibilityIdentifier("pks-file-actions-menu")
                .help(language.text("File actions and workspace options"))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.quickOpen)) { _ in
            openQuickPicker()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.newNote)) { _ in
            beginNewNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.search)) { _ in
            focusKnowledgeSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.toggleEdit)) { _ in
            toggleEditPreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.markdownFormat)) { note in
            guard let value = note.object as? String else { return }
            applyMarkdownFormat(value)
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.paste)) { _ in
            handlePaste()
        }
        .task(id: PreviewWarmupKey(
            identity: model.selected?.path ?? "",
            source: model.body,
            enabled: mode == .edit && model.selected != nil && !model.loadingNote
        )) {
            guard mode == .edit, !model.loadingNote, model.externalBody == nil,
                  let identity = model.selected?.path else { return }
            let input = model.draft
            guard previewCache?.matches(identity: identity, source: input, matchID: nil) != true
            else { return }
            // Idle-only parse in the background; no preview view is mounted or laid out.
            do { try await Task.sleep(for: .milliseconds(520)) }
            catch { return }
            guard !Task.isCancelled else { return }
            let parser = Task.detached(priority: .utility) {
                MarkdownPreviewParsing.prepare(input, match: nil)
            }
            defer { parser.cancel() }
            let sections = await parser.value
            guard !Task.isCancelled, model.selected?.path == identity,
                  model.draft == input, mode == .edit else { return }
            previewCache = MarkdownPreviewSnapshot(identity: identity, source: input,
                                                    matchID: nil, sections: sections)
        }
        .onReceive(model.$files) { files in
            visibleTreeRows = NoteTreePresentation.visibleRows(files, expandedPaths: expandedFolderPaths)
            allOpenableFiles = NoteTreePresentation.openableFiles(files)
        }
        .onChange(of: expandedFolderPaths) { _, expanded in
            visibleTreeRows = NoteTreePresentation.visibleRows(model.files, expandedPaths: expanded)
        }
        .onChange(of: model.root) { _, _ in
            expandedFolderPaths.removeAll()
            treeCursorPath = nil
            previewCache = nil
        }
        .onChange(of: model.selected) { _, note in
            let openAsMap = note != nil && note == pendingMindMapOpen
            showingMindMap = openAsMap
            if openAsMap {
                pendingMindMapOpen = nil
                mode = .read
            }
            showingBacklinks = false
            if let note, let root = model.root {
                expandedFolderPaths.formUnion(NoteTreePresentation.ancestorPaths(for: note, in: root))
                treeCursorPath = note.path
            }
            if note == pendingEditorFocus, note != nil {
                pendingEditorFocus = nil
                mode = .edit
                Task { @MainActor in editorFocused = true }
            }
        }
        .sheet(isPresented: $showingQuickOpen) {
            quickOpenSheet
        }
        .alert(language.text("Rename"), isPresented: $showingRename) {
            TextField(language.text("Name"), text: $renameValue)
                .accessibilityIdentifier("pks-rename-field")
            Button(language.text("Rename")) {
                if let item = renameCandidate { _ = model.renameItem(item, to: renameValue) }
                renameCandidate = nil
            }
            Button(language.text("Cancel"), role: .cancel) { renameCandidate = nil }
        } message: {
            Text(language.text("Change the name without moving the item. File extensions are preserved."))
        }
        .alert(language.text("Move Folder to Trash?"), isPresented: $confirmingFolderTrash) {
            Button(language.text("Move to Trash"), role: .destructive) {
                if let folder = folderTrashCandidate { _ = model.moveToTrash(folder) }
                folderTrashCandidate = nil
            }
            Button(language.text("Cancel"), role: .cancel) { folderTrashCandidate = nil }
        } message: {
            Text(language.text("The folder and all of its contents will move to the macOS Trash, where they can be restored."))
        }
    }

    private func toolbarSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: NotesGeometry.symbolSize, weight: .medium))
            .frame(width: NotesGeometry.toolbarTarget, height: NotesGeometry.toolbarTarget)
            .contentShape(Rectangle())
    }

    private func switchReadingMode(to choice: ReadingMode) {
        guard model.selected != nil, model.previewPDF == nil, model.externalBody == nil else { return }
        withAnimation(.easeOut(duration: 0.14)) { mode = choice }
        if choice == .edit {
            Task { @MainActor in
                await Task.yield()
                editorFocused = true
            }
        }
    }

    private func toggleEditPreview() {
        guard model.selected != nil, model.previewPDF == nil, model.externalBody == nil else { return }
        switchReadingMode(to: mode == .edit ? .read : .edit)
    }

    private func beginRename(_ item: URL) {
        guard model.canManage(item) else { return }
        renameCandidate = item
        renameValue = item.hasDirectoryPath || (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            ? item.lastPathComponent : item.deletingPathExtension().lastPathComponent
        showingRename = true
    }

    private func requestMoveToTrash(_ item: URL) {
        guard model.canManage(item) else { return }
        let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        if isFolder {
            folderTrashCandidate = item
            confirmingFolderTrash = true
        } else {
            _ = model.moveToTrash(item)
        }
    }

    private func focusKnowledgeSearch() {
        columnVisibility = .all
        sidebarTab = .search
        searchFieldFocused = true
    }

    private func beginNewNote(in folder: URL? = nil) {
        if model.root == nil {
            model.chooseWorkspace()
            guard model.root != nil else { return }
        }
        guard let created = model.newNote(in: folder) else { return }
        pendingEditorFocus = created
        mode = .edit
        if model.selected == created {
            pendingEditorFocus = nil
            Task { @MainActor in editorFocused = true }
        }
    }

    private func beginNewMindMap(in folder: URL? = nil) {
        if model.root == nil {
            model.chooseWorkspace()
            guard model.root != nil else { return }
        }
        guard let created = model.newNote(
            in: folder, initialContent: MindMapOutline.createMap()
        ) else { return }
        pendingEditorFocus = nil
        pendingMindMapOpen = created
        if model.selected == created {
            pendingMindMapOpen = nil
            showingMindMap = true
            mode = .read
        }
    }

    private func openQuickPicker() {
        quickOpenQuery = ""
        quickOpenIndex = 0
        showingQuickOpen = true
    }

    private func openQuickMatch(_ item: NoteItem) {
        showingQuickOpen = false
        model.openFile(item.url)
    }

    private var quickOpenSheet: some View {
        let matches = quickOpenMatches
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: NotesGeometry.symbolSize, weight: .medium))
                    .frame(width: NotesGeometry.treeIconWidth)
                    .foregroundStyle(.secondary)
                TextField(language.text("Search files…"), text: $quickOpenQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($quickOpenFocused)
                    .onSubmit {
                        guard !matches.isEmpty else { return }
                        openQuickMatch(matches[min(quickOpenIndex, matches.count - 1)])
                    }
                    .onKeyPress(.downArrow) {
                        quickOpenIndex = min(quickOpenIndex + 1, max(0, matches.count - 1))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        quickOpenIndex = max(0, quickOpenIndex - 1)
                        return .handled
                    }
                    .accessibilityIdentifier("pks-quick-open-input")
                Button {
                    showingQuickOpen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: NotesGeometry.toolbarTarget, height: NotesGeometry.toolbarTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help(language.text("Cancel (Esc)"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            Divider()
                .opacity(0.45)
                .padding(.horizontal, 20)
            if matches.isEmpty {
                Text(language.text(quickOpenQuery.isEmpty ? "Type a name to find a note in your library."
                     : "No files match your search."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(matches.indices, id: \.self) { i in
                            let item = matches[i]
                            Button {
                                openQuickMatch(item)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.iconName)
                                        .font(.system(size: NotesGeometry.symbolSize))
                                        .foregroundStyle(.secondary)
                                        .frame(width: NotesGeometry.treeIconWidth)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name)
                                            .font(.system(size: 14, weight: i == quickOpenIndex ? .semibold : .regular))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(NoteTreePresentation.quickOpenFolder(for: item.url, in: model.root))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .help(NoteTreePresentation.quickOpenFolder(for: item.url, in: model.root))
                                    }
                                    Spacer()
                                    if i == quickOpenIndex {
                                        Image(systemName: "return")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    i == quickOpenIndex ? theme.linkColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pks-quick-open-\(item.id)")
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 560, height: matches.isEmpty ? 176 : min(470, max(238, CGFloat(matches.count) * 54 + 83)))
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.16), value: matches.isEmpty)
        .onChange(of: quickOpenQuery) { _, _ in quickOpenIndex = 0 }
        .onAppear { quickOpenFocused = true }
    }

    /// Bear/Panda-inspired quiet navigation tint. Editorial content retains its own
    /// untouched white/paper canvas; no translucent cards or decorative shadows.
    private var sidebarCanvas: Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.112, blue: 0.121)
            : Color(red: 0.972, green: 0.978, blue: 0.975)
    }

    private func navigationRow(_ tab: SidebarTab, symbol: String, title: String) -> some View {
        let selected = sidebarTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.14)) { sidebarTab = tab }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18, height: 22)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if tab == .search && !model.hits.isEmpty {
                    Text("\(model.hits.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(selected ? Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.065) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(tab == .notes ? "pks-sidebar-notes" : "pks-sidebar-search")
    }

    private func fileTreeRow(_ row: NoteTreePresentation.Row) -> some View {
                        let isSelected = model.selected == row.item.url || model.previewPDF == row.item.url
                        return HStack(spacing: 0) {
                            // Both folders and documents reserve the same disclosure column.
                            if row.item.isFolder {
                                Button {
                                    treeCursorPath = row.id
                                    treeFocused = true
                                    toggleFolder(row.item.url)
                                } label: {
                                    Image(systemName: expandedFolderPaths.contains(row.item.id)
                                          ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: NotesGeometry.disclosureWidth,
                                               height: NotesGeometry.treeRowHeight)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(language.text(expandedFolderPaths.contains(row.item.id)
                                      ? "Collapse folder" : "Expand folder"))
                                .accessibilityLabel(
                                    language.text(expandedFolderPaths.contains(row.item.id) ? "Collapse" : "Expand")
                                    + " " + row.item.name
                                )
                            } else {
                                Color.clear.frame(width: NotesGeometry.disclosureWidth,
                                                  height: NotesGeometry.treeRowHeight)
                            }

                            Image(systemName: row.item.isFolder ? "folder.fill" : row.item.iconName)
                                .font(.system(size: NotesGeometry.symbolSize, weight: .regular))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                .frame(width: NotesGeometry.treeIconWidth,
                                       height: NotesGeometry.treeRowHeight)

                            if row.item.isFolder {
                                Text(row.item.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                    .frame(height: NotesGeometry.treeRowHeight)
                                    .padding(.leading, NotesGeometry.treeTextGap)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        treeCursorPath = row.id
                                        treeFocused = true
                                        toggleFolder(row.item.url)
                                    }
                                    .simultaneousGesture(TapGesture(count: 1).onEnded {
                                        treeCursorPath = row.id
                                        treeFocused = true
                                    })
                                    .help(language.text("Double-click to expand or collapse"))
                            } else {
                                Button {
                                    treeCursorPath = row.id
                                    treeFocused = true
                                    model.openFile(row.item.url)
                                } label: {
                                    Text(row.item.name)
                                        .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(1)
                                        .frame(height: NotesGeometry.treeRowHeight)
                                        .padding(.leading, NotesGeometry.treeTextGap)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("pks-note-\(row.item.name)")
                            }
                        }
                        .padding(.leading, CGFloat(row.depth) * NotesGeometry.treeIndent)
                        .background(isSelected ? Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.075)
                                    : fileDropTargetPath == row.id
                                        ? theme.linkColor.opacity(0.12)
                                        : treeFocused && treeCursorPath == row.id
                                            ? Color.primary.opacity(0.04) : .clear,
                                    in: RoundedRectangle(cornerRadius: NotesGeometry.selectionCorner))
                        .overlay {
                            if row.item.isFolder && fileDropTargetPath == row.id {
                                RoundedRectangle(cornerRadius: NotesGeometry.selectionCorner)
                                    .stroke(theme.linkColor.opacity(0.75), lineWidth: 1.5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .draggable(row.item.url)
                        .dropDestination(for: URL.self) { urls, _ in
                            guard row.item.isFolder,
                                  let source = urls.first?.standardizedFileURL,
                                  model.canManage(source),
                                  source != row.item.url else { return false }
                            let moved = model.moveItem(source, to: row.item.url)
                            if moved != nil {
                                expandedFolderPaths.insert(row.item.url.path)
                                fileDropTargetPath = nil
                                return true
                            }
                            return false
                        } isTargeted: { targeted in
                            guard row.item.isFolder else { return }
                            fileDropTargetPath = targeted ? row.id : nil
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .contextMenu {
                            if row.item.isFolder {
                                Button(language.text("New Note Here"), systemImage: "square.and.pencil") {
                                    beginNewNote(in: row.item.url)
                                }
                                Divider()
                            }
                            fileActions(row.item.url)
                        }
                        .help(row.item.url.path)
                        .accessibilityIdentifier(row.item.isFolder ? "pks-folder-\(row.item.name)" : row.item.id)
    }

    @ViewBuilder
    private var searchResultRows: some View {
                if !model.hits.isEmpty {
                    Section(language.text("PKS results · across all sources")) {
                        ForEach(model.groupedHits) { group in
                            let hit = group.primary
                            VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 6) {
                                Button {
                                    model.openResult(hit)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 6) {
                                            Image(systemName: hit.localFileURL != nil ? "doc.text" :
                                                  hit.webURL != nil ? "globe" : "doc.richtext")
                                                .font(.system(size: NotesGeometry.symbolSize))
                                                .frame(width: NotesGeometry.treeIconWidth)
                                                .foregroundStyle(.secondary)
                                            highlighted(hit.title, query: model.query)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(2)
                                        }
                                        Text(language.text(hit.sourceLabel) + " · " + hit.sourceLocation)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if let heading = hit.headingPath, !heading.isEmpty {
                                            Text(heading)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        if let snippet = hit.snippet, !snippet.isEmpty {
                                            highlighted(snippet.replacingOccurrences(of: "\n", with: " "), query: model.query)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("pks-result-\(hit.documentId)")

                                Menu {
                                    resultActions(hit)
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: NotesGeometry.symbolSize))
                                        .frame(width: NotesGeometry.toolbarTarget)
                                        .foregroundStyle(.secondary)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .frame(width: NotesGeometry.toolbarTarget)
                                .help(language.text("Source actions"))
                            }
                            if group.hits.count > 1 {
                                DisclosureGroup("\(group.hits.count) " + language.text("matching sections")) {
                                    ForEach(Array(group.hits.enumerated()), id: \.offset) { index, match in
                                        Button {
                                            model.openResult(match)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(match.headingPath?.isEmpty == false
                                                     ? match.headingPath! : language.text("Match") + " \(index + 1)")
                                                    .font(.caption)
                                                    .fontWeight(.medium)
                                                    .lineLimit(1)
                                                if let snippet = match.snippet, !snippet.isEmpty {
                                                    highlighted(snippet.replacingOccurrences(of: "\n", with: " "),
                                                                query: model.query)
                                                        .font(.caption2)
                                                        .lineLimit(2)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.vertical, 4)
                                        .accessibilityIdentifier("pks-match-\(match.id)")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 22)
                            }
                            }
                            .contextMenu { resultActions(hit) }
                            .help(hit.uri)
                        }
                    }
                } else {
                    Text(language.text(model.searching ? "Searching PKS…" : "Search the existing PKS index."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Nulis-style compact app identity and Quick Find, followed by real
            // PKS navigation destinations. No fake starred/archive/trash features.
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? theme.linkColor : Color.primary)
                    .frame(width: 22)
                Text("PKS Notes")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    beginNewNote()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(language.text("New Markdown note (⌘N)"))
                .accessibilityIdentifier("pks-new-note-button")
            }
            .padding(.horizontal, 17)
            .frame(height: 48)
            .padding(.top, 4)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField(language.text("Quick find in PKS…"), text: $model.query)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .accessibilityIdentifier("pks-search-input")
                    .onSubmit { model.search(); sidebarTab = .search }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        model.search()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pks-search-clear")
                } else if model.searching {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("⌘F")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 33)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.085 : 0.035),
                        in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 5)
            .padding(.bottom, 17)

            VStack(alignment: .leading, spacing: 4) {
                Text(language.text("NAVIGATION"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.75)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.bottom, 3)

                navigationRow(.notes, symbol: "square.stack.3d.up", title: language.text("All Notes"))
                navigationRow(.recent, symbol: "clock", title: language.text("Recent"))
                navigationRow(.favorites, symbol: "star", title: language.text("Favorites"))
                navigationRow(.search, symbol: "text.magnifyingglass", title: language.text("PKS Search"))

                Button(action: openQuickPicker) {
                    HStack(spacing: 10) {
                        Image(systemName: "command")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 18, height: 22)
                            .foregroundStyle(.secondary)
                        Text(language.text("Quick Open"))
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Text("⌘P")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(language.text("Quick Open a file in the current library"))
                .accessibilityIdentifier("pks-sidebar-quick-open")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 19)

            HStack(spacing: 6) {
                Text(language.text(sidebarSectionTitleKey))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.75)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if sidebarTab == .notes {
                    Menu {
                        Button(language.text("Choose Notes Folder…"), systemImage: "folder") {
                            model.chooseWorkspace()
                        }
                        if let root = model.root {
                            Button(language.text("Show in Finder"), systemImage: "arrow.up.forward.app") {
                                model.revealInFinder(root)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 25, height: 24)
                    }
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .foregroundStyle(.secondary)
                    .help(language.text("Current library folder"))
                    .accessibilityIdentifier("pks-workspace-menu")
                }
                if model.loadingFiles && sidebarTab == .notes {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.leading, 21)
            .padding(.trailing, 12)
            .frame(height: 28)

            if sidebarTab == .notes {
                HStack(spacing: 7) {
                    Image(systemName: "externaldrive")
                        .font(.system(size: 12))
                        .frame(width: 15)
                        .foregroundStyle(.tertiary)
                    Text(NotesGeometry.workspaceTitle(model.root, language: language))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .frame(height: 28)
            } else if model.searching || model.searchFailed {
                Text(model.searchStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 20)
                    .frame(height: 27)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                switch sidebarTab {
                case .search:
                    searchResultRows
                case .recent:
                    savedNoteRows(model.recentNotes, emptyMessage: language.text("No recent notes yet."))
                case .favorites:
                    savedNoteRows(model.favoriteNotes, emptyMessage: language.text("No favorite notes yet."))
                case .notes:
                    Group {
                        if model.loadingFiles {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(language.text("Loading local Markdown…"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(visibleTreeRows) { row in
                            fileTreeRow(row)
                        }
                    }
                }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .focusable(sidebarTab == .notes)
            .focused($treeFocused)
            .onMoveCommand { direction in
                guard sidebarTab == .notes else { return }
                let mapped: NoteTreePresentation.Direction
                switch direction {
                case .up: mapped = .up
                case .down: mapped = .down
                case .left: mapped = .left
                case .right: mapped = .right
                default: return
                }
                let rows = visibleTreeRows
                if let next = NoteTreePresentation.navigate(mapped, rows: rows,
                                                           focusedPath: treeCursorPath ?? model.selected?.path,
                                                           expandedPaths: expandedFolderPaths) {
                    treeCursorPath = next.path
                    expandedFolderPaths = next.expanded
                }
            }
            .onKeyPress(keys: [.delete]) { key in
                guard sidebarTab == .notes, treeFocused, key.modifiers.contains(.command),
                      let item = visibleTreeRows.first(where: { $0.id == treeCursorPath })?.item
                else { return .ignored }
                requestMoveToTrash(item.url)
                return .handled
            }
            .onKeyPress(.return) {
                guard sidebarTab == .notes, treeFocused else { return .ignored }
                let rows = visibleTreeRows
                guard let item = rows.first(where: { $0.id == treeCursorPath })?.item else {
                    return .ignored
                }
                if item.isFolder { toggleFolder(item.url) }
                else { model.openFile(item.url) }
                return .handled
            }
        }
        .background(sidebarCanvas)
    }

    private func toggleFolder(_ url: URL) {
        if !expandedFolderPaths.insert(url.path).inserted {
            expandedFolderPaths.remove(url.path)
            // Keep keyboard focus visible when collapsing a parent folder.
            if let focused = treeCursorPath, focused.hasPrefix(url.path + "/") {
                treeCursorPath = url.path
            }
        }
    }

    private func highlighted(_ value: String, query: String) -> Text {
        MatchHighlighter.pieces(in: value, query: query).reduce(Text("")) { result, piece in
            result + (piece.matched
                      ? Text(piece.text).bold().foregroundColor(.accentColor)
                      : Text(piece.text))
        }
    }

    @ViewBuilder
    private func fileActions(_ url: URL) -> some View {
        Button(language.text("Show in Finder"), systemImage: "folder") {
            model.revealInFinder(url)
        }
        Button(language.text("Open with Default App"), systemImage: "arrow.up.right.square") {
            model.openInDefaultApp(url)
        }
        Button(language.text("Copy File Path"), systemImage: "doc.on.doc") {
            model.copySource(url.path)
        }
        if let root = model.root,
           ["md", "markdown"].contains(url.pathExtension.lowercased()),
           WorkspaceFiles.contains(url, in: root) {
            Button(
                language.text(model.favoriteNotes.contains(url.standardizedFileURL)
                    ? "Remove from Favorites" : "Add to Favorites"),
                systemImage: model.favoriteNotes.contains(url.standardizedFileURL) ? "star.slash" : "star"
            ) {
                model.toggleFavorite(url)
            }
        }
        if model.canManage(url) {
            Divider()
            Button(language.text("Rename…"), systemImage: "pencil") {
                beginRename(url)
            }
            Button(language.text("Move to Folder…"), systemImage: "folder.badge.gearshape") {
                chooseDestination(for: url, copying: false)
            }
            Button(language.text("Copy to Folder…"), systemImage: "doc.on.doc") {
                chooseDestination(for: url, copying: true)
            }
            Button(role: .destructive) {
                requestMoveToTrash(url)
            } label: {
                Label(language.text("Move to Trash"), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func resultActions(_ hit: SearchHit) -> some View {
        if let file = hit.localFileURL {
            fileActions(file)
        } else if let link = hit.webURL {
            Button(language.text("Open Source in Browser"), systemImage: "globe") {
                model.openSourceLink(link)
            }
            Button(language.text("Copy Source Link"), systemImage: "link") {
                model.copySource(link.absoluteString)
            }
        } else {
            Button(language.text("Copy Source Identifier"), systemImage: "doc.on.doc") {
                model.copySource(hit.uri)
            }
        }
    }

    private func chooseDestination(for item: URL, copying: Bool) {
        guard let root = model.root else { return }
        let panel = NSOpenPanel()
        panel.title = language.text(copying ? "Copy to Folder" : "Move to Folder")
        panel.message = language.text("Choose a destination inside the current notes workspace.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = item.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard WorkspaceFiles.contains(folder, in: root) || folder.standardizedFileURL == root.standardizedFileURL else {
            model.message = language.text("Choose a destination inside the current notes workspace.")
            return
        }
        if copying {
            _ = model.copyItem(item, to: folder)
        } else {
            _ = model.moveItem(item, to: folder)
        }
    }

    private func applyMarkdownFormat(_ value: String) {
        guard editorFocused, model.selected != nil,
              model.externalBody == nil,
              let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let command: MarkdownEditCommand
        switch value {
        case "bold": command = .bold
        case "italic": command = .italic
        case "code": command = .inlineCode
        case "link": command = .link
        case "h1": command = .heading(1)
        case "h2": command = .heading(2)
        case "h3": command = .heading(3)
        case "bullet": command = .bullet
        case "task": command = .task
        default: return
        }
        let original = textView.string
        let result = MarkdownEditing.apply(command, to: original, selection: textView.selectedRange())
        applyNativeEditorChange(result, from: original, in: textView)
    }

    private func handlePaste() {
        guard editorFocused, model.selected != nil,
              model.externalBody == nil,
              let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            return
        }

        let pasteboard = NSPasteboard.general
        let hasImage = pasteboard.data(forType: .png) != nil
            || pasteboard.data(forType: .tiff) != nil
            || NSImage(pasteboard: pasteboard) != nil
        guard hasImage else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            return
        }
        guard let markdown = model.importClipboardImage() else {
            model.message = language.text("Could not save the pasted image inside this notes workspace.")
            return
        }
        let original = textView.string
        let result = MarkdownEditing.insert(markdown, into: original, selection: textView.selectedRange())
        applyNativeEditorChange(result, from: original, in: textView)
    }

    private func applyNativeEditorChange(_ result: MarkdownEditResult, from original: String,
                                         in textView: NSTextView) {
        guard let replacement = MarkdownEditing.minimalChange(from: original, to: result.text) else { return }
        // Inserting through NSTextView, instead of assigning the SwiftUI binding,
        // lets the native text system register a single undoable edit.
        textView.insertText(replacement.text, replacementRange: replacement.range)
        DispatchQueue.main.async {
            textView.setSelectedRange(result.selection)
            textView.scrollRangeToVisible(result.selection)
        }
    }

    private var outlinePopover: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(language.text("Document Outline"))
                        .font(.headline)
                    Spacer()
                    Text("\(outlineHeadings.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider()

                if outlineHeadings.isEmpty {
                    Text(language.text("No headings in this note."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                } else {
                    ForEach(outlineHeadings) { heading in
                        Button {
                            jumpToOutlineHeading(heading)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "number")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 14)
                                Text(heading.title)
                                    .font(.system(size: 12.5, weight: heading.level <= 2 ? .semibold : .regular))
                                    .lineLimit(2)
                                Spacer(minLength: 6)
                                Text("H\(heading.level)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.leading, CGFloat(max(0, heading.level - 1)) * 10)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pks-outline-heading-\(heading.id)")
                    }
                }
            }
        }
        .frame(width: 320, height: min(430, CGFloat(94 + outlineHeadings.count * 38)))
    }

    private func jumpToOutlineHeading(_ heading: MarkdownOutlineHeading) {
        showingOutline = false
        showingMindMap = false
        mode = .edit
        Task { @MainActor in
            editorFocused = true
            // A read-only preview must first mount the native TextEditor before
            // its NSTextView can become first responder.
            try? await Task.sleep(for: .milliseconds(40))
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let length = (textView.string as NSString).length
            let location = min(max(0, heading.utf16Offset), length)
            let range = NSRange(location: location, length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }
    }

    @ViewBuilder
    private func savedNoteRows(_ notes: [URL], emptyMessage: String) -> some View {
        if notes.isEmpty {
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
        } else {
            ForEach(notes, id: \.path) { note in
                Button {
                    model.openFile(note)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.favoriteNotes.contains(note.standardizedFileURL) ? "star.fill" : "doc.text")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.deletingPathExtension().lastPathComponent)
                                .font(.system(size: 12.5, weight: model.selected == note ? .semibold : .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(NoteTreePresentation.quickOpenFolder(for: note, in: model.root))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(model.selected == note
                                ? Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.075)
                                : .clear,
                                in: RoundedRectangle(cornerRadius: NotesGeometry.selectionCorner))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { fileActions(note) }
                .accessibilityIdentifier("pks-saved-note-\(note.lastPathComponent)")
            }
        }
    }

    @ViewBuilder
    private func relationshipSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 5)
    }

    @ViewBuilder
    private func relationshipEmpty(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func relationshipButton(
        title: String,
        detail: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if model.loadingNote && model.selected == nil && model.previewPDF == nil && model.externalBody == nil {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(language.text("Opening note…"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selected == nil && model.previewPDF == nil && model.externalBody == nil {
                VStack(spacing: 12) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 27, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text(language.text(model.root == nil ? "Open a notes folder" : "Choose a note"))
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(language.text(model.root == nil
                         ? "Open your existing Markdown folder. Files stay where they are."
                         : "Select a document in the sidebar, or search your PKS knowledge with ⌘F."))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 370)
                    if model.root == nil {
                        Button(language.text("Choose Folder")) { model.chooseWorkspace() }
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                reader
            }
            if let message = model.message {
                HStack(spacing: 9) {
                    Image(systemName: "info.circle")
                    Text(message).font(.caption).lineLimit(2)
                    Spacer()
                    Button(language.text("Dismiss")) { model.message = nil }
                        .buttonStyle(.borderless)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(theme.canvas)
        .navigationTitle(model.selected?.deletingPathExtension().lastPathComponent
                         ?? model.previewPDF?.lastPathComponent
                         ?? model.previewSource?.title
                         ?? language.text("PKS Notes"))
    }

    @ViewBuilder
    private var reader: some View {
        if let url = model.previewPDF {
            NativePDFPreview(url: url)
        } else if showingMindMap && model.selected != nil && model.externalBody == nil {
            MindMapCanvas(
                source: $model.draft,
                openLink: { target in _ = model.openKnowledgeLink(target) },
                importOutline: { markdown, name in
                    // Import into a new note rather than overwriting the active note.
                    guard model.newNote(named: name, initialContent: markdown) != nil else {
                        return false
                    }
                    showingMindMap = true
                    return true
                }
            )
        } else if model.externalBody != nil || mode == .read {
            renderedNote
        } else if mode == .edit {
            editor
        } else {
            HSplitView {
                editor
                    .frame(minWidth: 270)
                renderedNote
                    .frame(minWidth: 270)
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $model.draft)
            .focused($editorFocused)
            .font(.system(size: theme.typography.bodySize + fontAdjustment,
                          design: theme.typography.design))
            .lineSpacing(CGFloat(max(0.08, theme.typography.lineSpacing + lineAdjustment) * 9))
            .foregroundColor(theme.ink)
            .tint(theme.linkColor)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: theme.typography.pageWidth + widthAdjustment)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.canvas)
            // Only the blank 20pt page gutter toggles back to Preview.
            // Double-clicking actual NSTextView text must still select a word.
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 20)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { switchReadingMode(to: .read) }
                    .help(language.text("Double-click the margin to preview (⌘Return)"))
            }
            // The old draft remains intact until an off-main file load succeeds.
            .disabled(model.loadingNote)
            .accessibilityIdentifier("pks-markdown-editor")
    }

    private var renderedNote: some View {
        MarkdownPreviewPane(source: model.body, live: mode == .split,
                            identity: model.selected?.path ?? model.previewSource?.documentId ?? "",
                            theme: theme,
                            fontAdjustment: fontAdjustment,
                            lineAdjustment: lineAdjustment,
                            widthAdjustment: widthAdjustment,
                            cache: $previewCache)
            // A different note must never briefly display another file's parsed document.
            .id(model.selected?.path ?? model.previewSource?.documentId ?? "empty")
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if mode == .read, model.selected != nil, model.externalBody == nil {
                    switchReadingMode(to: .edit)
                }
            })
    }

}


/// PDFKit is part of macOS; no PDF renderer, server or extra dependency is bundled.
private struct NativePDFPreview: View {
    @Environment(\.notesLanguage) private var language
    let url: URL
    @State private var document: PDFDocument?
    @State private var attemptedURL: URL?

    var body: some View {
        Group {
            if let document, attemptedURL == url {
                PDFCanvas(document: document)
            } else if attemptedURL == url {
                VStack(spacing: 12) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 27, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text(language.text("Cannot preview this PDF"))
                        .font(.title3.weight(.medium))
                    Text(language.text("The original file may be unavailable or damaged."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(language.text("Open with Default App")) {
                        NSWorkspace.shared.open(url)
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView(language.text("Opening PDF…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            document = PDFDocument(url: url)
            attemptedURL = url
        }
        .accessibilityIdentifier("pks-pdf-preview")
    }
}

private struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.autoScales = true
        view.backgroundColor = .textBackgroundColor
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
    }
}
