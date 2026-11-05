import AppKit
import SwiftUI
import MarkdownUI

@MainActor
final class PKSNotesAppDelegate: NSObject, NSApplicationDelegate {
    weak var notesModel: NotesModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = notesModel, model.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Unsaved Markdown changes"
        alert.informativeText = "Save changes to \(model.title) before quitting?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save()
            return model.isDirty ? .terminateCancel : .terminateNow
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
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
            CommandMenu("PKS") {
                Button("Save Markdown") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Search Knowledge") { model.search() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Divider()
                Button("Refresh Files") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Choose Folder…") { model.chooseWorkspace() }
            }
        }
    }
}

private enum SidebarTab: String, CaseIterable {
    case notes = "Notes"
    case search = "Search"
}

private enum ReadingMode: String, CaseIterable {
    case split = "Split"
    case edit = "Edit"
    case read = "Read"
}

struct NotesWindow: View {
    @EnvironmentObject private var model: NotesModel
    @State private var mode: ReadingMode = .split
    @State private var sidebarTab: SidebarTab = .notes
    @State private var newNoteName = ""
    @State private var creatingNote = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: { model.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }.help("Refresh Markdown folders")
                Button(action: { creatingNote = true }) {
                    Image(systemName: "square.and.pencil")
                }.help("New Markdown note")
                Button(action: { model.chooseWorkspace() }) {
                    Image(systemName: "folder")
                }.help("Choose an existing folder")
            }
        }
        .alert("New Markdown note", isPresented: $creatingNote) {
            TextField("Note name", text: $newNoteName)
            Button("Create") {
                model.newNote(named: newNoteName)
                newNoteName = ""
            }
            Button("Cancel", role: .cancel) { newNoteName = "" }
        } message: {
            Text("Creates a plain Markdown file beside the selected note, or at the workspace root.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.tint)
                Text("PKS Notes")
                    .font(.headline)
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
                        ForEach(model.hits) { hit in
                            Button {
                                model.openResult(hit)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hit.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(2)
                                    if let heading = hit.headingPath, !heading.isEmpty {
                                        Text(heading)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    if let snippet = hit.snippet, !snippet.isEmpty {
                                        Text(snippet.replacingOccurrences(of: "\n", with: " "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
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
                    OutlineGroup(model.files, children: \NoteItem.children) { (item: NoteItem) in
                        if item.isFolder {
                            Label(item.name, systemImage: "folder")
                                .font(.system(size: 12))
                        } else {
                            Button {
                                model.openNote(item.url)
                            } label: {
                                Label(item.name, systemImage: "doc.text")
                                    .font(.system(size: 12))
                                    .foregroundColor(model.selected == item.url ? .accentColor : .primary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("pks-note-\(item.name)")
                            .help(item.url.path)
                        }
                    }
                } header: {
                    HStack {
                        Text(model.root?.path.contains("Mobile Documents") == true ? "Markdown · iCloud" : "Markdown · local")
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
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if model.selected == nil && model.externalBody == nil {
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
        .navigationTitle(model.selected?.deletingPathExtension().lastPathComponent ?? "PKS Notes")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(.headline).lineLimit(1)
                Text(model.selected?.path ?? "PKS search · external source")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            if model.externalBody == nil {
                Picker("View", selection: $mode) {
                    ForEach(ReadingMode.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 184)

                Button(action: { model.save() }) {
                    Label(model.isDirty ? "Save changes" : "Save", systemImage: "square.and.arrow.down")
                }
                .disabled(model.selected == nil || !model.isDirty)
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
        if model.externalBody != nil || mode == .read {
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
            .accessibilityIdentifier("pks-markdown-editor")
    }

    private var renderedNote: some View {
        ScrollView {
            Markdown(model.body)
                .markdownTheme(.gitHub)
                .markdownImageProvider(LocalMarkdownImageProvider(note: model.selected, root: model.root))
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == nil || url.isFileURL {
                        if !model.openInternalLink(url) {
                            model.message = "Link target not available in this workspace."
                        }
                        return .handled
                    }
                    return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                        ? .systemAction : .discarded
                })
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(26)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("pks-markdown-preview")
    }
}
