import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import MarkdownUI

@MainActor
final class PKSNotesAppDelegate: NSObject, NSApplicationDelegate {
    weak var notesModel: NotesModel?
    private var markdownKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        GlobalSearchController.shared.install()
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
    @StateObject private var purchases = ProPurchases()
    @AppStorage(AppAppearance.defaultsKey) private var appearanceID = AppAppearance.system.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var languageID = AppLanguage.system.rawValue

    private var appearance: AppAppearance { AppAppearance.restored(appearanceID) }
    private var language: AppLanguage { AppLanguage.restored(languageID) }

    var body: some Scene {
        WindowGroup {
            NotesWindow()
                .environmentObject(model)
                .environmentObject(purchases)
                .environment(\.notesLanguage, language)
                .environment(\.locale, language.locale)
                .preferredColorScheme(appearance.colorScheme)
                .task { await purchases.start() }
                .onAppear { appDelegate.notesModel = model }
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1220, height: 780)

        Settings {
            PKSNotesSettingsView()
                .environmentObject(purchases)
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
                // Replacing the pasteboard group also removes the system Select All item.
                // Route to the first responder so search, Quick Open, rename and editor
                // text inputs retain native selection behavior (without changing focus).
                Button(language.text("Select All")) {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
            }
            CommandMenu("Markdown") {
                Button(language.text("Bold")) {
                    if !MarkdownNativeCommand.perform("bold") {
                        NotificationCenter.default.post(name: .pksMindMapBold, object: nil)
                    }
                }
                .keyboardShortcut("b", modifiers: .command)
                Button(language.text("Italic")) {
                    if !MarkdownNativeCommand.perform("italic") {
                        NotificationCenter.default.post(name: .pksMindMapItalic, object: nil)
                    }
                }
                .keyboardShortcut("i", modifiers: .command)
                Button(language.text("Inline Code")) { MarkdownNativeCommand.perform("code") }
                    .keyboardShortcut("e", modifiers: .command)
                Button(language.text("Code Block")) { MarkdownNativeCommand.perform("codeBlock") }
                Button(language.text("Link")) { MarkdownNativeCommand.perform("link") }
                    .keyboardShortcut("k", modifiers: .command)
                Button(language.text("Insert PDF Citation at Cursor")) {
                    NotificationCenter.default.post(name: NotesMenuEvent.insertPDFCitationAtCursor, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.previewPDF == nil || model.selected == nil || model.externalBody != nil)
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
                Button(language.text("Numbered List")) { MarkdownNativeCommand.perform("ordered") }
                    .keyboardShortcut("7", modifiers: [.command, .shift])
                Button(language.text("Task")) { MarkdownNativeCommand.perform("task") }
                    .keyboardShortcut("9", modifiers: [.command, .shift])
                Button(language.text("Quote")) { MarkdownNativeCommand.perform("quote") }
                Button(language.text("Insert Table")) { MarkdownNativeCommand.perform("table") }
            }
            CommandMenu("Leafspan") {
                Button(language.text("New Markdown Note")) {
                    NotificationCenter.default.post(name: NotesMenuEvent.newNote, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button(language.text("Quick Open…")) {
                    NotificationCenter.default.post(name: NotesMenuEvent.quickOpen, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
                Button(language.resolved == .simplifiedChinese ? "全局搜索…" : "Global Search…") {
                    GlobalSearchController.shared.present()
                }
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
                Button(language.text("Find in Current File")) {
                    NotificationCenter.default.post(name: NotesMenuEvent.findCurrentFile, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                Button(language.text("Search Workspace")) {
                    NotificationCenter.default.post(name: NotesMenuEvent.search, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                Button(language.text("Search")) { model.search() }
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

private struct PKSNotesSettingsView: View {
    @EnvironmentObject private var purchases: ProPurchases
    @Environment(\.notesLanguage) private var language
    @State private var showingPro = false
    @State private var showingGlobalSearch = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                settingsPaneButton(
                    title: language.text("Appearance"),
                    symbol: "textformat.size",
                    selected: !showingPro && !showingGlobalSearch
                ) {
                    showingPro = false
                    showingGlobalSearch = false
                }
                settingsPaneButton(
                    title: language.text("Pro"),
                    symbol: "checkmark.seal",
                    selected: showingPro
                ) {
                    showingPro = true
                    showingGlobalSearch = false
                }
                settingsPaneButton(
                    title: language.resolved == .simplifiedChinese ? "搜索" : "Search",
                    symbol: "magnifyingglass",
                    selected: showingGlobalSearch
                ) {
                    showingGlobalSearch = true
                    showingPro = false
                }
            }
            .frame(width: 350)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            if showingGlobalSearch {
                GlobalSearchSettingsView()
            } else if showingPro {
                ProSettingsView()
                    .environmentObject(purchases)
            } else {
                NotesAppearanceSettings()
            }
        }
        .frame(width: 470)
    }

    private func settingsPaneButton(
        title: String,
        symbol: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    selected ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(selected ? "pks-settings-selected-pane" : "pks-settings-other-pane")
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
    static let railSymbolSize: CGFloat = 16
    static let documentInset: CGFloat = 32
    static let selectionCorner: CGFloat = 9
    static let workspacePanelRadius: CGFloat = 14
    static let workspacePanelInset: CGFloat = 9
    static let workspacePanelGap: CGFloat = 9
    static let auxiliaryPanelWidth: CGFloat = 312
    static let standardMainMinimumWidth: CGFloat = 700
    static let workbenchColor = Color(nsColor: .windowBackgroundColor)

    static func studySplitThreshold(showingMindMap: Bool) -> CGFloat {
        showingMindMap ? 940 : 820
    }

    static func fitsInlineAuxiliary(availableWidth: CGFloat, minimumMainWidth: CGFloat) -> Bool {
        availableWidth >= minimumMainWidth + auxiliaryPanelWidth
            + workspacePanelInset * 2 + workspacePanelGap
    }

    static func workspaceTitle(_ root: URL?, language: AppLanguage) -> String {
        guard let root else { return language.text("Knowledge Library") }
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
            case "7": return "ordered"
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
    static func insertText(_ value: String, at location: Int, in textView: NSTextView) -> Bool {
        guard textView.isEditable, !textView.isFieldEditor,
              !textView.hasMarkedText(), !value.isEmpty else { return false }
        let original = textView.string
        let length = (original as NSString).length
        let range = NSRange(location: min(max(location, 0), length), length: 0)
        let result = MarkdownEditing.insert(value, into: original, selection: range)
        apply(result, from: original, in: textView)
        return true
    }

    @discardableResult
    static func replaceSelection(_ value: String, in textView: NSTextView) -> Bool {
        guard textView.isEditable, !textView.isFieldEditor,
              !textView.hasMarkedText(), !value.isEmpty else { return false }
        let original = textView.string
        let result = MarkdownEditing.insert(value, into: original, selection: textView.selectedRange())
        apply(result, from: original, in: textView)
        return true
    }

    @discardableResult
    static func insertAtCaret(_ value: String, in textView: NSTextView) -> Bool {
        guard textView.selectedRange().length == 0 else { return false }
        return insertText(value, at: textView.selectedRange().location, in: textView)
    }

    @discardableResult
    static func perform(_ value: String) -> Bool {
        perform(value, in: activeTextView())
    }

    @discardableResult
    static func perform(_ value: String, in textView: NSTextView?) -> Bool {
        guard let textView, textView.isEditable, !textView.isFieldEditor,
              !textView.hasMarkedText(),
              let command = editCommand(for: value) else { return false }
        let original = textView.string
        let result = MarkdownEditing.apply(command, to: original, selection: textView.selectedRange())
        apply(result, from: original, in: textView)
        return true
    }

    private static func apply(_ result: MarkdownEditResult, from original: String, in textView: NSTextView) {
        guard let replacement = MarkdownEditing.minimalChange(from: original, to: result.text) else { return }
        textView.insertText(replacement.text, replacementRange: replacement.range)
        textView.didChangeText()
        // Selection is part of the same native edit transaction. Deferring it
        // to the next main-queue turn lets a fast follow-up keystroke use the
        // insertion-end caret instead of replacing the formatted selection.
        textView.setSelectedRange(result.selection)
        textView.scrollRangeToVisible(result.selection)
    }

    private static func editCommand(for value: String) -> MarkdownEditCommand? {
        switch value {
        case "bold": .bold
        case "italic": .italic
        case "code": .inlineCode
        case "codeBlock": .codeBlock
        case "link": .link
        case "h1": .heading(1)
        case "h2": .heading(2)
        case "h3": .heading(3)
        case "bullet": .bullet
        case "task": .task
        case "ordered": .ordered
        case "quote": .quote
        case "table": .table
        default: nil
        }
    }
}

@MainActor
final class PDFCitationDropTarget {
    private weak var textView: NSTextView?
    private weak var window: NSWindow?
    private let note: URL
    private let draftRevision: UInt64
    let insertionIndex: Int

    static func window(at screenPoint: NSPoint, in orderedWindows: [NSWindow]) -> NSWindow? {
        orderedWindows.first { $0.frame.contains(screenPoint) }
    }

    static func editableTextView(at screenPoint: NSPoint, in window: NSWindow) -> NSTextView? {
        guard let contentView = window.contentView else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let contentPoint = contentView.convert(windowPoint, from: nil)
        var candidate = contentView.hitTest(contentPoint)
        while let view = candidate {
            if let textView = view as? NSTextView,
               textView.isEditable, !textView.isFieldEditor,
               !textView.isHiddenOrHasHiddenAncestor,
               textView.window === window {
                return textView
            }
            candidate = view.superview
        }
        return nil
    }

    init?(screenPoint: NSPoint, note: URL, draftRevision: UInt64, textView: NSTextView) {
        guard textView.isEditable, !textView.isFieldEditor,
              let window = textView.window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let textPoint = textView.convert(windowPoint, from: nil)
        let insertionIndex = textView.characterIndexForInsertion(at: textPoint)
        guard insertionIndex != NSNotFound,
              !MindMapOutline.isInsideCode(in: textView.string, at: insertionIndex) else { return nil }

        self.textView = textView
        self.window = window
        self.note = note
        self.draftRevision = draftRevision
        self.insertionIndex = insertionIndex
    }

    /// A drop on any structural node title attaches to that node's body rather than
    /// splitting its title at the pointer. Drops in ordinary body text keep the
    /// exact pointer-derived insertion offset.
    nonisolated static func citationInsertionOffset(in markdown: String, at offset: Int) -> Int {
        let source = markdown as NSString
        let safeOffset = min(max(0, offset), source.length)
        guard let nodeID = MindMapOutline.nodeID(atUTF16Offset: safeOffset, in: markdown) else {
            return safeOffset
        }
        let lineIndex = source.substring(to: safeOffset).reduce(into: 0) { index, character in
            if character == "\n" { index += 1 }
        }
        // List and heading titles are both structural node labels. Attach a
        // citation to their body rather than splitting the title at the pointer.
        guard nodeID == lineIndex else { return safeOffset }

        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        source.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: safeOffset, length: 0)
        )
        return contentsEnd
    }

    nonisolated static func citationForInsertion(_ citation: String, in markdown: String, at offset: Int) -> String {
        let source = markdown as NSString
        let safeOffset = min(max(0, offset), source.length)
        guard let nodeID = MindMapOutline.nodeID(atUTF16Offset: safeOffset, in: markdown),
              MindMapOutline.isListNode(in: markdown, nodeID: nodeID) else {
            return citation
        }

        let lines = markdown.components(separatedBy: "\n")
        let currentLineIndex = source.substring(to: safeOffset).reduce(into: 0) { index, character in
            if character == "\n" { index += 1 }
        }
        guard lines.indices.contains(nodeID), lines.indices.contains(currentLineIndex) else {
            return citation
        }

        guard let continuationIndent = MindMapOutline.listContinuationIndent(
            in: markdown, nodeID: nodeID
        ) else { return citation }
        let currentLine = lines[currentLineIndex]
        let currentLineIndent = currentLine.prefix(while: { $0 == " " }).count
        let blankContinuation = currentLineIndex > nodeID
            && currentLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && lines[(nodeID + 1)..<currentLineIndex].allSatisfy {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || $0.prefix(while: { $0 == " " }).count >= continuationIndent
            }
        // Only indent on the list item, an indented continuation, or a blank
        // line still bounded by that item's indented content. Root-level blocks
        // and unindented code remain outside the earlier list item.
        guard currentLineIndex == nodeID
                || currentLineIndent >= continuationIndent
                || blankContinuation else {
            return citation
        }

        return citation.components(separatedBy: "\n").map { line in
            line.isEmpty ? line : String(repeating: " ", count: continuationIndent) + line
        }.joined(separator: "\n")
    }

    /// Insert a PDF citation into the selected node's own Markdown body.
    /// The first following outline node bounds that body, so descendants and
    /// siblings remain separate and the existing Markdown writer stays canonical.
    nonisolated static func citationForNodeInsertion(
        _ citation: String, in markdown: String, nodeID: Int
    ) -> String? {
        let parsed = MindMapOutline.nodes(in: markdown)
        guard let position = parsed.firstIndex(where: { $0.id == nodeID }) else { return nil }
        let lines = markdown.components(separatedBy: "\n")
        guard lines.indices.contains(nodeID) else { return nil }
        let bodyEnd = parsed.dropFirst(position + 1).first?.id ?? lines.count
        guard bodyEnd > nodeID, bodyEnd <= lines.count else { return nil }

        let insertionLine = (nodeID..<bodyEnd).reversed().first {
            !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nodeID
        let insertionOffset = lines[..<insertionLine].reduce(into: 0) { offset, line in
            offset += (line as NSString).length + 1
        } + (lines[insertionLine] as NSString).length

        let nodeIndent = lines[nodeID].prefix(while: { $0 == " " }).count
        let continuationIndent = MindMapOutline.listContinuationIndent(
            in: markdown, nodeID: nodeID
        ) ?? nodeIndent
        let citationLines = citation.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        guard citationLines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        let indentation = String(repeating: " ", count: continuationIndent)
        let block = citationLines.map { $0.isEmpty ? "" : indentation + $0 }.joined(separator: "\n")
        return MarkdownEditing.insert(
            "\n\n\(block)\n\n",
            into: markdown,
            selection: NSRange(location: insertionOffset, length: 0)
        ).text
    }

    /// The menu action uses the same structural-node placement as a PDF drag,
    /// without moving the editor's caret before the native undoable insertion.
    @discardableResult
    static func insertAtCaret(_ citation: String, in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0,
              !MindMapOutline.isInsideCode(in: textView.string, at: selection.location) else {
            return false
        }
        let insertionIndex = citationInsertionOffset(in: textView.string, at: selection.location)
        let formatted = citationForInsertion(citation, in: textView.string, at: insertionIndex)
        return MarkdownNativeCommand.insertText(formatted, at: insertionIndex, in: textView)
    }

    @discardableResult
    func insert(
        _ citation: String,
        currentNote: URL?,
        currentDraftRevision: UInt64,
        canEdit: Bool,
        asFileLink: Bool = false
    ) -> Bool {
        guard canEdit,
              currentNote == note,
              currentDraftRevision == draftRevision,
              let textView,
              let window,
              textView.window === window,
              window.makeFirstResponder(textView) else { return false }
        let targetIndex = Self.citationInsertionOffset(in: textView.string, at: insertionIndex)
        // Ordinary file drops insert at the pointer. A drop on a node title
        // becomes a body link rather than silently rewriting the heading.
        let linkOnTitle = asFileLink && targetIndex != insertionIndex
        let payload = linkOnTitle ? "\n\n\(citation)\n\n" : citation
        let formatted = asFileLink && !linkOnTitle
            ? payload : Self.citationForInsertion(payload, in: textView.string, at: targetIndex)
        return MarkdownNativeCommand.insertText(formatted, at: targetIndex, in: textView)
    }
}

enum NotesMenuEvent {
    static let quickOpen = Notification.Name("PKSNotesMenuQuickOpen")
    static let newNote = Notification.Name("PKSNotesMenuNewNote")
    static let findCurrentFile = Notification.Name("PKSNotesFindCurrentFile")
    static let search = Notification.Name("PKSNotesMenuSearch")
    static let toggleEdit = Notification.Name("PKSNotesToggleEditPreview")
    static let paste = Notification.Name("PKSNotesPaste")
    static let revealCurrentFile = Notification.Name("PKSNotesRevealCurrentFile")
    static let insertPDFCitationAtCursor = Notification.Name("PKSNotesInsertPDFCitationAtCursor")
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

struct MarkdownEditorRevealRequest: Equatable {
    enum Target: Equatable {
        case line(Int)
        case end
    }

    let note: URL
    let target: Target
    let keepsMindMapVisible: Bool

    func selectionRange(
        in source: String,
        selectedNote: URL?,
        selectedNodeLine: Int?
    ) -> NSRange? {
        guard let selectedNote,
              selectedNote.standardizedFileURL == note.standardizedFileURL else { return nil }
        switch target {
        case .line(let line):
            let targetLine = keepsMindMapVisible ? selectedNodeLine ?? line : line
            return MarkdownOutline.lineRange(in: source, lineIndex: targetLine)
        case .end:
            return NSRange(location: (source as NSString).length, length: 0)
        }
    }
}

private struct PDFCaptureRequest: Equatable {
    let id = UUID()
    let pdf: URL
    let page: Int
    let selectedText: String?
    let anchor: PDFSourceAnchor?
    let selectionWasUnanchored: Bool
}

struct NotesWindow: View {
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var purchases: ProPurchases
    @Environment(\.notesLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var readingModeNamespace
    @State private var mode: ReadingMode = .read
    @State private var showingMindMap = false
    @State private var showingMindMapSourcePane = false
    @State private var mindMapSelectionLine: Int?
    @State private var pendingMarkdownReveal: MarkdownEditorRevealRequest?
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
    @State private var quickOpenMatches: [NoteItem] = []
    @State private var showingQuickOpen = false
    @State private var showingBacklinks = false
    @State private var showingOutline = false
    @AppStorage("LeafspanAuxiliaryListPresentation") private var auxiliaryListPresentation = "pane"
    @AppStorage("LeafspanShowMarkdownToolbar") private var showMarkdownToolbar = true
    @State private var showingProUpsell = false
    @State private var quickOpenQuery = ""
    @State private var quickOpenIndex = 0
    @State private var quickOpenFallbackRescanRequested = false
    @State private var pdfCaptureRequest: PDFCaptureRequest?
    @State private var pdfCaptureCommentary = ""
    @State private var pdfCaptureTask: Task<Void, Never>?
    @State private var loadedPDFDocument: PDFDocument?
    @State private var loadedPDFLoadFailure: PDFDocumentLoadFailure?
    @State private var loadedPDFURL: URL?
    @State private var compactStudyShowsStudyPane = false
    @StateObject private var pdfReaderController = PDFReaderController()
    @State private var mindMapLinkNodeID: Int?
    @State private var linkRepairRequest: (source: URL, target: String, revision: UInt64)?
    @State private var mindMapLinkSectionMode = false
    @State private var mindMapSectionTarget: URL?
    @State private var mindMapSectionHeadings: [MarkdownOutlineHeading] = []
    @State private var loadingMindMapSectionHeadings = false

    private var localQuickOpenPriorityURLs: [URL] {
        var urls: [URL] = []
        if let selected = model.selected { urls.append(selected) }
        urls.append(contentsOf: model.recentNotes)
        urls.append(contentsOf: model.favoriteNotes.prefix(32))
        return urls
    }

    private func localQuickOpenEntries(_ files: [NoteItem]) -> [NoteTreePresentation.QuickOpenEntry] {
        NoteTreePresentation.quickOpenEntries(
            files,
            prioritizedFiles: localQuickOpenPriorityURLs
        )
    }

    private var pdfCapturePreviewText: String? {
        guard let text = pdfCaptureRequest?.selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private var theme: NotesTheme { NotesTheme.restored(themeID) }

    private var mindMapToggleBinding: Binding<Bool> {
        Binding(
            get: { showingMindMap },
            set: { requested in
                guard requested else {
                    setMindMapVisible(false)
                    return
                }
                if ProAccess.allows(.mindMap, unlocked: purchases.unlocked) {
                    setMindMapVisible(true)
                } else {
                    showingProUpsell = true
                }
            }
        )
    }
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarTab: SidebarTab = .notes
    @State private var hoveredRailTab: SidebarTab?
    @State private var pendingEditorFocus: URL?
    @State private var pendingBacklinkNote: URL?
    @State private var pendingBacklinkLine: Int?
    @State private var pendingBacklinkStamp: WorkspaceFileStamp?
    @State private var pendingMindMapOpen: URL?
    @State private var renameCandidate: URL?
    @State private var renameValue = ""
    @State private var showingRename = false
    @State private var newFolderParent: URL?
    @State private var newFolderValue = ""
    @State private var showingNewFolder = false
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
                .navigationSplitViewColumnWidth(min: 320, ideal: 368, max: 480)
        } detail: {
            GeometryReader { geometry in
                let minimumMainWidth = model.previewPDF != nil && model.selected != nil
                    && model.externalBody == nil
                    ? NotesGeometry.studySplitThreshold(showingMindMap: showingMindMap)
                    : NotesGeometry.standardMainMinimumWidth
                let inlineAuxiliary = auxiliaryListPresentation != "sheet"
                    && NotesGeometry.fitsInlineAuxiliary(
                        availableWidth: geometry.size.width, minimumMainWidth: minimumMainWidth
                    )

                HStack(spacing: NotesGeometry.workspacePanelGap) {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(
                            cornerRadius: NotesGeometry.workspacePanelRadius,
                            style: .continuous
                        ))
                    if inlineAuxiliary && (showingOutline || showingBacklinks) {
                        auxiliaryListPanel
                            .frame(width: NotesGeometry.auxiliaryPanelWidth)
                            .clipShape(RoundedRectangle(
                                cornerRadius: NotesGeometry.workspacePanelRadius,
                                style: .continuous
                            ))
                    }
                }
                .padding(NotesGeometry.workspacePanelInset)
                .background(NotesGeometry.workbenchColor)
                .sheet(isPresented: Binding(
                    get: {
                        (auxiliaryListPresentation == "sheet" || !inlineAuxiliary)
                            && (showingOutline || showingBacklinks)
                    },
                    set: { if !$0 { showingOutline = false; showingBacklinks = false } }
                )) {
                    auxiliaryListPanel.frame(width: 550, height: 610)
                }
            }
        }
        .toolbarBackground(NotesGeometry.workbenchColor, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.selected != nil && model.externalBody == nil && model.previewPDF == nil && !showingMindMap {
                    HStack(spacing: 2) {
                        ForEach(ReadingMode.allCases, id: \.self) { choice in
                            Button {
                                switchReadingMode(to: choice)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: choice.symbol)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(language.text(choice.rawValue))
                                        .font(.system(size: 11.5, weight: mode == choice ? .semibold : .medium))
                                }
                                .foregroundStyle(mode == choice ? Color.primary : Color.secondary)
                                .padding(.horizontal, 10)
                                .frame(height: 29)
                                .background {
                                    if mode == choice {
                                        Capsule()
                                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09))
                                            .matchedGeometryEffect(id: "reading-mode", in: readingModeNamespace)
                                    }
                                }
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(choice.shortcut, modifiers: .command)
                            .help("\(language.text(choice.rawValue)) Markdown")
                            .accessibilityIdentifier("pks-mode-\(choice.rawValue.lowercased())")
                        }
                    }
                    .padding(3)
                }

                if model.selected != nil && model.externalBody == nil && model.previewPDF == nil
                    && !showingMindMap && mode != .read {
                    Toggle(isOn: $showMarkdownToolbar) {
                        toolbarSymbol("textformat")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.plain)
                    .help(language.text(showMarkdownToolbar ? "Hide Markdown Toolbar" : "Show Markdown Toolbar"))
                    .accessibilityLabel(language.text("Markdown formatting toolbar"))
                    .accessibilityValue(language.text(showMarkdownToolbar ? "On" : "Off"))
                    .accessibilityIdentifier("pks-markdown-toolbar-toggle")
                }

                if model.selected != nil && model.externalBody == nil {
                    Toggle(isOn: mindMapToggleBinding) {
                        toolbarSymbol(showingMindMap ? "doc.text" : "point.3.connected.trianglepath.dotted")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.plain)
                    .help(language.text(showingMindMap
                        ? (model.previewPDF == nil ? "Return to Markdown" : "Return to Study Note")
                        : "Mind Map"))
                    .accessibilityLabel(language.text("Mind Map"))
                    .accessibilityValue(language.text(showingMindMap ? "On" : "Off"))
                    .accessibilityIdentifier("pks-mind-map-toggle")
                }
                if model.selected != nil && model.externalBody == nil && model.previewPDF == nil {
                    Button {
                        showingOutline.toggle()
                        if showingOutline { showingBacklinks = false }
                    } label: {
                        toolbarSymbol("list.bullet.indent")
                    }
                    .buttonStyle(.plain)
                    .disabled(outlineHeadings.isEmpty)
                    .help(language.text("Document Outline"))
                    .accessibilityLabel(language.text("Document Outline"))
                    .accessibilityIdentifier("pks-outline-menu")

                    Button {
                        model.toggleFavorite()
                    } label: {
                        toolbarSymbol(model.selectedIsFavorite ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .help(language.text(model.selectedIsFavorite ? "Remove from Favorites" : "Add to Favorites"))
                    .accessibilityLabel(language.text(model.selectedIsFavorite ? "Remove from Favorites" : "Add to Favorites"))
                    .accessibilityIdentifier("pks-favorite-toggle")
                }

                if (model.selected != nil && model.externalBody == nil) || model.previewPDF != nil {
                    Button {
                        if ProAccess.allows(.relationships, unlocked: purchases.unlocked) {
                            showingBacklinks.toggle()
                            if showingBacklinks {
                                showingOutline = false
                                model.loadRelationships()
                            }
                        } else {
                            showingProUpsell = true
                        }
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
                    .accessibilityLabel(language.text(model.previewPDF == nil
                                                      ? "Links and related notes"
                                                      : "Linked notes for this PDF"))
                    .accessibilityIdentifier("pks-relationships-menu")

                }

                if model.loadingNote, let requested = model.requestedNote {
                    ProgressView()
                        .controlSize(.small)
                        .help("\(language.text("Opening note…")) \(requested.deletingPathExtension().lastPathComponent)")
                        .accessibilityLabel(language.text("Opening note…"))
                        .accessibilityIdentifier("pks-note-open-progress")
                } else if let path = model.fileOperationInProgress {
                    ProgressView()
                        .controlSize(.small)
                        .help("\(language.text("Updating files…")) \(path.lastPathComponent)")
                        .accessibilityLabel(language.text("Updating files…"))
                        .accessibilityIdentifier("pks-path-change-progress")
                } else if model.autoSavePending && model.selected != nil {
                    ProgressView()
                        .controlSize(.small)
                        .help(language.text("Saving Markdown automatically…"))
                        .accessibilityIdentifier("pks-autosave-progress")
                }

                // Keep the active document locator one click away even when
                // the sidebar is showing search/recent items or is collapsed.
                Button {
                    revealCurrentFile()
                } label: {
                    toolbarSymbol("scope")
                }
                .buttonStyle(.plain)
                .disabled(currentWorkspaceFile == nil)
                .help(language.text("Reveal Current File"))
                .accessibilityLabel(language.text("Reveal Current File"))
                .accessibilityIdentifier("pks-reveal-current-file-button")

                Menu {
                    Button(language.text("Quick Open Note…"), systemImage: "doc.text.magnifyingglass") {
                        openQuickPicker()
                    }
                    Button(language.text("Reveal Current File"), systemImage: "scope") {
                        revealCurrentFile()
                    }
                    .disabled(currentWorkspaceFile == nil)
                    .accessibilityIdentifier("pks-reveal-current-file-menu")
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
                    if !ProAccess.allows(.mindMap, unlocked: purchases.unlocked) {
                        Button(language.text("Unlock Pro…"), systemImage: "checkmark.seal") {
                            showingProUpsell = true
                        }
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
                .accessibilityLabel(language.text("File actions and workspace options"))
            }
        }
        .sheet(isPresented: $showingProUpsell) {
            ProSettingsView()
                .environmentObject(purchases)
        }
        .onChange(of: purchases.unlocked) { _, unlocked in
            if !unlocked {
                showingMindMap = false
                showingBacklinks = false
            }
        }
        .onChange(of: showingMindMap) { _, visible in
            if !visible { showingMindMapSourcePane = false }
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
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.findCurrentFile)) { _ in
            findInCurrentFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.search)) { _ in
            focusKnowledgeSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.toggleEdit)) { _ in
            if showingMindMap {
                NotificationCenter.default.post(name: .pksMindMapToggleTask, object: nil)
            } else {
                toggleEditPreview()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.paste)) { _ in
            handlePaste()
        }
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.insertPDFCitationAtCursor)) { _ in
            insertPDFCitationAtCursor()
        }
        .task(id: "\(model.previewPDF?.standardizedFileURL.path ?? "")#\(model.previewPDFReloadSequence)") {
            guard let requestedURL = model.previewPDF?.standardizedFileURL else {
                loadedPDFDocument = nil
                loadedPDFLoadFailure = nil
                loadedPDFURL = nil
                return
            }
            let generation = model.previewPDFReloadSequence
            loadedPDFDocument = nil
            loadedPDFLoadFailure = nil
            loadedPDFURL = nil
            let result = await PDFDocumentLoading.load(requestedURL)
            guard !Task.isCancelled,
                  model.previewPDF?.standardizedFileURL == requestedURL,
                  model.previewPDFReloadSequence == generation else { return }
            switch result {
            case .success(let document):
                loadedPDFDocument = document
            case .failure(let failure):
                loadedPDFLoadFailure = failure
            }
            loadedPDFURL = requestedURL
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
            let delay = markdownDerivedWorkDelay(forUTF8Bytes: input.utf8.count)
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
            do {
                try await Task.sleep(
                    for: markdownDerivedWorkDelay(forUTF8Bytes: input.utf8.count)
                )
            } catch { return }
            guard !Task.isCancelled else { return }
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
            if showingQuickOpen, !model.globalFileIndexReady {
                // Folding/sorting the local tree is useful only while Quick Open is
                // visible. Directory expansion and file mutations should not pay this
                // derived-work cost in the background.
                quickOpenEntries = localQuickOpenEntries(files)
                rebuildQuickOpenMatches()
            }
        }
        .onReceive(model.$globalQuickOpenEntries) { entries in
            guard showingQuickOpen else { return }
            if model.globalFileIndexReady {
                quickOpenEntries = entries
            } else {
                // A local filesystem mutation invalidates only the full-vault
                // projection. Keep an open picker useful immediately from the loaded tree.
                quickOpenEntries = localQuickOpenEntries(model.files)
            }
            rebuildQuickOpenMatches()
        }
        .onChange(of: quickOpenQuery) { _, _ in
            guard showingQuickOpen else { return }
            rebuildQuickOpenMatches()
            requestGlobalQuickOpenIndexIfNeeded()
        }
        .onChange(of: model.indexingFiles) { _, indexing in
            if !indexing { requestGlobalQuickOpenIndexIfNeeded() }
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
        .onChange(of: model.previewPDF) { _, pdf in
            guard pdf != nil else { return }
            showingMindMapSourcePane = false
            showingOutline = false
            outlineHeadings = []
            compactStudyShowsStudyPane = showingMindMap
        }
        .onChange(of: model.loadingNote) { _, loading in
            if !loading, mode != .read {
                resetNativeEditorUndoBaseline()
            }
        }
        .onChange(of: model.selected) { _, note in
            showingMindMapSourcePane = false
            mindMapSelectionLine = nil
            let openAsMap = note != nil && note == pendingMindMapOpen
            showingMindMap = openAsMap && ProAccess.allows(.mindMap, unlocked: purchases.unlocked)
            if openAsMap {
                pendingMindMapOpen = nil
                mode = .read
                if model.previewPDF != nil {
                    compactStudyShowsStudyPane = true
                }
            }
            showingBacklinks = false
            showingOutline = false
            outgoingLinks = []
            outlineHeadings = []
            if let note, let root = model.root {
                let ancestors = NoteTreePresentation.ancestorPaths(for: note, in: root)
                expandedFolderPaths.formUnion(ancestors)
                model.prioritizeExpandedPath(
                    ancestors,
                    toward: note.deletingLastPathComponent()
                )
                treeCursorPath = note.path
            }
            if note == pendingBacklinkNote,
               let line = pendingBacklinkLine,
               let expectedStamp = pendingBacklinkStamp {
                pendingBacklinkNote = nil
                pendingBacklinkLine = nil
                pendingBacklinkStamp = nil
                guard let note,
                      WorkspaceFiles.fileStamp(note) == expectedStamp else {
                    model.message = language.text("Link target not available in this workspace.")
                    return
                }
                revealMarkdownLineIndex(line)
            } else if note == pendingEditorFocus, note != nil {
                pendingEditorFocus = nil
                mode = .edit
                Task { @MainActor in
                    await Task.yield()
                    editorFocused = true
                    applyPendingMarkdownReveal()
                }
            } else if note != nil && !openAsMap {
                // Existing Markdown always opens in Preview. Edit is an explicit
                // per-note action; only the New Note path carries editor intent.
                mode = .read
            }
        }
        .sheet(isPresented: $showingQuickOpen) {
            quickOpenSheet
        }
        .interactiveDismissDisabled(pdfCaptureTask != nil)
        .alert(language.text("New Folder"), isPresented: $showingNewFolder) {
            TextField(language.text("Folder Name"), text: $newFolderValue)
                .accessibilityIdentifier("pks-new-folder-field")
            Button(language.text("Create")) {
                if let parent = newFolderParent,
                   let created = model.newFolder(named: newFolderValue, in: parent) {
                    if parent != model.root?.standardizedFileURL {
                        expandedFolderPaths.insert(parent.path)
                        model.loadExpandedFolder(parent)
                    }
                    treeCursorPath = created.path
                }
                newFolderParent = nil
                newFolderValue = ""
            }
            Button(language.text("Cancel"), role: .cancel) {
                newFolderParent = nil
                newFolderValue = ""
            }
        } message: {
            Text(language.text("Create a folder inside the current notes workspace."))
        }
        .alert(language.text("Rename"), isPresented: $showingRename) {
            TextField(language.text("Name"), text: $renameValue)
                .accessibilityIdentifier("pks-rename-field")
            Button(language.text("Rename")) {
                let item = renameCandidate
                let value = renameValue
                renameCandidate = nil
                if let item {
                    Task { @MainActor in
                        _ = await model.renameItem(item, to: value)
                    }
                }
            }
            .disabled(model.fileOperationInProgress != nil)
            Button(language.text("Cancel"), role: .cancel) { renameCandidate = nil }
        } message: {
            Text(language.text("Change the name without moving the item. File extensions are preserved."))
        }
        .alert(language.text("Move Folder to Trash?"), isPresented: $confirmingFolderTrash) {
            Button(language.text("Move to Trash"), role: .destructive) {
                if let folder = folderTrashCandidate { _ = model.moveToTrash(folder) }
                folderTrashCandidate = nil
            }
            .disabled(model.fileOperationInProgress != nil)
            Button(language.text("Cancel"), role: .cancel) { folderTrashCandidate = nil }
        } message: {
            Text(language.text("The folder and all of its contents will move to the macOS Trash, where they can be restored."))
        }
    }

    private func toolbarSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: NotesGeometry.symbolSize, weight: .medium))
            .frame(width: NotesGeometry.toolbarTarget, height: NotesGeometry.toolbarTarget)
            .contentShape(Rectangle())
    }

    private func markdownDerivedWorkDelay(forUTF8Bytes bytes: Int) -> Duration {
        bytes >= 5_000_000 ? .milliseconds(1_200)
            : bytes >= 1_000_000 ? .milliseconds(700)
            : bytes >= 250_000 ? .milliseconds(320)
            : .milliseconds(140)
    }

    private func switchReadingMode(to choice: ReadingMode) {
        guard model.selected != nil, model.previewPDF == nil, model.externalBody == nil else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84)) {
            mode = choice
        }
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

    private func beginNewFolder(in parent: URL) {
        guard let root = model.root else { return }
        let folder = parent.standardizedFileURL
        guard folder == root.standardizedFileURL || WorkspaceFiles.contains(folder, in: root) else { return }
        newFolderParent = folder
        newFolderValue = ""
        showingNewFolder = true
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

    private func findInCurrentFile() {
        // PDF owns its own native PDFKit match navigator and handles this event.
        if model.previewPDF != nil { return }
        guard model.selected != nil, model.externalBody == nil else {
            focusKnowledgeSearch()
            return
        }
        if showingMindMap { showingMindMap = false }
        if mode == .read { mode = .edit }
        Task { @MainActor in
            editorFocused = true
            // A mode change may mount TextEditor on the next render pass.
            await Task.yield()
            let window = NSApp.keyWindow ?? NSApp.mainWindow
            if let textView = markdownTextView(in: window?.contentView) {
                textView.usesFindBar = true
                window?.makeFirstResponder(textView)
                let action = NSMenuItem()
                action.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
                textView.performFindPanelAction(action)
            }
        }
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
        let ancestors = NoteTreePresentation.ancestorPaths(for: file, in: root)
        expandedFolderPaths.formUnion(ancestors)
        model.prioritizeExpandedPath(
            ancestors,
            toward: file.deletingLastPathComponent()
        )
        treeCursorPath = file.path
        treeFocused = true
        Task { @MainActor in
            await Task.yield()
            treeRevealRequest = file.path
        }
    }

    private func importAsEditableMindMap(_ url: URL) {
        guard let root = model.root, WorkspaceFiles.contains(url, in: root) else { return }
        let ext = url.pathExtension.lowercased()
        guard ["mindnode", "xmind"].contains(ext) else { return }
        do {
            let markdown: String
            let images: [MindNodePackage.ImportedImage]
            let pdfs: [MindNodePackage.ImportedPDF]
            if ext == "mindnode" {
                let imported = try MindNodePackage.importDocument(from: url)
                markdown = imported.markdown
                images = imported.images
                pdfs = imported.pdfs
            } else {
                let imported = try XMindPackage.importDocument(from: url)
                markdown = imported.markdown
                images = imported.images
                pdfs = []
            }
            let sourceName = url.deletingPathExtension().lastPathComponent
            guard let created = model.newNote(
                named: sourceName, in: url.deletingLastPathComponent(),
                initialContent: markdown, importedImages: images, importedPDFs: pdfs
            ) else { return }
            pendingMindMapOpen = created
            model.message = language.text("Imported editable content and supported attachments without altering the original map. Unsupported native formatting and connections remain in the source.")
        } catch {
            model.message = error.localizedDescription
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
        guard ProAccess.allows(.mindMap, unlocked: purchases.unlocked) else {
            showingProUpsell = true
            return
        }
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

    private func rebuildQuickOpenMatches() {
        let matches = NoteTreePresentation.quickOpen(quickOpenEntries, query: quickOpenQuery)
        if pdfCaptureRequest != nil || mindMapLinkNodeID != nil || linkRepairRequest != nil {
            quickOpenMatches = matches.filter { item in
                guard !item.isFolder else { return false }
                if linkRepairRequest != nil {
                    return item.isMarkdown || item.isPDF
                }
                guard item.isMarkdown else { return false }
                if mindMapLinkNodeID != nil, let selected = model.selected,
                   item.url.standardizedFileURL == selected.standardizedFileURL {
                    return false
                }
                return true
            }
        } else {
            quickOpenMatches = matches
        }
        quickOpenIndex = quickOpenMatches.isEmpty
            ? 0
            : min(quickOpenIndex, quickOpenMatches.count - 1)
        if quickOpenMatches.indices.contains(quickOpenIndex) {
            model.prefetchFile(quickOpenMatches[quickOpenIndex].url)
        }
    }

    private func requestGlobalQuickOpenIndexIfNeeded() {
        guard showingQuickOpen,
              !quickOpenQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.indexingFiles else { return }

        if !model.globalFileIndexReady {
            model.prepareGlobalFileIndex()
            return
        }

        // Keep the cached full-vault index fast for normal searches. A zero-result
        // query is the only signal that an external/iCloud mutation may have made
        // the snapshot stale, and each picker session gets at most one fallback scan.
        guard quickOpenMatches.isEmpty, !quickOpenFallbackRescanRequested else { return }
        quickOpenFallbackRescanRequested = true
        model.refreshGlobalFileIndex()
    }

    private func prepareQuickOpenPresentation() {
        quickOpenFallbackRescanRequested = false
        quickOpenEntries = model.globalFileIndexReady
            ? model.globalQuickOpenEntries
            : localQuickOpenEntries(model.files)
        rebuildQuickOpenMatches()
        // Opening the picker itself must not recurse through a large/iCloud vault.
        // Current/recent/local entries are ready immediately; the complete utility
        // scan begins only after a non-empty query expresses full-library intent.
        showingQuickOpen = true
    }

    private func resetMindMapLinkState() {
        mindMapLinkNodeID = nil
        mindMapLinkSectionMode = false
        mindMapSectionTarget = nil
        mindMapSectionHeadings = []
        loadingMindMapSectionHeadings = false
    }

    private func openQuickPicker() {
        pdfCaptureTask?.cancel()
        pdfCaptureTask = nil
        linkRepairRequest = nil
        pdfCaptureRequest = nil
        pdfCaptureCommentary = ""
        resetMindMapLinkState()
        quickOpenQuery = ""
        quickOpenIndex = 0
        prepareQuickOpenPresentation()
    }

    private func beginMindMapLink(nodeID: Int, section: Bool = false) {
        guard model.selected != nil else { return }
        pdfCaptureTask?.cancel()
        pdfCaptureTask = nil
        linkRepairRequest = nil
        pdfCaptureRequest = nil
        pdfCaptureCommentary = ""
        mindMapLinkNodeID = nodeID
        mindMapLinkSectionMode = section
        mindMapSectionTarget = nil
        mindMapSectionHeadings = []
        loadingMindMapSectionHeadings = false
        quickOpenQuery = ""
        quickOpenIndex = 0
        prepareQuickOpenPresentation()
    }

    private func beginPDFCapture(
        pdf: URL,
        page: Int,
        selectedText: String?,
        anchor: PDFSourceAnchor?
    ) {
        pdfCaptureTask?.cancel()
        pdfCaptureTask = nil
        linkRepairRequest = nil
        resetMindMapLinkState()
        let normalizedSelectedText = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectionWasUnanchored: Bool
        if let normalizedSelectedText, !normalizedSelectedText.isEmpty {
            selectionWasUnanchored = anchor.map {
                $0.page == page && $0.matches(text: normalizedSelectedText)
            } != true
        } else {
            selectionWasUnanchored = false
        }
        pdfCaptureRequest = PDFCaptureRequest(
            pdf: pdf,
            page: page,
            selectedText: normalizedSelectedText,
            anchor: selectionWasUnanchored ? nil : anchor,
            selectionWasUnanchored: selectionWasUnanchored
        )
        pdfCaptureCommentary = ""
        quickOpenQuery = ""
        quickOpenIndex = 0
        prepareQuickOpenPresentation()
    }

    private func beginLinkRepair(_ target: String) {
        guard let source = model.selected, model.externalBody == nil,
              model.previewPDF == nil else { return }
        pdfCaptureTask?.cancel()
        pdfCaptureTask = nil
        showingBacklinks = false
        resetMindMapLinkState()
        pdfCaptureRequest = nil
        model.message = nil
        linkRepairRequest = (source, target, model.draftRevision)
        // Prior filename only seeds search. The user selects the new authority.
        let path = String(target.split(separator: "#", maxSplits: 1).first ?? "")
        let decoded = path.removingPercentEncoding ?? path
        quickOpenQuery = URL(fileURLWithPath: decoded).deletingPathExtension().lastPathComponent
        quickOpenIndex = 0
        prepareQuickOpenPresentation()
    }

    private func closeQuickPicker() {
        pdfCaptureTask?.cancel()
        pdfCaptureTask = nil
        showingQuickOpen = false
        linkRepairRequest = nil
        quickOpenMatches = []
        quickOpenFallbackRescanRequested = false
        pdfCaptureRequest = nil
        pdfCaptureCommentary = ""
        resetMindMapLinkState()
    }

    private func savePDFCapture(to studyNote: URL) {
        guard pdfCaptureTask == nil, let capture = pdfCaptureRequest else { return }
        let commentary = pdfCaptureCommentary
        pdfCaptureTask = Task { @MainActor in
            let saved = await model.appendPDFReference(
                pdf: capture.pdf,
                page: capture.page,
                commentary: commentary,
                selectedText: capture.selectedText,
                anchor: capture.anchor,
                to: studyNote
            )
            // A cancelled picker or a newer capture must not let this task
            // clear the newer task or navigate after its request was replaced.
            guard pdfCaptureRequest?.id == capture.id else { return }
            pdfCaptureTask = nil
            guard !Task.isCancelled, saved else { return }

            closeQuickPicker()
            showingMindMap = false
            showingMindMapSourcePane = false
            // In narrow windows, show the citation in the note immediately.
            compactStudyShowsStudyPane = true
            pendingMarkdownReveal = MarkdownEditorRevealRequest(
                note: studyNote.standardizedFileURL,
                target: .end,
                keepsMindMapVisible: false
            )
            pendingEditorFocus = studyNote
            model.openStudyNote(studyNote)
            if model.selected == studyNote {
                pendingEditorFocus = nil
                mode = .edit
                Task { @MainActor in
                    await Task.yield()
                    applyPendingMarkdownReveal()
                }
            }
        }
    }

    private func openBacklinkLocation(
        _ backlink: NoteBacklink,
        location: NoteBacklinkLocation
    ) {
        let source = backlink.source.standardizedFileURL
        guard WorkspaceFiles.fileStamp(source) == backlink.sourceStamp,
              !(model.selected?.standardizedFileURL == source && model.isDirty) else {
            model.message = language.text("Link target not available in this workspace.")
            return
        }

        showingBacklinks = false
        pendingBacklinkNote = source
        pendingBacklinkLine = location.lineIndex
        pendingBacklinkStamp = backlink.sourceStamp
        if model.previewPDF != nil {
            model.openStudyNote(source)
        } else {
            model.openFile(source)
        }

        if model.selected?.standardizedFileURL != source, !model.loadingNote {
            pendingBacklinkNote = nil
            pendingBacklinkLine = nil
            pendingBacklinkStamp = nil
            return
        }

        if model.selected?.standardizedFileURL == source, !model.loadingNote {
            pendingBacklinkNote = nil
            pendingBacklinkLine = nil
            pendingBacklinkStamp = nil
            guard WorkspaceFiles.fileStamp(source) == backlink.sourceStamp else {
                model.message = language.text("Link target not available in this workspace.")
                return
            }
            revealMarkdownLineIndex(location.lineIndex)
        }
    }

    private func openQuickMatch(_ item: NoteItem) {
        // The cached full-vault index can outlive an external/iCloud rename.
        // Do not dismiss Quick Open or navigate to a vanished path; refresh
        // its one existing index, at most once per picker session.
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            if !quickOpenFallbackRescanRequested && !model.indexingFiles {
                quickOpenFallbackRescanRequested = true
                model.refreshGlobalFileIndex()
            }
            return
        }
        if let request = linkRepairRequest {
            // Never mutate a different document or a draft that changed while
            // the picker was open. Repair is a source-scoped user action.
            guard model.selected?.standardizedFileURL == request.source.standardizedFileURL,
                  model.draftRevision == request.revision,
                  !model.loadingNote else {
                closeQuickPicker()
                model.message = language.text("Note changed while choosing a replacement. Try again.")
                return
            }
            guard let root = model.root,
                  let canonicalTarget = WorkspaceFiles.canonicalLinkTarget(for: item.url, in: root)
            else {
                model.message = language.text("Link target not available in this workspace.")
                return
            }
            let oldPath = String(request.target.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first ?? "")
            let oldFragment = request.target.firstIndex(of: "#").map {
                String(request.target[$0...])
            } ?? ""
            let preservePDFFRagment = item.isPDF
                && URL(fileURLWithPath: oldPath).pathExtension.lowercased() == "pdf"
                && PDFPageReference.page(
                    from: URL(string: request.target) ?? URL(fileURLWithPath: request.target)
                ) != nil
            let newTarget = canonicalTarget + (preservePDFFRagment ? oldFragment : "")
            guard let updated = MindMapOutline.retargetLinks(
                    in: model.draft, from: request.target, to: newTarget
                  ) else {
                model.message = language.text("Link target not available in this workspace.")
                return
            }
            model.draft = updated
            closeQuickPicker()
            model.message = nil
            return
        }
        if let nodeID = mindMapLinkNodeID {
            if mindMapLinkSectionMode {
                prepareMindMapSectionTarget(nodeID: nodeID, target: item.url)
            } else {
                connectMindMapNode(nodeID, to: item.url)
            }
            return
        }
        if pdfCaptureRequest != nil {
            savePDFCapture(to: item.url)
            return
        }
        closeQuickPicker()
        model.openFile(item.url)
    }

    private func connectMindMapNode(_ nodeID: Int, to target: URL, heading: String? = nil) {
        guard let root = model.root,
              let selected = model.selected,
              target.standardizedFileURL != selected.standardizedFileURL
        else {
            model.message = AppLanguage.current.text("Link target not available in this workspace.")
            return
        }

        let wikiTarget: String?
        if let heading {
            wikiTarget = WorkspaceFiles.canonicalWikiTarget(for: target, in: root, heading: heading)
        } else {
            wikiTarget = WorkspaceFiles.canonicalWikiTarget(for: target, in: root)
        }
        let noteName = target.deletingPathExtension().lastPathComponent
        let label = heading.map { "\(noteName) · \($0)" } ?? noteName
        guard let wikiTarget,
              let updated = MindMapOutline.appendWikiLink(
                in: model.draft,
                nodeID: nodeID,
                target: wikiTarget,
                label: label
              )
        else {
            model.message = AppLanguage.current.text("Link target not available in this workspace.")
            return
        }

        model.draft = updated
        mindMapSelectionLine = nodeID
        closeQuickPicker()
        model.message = nil
    }

    private func createLinkedNoteFromMindMap(nodeID: Int) {
        guard let root = model.root,
              let sourceNote = model.selected?.standardizedFileURL,
              sourceNote.pathExtension.lowercased() == "md"
                || sourceNote.pathExtension.lowercased() == "markdown"
        else {
            model.message = language.text("Could not create a linked note from this node.")
            return
        }

        if model.isDirty {
            model.save()
            guard !model.isDirty else { return }
        }

        guard let node = MindMapOutline.nodes(in: model.draft).first(where: { $0.id == nodeID }) else {
            model.message = language.text("Could not create a linked note from this node.")
            return
        }
        let title = MindMapOutline.presentation(for: node.title).title
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = sourceNote.deletingLastPathComponent()
        guard !title.isEmpty,
              let filename = WorkspaceFiles.nextAvailableNoteName(basedOn: title, in: folder)
        else {
            model.message = language.text("Could not create a linked note from this node.")
            return
        }

        let target = folder.appendingPathComponent(filename).standardizedFileURL
        guard let wikiTarget = WorkspaceFiles.canonicalWikiTarget(for: target, in: root),
              let updated = MindMapOutline.appendWikiLink(
                in: model.draft,
                nodeID: nodeID,
                target: wikiTarget,
                label: title
              )
        else {
            model.message = language.text("Could not create a linked note from this node.")
            return
        }

        let linkedNoteContent = "# \(title)\n\n"
        guard let created = model.newNote(
            named: filename,
            in: folder,
            initialContent: linkedNoteContent,
            activateAfterCreation: false
        ) else { return }

        let sourceBeforeLink = model.draft
        model.draft = updated
        model.save()
        mindMapSelectionLine = nodeID
        guard !model.isDirty else {
            let rolledBack = model.rollbackNewNoteIfUnchanged(
                created,
                expectedContent: linkedNoteContent
            )
            model.draft = sourceBeforeLink
            model.message = rolledBack
                ? language.text("Could not save the link, so the new note was not kept.")
                : language.text("Could not save the link. The new note changed before rollback; review both notes.")
            return
        }
        model.message = "\(language.text("Created linked note")): \(created.deletingPathExtension().lastPathComponent)"
    }

    private func prepareMindMapSectionTarget(nodeID: Int, target: URL) {
        guard let root = model.root else { return }
        let expectedTarget = target.standardizedFileURL
        mindMapSectionTarget = expectedTarget
        mindMapSectionHeadings = []
        loadingMindMapSectionHeadings = true
        quickOpenFocused = false

        Task { @MainActor in
            let headings = await Task.detached(priority: .userInitiated) {
                WorkspaceFiles.linkableMarkdownHeadings(at: expectedTarget, in: root)
            }.value
            guard mindMapLinkNodeID == nodeID,
                  mindMapLinkSectionMode,
                  mindMapSectionTarget?.standardizedFileURL == expectedTarget else { return }

            loadingMindMapSectionHeadings = false
            guard let headings else {
                model.message = language.text("Could not read headings from this note.")
                return
            }
            model.message = nil
            mindMapSectionHeadings = headings
        }
    }

    private func backToMindMapLinkTargetPicker() {
        mindMapSectionTarget = nil
        mindMapSectionHeadings = []
        loadingMindMapSectionHeadings = false
        quickOpenQuery = ""
        quickOpenIndex = 0
        rebuildQuickOpenMatches()
        Task { @MainActor in
            await Task.yield()
            quickOpenFocused = true
        }
    }

    private func createNoteFromPDFCapture() {
        guard pdfCaptureTask == nil,
              let capture = pdfCaptureRequest,
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

    @ViewBuilder
    private var quickOpenSheet: some View {
        if let target = mindMapSectionTarget, let nodeID = mindMapLinkNodeID {
            mindMapSectionPicker(nodeID: nodeID, target: target)
        } else {
            quickOpenFilePicker
        }
    }

    private var quickOpenFilePicker: some View {
        let matches = quickOpenMatches
        let selectedPreview = pdfCapturePreviewText
        let linkingMindMapNode = mindMapLinkNodeID != nil
        let markdownOnly = pdfCaptureRequest != nil || linkingMindMapNode
        return VStack(alignment: .leading, spacing: 0) {
            if linkRepairRequest != nil {
                Label(language.text("Choose replacement file"), systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            }
            if linkingMindMapNode {
                Label(
                    language.text(mindMapLinkSectionMode
                                  ? "Link selected node to section"
                                  : "Link selected node to note"),
                    systemImage: "link.badge.plus"
                )
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            }
            if let capture = pdfCaptureRequest {
                HStack(spacing: 10) {
                    Label(
                        "\(language.text("Add PDF page to note")) · \(capture.page)",
                        systemImage: "note.text.badge.plus"
                    )
                    .font(.subheadline.weight(.semibold))
                    if pdfCaptureTask != nil {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(language.text("Saving"))
                            .accessibilityIdentifier("pks-pdf-capture-saving")
                    }
                    Spacer()
                    if let studyNote = model.selected, model.externalBody == nil {
                        Button(language.text("Add to Study Note")) {
                            savePDFCapture(to: studyNote)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help(studyNote.deletingPathExtension().lastPathComponent)
                        .disabled(pdfCaptureTask != nil)
                        .accessibilityIdentifier("pks-pdf-capture-current-note")
                    }
                    Button(language.text("New note from this page")) {
                        createNoteFromPDFCapture()
                    }
                    .buttonStyle(.borderless)
                    .disabled(pdfCaptureTask != nil)
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

                if pdfCaptureRequest?.selectionWasUnanchored == true {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(language.text("This PDF selection cannot be linked precisely. The quote will still be saved with a page-only link to its first page. Select a smaller passage on one page to enable precise highlighting."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("pks-pdf-capture-selection-warning")
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
                .disabled(pdfCaptureTask != nil)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: NotesGeometry.symbolSize, weight: .medium))
                    .frame(width: NotesGeometry.treeIconWidth)
                    .foregroundStyle(.secondary)
                TextField(
                    language.text(markdownOnly ? "Search Markdown notes…" : "Search files…"),
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
                        if matches.indices.contains(quickOpenIndex) {
                            model.prefetchFile(matches[quickOpenIndex].url)
                        }
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        quickOpenIndex = max(0, quickOpenIndex - 1)
                        if matches.indices.contains(quickOpenIndex) {
                            model.prefetchFile(matches[quickOpenIndex].url)
                        }
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
                .disabled(pdfCaptureTask != nil)
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
                            linkingMindMapNode
                                ? (quickOpenQuery.isEmpty
                                   ? (mindMapLinkSectionMode
                                      ? "Choose a Markdown note to link a section."
                                      : "Choose a Markdown note to link this node.")
                                   : "No Markdown notes match your search.")
                                : (pdfCaptureRequest != nil
                                   ? (quickOpenQuery.isEmpty
                                      ? "Choose a Markdown note for this PDF page."
                                      : "No Markdown notes match your search.")
                                   : (linkRepairRequest != nil
                                      ? (quickOpenQuery.isEmpty
                                         ? "Choose a replacement Markdown or PDF file."
                                         : "No Markdown or PDF files match your search.")
                                      : (quickOpenQuery.isEmpty
                                         ? "Type a name to find a note in your library."
                                         : "No files match your search.")))
                        ))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
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
                                .disabled(pdfCaptureTask != nil)
                                .onHover { hovering in
                                    if hovering {
                                        quickOpenIndex = i
                                        model.prefetchFile(item.url)
                                    }
                                }
                                .id(i)
                                .accessibilityIdentifier("pks-quick-open-\(item.id)")
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: quickOpenIndex) { _, index in
                        guard matches.indices.contains(index) else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(
            width: 560,
            height: min(
                620,
                (matches.isEmpty ? 176 : min(470, max(238, CGFloat(matches.count) * 54 + 83)))
                    + (pdfCaptureRequest == nil ? 0 : (selectedPreview == nil ? 104 : 148))
                    + (linkingMindMapNode ? 44 : 0)
            )
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: matches.isEmpty)
        .onChange(of: quickOpenQuery) { _, _ in quickOpenIndex = 0 }
        .onAppear {
            if pdfCaptureRequest != nil {
                pdfCaptureCommentaryFocused = true
            } else {
                quickOpenFocused = true
            }
        }
    }

    private func mindMapSectionPicker(nodeID: Int, target: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    backToMindMapLinkTargetPicker()
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: NotesGeometry.toolbarTarget, height: NotesGeometry.toolbarTarget)
                }
                .buttonStyle(.plain)
                .help(language.text("Back"))

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("Link Section"))
                        .font(.subheadline.weight(.semibold))
                    Text(target.deletingPathExtension().lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    closeQuickPicker()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: NotesGeometry.toolbarTarget, height: NotesGeometry.toolbarTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.45)

            if loadingMindMapSectionHeadings {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(language.text("Reading headings…"))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if mindMapSectionHeadings.isEmpty {
                VStack(spacing: 12) {
                    Text(language.text("This note has no unique headings to link."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(language.text("Link Whole Note Instead")) {
                        connectMindMapNode(nodeID, to: target)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(mindMapSectionHeadings) { heading in
                            Button {
                                connectMindMapNode(nodeID, to: target, heading: heading.title)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "number")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: NotesGeometry.treeIconWidth)
                                    Text(heading.title)
                                        .font(.system(size: 14))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("H\(heading.level)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.leading, CGFloat(max(0, heading.level - 1)) * 10)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pks-mind-map-section-\(heading.id)")
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(
            width: 560,
            height: min(560, max(230, CGFloat(max(1, mindMapSectionHeadings.count)) * 44 + 92))
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func fileTreeRow(_ row: NoteTreePresentation.Row) -> some View {
                        let isSelected = model.selected == row.item.url || model.previewPDF == row.item.url
                        return Group {
                            if !row.item.isFolder {
                                fileTreeDocumentRow(row, isSelected: isSelected)
                            } else {
                                HStack(spacing: 0) {
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

                            if model.fileOperationInProgress?.standardizedFileURL == row.item.url.standardizedFileURL {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: NotesGeometry.treeIconWidth,
                                           height: NotesGeometry.treeRowHeight)
                                    .accessibilityLabel(language.text("Updating files…"))
                            } else if model.loadingNote && model.requestedNote?.standardizedFileURL == row.item.url.standardizedFileURL {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: NotesGeometry.treeIconWidth,
                                           height: NotesGeometry.treeRowHeight)
                                    .accessibilityLabel(language.text("Opening note…"))
                            } else {
                                Group {
                                    if row.item.isFolder {
                                        Image(systemName: row.item.iconName)
                                            .font(.system(size: NotesGeometry.symbolSize))
                                            .symbolRenderingMode(.hierarchical)
                                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                    } else {
                                        Image(systemName: row.item.iconName)
                                            .font(.system(size: NotesGeometry.symbolSize))
                                            .symbolRenderingMode(.hierarchical)
                                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                            .draggable(row.item.url)
                                            }
                                }
                                .frame(width: NotesGeometry.treeIconWidth,
                                       height: NotesGeometry.treeRowHeight)
                            }

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
                                        guard model.fileOperationInProgress == nil,
                                              let source = urls.first?.standardizedFileURL,
                                              model.canManage(source),
                                              source != row.item.url else { return false }
                                        Task { @MainActor in
                                            let moved = await model.moveItem(source, to: row.item.url)
                                            if moved != nil {
                                                expandedFolderPaths.insert(row.item.url.path)
                                            }
                                            fileDropTargetPath = nil
                                        }
                                        return true
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
                                Button {
                                    treeCursorPath = row.id
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
                        .onHover { hovering in
                            if hovering && (row.item.isMarkdown || row.item.isPDF) { model.prefetchFile(row.item.url) }
                        }
                        .help(row.item.url.path)
                        .id(row.id)
                        .accessibilityIdentifier(row.item.isFolder ? "pks-folder-\(row.item.name)" : row.item.id)
    }

    private func fileTreeDocumentRow(_ row: NoteTreePresentation.Row, isSelected: Bool) -> some View {
        Button {
            treeCursorPath = row.id
            treeFocused = true
            model.openFile(row.item.url)
        } label: {
            HStack(spacing: 0) {
                Color.clear.frame(width: NotesGeometry.disclosureWidth,
                                  height: NotesGeometry.treeRowHeight)
                if model.fileOperationInProgress?.standardizedFileURL == row.item.url.standardizedFileURL {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: NotesGeometry.treeIconWidth,
                               height: NotesGeometry.treeRowHeight)
                        .accessibilityLabel(language.text("Updating files…"))
                } else if model.loadingNote && model.requestedNote?.standardizedFileURL == row.item.url.standardizedFileURL {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: NotesGeometry.treeIconWidth,
                               height: NotesGeometry.treeRowHeight)
                        .accessibilityLabel(language.text("Opening note…"))
                } else {
                    Image(systemName: row.item.iconName)
                        .font(.system(size: NotesGeometry.symbolSize))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(width: NotesGeometry.treeIconWidth,
                               height: NotesGeometry.treeRowHeight)
                }
                Text(row.item.name)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .frame(height: NotesGeometry.treeRowHeight)
                    .padding(.leading, NotesGeometry.treeTextGap)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(row.item.url)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("pks-note-\(row.item.name)")
    }

    @ViewBuilder
    private var searchResultRows: some View {
                if !model.hits.isEmpty {
                    Section(language.text("Search results")) {
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
                } else if model.searching {
                    Text(language.text("Searching…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.searchFailed {
                    Text(language.text("Library search unavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(language.text("Enter a name or words from a note."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(language.text("No matching files or notes."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
    }

    // The icon rail and file/search surface share one continuous native material;
    // selection is expressed on each control rather than a floating rail container.
    private var sidebar: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(spacing: 5) {
                    railButton(.notes, symbol: "square.stack", title: language.text("All Notes"))
                    railButton(.recent, symbol: "clock", title: language.text("Recent"))
                    railButton(.favorites, symbol: "star", title: language.text("Favorites"))
                    railButton(.search, symbol: "magnifyingglass", title: language.text("Search"))
                }
                .padding(.horizontal, 5)
                // Align the first navigation control with the adjacent title row.
                .padding(.top, 11)
                .padding(.bottom, 7)

                Spacer(minLength: 12)
                Button(action: openQuickPicker) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 16))
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(language.text("Quick Open a file in the current library") + " (⌘P)")
                .accessibilityIdentifier("pks-sidebar-quick-open")
                .padding(.bottom, 15)
            }
            .frame(width: 66)
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(language.text(sidebarTab == .notes ? "All Notes" :
                                       sidebarTab == .recent ? "Recent" :
                                       sidebarTab == .favorites ? "Favorites" : "Search"))
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.25)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        beginNewNote()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(language.text("New Markdown note (⌘N)"))
                    .accessibilityIdentifier("pks-new-note-button")
                }
                .padding(.leading, 17)
                .padding(.trailing, 13)
                .frame(height: 61)

                HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField(language.text("Search notes and files…"), text: $model.query)
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
                    Text("⌘⇧F")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 33)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.035),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 5)
            .padding(.bottom, 9)

            if sidebarTab == .notes {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 17)
                        .foregroundStyle(.secondary)
                    Text(NotesGeometry.workspaceTitle(model.root, language: language))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if model.loadingFiles {
                        ProgressView().controlSize(.mini)
                    }
                    Menu {
                        if let root = model.root {
                            Button(language.text("New Folder…"), systemImage: "folder.badge.plus") {
                                beginNewFolder(in: root)
                            }
                            Divider()
                        }
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
                            .frame(width: 25, height: 25)
                    }
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .foregroundStyle(.secondary)
                    .help(language.text("Current library folder"))
                    .accessibilityIdentifier("pks-workspace-menu")
                }
                .padding(.leading, 22)
                .padding(.trailing, 12)
                .frame(height: 34)
                .padding(.bottom, 4)
            } else if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(model.searchStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 22)
                    .frame(height: 31)
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
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        proxy.scrollTo(path, anchor: .center)
                    }
                    treeRevealRequest = nil
                }
                .focusable(sidebarTab == .notes)
                // The row highlight already conveys keyboard focus. Avoid
                // a second large blue rectangle around the entire file tree.
                .focusEffectDisabled()
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
                        if let item = rows.first(where: { $0.id == next.path })?.item,
                           item.isMarkdown || item.isPDF {
                            model.prefetchFile(item.url)
                        }
                        // Scroll after folder expansion yields its visible rows.
                        Task { @MainActor in
                            await Task.yield()
                            treeRevealRequest = next.path
                        }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(NotesGeometry.workbenchColor)
    }

    private func railButton(_ tab: SidebarTab, symbol: String, title: String) -> some View {
        let selected = sidebarTab == tab
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { sidebarTab = tab }
        } label: {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: NotesGeometry.railSymbolSize, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 40, height: 40)
                .background(
                    selected
                        ? Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.085)
                        : (hoveredRailTab == tab ? Color.primary.opacity(0.045) : .clear),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredRailTab = tab
            } else if hoveredRailTab == tab {
                hoveredRailTab = nil
            }
        }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("pks-sidebar-\(tab.rawValue.lowercased())")
    }

    private func toggleFolder(_ url: URL) {
        if expandedFolderPaths.insert(url.path).inserted {
            model.loadExpandedFolder(url)
        } else {
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
        if ["mindnode", "xmind"].contains(url.pathExtension.lowercased()) {
            Button(language.text("Import as Editable Mind Map"),
                   systemImage: "point.3.connected.trianglepath.dotted") {
                importAsEditableMindMap(url)
            }
        }
        Button(language.text("Show in Finder"), systemImage: "folder") {
            model.revealInFinder(url)
        }
        Button(language.text("Open with Default App"), systemImage: "arrow.up.right.square") {
            model.openInDefaultApp(url)
        }
        Button(language.text("Copy File Path"), systemImage: "doc.on.doc") {
            model.copySource(url.path)
        }
        if model.selected == url, model.isDirty {
            Button(language.text("Save Draft Copy"), systemImage: "doc.badge.plus") {
                model.saveDraftCopy()
            }
            .accessibilityIdentifier("pks-save-draft-copy")
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
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                && !WorkspaceFiles.isOpaqueDocumentPackage(url) {
                Button(language.text("New Folder…"), systemImage: "folder.badge.plus") {
                    beginNewFolder(in: url)
                }
            }
            Button(language.text("Rename…"), systemImage: "pencil") {
                beginRename(url)
            }
            .disabled(model.fileOperationInProgress != nil)
            Button(language.text("Move to Folder…"), systemImage: "folder.badge.gearshape") {
                chooseDestination(for: url, copying: false)
            }
            .disabled(model.fileOperationInProgress != nil)
            Button(language.text("Copy to Folder…"), systemImage: "doc.on.doc") {
                chooseDestination(for: url, copying: true)
            }
            .disabled(model.fileOperationInProgress != nil)
            Button(role: .destructive) {
                requestMoveToTrash(url)
            } label: {
                Label(language.text("Move to Trash"), systemImage: "trash")
            }
            .disabled(model.fileOperationInProgress != nil)
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
        guard model.fileOperationInProgress == nil else {
            model.message = language.text("Another file operation is still in progress.")
            return
        }
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
        Task { @MainActor in
            if copying {
                _ = await model.copyItem(item, to: folder)
            } else {
                _ = await model.moveItem(item, to: folder)
            }
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

    @MainActor
    private func handleMarkdownDrop(_ providers: [NSItemProvider]) -> Bool {
        let dropScreenPoint = NSEvent.mouseLocation
        let typeIdentifier = PDFCitationPasteboard.type.rawValue
        let citationProvider = providers.first {
            $0.hasItemConformingToTypeIdentifier(typeIdentifier)
        }
        let fileProvider = citationProvider == nil
            ? providers.first { $0.canLoadObject(ofClass: NSURL.self) } : nil
        guard citationProvider != nil || fileProvider != nil,
              let note = model.selected,
              model.externalBody == nil,
              !model.loadingNote,
              let window = PDFCitationDropTarget.window(
                at: dropScreenPoint,
                in: NSApp.orderedWindows
              ),
              let textView = PDFCitationDropTarget.editableTextView(
                at: dropScreenPoint,
                in: window
              ),
              let target = PDFCitationDropTarget(
                screenPoint: dropScreenPoint,
                note: note,
                draftRevision: model.draftRevision,
                textView: textView
              ) else { return false }

        // Snapshot editor, note revision and insertion caret before asynchronous
        // provider loading. Never insert into a different note or stale draft.
        if let citationProvider {
            citationProvider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                guard let citation = PDFCitationPasteboard.markdown(from: item) else {
                    Task { @MainActor in
                        model.message = language.text(
                            "Could not read the PDF citation. Try dragging the selection again."
                        )
                    }
                    return
                }
                Task { @MainActor in
                    let canEdit = model.externalBody == nil
                        && !model.loadingNote
                        && !showingMindMap
                        && mode != .read
                    guard canEdit else {
                        model.message = language.text(
                            "Return to the Markdown editor in Edit mode to insert the PDF citation."
                        )
                        return
                    }
                    guard target.insert(
                        citation, currentNote: model.selected,
                        currentDraftRevision: model.draftRevision, canEdit: true
                    ) else {
                        model.message = language.text(
                            "The note or editor changed before the citation was inserted. Drag the PDF selection again."
                        )
                        return
                    }
                }
            }
        } else if let fileProvider {
            fileProvider.loadObject(ofClass: NSURL.self) { item, _ in
                guard let file = item as? URL else {
                    Task { @MainActor in
                        model.message = language.text(
                            "Could not read the dropped file. Try dropping it again."
                        )
                    }
                    return
                }
                Task { @MainActor in
                    guard let root = model.root,
                          let link = WorkspaceFiles.markdownLinkForDrop(for: file, in: root) else {
                        model.message = language.text("Link target not available in this workspace.")
                        return
                    }
                    let canEdit = model.externalBody == nil
                        && !model.loadingNote
                        && !showingMindMap
                        && mode != .read
                    guard canEdit else {
                        model.message = language.text(
                            "Return to the Markdown editor in Edit mode to insert the file link."
                        )
                        return
                    }
                    guard target.insert(
                        link, currentNote: model.selected,
                        currentDraftRevision: model.draftRevision, canEdit: true,
                        asFileLink: true
                    ) else {
                        model.message = language.text(
                            "The note or editor changed before the file link was inserted. Drop the file again."
                        )
                        return
                    }
                }
            }
        }
        return true
    }

    /// A newly mounted/reloaded TextEditor must not inherit undo operations
    /// recorded while its visible string represented another draft/view state.
    private func resetNativeEditorUndoBaseline() {
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(60))
            markdownTextView(in: NSApp.keyWindow?.contentView)?.undoManager?.removeAllActions()
        }
    }

    private func insertPDFCitationAtCursor() {
        guard let pdf = model.previewPDF, let root = model.root,
              model.selected != nil, model.externalBody == nil, !model.loadingNote,
              !showingMindMap, mode == .edit,
              loadedPDFURL?.standardizedFileURL == pdf.standardizedFileURL else {
            model.message = language.text("Open the study note in Edit mode first.")
            return
        }
        guard let textView = MarkdownNativeCommand.activeTextView(),
              textView.string == model.draft,
              let citation = pdfReaderController.selectedCitationForDrag(pdf: pdf, root: root) else {
            model.message = language.text("Select PDF text and place the note cursor without selecting text.")
            return
        }
        guard PDFCitationDropTarget.insertAtCaret(citation, in: textView) else {
            model.message = language.text("Select PDF text and place the note cursor without selecting text.")
            return
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
        insertClipboardImage(into: textView)
    }

    private func pasteImageFromClipboard() {
        guard model.selected != nil,
              model.externalBody == nil,
              let textView = markdownTextView(in: NSApp.keyWindow?.contentView) else { return }

        let pasteboard = NSPasteboard.general
        let hasImage = pasteboard.data(forType: .png) != nil
            || pasteboard.data(forType: .tiff) != nil
            || NSImage(pasteboard: pasteboard) != nil
        guard hasImage else {
            model.message = language.text("Copy an image to the clipboard first.")
            return
        }
        insertClipboardImage(into: textView)
    }

    private func chooseImageFile() {
        guard model.selected != nil,
              model.externalBody == nil,
              let window = NSApp.keyWindow,
              let textView = markdownTextView(in: window.contentView),
              !textView.hasMarkedText() else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = language.text("Insert")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let markdown = model.importImage(from: url) else {
            model.message = language.text("Could not import the selected image into this notes workspace.")
            return
        }
        window.makeFirstResponder(textView)
        editorFocused = true
        _ = MarkdownNativeCommand.replaceSelection(markdown, in: textView)
    }

    private func insertClipboardImage(into textView: NSTextView) {
        // Image insertion is also a Markdown mutation; leave active IME composition intact.
        guard !textView.hasMarkedText() else { return }
        guard let markdown = model.importClipboardImage() else {
            model.message = language.text("Could not save the pasted image inside this notes workspace.")
            return
        }
        textView.window?.makeFirstResponder(textView)
        editorFocused = true
        _ = MarkdownNativeCommand.replaceSelection(markdown, in: textView)
    }

    private func jumpToOutlineHeading(_ heading: MarkdownOutlineHeading) {
        guard MarkdownOutline.currentUTF16Offset(for: heading, in: model.draft) != nil else {
            showingOutline = false
            outlineHeadings = []
            return
        }
        showingMindMap = false
        mode = .edit
        Task { @MainActor in
            editorFocused = true
            // A read-only preview must first mount the native TextEditor before
            // its NSTextView can become first responder.
            try? await Task.sleep(for: .milliseconds(40))
            guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
                  let location = MarkdownOutline.currentUTF16Offset(
                    for: heading, in: textView.string
                  ) else {
                showingOutline = false
                outlineHeadings = []
                return
            }
            let range = NSRange(
                location: min(max(0, location), (textView.string as NSString).length),
                length: 0
            )
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
                .onHover { hovering in
                    if hovering { model.prefetchFile(note) }
                }
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
                    Text(title)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }


    private var relationshipsPanel: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(language.text("Relationships")).font(.headline)
                    Spacer()
                    Button {
                        showingBacklinks = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(language.text("Close"))
                    if model.loadingBacklinks || model.loadingRelated {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if model.previewPDF == nil {
                    relationshipSectionTitle(language.text("Outgoing"))
                    if outgoingLinks.isEmpty {
                        relationshipEmpty(language.text("No links from this note."))
                    } else {
                        ForEach(Array(outgoingLinks.enumerated()), id: \.offset) { _, link in
                            relationshipButton(
                                title: MindMapOutline.displayMarkdownLinkLabel(link.label),
                                detail: link.target,
                                symbol: "arrow.up.right"
                            ) {
                                showingBacklinks = false
                                _ = model.openKnowledgeLink(
                                    link.target,
                                    onUnresolved: { beginLinkRepair(link.target) }
                                )
                            }
                            .contextMenu {
                                Button(language.text("Change link target…")) {
                                    beginLinkRepair(link.target)
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 10)
                }

                relationshipSectionTitle(language.text(model.previewPDF == nil
                                                      ? "Backlinks"
                                                      : "Linked Notes"))
                if model.loadingBacklinks {
                    relationshipEmpty(language.text(model.previewPDF == nil
                                                    ? "Finding notes that link here…"
                                                    : "Finding notes linked to this PDF…"))
                } else if model.backlinks.isEmpty {
                    relationshipEmpty(language.text(model.backlinkSkippedCloudFiles > 0
                                                    ? "No local backlinks found yet."
                                                    : (model.previewPDF == nil
                                                        ? "No backlinks in this workspace."
                                                        : "No notes link to this PDF yet.")))
                } else {
                    ForEach(model.backlinks) { backlink in
                        ForEach(backlink.locations) { location in
                            let lineLabel = location.count > 1
                                ? "L\(location.lineIndex + 1) · \(location.count) \(language.text("references"))"
                                : "L\(location.lineIndex + 1)"
                            let detail = location.context.isEmpty
                                ? lineLabel
                                : "\(lineLabel) · \(location.context)"
                            relationshipButton(
                                title: backlink.title,
                                detail: detail,
                                symbol: "arrow.turn.up.left"
                            ) {
                                openBacklinkLocation(backlink, location: location)
                            }
                        }
                    }
                }
                if model.backlinkSkippedCloudFiles > 0 {
                    relationshipEmpty(String(
                        format: language.text("Cloud-only notes skipped: %d"),
                        model.backlinkSkippedCloudFiles
                    ))
                    Button(language.text("Check up to 6 more cloud notes")) {
                        model.loadMoreCloudBacklinks()
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.loadingBacklinks)
                    .help(language.text("Download a small batch only when requested."))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }

                if model.previewPDF == nil {
                    Color.clear.frame(height: 10)
                    relationshipSectionTitle(language.text("Related knowledge"))
                    if model.loadingRelated {
                        relationshipEmpty(language.text("Finding related knowledge…"))
                    } else if let error = model.relatedError {
                        relationshipEmpty(language.text(error))
                    } else if model.relatedHits.isEmpty {
                        relationshipEmpty(language.text("No related results."))
                    } else {
                        ForEach(model.relatedHits) { hit in
                            relationshipButton(
                                title: hit.title,
                                detail: hit.snippet.flatMap { $0.isEmpty ? nil : $0 }
                                    ?? language.text(hit.sourceLabel),
                                symbol: "text.magnifyingglass"
                            ) {
                                showingBacklinks = false
                                model.openResult(hit)
                        }
                    }
                }
            }
        }
        }
        .scrollIndicators(.visible)
        .accessibilityIdentifier("pks-relationships-scroll")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var auxiliaryListPanel: some View {
        Group {
            if showingOutline {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(language.text("Document Outline"))
                            .font(.headline)
                        Spacer()
                        Button {
                            showingOutline = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(language.text("Close"))
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(outlineHeadings) { heading in
                                Button {
                                    jumpToOutlineHeading(heading)
                                    if auxiliaryListPresentation == "sheet" { showingOutline = false }
                                } label: {
                                    Text(heading.title)
                                        .font(.system(size: 13))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 9)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("pks-outline-heading-\(heading.id)")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 18)
                    }
                    .accessibilityIdentifier("pks-outline-list")
                }
            } else if showingBacklinks {
                relationshipsPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .accessibilityIdentifier("pks-auxiliary-list-panel")
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
                // A small reading desk rather than an empty dashboard or a promotional card.
                VStack(alignment: .leading, spacing: 0) {
                    Text("Leafspan")
                        .font(.system(size: 40, weight: .regular, design: .serif))
                        .tracking(-1.1)
                        .foregroundStyle(.primary)
                        .padding(.bottom, 32)

                    if model.root == nil {
                        Text(language.text("Open a notes folder"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 16)
                        Button(language.text("Choose Folder")) { model.chooseWorkspace() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        HStack {
                            Text(language.text("Recent"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                beginNewNote()
                            } label: {
                                Label(language.text("New Note"), systemImage: "square.and.pencil")
                                    .font(.system(size: 11.5))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 12)

                        if model.recentNotes.isEmpty {
                            Button {
                                beginNewNote()
                            } label: {
                                Label(language.text("New Note"), systemImage: "square.and.pencil")
                                    .font(.system(size: 13))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                        } else {
                            ForEach(Array(model.recentNotes.prefix(6)), id: \.path) { note in
                                Button {
                                    model.openFile(note)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.text")
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18)
                                        Text(note.deletingPathExtension().lastPathComponent)
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 11)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("pks-welcome-recent-\(note.lastPathComponent)")
                            }
                        }
                    }
                }
                .frame(maxWidth: 570, alignment: .leading)
                .padding(.horizontal, 54)
                .padding(.top, 82)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                reader
            }
            if let message = model.message {
                HStack(spacing: 9) {
                    Image(systemName: "info.circle")
                    Text(message).font(.caption).lineLimit(2)
                    Spacer()
                    if model.isDirty {
                        Button(language.text("Save Draft Copy")) { model.saveDraftCopy() }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("pks-recover-draft")
                    }
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
                         ?? "Leafspan")
    }

    @ViewBuilder
    private var reader: some View {
        if let url = model.previewPDF {
            if let note = model.selected, model.externalBody == nil {
                // Never squeeze a PDF into a thin third column beside the sidebar.
                // Small windows show one full-width surface; larger windows provide
                // a balanced, user-resizable PDF + note workspace.
                GeometryReader { geometry in
                    let splitThreshold = NotesGeometry.studySplitThreshold(showingMindMap: showingMindMap)
                    let secondaryMinimumWidth: CGFloat = showingMindMap ? 460 : 340
                    if geometry.size.width >= splitThreshold {
                        HSplitView {
                            pdfReader(url)
                                .frame(minWidth: 420, idealWidth: geometry.size.width * (showingMindMap ? 0.50 : 0.55))
                            studyNotePane(note)
                                .frame(minWidth: secondaryMinimumWidth, idealWidth: geometry.size.width * (showingMindMap ? 0.50 : 0.45))
                        }
                    } else {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Picker("", selection: $compactStudyShowsStudyPane) {
                                    Text("PDF").tag(false)
                                    Text(language.text(showingMindMap ? "Mind Map" : "Study Note")).tag(true)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 224)
                                .accessibilityIdentifier("pks-study-compact-picker")
                                Spacer(minLength: 0)
                                Text(compactStudyShowsStudyPane
                                     ? note.deletingPathExtension().lastPathComponent
                                     : url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.025))

                            if compactStudyShowsStudyPane {
                                studyNotePane(note)
                            } else {
                                pdfReader(url)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("pks-study-workspace")
            } else {
                pdfReader(url)
            }
        } else if showingMindMap
                    && ProAccess.allows(.mindMap, unlocked: purchases.unlocked)
                    && model.selected != nil && model.externalBody == nil {
            HSplitView {
                mindMapCanvas
                    .frame(
                        minWidth: showingMindMapSourcePane ? 280 : 0,
                        idealWidth: showingMindMapSourcePane ? 480 : 900
                    )
                if showingMindMapSourcePane {
                    editor
                        .frame(minWidth: 300, idealWidth: 420)
                }
            }
            .accessibilityIdentifier(
                showingMindMapSourcePane
                    ? "pks-mind-map-source-workspace"
                    : "pks-mind-map-workspace"
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

    private var mindMapCanvas: some View {
        let sourceNote = model.selected?.standardizedFileURL
        return MindMapCanvas(
            source: $model.draft,
            selectedID: $mindMapSelectionLine,
            revision: model.draftRevision,
            validateSource: { expectedRevision, expectedSource in
                guard let sourceNote else { return false }
                return model.selected?.standardizedFileURL == sourceNote
                    && model.draftRevision == expectedRevision
                    && model.draft == expectedSource
                    && !model.loadingNote
                    && model.externalBody == nil
            },
            hidesNodeDetails: showingMindMapSourcePane,
            activeMarkdownTextView: { markdownTextView(in: NSApp.keyWindow?.contentView) },
            openLink: { target in
                _ = model.openKnowledgeLink(
                    target,
                    onUnresolved: { beginLinkRepair(target) }
                )
            },
            connectNote: { nodeID in beginMindMapLink(nodeID: nodeID) },
            connectSection: { nodeID in beginMindMapLink(nodeID: nodeID, section: true) },
            createLinkedNote: { nodeID in createLinkedNoteFromMindMap(nodeID: nodeID) },
            revealSource: { line in revealMarkdownLine(line) },
            importOutline: { markdown, name, images, pdfs in
                // Import into a new note rather than overwriting the active note.
                guard model.newNote(named: name, initialContent: markdown,
                                    importedImages: images, importedPDFs: pdfs) != nil else {
                    return false
                }
                showingMindMap = true
                compactStudyShowsStudyPane = true
                return true
            }
        )
        .id(model.selected?.standardizedFileURL.path ?? "")
    }

    private func pdfReader(_ url: URL) -> some View {
        NativePDFPreview(
            url: url,
            root: model.root,
            document: loadedPDFURL?.standardizedFileURL == url.standardizedFileURL
                ? loadedPDFDocument : nil,
            attemptedURL: loadedPDFURL,
            loadFailure: loadedPDFURL?.standardizedFileURL == url.standardizedFileURL
                ? loadedPDFLoadFailure : nil,
            controller: pdfReaderController,
            requestedPage: model.previewPDFPage,
            requestedAnchor: model.previewPDFAnchor,
            navigationSequence: model.previewPDFNavigationSequence,
            onAddPageToNote: { page, selectedText, anchor in
                beginPDFCapture(
                    pdf: url,
                    page: page,
                    selectedText: selectedText,
                    anchor: anchor
                )
            },
            onQuoteToCurrentNote: PDFStudyNoteTarget.resolve(
                note: model.selected, pdf: url, root: model.root, externalBody: model.externalBody
            ).map { note in
                { page, selectedText, anchor in
                    guard PDFStudyNoteTarget.resolve(
                        note: model.selected, pdf: url, root: model.root, externalBody: model.externalBody
                    )?.standardizedFileURL == note.standardizedFileURL else { return }
                    Task { @MainActor in
                        let saved = await model.appendPDFReference(
                            pdf: url, page: page, selectedText: selectedText,
                            anchor: anchor, to: note
                        )
                        guard saved, model.selected?.standardizedFileURL == note.standardizedFileURL else { return }
                        pendingMarkdownReveal = MarkdownEditorRevealRequest(
                            note: note.standardizedFileURL,
                            target: .end,
                            keepsMindMapVisible: false
                        )
                        showingMindMap = false
                        compactStudyShowsStudyPane = true
                        mode = .edit
                        Task { @MainActor in
                            await Task.yield()
                            applyPendingMarkdownReveal()
                        }
                    }
                }
            },
            onReload: { model.reloadPreviewPDF() }
        )
        .id(model.previewPDFReloadSequence)
    }

    private func studyNotePane(_ note: URL) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: showingMindMap ? "point.3.connected.trianglepath.dotted" : "note.text")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: NotesGeometry.symbolSize, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.deletingPathExtension().lastPathComponent)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(language.text(showingMindMap ? "Mind Map" : "Study Note"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.autoSavePending {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(language.text("Save"))
                }
                if !showingMindMap {
                    Button {
                        mode = mode == .read ? .edit : .read
                        if mode == .edit {
                            Task { @MainActor in editorFocused = true }
                        }
                    } label: {
                        toolbarSymbol(mode == .read ? "square.and.pencil" : "book")
                    }
                    .buttonStyle(.plain)
                    .help(language.text(mode == .read ? "Edit" : "Read"))
                    .accessibilityLabel(language.text(mode == .read ? "Edit" : "Read"))
                    .accessibilityIdentifier("pks-study-note-mode-toggle")
                }
                Button {
                    showingMindMap = false
                    model.closePDFPreview()
                    mode = .edit
                    Task { @MainActor in editorFocused = true }
                } label: {
                    toolbarSymbol("arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .help(language.text("Open note only"))
                .accessibilityLabel(language.text("Open note only"))
                .accessibilityIdentifier("pks-study-note-only")
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.03))
            // The note and map are two views of the same canonical Markdown draft.
            // Preserve the normal read/edit mode whenever the map is not visible.
            if showingMindMap {
                mindMapCanvas
            } else if mode == .read {
                renderedNote
            } else {
                editor
            }
        }
        .background(theme.canvas)
        .accessibilityIdentifier("pks-study-note-pane")
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if showMarkdownToolbar {
                markdownFormattingToolbar
            }
            TextEditor(text: $model.draft)
                .focused($editorFocused)
                .font(.system(size: theme.typography.bodySize + fontAdjustment,
                              design: theme.typography.design))
                .lineSpacing(CGFloat(max(0.08, theme.typography.lineSpacing + lineAdjustment) * 9))
                .foregroundColor(theme.ink)
                .tint(theme.linkColor)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: theme.typography.pageWidth + widthAdjustment)
                .padding(.horizontal, NotesGeometry.documentInset)
                .padding(.vertical, NotesGeometry.documentInset)
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
                .onDrop(
                    of: [
                        UTType(exportedAs: PDFCitationPasteboard.type.rawValue, conformingTo: .plainText),
                        .url, .fileURL
                    ],
                    isTargeted: nil
                ) { providers, _ in
                    handleMarkdownDrop(providers)
                }
                .accessibilityIdentifier("pks-markdown-editor")
                .onAppear {
                    resetNativeEditorUndoBaseline()
                    Task { @MainActor in
                        await Task.yield()
                        applyPendingMarkdownReveal()
                    }
                }
        }
        .frame(maxWidth: theme.typography.pageWidth + widthAdjustment
                + NotesGeometry.documentInset * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .onChange(of: model.draftRevision) { _, _ in
            guard pendingMarkdownReveal != nil else { return }
            Task { @MainActor in
                await Task.yield()
                applyPendingMarkdownReveal()
            }
        }
    }

    @ViewBuilder
    private var pdfCitationInsertMenuSection: some View {
        if let pdf = model.previewPDF {
            Divider()
            Button(language.text("Insert PDF Citation at Cursor"), systemImage: "text.quote") {
                NotificationCenter.default.post(name: NotesMenuEvent.insertPDFCitationAtCursor, object: nil)
            }
            .disabled(model.loadingNote || loadedPDFURL?.standardizedFileURL != pdf.standardizedFileURL)
            .accessibilityIdentifier("pks-markdown-insert-pdf-citation")
        }
    }

    private var markdownFormattingToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                Menu {
                    Button(language.text("Heading 1")) { applyMarkdownFormatting("h1") }
                    Button(language.text("Heading 2")) { applyMarkdownFormatting("h2") }
                    Button(language.text("Heading 3")) { applyMarkdownFormatting("h3") }
                } label: {
                    toolbarSymbol("textformat.size")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(language.text("Heading"))
                .accessibilityLabel(language.text("Heading"))
                .accessibilityIdentifier("pks-markdown-format-heading")

                markdownCommandButton("bold", title: "Bold", symbol: "bold",
                                      identifier: "pks-markdown-format-bold")
                markdownCommandButton("italic", title: "Italic", symbol: "italic",
                                      identifier: "pks-markdown-format-italic")

                Menu {
                    Button(language.text("Bullet List")) { applyMarkdownFormatting("bullet") }
                    Button(language.text("Numbered List")) { applyMarkdownFormatting("ordered") }
                    Button(language.text("Task")) { applyMarkdownFormatting("task") }
                } label: {
                    toolbarSymbol("list.bullet")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(language.text("List"))
                .accessibilityLabel(language.text("List"))
                .accessibilityIdentifier("pks-markdown-format-list")

                markdownCommandButton("quote", title: "Quote", symbol: "text.quote",
                                      identifier: "pks-markdown-format-quote")
                markdownCommandButton("link", title: "Link", symbol: "link",
                                      identifier: "pks-markdown-format-link")
                Menu {
                    Button(language.text("Inline Code")) { applyMarkdownFormatting("code") }
                        .accessibilityIdentifier("pks-markdown-format-inline-code")
                    Button(language.text("Code Block")) { applyMarkdownFormatting("codeBlock") }
                        .accessibilityIdentifier("pks-markdown-format-code-block")
                } label: {
                    toolbarSymbol("chevron.left.forwardslash.chevron.right")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(language.text("Code"))
                .accessibilityLabel(language.text("Code"))
                .accessibilityIdentifier("pks-markdown-format-code")

                Menu {
                    Button(language.text("Insert Table"), systemImage: "tablecells") {
                        applyMarkdownFormatting("table")
                    }
                    Button(language.text("Choose Image…"), systemImage: "photo.on.rectangle") {
                        chooseImageFile()
                    }
                    Button(language.text("Paste Image from Clipboard"), systemImage: "photo") {
                        pasteImageFromClipboard()
                    }
                    pdfCitationInsertMenuSection
                } label: {
                    toolbarSymbol("plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(language.text("Insert"))
                .accessibilityLabel(language.text("Insert"))
                .accessibilityIdentifier("pks-markdown-format-insert")

                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: true, vertical: false)
            compactMarkdownFormattingToolbar
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.plain)
        .controlSize(.small)
        .padding(.horizontal, NotesGeometry.documentInset)
        .frame(height: 36)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.025))
        .accessibilityIdentifier("pks-markdown-formatting-toolbar")
    }

    private var compactMarkdownFormattingToolbar: some View {
        HStack(spacing: 8) {
            markdownCommandButton(
                "bold", title: "Bold", symbol: "bold",
                identifier: "pks-markdown-format-bold"
            )
            markdownCommandButton(
                "italic", title: "Italic", symbol: "italic",
                identifier: "pks-markdown-format-italic"
            )

            Menu {
                Button(language.text("Heading 1")) { applyMarkdownFormatting("h1") }
                Button(language.text("Heading 2")) { applyMarkdownFormatting("h2") }
                Button(language.text("Heading 3")) { applyMarkdownFormatting("h3") }
                Divider()
                Button(language.text("Bullet List")) { applyMarkdownFormatting("bullet") }
                Button(language.text("Numbered List")) { applyMarkdownFormatting("ordered") }
                Button(language.text("Task")) { applyMarkdownFormatting("task") }
                Button(language.text("Quote")) { applyMarkdownFormatting("quote") }
                Button(language.text("Link")) { applyMarkdownFormatting("link") }
                Button(language.text("Inline Code")) { applyMarkdownFormatting("code") }
                Button(language.text("Code Block")) { applyMarkdownFormatting("codeBlock") }
            } label: {
                toolbarSymbol("textformat")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(language.text("Markdown formatting toolbar"))
            .accessibilityLabel(language.text("Markdown formatting toolbar"))
            .accessibilityIdentifier("pks-markdown-format-compact")

            Menu {
                Button(language.text("Insert Table"), systemImage: "tablecells") {
                    applyMarkdownFormatting("table")
                }
                Button(language.text("Choose Image…"), systemImage: "photo.on.rectangle") {
                    chooseImageFile()
                }
                Button(language.text("Paste Image from Clipboard"), systemImage: "photo") {
                    pasteImageFromClipboard()
                }
                pdfCitationInsertMenuSection
            } label: {
                toolbarSymbol("plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(language.text("Insert"))
            .accessibilityLabel(language.text("Insert"))
            .accessibilityIdentifier("pks-markdown-format-insert")

            Spacer(minLength: 0)
        }
    }

    private func markdownCommandButton(
        _ command: String,
        title: String,
        symbol: String,
        identifier: String
    ) -> some View {
        Button {
            applyMarkdownFormatting(command)
        } label: {
            toolbarSymbol(symbol)
        }
        .buttonStyle(.plain)
        .help(language.text(title))
        .accessibilityLabel(language.text(title))
        .accessibilityIdentifier(identifier)
    }

    private func applyMarkdownFormatting(_ command: String) {
        guard let textView = markdownTextView(in: NSApp.keyWindow?.contentView) else { return }
        NSApp.keyWindow?.makeFirstResponder(textView)
        editorFocused = true
        _ = MarkdownNativeCommand.perform(command, in: textView)
    }

    private func setMindMapVisible(_ visible: Bool) {
        guard visible != showingMindMap else { return }
        if visible {
            modeBeforeMindMap = mode
            showingMindMapSourcePane = false
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
            if model.previewPDF != nil {
                compactStudyShowsStudyPane = true
            }
        } else if let line = mindMapSelectionLine {
            revealMarkdownLineIndex(line)
        } else {
            showingMindMap = false
            showingMindMapSourcePane = false
            mode = modeBeforeMindMap
        }
    }

    private func revealMarkdownLine(_ line: Int) {
        guard MindMapOutline.sourceLineRange(in: model.draft, nodeID: line) != nil else { return }
        revealMarkdownLineIndex(
            line,
            keepMindMapVisible: showingMindMap && model.previewPDF == nil
        )
    }

    private func revealMarkdownLineIndex(_ line: Int, keepMindMapVisible: Bool = false) {
        guard let note = model.selected,
              let range = MarkdownOutline.lineRange(in: model.draft, lineIndex: line) else {
            model.message = language.text("Link target not available in this workspace.")
            return
        }
        mindMapSelectionLine = MindMapOutline.nodeID(atUTF16Offset: range.location, in: model.draft)
        pendingMarkdownReveal = MarkdownEditorRevealRequest(
            note: note.standardizedFileURL,
            target: .line(line),
            keepsMindMapVisible: keepMindMapVisible
        )
        if keepMindMapVisible {
            showingMindMapSourcePane = true
        } else {
            showingMindMap = false
            showingMindMapSourcePane = false
        }
        mode = .edit
        Task { @MainActor in
            await Task.yield()
            applyPendingMarkdownReveal()
        }
    }

    @MainActor
    private func applyPendingMarkdownReveal() {
        guard let request = pendingMarkdownReveal else { return }
        guard !model.loadingNote else { return }
        guard let selectedNote = model.selected,
              selectedNote.standardizedFileURL == request.note.standardizedFileURL else {
            pendingMarkdownReveal = nil
            return
        }
        let presentationIsCurrent = request.keepsMindMapVisible
            ? showingMindMap && showingMindMapSourcePane
            : !showingMindMap && mode == .edit
        guard presentationIsCurrent else {
            pendingMarkdownReveal = nil
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let textView = markdownTextView(in: window.contentView),
              textView.window === window,
              textView.string == model.draft else { return }
        guard let range = request.selectionRange(
            in: textView.string,
            selectedNote: selectedNote,
            selectedNodeLine: request.keepsMindMapVisible ? mindMapSelectionLine : nil
        ) else {
            pendingMarkdownReveal = nil
            return
        }
        pendingMarkdownReveal = nil
        editorFocused = true
        window.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }


    private var renderedNote: some View {
        MarkdownPreviewPane(source: model.body, revision: model.bodyRevision,
                            live: mode == .split,
                            identity: model.selected?.path ?? model.previewSource?.documentId ?? "",
                            theme: theme,
                            fontAdjustment: fontAdjustment,
                            lineAdjustment: lineAdjustment,
                            widthAdjustment: widthAdjustment,
                            onRepairLink: { beginLinkRepair($0) },
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
