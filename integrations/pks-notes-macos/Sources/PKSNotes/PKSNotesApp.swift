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

private struct PreviewWarmupKey: Hashable {
    let identity: String
    let source: String
    let enabled: Bool
}

struct NotesWindow: View {
    @EnvironmentObject private var model: NotesModel
    @State private var mode: ReadingMode = .read
    @AppStorage("PKSNotesReadingTheme") private var themeID = NotesTheme.system.rawValue
    @AppStorage("PKSNotesFontAdjustment") private var fontAdjustment = 0.0
    @AppStorage("PKSNotesLineAdjustment") private var lineAdjustment = 0.0
    @AppStorage("PKSNotesWidthAdjustment") private var widthAdjustment = 0.0
    @State private var showingTypography = false
    @State private var previewCache: MarkdownPreviewSnapshot?
    @State private var visibleTreeRows: [NoteTreePresentation.Row] = []
    @State private var allOpenableFiles: [NoteItem] = []
    @State private var showingQuickOpen = false
    @State private var quickOpenQuery = ""
    @State private var quickOpenIndex = 0

    private var quickOpenMatches: [NoteItem] {
        NoteTreePresentation.quickOpen(allOpenableFiles, query: quickOpenQuery)
    }

    private var theme: NotesTheme { NotesTheme.restored(themeID) }
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarTab: SidebarTab = .notes
    @State private var newNoteName = ""
    @State private var creatingNote = false
    @State private var newNoteParent: URL?
    @State private var expandedFolderPaths: Set<String> = []
    @State private var treeCursorPath: String?
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var treeFocused: Bool
    @FocusState private var quickOpenFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 235, ideal: 278, max: 365)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                if model.selected != nil && model.externalBody == nil && model.previewPDF == nil {
                    HStack(spacing: 2) {
                        ForEach(ReadingMode.allCases, id: \.self) { choice in
                            Button {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    mode = choice
                                }
                            } label: {
                                Label(choice.rawValue, systemImage: choice.symbol)
                                    .font(.system(size: 12, weight: mode == choice ? .semibold : .regular))
                                    .foregroundStyle(mode == choice ? Color.primary : Color.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(choice.shortcut, modifiers: .command)
                            .accessibilityIdentifier("pks-mode-\(choice.rawValue.lowercased())")
                            .help("Switch to \(choice.rawValue) Markdown")
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openQuickPicker()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .keyboardShortcut("p", modifiers: .command)
                .help("Quick Open Note (⌘P)")
                .accessibilityIdentifier("pks-quick-open-button")

                Button {
                    showingTypography = true
                } label: {
                    Image(systemName: "textformat.size")
                }
                .popover(isPresented: $showingTypography, arrowEdge: .bottom) {
                    typographyInspector
                }
                .help("Reading theme and typography")
                .accessibilityIdentifier("pks-theme-menu")

                if model.autoSavePending && model.selected != nil {
                    ProgressView()
                        .controlSize(.small)
                        .help("Saving Markdown automatically…")
                        .accessibilityIdentifier("pks-autosave-progress")
                }

                Button {
                    newNoteParent = nil
                    creatingNote = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Markdown note (⌘N)")
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    sidebarTab = .search
                    searchFieldFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search PKS knowledge (⌘F)")
                .keyboardShortcut("f", modifiers: .command)

                Menu {
                    Button("Quick Open Note…", systemImage: "doc.text.magnifyingglass") {
                        openQuickPicker()
                    }
                    Divider()
                    if let file = model.selected ?? model.previewPDF ?? model.previewSource?.localFileURL {
                        fileActions(file)
                        Divider()
                    } else if let link = model.previewSource?.webURL {
                        Button("Open Source in Browser", systemImage: "globe") { model.openSourceLink(link) }
                        Button("Copy Source Link", systemImage: "link") { model.copySource(link.absoluteString) }
                        Divider()
                    }
                    Button("Refresh Files", systemImage: "arrow.clockwise") { model.refresh() }
                    Button("Choose Folder…", systemImage: "folder") { model.chooseWorkspace() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .help("File actions and workspace options")
            }
        }
        .preferredColorScheme(theme.appearance)
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
            if let note, let root = model.root {
                expandedFolderPaths.formUnion(NoteTreePresentation.ancestorPaths(for: note, in: root))
                treeCursorPath = note.path
            }
        }
        .sheet(isPresented: $showingQuickOpen) {
            quickOpenSheet
        }
        .alert("New Markdown note", isPresented: $creatingNote) {
            TextField("Note name", text: $newNoteName)
            Button("Create") {
                model.newNote(named: newNoteName, in: newNoteParent)
                mode = .edit
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
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search files…", text: $quickOpenQuery)
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
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Cancel (Esc)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            Divider()
                .opacity(0.45)
            if matches.isEmpty {
                Text(quickOpenQuery.isEmpty ? "Type a name to find a note in your library."
                     : "No files match your search.")
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
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name)
                                            .font(.system(size: 14, weight: i == quickOpenIndex ? .semibold : .regular))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(item.url.deletingLastPathComponent().lastPathComponent)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
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
                                    i == quickOpenIndex ? Color.accentColor.opacity(0.085) : .clear,
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

    private var typographyInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reading Appearance")
                .font(.headline)
                .padding(.bottom, 1)

            ForEach(NotesTheme.allCases) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        themeID = option.rawValue
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: option.symbol)
                            .frame(width: 20)
                            .foregroundStyle(.secondary)
                        Text(option.name)
                            .fontWeight(theme == option ? .semibold : .regular)
                        Spacer(minLength: 6)
                        if theme == option {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pks-theme-\(option.rawValue)")
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Text Size")
                    Spacer()
                    Text("\(theme.typography.bodySize + fontAdjustment, specifier: "%.1f") pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $fontAdjustment, in: -2...4)
                    .accessibilityIdentifier("pks-typography-size")
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Line Spacing")
                    Spacer()
                    Text("\(Int((theme.typography.lineSpacing + lineAdjustment) * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $lineAdjustment, in: -0.15...0.30)
                    .accessibilityIdentifier("pks-typography-leading")
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Reading Width")
                    Spacer()
                    Text("\(Int(theme.typography.pageWidth + widthAdjustment)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $widthAdjustment, in: -160...160)
                    .accessibilityIdentifier("pks-typography-width")
            }
            Button("Reset Typography") {
                fontAdjustment = 0
                lineAdjustment = 0
                widthAdjustment = 0
            }
            .disabled(fontAdjustment == 0 && lineAdjustment == 0 && widthAdjustment == 0)
            .font(.caption)
            .buttonStyle(.link)
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .padding(18)
        .frame(width: 288)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                TextField("Search notes and knowledge", text: $model.query)
                    .font(.system(size: 13))
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .accessibilityIdentifier("pks-search-input")
                    .onSubmit { model.search(); sidebarTab = .search }
                if model.searching {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.042), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 12)

            if model.searching || model.searchStatus.hasPrefix("PKS offline") {
                Text(model.searchStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
            }

            HStack(spacing: 18) {
                ForEach(SidebarTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            sidebarTab = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab == .notes ? "folder" : "text.magnifyingglass")
                            Text(tab == .notes ? "Files" : "Results")
                        }
                        .font(.system(size: 13, weight: sidebarTab == tab ? .semibold : .regular))
                        .foregroundStyle(sidebarTab == tab ? Color.accentColor : Color.secondary)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pks-sidebar-\(tab.rawValue.lowercased())")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

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
                    ForEach(visibleTreeRows) { row in
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
                                    .font(.system(size: 13, weight: .medium))
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
                                    .foregroundStyle(model.selected == row.item.url || model.previewPDF == row.item.url
                                                     ? Color.accentColor : Color.secondary)
                                    .font(.system(size: 12))
                                    .frame(width: 14)
                                Button {
                                    treeCursorPath = row.id
                                    treeFocused = true
                                    model.openFile(row.item.url)
                                } label: {
                                    Text(row.item.name)
                                        .font(.system(size: 13, weight: model.selected == row.item.url
                                                      || model.previewPDF == row.item.url ? .semibold : .regular))
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
                        .padding(.vertical, 5)
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
                        Text(model.root?.lastPathComponent ?? "Library")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button(action: { model.chooseWorkspace() }) {
                            Image(systemName: "folder")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Change notes folder")
                    }
                }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
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
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Opening note…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selected == nil && model.previewPDF == nil && model.externalBody == nil {
                VStack(spacing: 12) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 27, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text(model.root == nil ? "Open a notes folder" : "Choose a note")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(model.root == nil
                         ? "Open your existing Markdown folder. Files stay where they are."
                         : "Select a document in the sidebar, or search your PKS knowledge with ⌘F.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 370)
                    if model.root == nil {
                        Button("Choose Folder") { model.chooseWorkspace() }
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
                    Button("Dismiss") { model.message = nil }
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
                         ?? (model.selected == nil && model.previewPDF == nil && model.externalBody == nil
                             ? "PKS Notes" : model.title))
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
                VStack(spacing: 12) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 27, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("Cannot preview this PDF")
                        .font(.title3.weight(.medium))
                    Text("The original file may be unavailable or damaged.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Open with Default App") {
                        NSWorkspace.shared.open(url)
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
