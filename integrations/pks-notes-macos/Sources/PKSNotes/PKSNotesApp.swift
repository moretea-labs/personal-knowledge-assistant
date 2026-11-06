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

    var body: some Scene {
        WindowGroup {
            NotesWindow()
                .environmentObject(model)
                .onAppear { appDelegate.notesModel = model }
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1220, height: 780)
        .commands {
            // This single-window editor uses Cmd+N for a note, not another app window.
            CommandGroup(replacing: .newItem) {}
            CommandMenu("PKS") {
                Button("Save Markdown") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Search Knowledge") { model.search() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Divider()
                Button("Refresh Files") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Choose Folder…") { model.chooseWorkspace() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

private enum SidebarTab: String, CaseIterable {
    case notes = "Notes"
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

struct NotesWindow: View {
    @EnvironmentObject private var model: NotesModel
    @State private var mode: ReadingMode = .edit
    @State private var sidebarTab: SidebarTab = .notes
    @State private var newNoteName = ""
    @State private var creatingNote = false
    @State private var newNoteParent: URL?
    @State private var expandedFolderPaths: Set<String> = []
    @State private var treeCursorPath: String?
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var treeFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    sidebarTab = .search
                    searchFieldFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Focus PKS search (⌘F)")
                .keyboardShortcut("f", modifiers: .command)
                Button(action: { model.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }.help("Refresh Markdown folders")
                Button(action: {
                    newNoteParent = nil
                    creatingNote = true
                }) {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Markdown note (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
                Button(action: { model.chooseWorkspace() }) {
                    Image(systemName: "folder")
                }.help("Choose an existing folder")
            }
        }
        .onChange(of: model.root) { _, _ in
            expandedFolderPaths.removeAll()
            treeCursorPath = nil
        }
        .onChange(of: model.selected) { _, note in
            if let note, let root = model.root {
                expandedFolderPaths.formUnion(NoteTreePresentation.ancestorPaths(for: note, in: root))
                treeCursorPath = note.path
            }
        }
        .alert("New Markdown note", isPresented: $creatingNote) {
            TextField("Note name", text: $newNoteName)
            Button("Create") {
                model.newNote(named: newNoteName, in: newNoteParent)
                newNoteName = ""
                newNoteParent = nil
            }
            Button("Cancel", role: .cancel) {
                newNoteName = ""
                newNoteParent = nil
            }
        } message: {
            Text(newNoteParent.map { "Creates a Markdown file inside \($0.lastPathComponent)." }
                 ?? "Creates a Markdown file beside the selected note, or at the workspace root.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.tint)
                Text("PKS Notes")
                    .font(.headline)
                    .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
                    .help("Double-click to zoom or restore the window")
                Spacer()
                Image(systemName: model.searching ? "arrow.triangle.2.circlepath" :
                      model.searchStatus.hasPrefix("PKS offline") ? "exclamationmark.circle" : "circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.top, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search all PKS knowledge", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .accessibilityIdentifier("pks-search-input")
                    .onSubmit { model.search(); sidebarTab = .search }
                if model.searching {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { model.search(); sidebarTab = .search } label: {
                        Image(systemName: "arrow.right.circle.fill")
                    }.buttonStyle(.borderless)
                }
            }
            .padding(9)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 10)

            Text(model.searchStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            Picker("Sidebar", selection: $sidebarTab) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)

            List {
                if sidebarTab == .search {
                if !model.hits.isEmpty {
                    Section("PKS results · across all sources") {
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
                                                .foregroundStyle(.secondary)
                                            highlighted(hit.title, query: model.query)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(2)
                                        }
                                        Text(hit.sourceLabel + " · " + hit.sourceLocation)
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
                                        .foregroundStyle(.secondary)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .frame(width: 25)
                                .help("Source actions")
                            }
                            if group.hits.count > 1 {
                                DisclosureGroup("\(group.hits.count) matching sections") {
                                    ForEach(Array(group.hits.enumerated()), id: \.offset) { index, match in
                                        Button {
                                            model.openResult(match)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(match.headingPath?.isEmpty == false
                                                     ? match.headingPath! : "Match \(index + 1)")
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
                    Text(model.searching ? "Searching PKS…" : "Search the existing PKS index.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                } else {
                Section {
                    if model.loadingFiles {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading local Markdown…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(NoteTreePresentation.visibleRows(model.files, expandedPaths: expandedFolderPaths)) { row in
                        HStack(spacing: 7) {
                            if row.item.isFolder {
                                Button {
                                    treeCursorPath = row.id
                                    treeFocused = true
                                    toggleFolder(row.item.url)
                                } label: {
                                    Image(systemName: expandedFolderPaths.contains(row.item.id) ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 14, height: 20)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(expandedFolderPaths.contains(row.item.id) ? "Collapse folder" : "Expand folder")
                                .accessibilityLabel(expandedFolderPaths.contains(row.item.id)
                                                    ? "Collapse \(row.item.name)" : "Expand \(row.item.name)")
                                Label(row.item.name, systemImage: "folder")
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
                                    .help("Double-click to expand or collapse")
                            } else {
                                Image(systemName: row.item.iconName)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Button {
                                    treeCursorPath = row.id
                                    treeFocused = true
                                    model.openFile(row.item.url)
                                } label: {
                                    Text(row.item.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(model.selected == row.item.url || model.previewPDF == row.item.url ? .accentColor : .primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("pks-note-\(row.item.name)")
                            }
                        }
                        .padding(.leading, CGFloat(row.depth) * 17)
                        .padding(.vertical, 2)
                        .background(treeFocused && treeCursorPath == row.id
                                    ? Color.accentColor.opacity(0.22)
                                    : model.selected == row.item.url || model.previewPDF == row.item.url
                                        ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contextMenu {
                            if row.item.isFolder {
                                Button("New Note Here", systemImage: "square.and.pencil") {
                                    newNoteParent = row.item.url
                                    creatingNote = true
                                }
                                Divider()
                            }
                            fileActions(row.item.url)
                        }
                        .help(row.item.url.path)
                        .accessibilityIdentifier(row.item.isFolder ? "pks-folder-\(row.item.name)" : row.item.id)
                    }
                } header: {
                    HStack {
                        Text(model.root?.path.contains("Mobile Documents") == true ? "Files · iCloud" : "Files · local")
                        Spacer()
                        Button(action: { model.chooseWorkspace() }) {
                            Image(systemName: "folder.badge.gearshape")
                        }
                        .buttonStyle(.borderless)
                    }
                } footer: {
                    Text(model.root?.path ?? "Choose an existing folder")
                        .font(.caption2)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                }
            }
            .listStyle(.sidebar)
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
                let rows = NoteTreePresentation.visibleRows(model.files, expandedPaths: expandedFolderPaths)
                if let next = NoteTreePresentation.navigate(mapped, rows: rows,
                                                           focusedPath: treeCursorPath ?? model.selected?.path,
                                                           expandedPaths: expandedFolderPaths) {
                    treeCursorPath = next.path
                    expandedFolderPaths = next.expanded
                }
            }
            .onKeyPress(.return) {
                guard sidebarTab == .notes, treeFocused else { return .ignored }
                let rows = NoteTreePresentation.visibleRows(model.files, expandedPaths: expandedFolderPaths)
                guard let item = rows.first(where: { $0.id == treeCursorPath })?.item else {
                    return .ignored
                }
                if item.isFolder { toggleFolder(item.url) }
                else { model.openFile(item.url) }
                return .handled
            }
        }
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
        Button("Show in Finder", systemImage: "folder") {
            model.revealInFinder(url)
        }
        Button("Open with Default App", systemImage: "arrow.up.right.square") {
            model.openInDefaultApp(url)
        }
        Button("Copy File Path", systemImage: "doc.on.doc") {
            model.copySource(url.path)
        }
    }

    @ViewBuilder
    private func resultActions(_ hit: SearchHit) -> some View {
        if let file = hit.localFileURL {
            fileActions(file)
        } else if let link = hit.webURL {
            Button("Open Source in Browser", systemImage: "globe") {
                model.openSourceLink(link)
            }
            Button("Copy Source Link", systemImage: "link") {
                model.copySource(link.absoluteString)
            }
        } else {
            Button("Copy Source Identifier", systemImage: "doc.on.doc") {
                model.copySource(hit.uri)
            }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if model.loadingNote && model.selected == nil && model.previewPDF == nil && model.externalBody == nil {
                ContentUnavailableView {
                    Label("Opening Markdown…", systemImage: "doc.text")
                } description: {
                    ProgressView().controlSize(.small)
                }
            } else if model.selected == nil && model.previewPDF == nil && model.externalBody == nil {
                ContentUnavailableView {
                    Label("Your Markdown, indexed by PKS", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Choose a note on the left, or search your entire PKS knowledge collection. No account or second sync system.")
                } actions: {
                    Button("Choose Folder") { model.chooseWorkspace() }
                }
            } else {
                header
                Divider()
                reader
            }
            if let message = model.message {
                Divider()
                HStack {
                    Image(systemName: "info.circle")
                    Text(message).font(.callout).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { model.message = nil }
                        .buttonStyle(.borderless)
                }
                .padding(9)
                .background(.thinMaterial)
            }
        }
        .navigationTitle(model.selected?.deletingPathExtension().lastPathComponent ?? model.previewPDF?.lastPathComponent ?? "PKS Notes")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(model.title).font(.headline).lineLimit(1)
                    if model.loadingNote {
                        ProgressView().controlSize(.mini)
                        Text("Opening…").font(.caption2).foregroundStyle(.secondary)
                    } else if model.isDirty {
                        Text("Unsaved")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                    .onTapGesture(count: 2) { NSApp.keyWindow?.zoom(nil) }
                    .help("Double-click to zoom or restore the window")
                Text(model.selected?.path ?? model.previewPDF?.path ?? model.previewSource?.uri ?? "PKS search · external source")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            if let url = model.selected ?? model.previewPDF ?? model.previewSource?.localFileURL {
                Menu {
                    fileActions(url)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("File actions: Finder, open, copy path")
            } else if let url = model.previewSource?.webURL {
                Menu {
                    Button("Open Source in Browser", systemImage: "globe") {
                        model.openSourceLink(url)
                    }
                    Button("Copy Source Link", systemImage: "link") {
                        model.copySource(url.absoluteString)
                    }
                } label: {
                    Image(systemName: "link")
                }
                .menuStyle(.borderlessButton)
                .help("Source actions")
            }
            if model.externalBody == nil && model.previewPDF == nil {
                HStack(spacing: 2) {
                    ForEach(ReadingMode.allCases, id: \.self) { choice in
                        Button {
                            mode = choice
                        } label: {
                            Label(choice.rawValue, systemImage: choice.symbol)
                                .font(.system(size: 12, weight: mode == choice ? .semibold : .regular))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .frame(minWidth: 75)
                                .background(
                                    mode == choice ? Color(nsColor: .controlBackgroundColor) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(choice.shortcut, modifiers: .command)
                        .accessibilityIdentifier("pks-mode-\(choice.rawValue.lowercased())")
                        .help("Switch to \(choice.rawValue) Markdown")
                    }
                }
                .padding(3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))

                Button(action: { model.save() }) {
                    Label(model.isDirty ? "Save changes" : "Save", systemImage: "square.and.arrow.down")
                }
                .disabled(model.selected == nil || model.loadingNote || !model.isDirty)
            } else {
                Label("Read-only", systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var reader: some View {
        if let url = model.previewPDF {
            NativePDFPreview(url: url)
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
            .font(.system(size: 14, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .padding(10)
            // The old draft remains intact until an off-main file load succeeds.
            .disabled(model.loadingNote)
            .accessibilityIdentifier("pks-markdown-editor")
    }

    private var renderedNote: some View {
        MarkdownPreviewPane(source: model.body, live: mode == .split)
            // A different note must never briefly display another file's parsed document.
            .id(model.selected?.path ?? model.previewSource?.documentId ?? "empty")
    }

}


/// PDFKit is part of macOS; no PDF renderer, server or extra dependency is bundled.
private struct NativePDFPreview: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var attemptedURL: URL?

    var body: some View {
        Group {
            if let document, attemptedURL == url {
                PDFCanvas(document: document)
            } else if attemptedURL == url {
                ContentUnavailableView {
                    Label("Cannot preview this PDF", systemImage: "doc.richtext")
                } description: {
                    Text("The original file may be unavailable or damaged.")
                } actions: {
                    Button("Open with Default App") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                ProgressView("Opening PDF…")
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
