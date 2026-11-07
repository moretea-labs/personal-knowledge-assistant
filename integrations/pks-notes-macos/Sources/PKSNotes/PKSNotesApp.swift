import AppKit
import SwiftUI
import MarkdownUI

@MainActor
final class PKSNotesAppDelegate: NSObject, NSApplicationDelegate {
    weak var notesModel: NotesModel?
    private var markdownKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        markdownKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let command = MarkdownShortcut.command(for: event),
                  MarkdownNativeCommand.perform(command) else { return event }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let markdownKeyMonitor {
            NSEvent.removeMonitor(markdownKeyMonitor)
            self.markdownKeyMonitor = nil
        }
    }

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
            // PKS Notes edits plain Markdown. Remove AppKit rich-text formatting
            // equivalents (notably Cmd+B/Cmd+I) so one shortcut has one authority.
            CommandGroup(replacing: .textFormatting) {}

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
                Button(language.text("Bold")) { MarkdownNativeCommand.perform("bold") }
                    .keyboardShortcut("b", modifiers: .command)
                Button(language.text("Italic")) { MarkdownNativeCommand.perform("italic") }
                    .keyboardShortcut("i", modifiers: .command)
                Button(language.text("Inline Code")) { MarkdownNativeCommand.perform("code") }
                    .keyboardShortcut("e", modifiers: .command)
                Button(language.text("Link")) { MarkdownNativeCommand.perform("link") }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button(language.text("Heading 1")) { MarkdownNativeCommand.perform("h1") }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button(language.text("Heading 2")) { MarkdownNativeCommand.perform("h2") }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button(language.text("Heading 3")) { MarkdownNativeCommand.perform("h3") }
                    .keyboardShortcut("3", modifiers: [.command, .shift])
                Divider()
                Button(language.text("Bullet List")) { MarkdownNativeCommand.perform("bullet") }
                    .keyboardShortcut("8", modifiers: [.command, .shift])
                Button(language.text("Task")) { MarkdownNativeCommand.perform("task") }
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
                Button(language.text("Reveal Current File")) {
                    NotificationCenter.default.post(name: NotesMenuEvent.revealCurrentFile, object: nil)
                }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(0xF704)!)), modifiers: .option)
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

enum MarkdownShortcut {
    static func command(for event: NSEvent) -> String? {
        command(
            key: event.charactersIgnoringModifiers?.lowercased(),
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }

    static func command(key: String?, modifiers: NSEvent.ModifierFlags) -> String? {
        if modifiers == .command {
            switch key {
            case "b": return "bold"
            case "i": return "italic"
            case "e": return "code"
            case "k": return "link"
            default: return nil
            }
        }
        if modifiers == [.command, .shift] {
            switch key {
            case "1": return "h1"
            case "2": return "h2"
            case "3": return "h3"
            case "8": return "bullet"
            case "9": return "task"
            default: return nil
            }
        }
        return nil
    }
}

enum MarkdownNativeCommand {
    static func activeTextView() -> NSTextView? {
        let responder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
        guard let textView = responder as? NSTextView,
              textView.isEditable, !textView.isFieldEditor else { return nil }
        return textView
    }

    @discardableResult
    static func perform(_ value: String) -> Bool {
        guard let textView = activeTextView(),
              let command = editCommand(for: value) else { return false }
        let original = textView.string
        let result = MarkdownEditing.apply(command, to: original, selection: textView.selectedRange())
        apply(result, from: original, in: textView)
        return true
    }

    static func apply(_ result: MarkdownEditResult, from original: String, in textView: NSTextView) {
        guard let replacement = MarkdownEditing.minimalChange(from: original, to: result.text) else { return }
        textView.insertText(replacement.text, replacementRange: replacement.range)
        textView.didChangeText()
        DispatchQueue.main.async {
            textView.setSelectedRange(result.selection)
            textView.scrollRangeToVisible(result.selection)
        }
    }

    private static func editCommand(for value: String) -> MarkdownEditCommand? {
        switch value {
        case "bold": .bold
        case "italic": .italic
        case "code": .inlineCode
        case "link": .link
        case "h1": .heading(1)
        case "h2": .heading(2)
        case "h3": .heading(3)
        case "bullet": .bullet
        case "task": .task
        default: nil
        }
    }
}

private enum NotesMenuEvent {
    static let quickOpen = Notification.Name("PKSNotesMenuQuickOpen")
    static let newNote = Notification.Name("PKSNotesMenuNewNote")
    static let search = Notification.Name("PKSNotesMenuSearch")
    static let toggleEdit = Notification.Name("PKSNotesToggleEditPreview")
    static let paste = Notification.Name("PKSNotesPaste")
    static let revealCurrentFile = Notification.Name("PKSNotesRevealCurrentFile")
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

private struct OutlineWarmupKey: Hashable {
    let identity: String
    let revision: UInt64
    let enabled: Bool
}

private struct RelationshipWarmupKey: Hashable {
    let identity: String
    let revision: UInt64
    let enabled: Bool
}

private struct PDFCaptureRequest: Equatable {
    let pdf: URL
    let page: Int
    let selectedText: String?
    let anchor: PDFSourceAnchor?
}

struct NotesWindow: View {
    @EnvironmentObject private var model: NotesModel
    @Environment(\.notesLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    @State private var mode: ReadingMode = .read
    @State private var showingMindMap = false
    @State private var mindMapSelectionLine: Int?
    @State private var modeBeforeMindMap: ReadingMode = .read
    @AppStorage("PKSNotesReadingTheme") private var themeID = NotesTheme.system.rawValue
    @AppStorage("PKSNotesFontAdjustment") private var fontAdjustment = 0.0
    @AppStorage("PKSNotesLineAdjustment") private var lineAdjustment = 0.0
    @AppStorage("PKSNotesWidthAdjustment") private var widthAdjustment = 0.0
    @State private var previewCache: MarkdownPreviewSnapshot?
    @State private var outlineHeadings: [MarkdownOutlineHeading] = []
    @State private var outgoingLinks: [MindMapLink] = []
    @State private var visibleTreeRows: [NoteTreePresentation.Row] = []
    @State private var quickOpenEntries: [NoteTreePresentation.QuickOpenEntry] = []
    @State private var showingQuickOpen = false
    @State private var showingBacklinks = false
    @State private var quickOpenQuery = ""
    @State private var quickOpenIndex = 0
    @State private var pdfCaptureRequest: PDFCaptureRequest?
    @State private var pdfCaptureCommentary = ""

    private var quickOpenMatches: [NoteItem] {
        let matches = NoteTreePresentation.quickOpen(quickOpenEntries, query: quickOpenQuery)
        guard pdfCaptureRequest != nil else { return matches }
        return matches.filter {
            !$0.isFolder && ["md", "markdown"].contains($0.url.pathExtension.lowercased())
        }
    }

    private var pdfCapturePreviewText: String? {
        guard let text = pdfCaptureRequest?.selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
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
    @State private var treeRevealRequest: String?
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var treeFocused: Bool
    @FocusState private var quickOpenFocused: Bool
    @FocusState private var pdfCaptureCommentaryFocused: Bool
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
                    Toggle(isOn: Binding(
                        get: { showingMindMap },
                        set: { setMindMapVisible($0) }
                    )) {
                        toolbarSymbol(showingMindMap ? "doc.text" : "point.3.connected.trianglepath.dotted")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.plain)
                    .help(language.text(showingMindMap ? "Return to Markdown" : "Mind Map"))
                    .accessibilityLabel(language.text("Mind Map"))
                    .accessibilityValue(language.text(showingMindMap ? "On" : "Off"))
                    .accessibilityIdentifier("pks-mind-map-toggle")
                }
                if model.selected != nil && model.externalBody == nil && model.previewPDF == nil {
                    Menu {
                        ForEach(outlineHeadings) { heading in
                            Button {
                                jumpToOutlineHeading(heading)
                            } label: {
                                Label(heading.title, systemImage: "number")
                            }
                            .accessibilityIdentifier("pks-outline-heading-\(heading.id)")
                        }
                    } label: {
                        toolbarSymbol("list.bullet.indent")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .disabled(outlineHeadings.isEmpty)
                    .help(language.text("Document Outline"))
                    .accessibilityIdentifier("pks-outline-menu")

                    Button {
                        model.toggleFavorite()
                    } label: {
                        toolbarSymbol(model.selectedIsFavorite ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .help(language.text(model.selectedIsFavorite ? "Remove from Favorites" : "Add to Favorites"))
                    .accessibilityIdentifier("pks-favorite-toggle")
                }

                if (model.selected != nil && model.externalBody == nil) || model.previewPDF != nil {
                    Button {
                        showingBacklinks.toggle()
                        if showingBacklinks { model.loadRelationships() }
                    } label: {
                        HStack(spacing: 4) {
                            toolbarSymbol("link")
                            if model.previewPDF != nil {
                                Text(language.text("Linked Notes"))
                                    .font(.caption.weight(.medium))
                            }
                            if !model.backlinks.isEmpty {
                                Text("\(model.backlinks.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(language.text(model.previewPDF == nil
                                        ? "Links and related notes"
                                        : "Linked notes for this PDF"))
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

                                if model.previewPDF == nil {
                                    relationshipSectionTitle(language.text("Outgoing"))
                                    if outgoingLinks.isEmpty {
                                        relationshipEmpty(language.text("No links from this note."))
                                    } else {
                                        ForEach(Array(outgoingLinks.enumerated()), id: \.offset) { _, link in
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
                                }

                                relationshipSectionTitle(language.text(model.previewPDF == nil
                                                                      ? "Backlinks"
                                                                      : "Linked Notes"))
                                if model.loadingBacklinks {
                                    relationshipEmpty(language.text(model.previewPDF == nil
                                                                    ? "Finding notes that link here…"
                                                                    : "Finding notes linked to this PDF…"))
                                } else if model.backlinks.isEmpty {
                                    relationshipEmpty(language.text(model.previewPDF == nil
                                                                    ? "No backlinks in this workspace."
                                                                    : "No notes link to this PDF yet."))
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
                                if model.backlinkSkippedCloudFiles > 0 {
                                    relationshipEmpty(String(
                                        format: language.text("Cloud-only notes skipped: %d"),
                                        model.backlinkSkippedCloudFiles
                                    ))
                                }

                                if model.previewPDF == nil {
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
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.revealCurrentFile)) { _ in
            revealCurrentFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.search)) { _ in
            focusKnowledgeSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.toggleEdit)) { _ in
            toggleEditPreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.paste)) { _ in
            handlePaste()
        }
        .task(id: OutlineWarmupKey(
            identity: model.selected?.path ?? "",
            revision: model.draftRevision,
            enabled: model.selected != nil && model.externalBody == nil && model.previewPDF == nil
        )) {
            guard model.externalBody == nil, model.previewPDF == nil,
                  let identity = model.selected?.path else {
                outlineHeadings = []
                return
            }
            let input = model.draft
            let revision = model.draftRevision
            // Keep typing responsive. Large notes make a full heading pass
            // measurably expensive, so require a longer idle window before doing
            // this derived outline work.
            let bytes = input.utf8.count
            let delay: Duration = bytes >= 5_000_000 ? .milliseconds(1_200)
                : bytes >= 1_000_000 ? .milliseconds(700)
                : bytes >= 250_000 ? .milliseconds(320)
                : .milliseconds(140)
            do { try await Task.sleep(for: delay) }
            catch { return }
            let scanner = Task.detached(priority: .utility) {
                MarkdownOutline.headings(in: input)
            }
            defer { scanner.cancel() }
            let headings = await scanner.value
            guard !Task.isCancelled, model.selected?.path == identity,
                  model.draftRevision == revision else { return }
            outlineHeadings = headings
        }
        .task(id: RelationshipWarmupKey(
            identity: showingBacklinks && model.previewPDF == nil ? (model.selected?.path ?? "") : "",
            revision: showingBacklinks && model.previewPDF == nil ? model.draftRevision : 0,
            enabled: showingBacklinks && model.previewPDF == nil && model.selected != nil
        )) {
            guard showingBacklinks, model.previewPDF == nil, model.externalBody == nil,
                  let identity = model.selected?.path else {
                outgoingLinks = []
                return
            }
            let input = model.draft
            let revision = model.draftRevision
            let scanner = Task.detached(priority: .utility) {
                MindMapOutline.knowledgeLinks(in: input)
            }
            defer { scanner.cancel() }
            let links = await scanner.value
            guard !Task.isCancelled, showingBacklinks, model.previewPDF == nil,
                  model.selected?.path == identity, model.draftRevision == revision else { return }
            outgoingLinks = links
        }
        .onReceive(model.$files) { files in
            visibleTreeRows = NoteTreePresentation.visibleRows(files, expandedPaths: expandedFolderPaths)
            if !model.globalFileIndexReady {
                quickOpenEntries = NoteTreePresentation.quickOpenEntries(files)
            }
            model.loadExpandedFolders(expandedFolderPaths)
        }
        .onReceive(model.$globalFiles) { files in
            guard model.globalFileIndexReady else { return }
            quickOpenEntries = NoteTreePresentation.quickOpenEntries(files)
        }
        .onChange(of: expandedFolderPaths) { _, expanded in
            visibleTreeRows = NoteTreePresentation.visibleRows(model.files, expandedPaths: expanded)
            model.loadExpandedFolders(expanded)
        }
        .onChange(of: model.root) { _, _ in
            expandedFolderPaths.removeAll()
            treeCursorPath = nil
            previewCache = nil
        }
        .onChange(of: model.loadingNote) { _, loading in
            if !loading, mode != .read {
                resetNativeEditorUndoBaseline()
            }
        }
        .onChange(of: model.selected) { _, note in
            mindMapSelectionLine = nil
            let openAsMap = note != nil && note == pendingMindMapOpen
            showingMindMap = openAsMap
            if openAsMap {
                pendingMindMapOpen = nil
                mode = .read
            }
            showingBacklinks = false
            outgoingLinks = []
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

    private var currentWorkspaceFile: URL? {
        guard let root = model.root else { return nil }
        return [model.selected, model.previewPDF, model.previewSource?.localFileURL]
            .compactMap { $0 }
            .first { WorkspaceFiles.contains($0, in: root) }
    }

    private func revealCurrentFile() {
        guard let file = currentWorkspaceFile, let root = model.root else { return }
        columnVisibility = .all
        sidebarTab = .notes
        expandedFolderPaths.formUnion(NoteTreePresentation.ancestorPaths(for: file, in: root))
        treeCursorPath = file.path
        treeFocused = true
        Task { @MainActor in
            await Task.yield()
            treeRevealRequest = file.path
        }
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
        pdfCaptureRequest = nil
        pdfCaptureCommentary = ""
        quickOpenQuery = ""
        quickOpenIndex = 0
        model.prepareGlobalFileIndex()
        showingQuickOpen = true
    }

    private func beginPDFCapture(
        pdf: URL,
        page: Int,
        selectedText: String?,
        anchor: PDFSourceAnchor?
    ) {
        pdfCaptureRequest = PDFCaptureRequest(
            pdf: pdf,
            page: page,
            selectedText: selectedText,
            anchor: anchor
        )
        pdfCaptureCommentary = ""
        quickOpenQuery = ""
        quickOpenIndex = 0
        model.prepareGlobalFileIndex()
        showingQuickOpen = true
    }

    private func closeQuickPicker() {
        showingQuickOpen = false
        pdfCaptureRequest = nil
        pdfCaptureCommentary = ""
    }

    private func savePDFCapture(to studyNote: URL) {
        guard let capture = pdfCaptureRequest else { return }
        guard model.appendPDFReference(
            pdf: capture.pdf,
            page: capture.page,
            commentary: pdfCaptureCommentary,
            selectedText: capture.selectedText,
            anchor: capture.anchor,
            to: studyNote
        ) else { return }

        closeQuickPicker()
        pendingEditorFocus = studyNote
        model.openStudyNote(studyNote)
        if model.selected == studyNote {
            pendingEditorFocus = nil
            mode = .edit
            Task { @MainActor in editorFocused = true }
        }
    }

    private func openQuickMatch(_ item: NoteItem) {
        if pdfCaptureRequest != nil {
            savePDFCapture(to: item.url)
            return
        }
        closeQuickPicker()
        model.openFile(item.url)
    }

    private func createNoteFromPDFCapture() {
        guard let capture = pdfCaptureRequest,
              let root = model.root,
              let snippet = PDFPageReference.noteSnippet(
                for: capture.pdf,
                page: capture.page,
                root: root,
                commentary: pdfCaptureCommentary,
                selectedText: capture.selectedText,
                anchor: capture.anchor
              )
        else { return }

        let sourceTitle = capture.pdf.deletingPathExtension().lastPathComponent
        guard let filename = WorkspaceFiles.nextAvailableNoteName(
            basedOn: "\(sourceTitle) · p.\(capture.page)",
            in: root
        ) else { return }

        guard let created = model.newNote(
            named: filename,
            initialContent: "\(snippet)\n",
            preservePDFPreview: true
        ) else { return }
        closeQuickPicker()
        pendingEditorFocus = created
        mode = .edit
    }

    private var quickOpenSheet: some View {
        let matches = quickOpenMatches
        let selectedPreview = pdfCapturePreviewText
        return VStack(alignment: .leading, spacing: 0) {
            if let capture = pdfCaptureRequest {
                HStack(spacing: 10) {
                    Label(
                        "\(language.text("Add PDF page to note")) · \(capture.page)",
                        systemImage: "note.text.badge.plus"
                    )
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let studyNote = model.selected, model.externalBody == nil {
                        Button(language.text("Add to Study Note")) {
                            savePDFCapture(to: studyNote)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help(studyNote.deletingPathExtension().lastPathComponent)
                        .accessibilityIdentifier("pks-pdf-capture-current-note")
                    }
                    Button(language.text("New note from this page")) {
                        createNoteFromPDFCapture()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("pks-pdf-capture-new-note")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, selectedPreview == nil ? 8 : 6)

                if let selectedPreview {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "quote.opening")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                        Text(selectedPreview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(language.text("Selected PDF text"))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                }

                TextField(
                    language.text("Your note…"),
                    text: $pdfCaptureCommentary,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
                .lineLimit(2...4)
                .focused($pdfCaptureCommentaryFocused)
                .accessibilityLabel(language.text("Your note"))
                .accessibilityIdentifier("pks-pdf-capture-commentary")
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: NotesGeometry.symbolSize, weight: .medium))
                    .frame(width: NotesGeometry.treeIconWidth)
                    .foregroundStyle(.secondary)
                TextField(
                    language.text(pdfCaptureRequest == nil ? "Search files…" : "Search Markdown notes…"),
                    text: $quickOpenQuery
                )
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
                    closeQuickPicker()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: NotesGeometry.toolbarTarget, height: NotesGeometry.toolbarTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help(language.text("Cancel (Esc)"))
                .accessibilityIdentifier("pks-quick-open-cancel")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            Divider()
                .opacity(0.45)
                .padding(.horizontal, 20)
            if matches.isEmpty {
                VStack(spacing: 10) {
                    if model.indexingFiles {
                        ProgressView()
                            .controlSize(.small)
                        Text(language.text("Scanning files…"))
                    } else {
                        Text(language.text(
                            pdfCaptureRequest != nil
                                ? (quickOpenQuery.isEmpty
                                   ? "Choose a Markdown note for this PDF page."
                                   : "No Markdown notes match your search.")
                                : (quickOpenQuery.isEmpty
                                   ? "Type a name to find a note in your library."
                                   : "No files match your search.")
                        ))
                    }
                }
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
        .frame(
            width: 560,
            height: min(
                620,
                (matches.isEmpty ? 176 : min(470, max(238, CGFloat(matches.count) * 54 + 83)))
                    + (pdfCaptureRequest == nil ? 0 : (selectedPreview == nil ? 104 : 148))
            )
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.16), value: matches.isEmpty)
        .onChange(of: quickOpenQuery) { _, _ in quickOpenIndex = 0 }
        .onAppear {
            if pdfCaptureRequest != nil {
                pdfCaptureCommentaryFocused = true
            } else {
                quickOpenFocused = true
            }
        }
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
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 13.5, weight: .medium))
                        .frame(width: 22, height: 18)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                    if tab == .search && !model.hits.isEmpty {
                        Circle()
                            .fill(theme.linkColor)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: -1)
                    }
                }
                Text(title)
                    .font(.system(size: 9.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(selected ? Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.065) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityIdentifier("pks-sidebar-\(tab.rawValue.lowercased())")
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
                                    .draggable(row.item.url)
                                    .dropDestination(for: URL.self) { urls, _ in
                                        guard let source = urls.first?.standardizedFileURL,
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
                                        fileDropTargetPath = targeted ? row.id : nil
                                    }
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
                                Text(row.item.name)
                                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                    .frame(height: NotesGeometry.treeRowHeight)
                                    .padding(.leading, NotesGeometry.treeTextGap)
                                    .contentShape(Rectangle())
                                    .draggable(row.item.url)
                                    .simultaneousGesture(TapGesture(count: 1).onEnded {
                                        treeCursorPath = row.id
                                        treeFocused = true
                                        model.openFile(row.item.url)
                                    })
                                    .accessibilityAddTraits(.isButton)
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
                        .id(row.id)
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
                    revealCurrentFile()
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(currentWorkspaceFile == nil)
                .help(language.text("Reveal Current File") + " (⌥F1)")
                .accessibilityIdentifier("pks-reveal-current-file-button")

                Button(action: openQuickPicker) {
                    Image(systemName: "command")
                        .font(.system(size: 13.5, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(language.text("Quick Open a file in the current library") + " (⌘P)")
                .accessibilityIdentifier("pks-sidebar-quick-open")

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
            .padding(.top, 1)

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
            .padding(.bottom, 9)

            HStack(spacing: 4) {
                navigationRow(.notes, symbol: "square.stack.3d.up", title: language.text("All Notes"))
                navigationRow(.recent, symbol: "clock", title: language.text("Recent"))
                navigationRow(.favorites, symbol: "star", title: language.text("Favorites"))
                navigationRow(.search, symbol: "text.magnifyingglass", title: language.text("PKS Search"))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

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

            ScrollViewReader { proxy in
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
                .onChange(of: treeRevealRequest) { _, path in
                    guard let path else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(path, anchor: .center)
                    }
                    treeRevealRequest = nil
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
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
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

    private func markdownTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView,
           textView.isEditable, !textView.isFieldEditor {
            return textView
        }
        for subview in view.subviews {
            if let match = markdownTextView(in: subview) { return match }
        }
        return nil
    }

    /// A newly mounted/reloaded TextEditor must not inherit AppKit undo operations
    /// recorded while its visible string represented another draft/view state.
    private func resetNativeEditorUndoBaseline() {
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(60))
            markdownTextView(in: NSApp.keyWindow?.contentView)?.undoManager?.removeAllActions()
        }
    }

    private func handlePaste() {
        guard model.selected != nil,
              model.externalBody == nil,
              let textView = MarkdownNativeCommand.activeTextView() else {
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
        let result = MarkdownEditing.insert(markdown, into: model.draft, selection: textView.selectedRange())
        // NotesModel.draft is the single Markdown writer. SwiftUI remounts the native
        // editor from that canonical value; NSTextView only restores the caret.
        model.draft = result.text
        Task { @MainActor in
            await Task.yield()
            guard let active = MarkdownNativeCommand.activeTextView()
                    ?? markdownTextView(in: NSApp.keyWindow?.contentView) else { return }
            active.setSelectedRange(result.selection)
            active.scrollRangeToVisible(result.selection)
        }
    }

    private func jumpToOutlineHeading(_ heading: MarkdownOutlineHeading) {
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
        .overlay(alignment: .topTrailing) {
            if let opening = model.openingNoteName, model.selected != nil {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("\(language.text("Opening note…")) \(opening)")
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.regularMaterial, in: Capsule())
                .padding(10)
                .allowsHitTesting(false)
                .accessibilityIdentifier("pks-opening-note-indicator")
            }
        }
        .navigationTitle(model.previewPDF?.lastPathComponent
                         ?? model.selected?.deletingPathExtension().lastPathComponent
                         ?? model.previewSource?.title
                         ?? language.text("PKS Notes"))
    }

    @ViewBuilder
    private var reader: some View {
        if let url = model.previewPDF {
            if let note = model.selected, model.externalBody == nil {
                HSplitView {
                    pdfReader(url)
                        .frame(minWidth: 330)
                    studyNotePane(note)
                        .frame(minWidth: 280, idealWidth: 400)
                }
                .accessibilityIdentifier("pks-study-workspace")
            } else {
                pdfReader(url)
            }
        } else if showingMindMap && model.selected != nil && model.externalBody == nil {
            MindMapCanvas(
                source: $model.draft,
                selectedID: $mindMapSelectionLine,
                revision: model.draftRevision,
                openLink: { target in _ = model.openKnowledgeLink(target) },
                revealSource: { line in revealMarkdownLine(line) },
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

    private func pdfReader(_ url: URL) -> some View {
        NativePDFPreview(
            url: url,
            root: model.root,
            requestedPage: model.previewPDFPage,
            requestedAnchor: model.previewPDFAnchor,
            onAddPageToNote: { page, selectedText, anchor in
                beginPDFCapture(
                    pdf: url,
                    page: page,
                    selectedText: selectedText,
                    anchor: anchor
                )
            }
        )
    }

    private func studyNotePane(_ note: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.deletingPathExtension().lastPathComponent)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(language.text("Study Note"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.autoSavePending {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(language.text("Save"))
                }
                Button {
                    model.closePDFPreview()
                    mode = .edit
                    Task { @MainActor in editorFocused = true }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(language.text("Open note only"))
                .accessibilityLabel(language.text("Open note only"))
                .accessibilityIdentifier("pks-study-note-only")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.025))

            Divider()
            editor
        }
        .background(theme.canvas)
        .accessibilityIdentifier("pks-study-note-pane")
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
            .onAppear { resetNativeEditorUndoBaseline() }
    }

    private func setMindMapVisible(_ visible: Bool) {
        guard visible != showingMindMap else { return }
        if visible {
            modeBeforeMindMap = mode
            if let textView = MarkdownNativeCommand.activeTextView()
                ?? markdownTextView(in: NSApp.keyWindow?.contentView) {
                mindMapSelectionLine = MindMapOutline.nodeID(
                    atUTF16Offset: textView.selectedRange().location,
                    in: model.draft
                )
            } else if mindMapSelectionLine == nil {
                mindMapSelectionLine = MindMapOutline.nodes(in: model.draft).first?.id
            }
            showingMindMap = true
        } else if let line = mindMapSelectionLine {
            revealMarkdownLine(line)
        } else {
            showingMindMap = false
            mode = modeBeforeMindMap
        }
    }

    private func revealMarkdownLine(_ line: Int) {
        guard model.selected != nil,
              let range = MindMapOutline.sourceLineRange(in: model.draft, nodeID: line) else { return }
        mindMapSelectionLine = line
        showingMindMap = false
        mode = .edit
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(60))
            guard let textView = MarkdownNativeCommand.activeTextView()
                    ?? markdownTextView(in: NSApp.keyWindow?.contentView) else { return }
            NSApp.keyWindow?.makeFirstResponder(textView)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }
    }

    private var renderedNote: some View {
        MarkdownPreviewPane(source: model.body, revision: model.bodyRevision,
                            live: mode == .split,
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
