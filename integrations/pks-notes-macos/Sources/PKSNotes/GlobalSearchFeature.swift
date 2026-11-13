import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

// Optional native search launcher. PKS owns file/full-text indexing; this component
// only presents results and discovers installed application bundles.
enum GlobalSearchPreferences {
    static let enabledKey = "LeafspanGlobalSearchEnabled"
    static let indexedFoldersEnabledKey = "LeafspanPKSIndexedFoldersEnabled"
    static let shortcutKey = "LeafspanGlobalSearchShortcut"
}

enum GlobalSearchShortcut: String, CaseIterable, Identifiable {
    case controlOptionP
    case optionSpace

    static let defaultChoice: GlobalSearchShortcut = .controlOptionP

    var id: String { rawValue }
    var label: String {
        switch self {
        case .optionSpace: "⌥Space"
        case .controlOptionP: "⌃⌥P"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .optionSpace: UInt32(kVK_Space)
        case .controlOptionP: UInt32(kVK_ANSI_P)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlOptionP: UInt32(controlKey | optionKey)
        }
    }
}

struct GlobalSearchItem: Identifiable, Sendable {
    enum Kind: Sendable {
        case application
        case file
        case folder
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let url: URL
    let snippet: String?
    // Existing PKS provenance for in-workspace Markdown/PDF navigation.
    let sourceHit: SearchHit?
    let isRelated: Bool
    let spotlightContentMatch: Bool
    let spotlightRelevance: Double

    static func application(_ url: URL, title: String) -> GlobalSearchItem {
        .init(id: "app:" + url.path, kind: .application, title: title,
              subtitle: url.deletingLastPathComponent().path, url: url,
              snippet: nil, sourceHit: nil, isRelated: false,
              spotlightContentMatch: false, spotlightRelevance: 0)
    }

    static func file(_ hit: SearchHit, url: URL, isRelated: Bool = false) -> GlobalSearchItem {
        .init(id: "file:" + url.path, kind: .file, title: hit.title,
              subtitle: url.deletingLastPathComponent().path, url: url,
              snippet: hit.snippet, sourceHit: hit, isRelated: isRelated,
              spotlightContentMatch: false, spotlightRelevance: 0)
    }

    static func spotlight(_ url: URL, title: String, isFolder: Bool,
                          contentMatch: Bool = false, relevance: Double = 0) -> GlobalSearchItem {
        .init(id: (isFolder ? "folder:" : "file:") + url.path,
              kind: isFolder ? .folder : .file, title: title,
              subtitle: url.deletingLastPathComponent().path, url: url,
              snippet: nil, sourceHit: nil, isRelated: false,
              spotlightContentMatch: contentMatch, spotlightRelevance: relevance)
    }
}

// Only regular application bundles in conventional installation locations.
// No recursive filesystem crawler, persistent application index, or permissions.
enum GlobalApplicationCatalog {
    static func installed() -> [GlobalSearchItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        ]
        var seen = Set<String>()
        var items: [GlobalSearchItem] = []
        for root in roots {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls where url.pathExtension.lowercased() == "app" {
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted, let bundle = Bundle(url: url),
                      bundle.bundleIdentifier != nil else { continue }
                let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                items.append(.application(url, title: name))
            }
        }
        return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func matches(_ apps: [GlobalSearchItem], query: String, limit: Int = 16) -> [GlobalSearchItem] {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return apps.compactMap { app -> (Int, GlobalSearchItem)? in
            let title = app.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let bundle = app.url.deletingPathExtension().lastPathComponent
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if title == q || bundle == q { return (0, app) }
            if title.hasPrefix(q) || bundle.hasPrefix(q) { return (1, app) }
            if title.contains(q) || bundle.contains(q) { return (2, app) }
            return nil
        }
        .sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1.title.count != $1.1.title.count {
                return $0.1.title.count < $1.1.title.count
            }
            return $0.1.title.localizedStandardCompare($1.1.title) == .orderedAscending
        }
        .prefix(limit).map(\.1)
    }
}


/// Presentation-only ranker: one visible result per path, regardless of the
/// separate OS application/Spotlight and PKS content result providers.
enum GlobalSearchRanker {
    // Extra suggestions require at least two meaningful terms or a longer Han
    // phrase. The PKS "related" mode independently requires multiple
    // matching content signals; never infer relatedness from names alone.
    static func shouldFindRelated(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hanCount = text.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains($0.value)
        }.count
        if hanCount > 0 {
            // Chinese generic search terms are not evidence of a substantive
            // topic. Remove them before counting the remaining phrase.
            let ignoredPhrases = [
                "请帮我", "帮我", "找一下", "找找", "找",
                "在哪里", "在哪儿", "在哪", "路径", "位置",
                "文件夹", "我的", "所有", "全部", "文件", "资料", "笔记",
                "相关", "搜索", "内容", "文档", "这个", "那个", "一个",
                "怎么", "如何", "的", "以及", "与"
            ]
            let meaningful = ignoredPhrases.reduce(text) {
                $0.replacingOccurrences(of: $1, with: "")
            }
            return meaningful.unicodeScalars.filter {
                (0x4E00...0x9FFF).contains($0.value)
            }.count >= 4
        }
        let ignored: Set<String> = [
            "my", "the", "and", "about", "file", "files", "folder", "folders",
            "document", "documents", "note", "notes", "markdown", "search",
            "content", "pdf", "path", "paths", "location", "where", "find", "locate",
            "please", "help", "all", "every", "from", "with", "this", "that", "your",
            "for", "are", "was", "were", "into", "is", "to", "of", "in", "on", "at",
            "by", "as", "or", "but", "how", "what", "when", "which", "who", "why",
            "can", "could", "should", "would"
        ]
        let meaningful = text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 2 && !ignored.contains(String($0)) }
        return meaningful.count >= 2
    }

    /// Rank directory components independently from filenames and body text.
    /// Exact/prefix/substring folder matches are useful global-search signals,
    /// but must never outrank a direct filename match.
    static func pathMatchRank(url: URL, for query: String) -> Int {
        let term = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return 3 }
        let folders = url.deletingLastPathComponent().pathComponents.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        if folders.contains(term) { return 0 }
        if folders.contains(where: { $0.hasPrefix(term) }) { return 1 }
        if folders.contains(where: { $0.contains(term) }) { return 2 }
        return 3
    }

    static func merge(apps: [GlobalSearchItem], documents: [GlobalSearchItem],
                      spotlight: [GlobalSearchItem],
                      related: [GlobalSearchItem] = [], query: String,
                      limit: Int = 45) -> [GlobalSearchItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var seen = Set<String>()
        let unique = (apps + documents + spotlight + related).filter {
            seen.insert($0.url.standardizedFileURL.path).inserted
        }
        func weight(_ item: GlobalSearchItem) -> Int {
            let name = item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let isApp = item.kind == .application
            if name == term { return isApp ? 0 : 1 }
            if name.hasPrefix(term) { return isApp ? 2 : 3 }
            if name.contains(term) { return isApp ? 4 : 5 }
            if !isApp {
                let pathRank = pathMatchRank(url: item.url, for: term)
                if pathRank < 3 { return 6 + pathRank }
            }
            if !isApp, WorkspaceSearch.transliteratedContains(item.title, term) { return 9 }
            if !isApp, WorkspaceSearch.transliteratedContains(
                item.url.deletingLastPathComponent().path, term
            ) { return 10 }
            if !isApp, WorkspaceSearch.fuzzyContains(item.title, term) { return 11 }
            if !isApp, WorkspaceSearch.fuzzyContains(
                item.url.deletingLastPathComponent().path, term
            ) { return 12 }
            if item.isRelated { return 14 }
            return 13 // body-only PKS/Spotlight match
        }
        let ranked = unique.sorted { left, right in
            let a = weight(left)
            let b = weight(right)
            if a != b { return a < b }
            if a >= 6 {
                if let leftHit = left.sourceHit, let rightHit = right.sourceHit {
                    let leftScore = leftHit.score ?? -.infinity
                    let rightScore = rightHit.score ?? -.infinity
                    if leftScore != rightScore { return leftScore > rightScore }
                } else if left.sourceHit != nil {
                    // PKS carries a grounded snippet and canonical navigation; its score is not a Spotlight score.
                    return true
                } else if right.sourceHit != nil {
                    return false
                } else if left.spotlightRelevance != right.spotlightRelevance {
                    return left.spotlightRelevance > right.spotlightRelevance
                }
            }
            if left.title.count != right.title.count {
                return left.title.count < right.title.count
            }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
        // Keep all direct-result slots. Related suggestions have a separate
        // eight-item budget so a large Spotlight list cannot hide them.
        let direct = ranked.lazy.filter { !$0.isRelated }.prefix(max(0, limit))
        let suggestions = ranked.lazy.filter(\.isRelated).prefix(8)
        return Array(direct) + Array(suggestions)
    }
}

@MainActor
final class GlobalSearchResults: ObservableObject {
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var items: [GlobalSearchItem] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var loading = false

    private var applications: [GlobalSearchItem] = []
    private let spotlight = GlobalSpotlightLookup()
    private var appHits: [GlobalSearchItem] = []
    private var pksHits: [SearchHit] = []
    private var workspaceHits: [SearchHit] = []
    private var relatedHits: [GlobalSearchItem] = []
    private var spotlightHits: [GlobalSearchItem] = []
    private var searchTask: Task<Void, Never>?
    private var workspaceSearchTask: Task<Void, Never>?

    func start() {
        if applications.isEmpty {
            applications = GlobalApplicationCatalog.installed()
        }
        query = ""
        items = []
        selectedIndex = 0
        statusMessage = nil
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        workspaceSearchTask?.cancel()
        workspaceSearchTask = nil
        spotlight.cancel()
    }

    private func publish() {
        let selectedID = selected?.id
        let documentHits = WorkspaceSearch.merging(local: workspaceHits, remote: pksHits)
        let documents = documentHits.compactMap { hit -> GlobalSearchItem? in
            guard let file = hit.localFileURL else { return nil }
            return GlobalSearchItem.file(hit, url: file)
        }
        let combined = GlobalSearchRanker.merge(
            apps: appHits, documents: documents, spotlight: spotlightHits,
            related: relatedHits, query: query
        )
        items = combined
        if let selectedID, let index = combined.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else {
            selectedIndex = max(0, min(selectedIndex, max(0, combined.count - 1)))
        }
    }

    private func scheduleSearch() {
        cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedIndex = 0
        statusMessage = nil
        appHits = GlobalApplicationCatalog.matches(applications, query: text)
        pksHits = []
        workspaceHits = []
        relatedHits = []
        spotlightHits = []
        publish()
        loading = false
        guard text.count >= 2 else { return }
        loading = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            // System Spotlight handles file/folder names without a bundled search daemon.
            // PKS remains the authority for document content, chunks and semantic results.
            self.spotlight.start(text) { [weak self] hits in
                guard let self, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                self.spotlightHits = hits
                self.publish()
            }
            // App/Spotlight results stay available independently of PKS.
            guard UserDefaults.standard.bool(forKey: GlobalSearchPreferences.indexedFoldersEnabledKey) else {
                self.loading = false
                self.searchTask = nil
                return
            }
            if let notesModel = (NSApp.delegate as? PKSNotesAppDelegate)?.notesModel {
                self.workspaceSearchTask = Task { [weak self] in
                    let hits = await notesModel.searchWorkspaceNames(text)
                    guard let self, !Task.isCancelled,
                          self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                    self.workspaceHits = hits
                    self.publish()
                }
            }
            do {
                var url = URLComponents(string: "http://127.0.0.1:3217/api/search")!
                url.queryItems = [
                    URLQueryItem(name: "q", value: text),
                    URLQueryItem(name: "mode", value: "auto"),
                    URLQueryItem(name: "limit", value: "40")
                ]
                var request = URLRequest(url: url.url!)
                request.timeoutInterval = 3
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let hits = try JSONDecoder().decode([SearchHit].self, from: data)
                guard !Task.isCancelled, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                var seen = Set<String>()
                self.pksHits = hits.filter { hit in
                    guard let file = hit.localFileURL else { return false }
                    return seen.insert(file.standardizedFileURL.path).inserted
                }
                self.statusMessage = nil
                // Primary results are ready; optional related retrieval must not hold the main spinner.
                self.loading = false
                self.publish()

                // Only request additional evidence-based suggestions for
                // substantive queries when literal/content results are sparse.
                // PKS uses the same existing catalog, not a second index.
                if GlobalSearchRanker.shouldFindRelated(text), self.pksHits.count < 15 {
                    var relatedURL = URLComponents(string: "http://127.0.0.1:3217/api/search")!
                    relatedURL.queryItems = [
                        URLQueryItem(name: "q", value: text),
                        URLQueryItem(name: "mode", value: "related"),
                        URLQueryItem(name: "limit", value: "12")
                    ]
                    var relatedRequest = URLRequest(url: relatedURL.url!)
                    relatedRequest.timeoutInterval = 3
                    do {
                        let (relatedData, relatedResponse) = try await URLSession.shared.data(for: relatedRequest)
                        guard (relatedResponse as? HTTPURLResponse)?.statusCode == 200 else {
                            throw URLError(.badServerResponse)
                        }
                        let relatedResults = try JSONDecoder().decode([SearchHit].self, from: relatedData)
                        guard !Task.isCancelled,
                              self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                        var seen = Set<String>()
                        self.relatedHits = relatedResults.compactMap { hit in
                            guard let file = hit.localFileURL,
                                  seen.insert(file.standardizedFileURL.path).inserted else { return nil }
                            return GlobalSearchItem.file(hit, url: file, isRelated: true)
                        }
                        self.publish()
                    } catch {
                        // Optional related suggestions must not break primary search.
                    }
                }
            } catch {
                guard !Task.isCancelled, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                // Ordinary filename search remains available through Spotlight.
                self.statusMessage = "文档内容搜索暂不可用"
            }
            self.loading = false
            self.searchTask = nil
        }
    }

    func moveSelection(_ offset: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, min(items.count - 1, selectedIndex + offset))
    }

    var selected: GlobalSearchItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    func select(_ item: GlobalSearchItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            selectedIndex = index
        }
    }
}

@MainActor
final class GlobalSearchController: NSObject, ObservableObject {
    static let shared = GlobalSearchController()

    @Published private(set) var shortcutStatus = ""
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let results = GlobalSearchResults()

    func install() {
        configure()
    }

    func configure() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard UserDefaults.standard.bool(forKey: GlobalSearchPreferences.enabledKey) else {
            shortcutStatus = ""
            dismiss()
            return
        }
        if handler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<GlobalSearchController>
                    .fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { controller.present() }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else {
                shortcutStatus = "无法启用全局快捷键"
                return
            }
        }
        let choice = GlobalSearchShortcut(rawValue: UserDefaults.standard.string(
            forKey: GlobalSearchPreferences.shortcutKey) ?? "") ?? .defaultChoice
        let identifier = EventHotKeyID(signature: OSType(0x4C465347), id: 1)
        let status = RegisterEventHotKey(choice.keyCode, choice.modifiers,
                                         identifier, GetApplicationEventTarget(), 0, &hotKey)
        shortcutStatus = status == noErr
            ? "已启用 " + choice.label
            : "无法注册快捷键，请检查是否被其他应用占用"
    }

    func present() {
        if let panel, panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // Recreate the view when a previously hidden panel is invoked again.
        dismiss()
        results.start()
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isFloatingPanel = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = true
        window.contentView = NSHostingView(rootView: GlobalSearchPalette(results: results))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.midX - 325, y: frame.maxY - 540))
        } else {
            window.center()
        }
        panel = window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel === NSApp.keyWindow else { return event }
            switch event.keyCode {
            case 53: self.dismiss(); return nil
            case 125: self.results.moveSelection(1); return nil
            case 126: self.results.moveSelection(-1); return nil
            default: return event
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        results.cancel()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        panel?.close()
        panel = nil
    }

    func open(_ item: GlobalSearchItem) {
        switch item.kind {
        case .application:
            dismiss()
            NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                guard error != nil else { return }
                Task { @MainActor in self?.reportOpenFailure() }
            }
        case .file, .folder:
            if let hit = item.sourceHit,
               let model = (NSApp.delegate as? PKSNotesAppDelegate)?.notesModel {
                dismiss()
                // Reuse the sole note-navigation authority, including dirty-draft
                // confirmation and exact Markdown match handling.
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: {
                    $0.isVisible && !($0 is NSPanel)
                })?.makeKeyAndOrderFront(nil)
                model.openResult(hit)
            } else {
                let opened = NSWorkspace.shared.open(item.url)
                dismiss()
                if !opened { reportOpenFailure() }
            }
        }
    }

    private func reportOpenFailure() {
        guard let model = (NSApp.delegate as? PKSNotesAppDelegate)?.notesModel else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
        model.message = AppLanguage.current.text("Unable to open this item")
    }

    func reveal(_ item: GlobalSearchItem) {
        dismiss()
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyPath(_ item: GlobalSearchItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
    }
}

private struct GlobalSearchPalette: View {
    @ObservedObject var results: GlobalSearchResults
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(AppLanguage.current.resolved == .simplifiedChinese
                          ? "搜索应用、文件和文档内容" : "Search apps, files and document contents", text: $results.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 21))
                    .focused($searchFocused)
                    .onSubmit { if let item = results.selected { GlobalSearchController.shared.open(item) } }
                    .accessibilityIdentifier("leafspan-global-search-input")
                if results.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 23)
            .padding(.top, 32)
            .padding(.bottom, 18)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(results.items.enumerated()), id: \.element.id) { index, item in
                            if item.isRelated &&
                                (index == 0 || !results.items[index - 1].isRelated) {
                                Text(AppLanguage.current.resolved == .simplifiedChinese
                                     ? "可能相关" : "Possibly related")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 11)
                            }
                            Button {
                                GlobalSearchController.shared.open(item)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                        .resizable()
                                        .interpolation(.high)
                                        .scaledToFit()
                                        .frame(width: 24, height: 24)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).lineLimit(1).font(.system(size: 14, weight: .medium))
                                        Text(item.subtitle).lineLimit(1).font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        if item.spotlightContentMatch {
                                            Text(AppLanguage.current.resolved == .simplifiedChinese
                                                 ? "正文匹配" : "Content match")
                                                .lineLimit(1).font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        } else if let snippet = item.snippet, !snippet.isEmpty, snippet != item.subtitle {
                                            Text(snippet).lineLimit(1).font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 5)
                                    if results.selectedIndex == index {
                                        Text("↵").foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(results.selectedIndex == index ? Color.accentColor.opacity(0.10) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                let chinese = AppLanguage.current.resolved == .simplifiedChinese
                                Button(chinese ? "打开" : "Open") { GlobalSearchController.shared.open(item) }
                                Button(chinese ? "在 Finder 中显示" : "Show in Finder") {
                                    GlobalSearchController.shared.reveal(item)
                                }
                                Button(chinese ? "复制路径" : "Copy Path") {
                                    GlobalSearchController.shared.copyPath(item)
                                }
                            }
                            .id(item.id)
                            .accessibilityIdentifier("leafspan-global-result-\(index)")
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                }
                .onChange(of: results.selectedIndex) { _, index in
                    guard results.items.indices.contains(index) else { return }
                    withAnimation(.none) { proxy.scrollTo(results.items[index].id, anchor: .center) }
                }
            }
            if let status = results.statusMessage {
                Divider()
                Text(AppLanguage.current.resolved == .simplifiedChinese ? status : "File search is unavailable")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 10)
            }
        }
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
        .frame(width: 650, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct GlobalSearchSettingsView: View {
    @AppStorage(GlobalSearchPreferences.enabledKey) private var enabled = false
    @AppStorage(GlobalSearchPreferences.indexedFoldersEnabledKey) private var indexedFoldersEnabled = false
    @AppStorage(GlobalSearchPreferences.shortcutKey) private var shortcut = GlobalSearchShortcut.defaultChoice.rawValue
    @ObservedObject private var controller = GlobalSearchController.shared

    private var chinese: Bool { AppLanguage.current.resolved == .simplifiedChinese }

    var body: some View {
        Form {
            Toggle(chinese ? "搜索 PKS 已索引文件夹" : "Search PKS indexed folders", isOn: $indexedFoldersEnabled)
            Toggle(chinese ? "启用全局快捷键" : "Enable global shortcut", isOn: $enabled)
            Picker(chinese ? "全局快捷键" : "Global shortcut", selection: $shortcut) {
                ForEach(GlobalSearchShortcut.allCases) { choice in
                    Text(choice.label).tag(choice.rawValue)
                }
            }
            .disabled(!enabled)
            if enabled {
                Text(controller.shortcutStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(chinese ? "打开全局搜索" : "Open Global Search") { controller.present() }
        }
        .formStyle(.grouped)
        .padding(.top, 12)
        .onAppear { controller.configure() }
        .onChange(of: enabled) { _, _ in controller.configure() }
        .onChange(of: shortcut) { _, _ in controller.configure() }
    }
}
