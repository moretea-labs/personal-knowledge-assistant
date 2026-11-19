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


/// The stored shortcut is the single authority for the native Carbon hot key.
/// Legacy preset values remain readable when an existing user upgrades.
struct GlobalSearchKeyBinding: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    private static let supportedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)

    var label: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (key == " " ? "Space" : key)
    }

    var storedValue: String { "custom:\(keyCode):\(modifiers):\(key)" }

    static func resolved(_ stored: String?) -> Self {
        if let preset = GlobalSearchShortcut(rawValue: stored ?? "") {
            return .init(keyCode: preset.keyCode, modifiers: preset.modifiers,
                         key: preset == .optionSpace ? " " : "P")
        }
        let parts = (stored ?? "").split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        if parts.count == 4, parts[0] == "custom",
           let code = UInt32(parts[1]), let flags = UInt32(parts[2]),
           let binding = make(keyCode: code, modifiers: flags, key: String(parts[3])) {
            return binding
        }
        let preset = GlobalSearchShortcut.defaultChoice
        return .init(keyCode: preset.keyCode, modifiers: preset.modifiers, key: "P")
    }

    static func make(keyCode: UInt32, modifiers: UInt32, key: String) -> Self? {
        guard keyCode <= 127, modifiers & ~supportedModifiers == 0,
              key.count == 1,
              key == " " || key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let count = [cmdKey, controlKey, optionKey, shiftKey].filter {
            modifiers & UInt32($0) != 0
        }.count
        // Never capture typing, bare Cmd+Q/W or system single-modifier equivalents.
        guard count >= 2 else { return nil }
        return .init(keyCode: keyCode, modifiers: modifiers, key: key.uppercased())
    }

    static func captured(_ event: NSEvent) -> Self? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard let key = event.charactersIgnoringModifiers else { return nil }
        return make(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
    }
}

struct GlobalSearchRanking: Sendable {
    let query: String
    let spotlightNameRank: Int
    let spotlightPathRank: Int
    let mergeWeight: Int
    let contentMatch: Bool
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
    // One query-scoped rank is reused by Spotlight top-N and final provider merge.
    let searchRanking: GlobalSearchRanking?

    static func application(_ url: URL, title: String) -> GlobalSearchItem {
        .init(id: "app:" + url.path, kind: .application, title: title,
              subtitle: url.deletingLastPathComponent().path, url: url,
              snippet: nil, sourceHit: nil, isRelated: false,
              spotlightContentMatch: false, spotlightRelevance: 0,
              searchRanking: nil)
    }

    static func file(_ hit: SearchHit, url: URL, isRelated: Bool = false) -> GlobalSearchItem {
        .init(id: "file:" + url.path, kind: .file, title: hit.title,
              subtitle: url.deletingLastPathComponent().path, url: url,
              snippet: hit.snippet, sourceHit: hit, isRelated: isRelated,
              spotlightContentMatch: false, spotlightRelevance: 0,
              searchRanking: nil)
    }

    static func spotlight(_ url: URL, title: String, isFolder: Bool,
                          contentMatch: Bool = false, relevance: Double = 0) -> GlobalSearchItem {
        .init(id: (isFolder ? "folder:" : "file:") + url.path,
              kind: isFolder ? .folder : .file, title: title,
              subtitle: url.deletingLastPathComponent().path, url: url,
              snippet: nil, sourceHit: nil, isRelated: false,
              spotlightContentMatch: contentMatch, spotlightRelevance: relevance,
              searchRanking: nil)
    }

    func withSnippet(_ snippet: String) -> GlobalSearchItem {
        .init(id: id, kind: kind, title: title, subtitle: subtitle, url: url,
              snippet: snippet, sourceHit: sourceHit, isRelated: isRelated,
              spotlightContentMatch: spotlightContentMatch,
              spotlightRelevance: spotlightRelevance, searchRanking: searchRanking)
    }

    func withRanking(_ ranking: GlobalSearchRanking) -> GlobalSearchItem {
        .init(id: id, kind: kind, title: title, subtitle: subtitle, url: url,
              snippet: snippet, sourceHit: sourceHit, isRelated: isRelated,
              spotlightContentMatch: ranking.contentMatch,
              spotlightRelevance: spotlightRelevance, searchRanking: ranking)
    }

    var fileName: String { url.lastPathComponent }

    static func isLeafspanWorkspaceDocument(_ item: GlobalSearchItem, in root: URL?) -> Bool {
        guard case .file = item.kind,
              let root,
              WorkspaceFiles.contains(item.url, in: root) else { return false }
        return ["md", "markdown", "pdf"].contains(item.url.pathExtension.lowercased())
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
    static func shouldStartDocumentSearch(for query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.count >= 2 { return true }
        // A single Han ideograph is a meaningful Chinese search term; do not
        // suppress local document search just because it is one grapheme.
        return text.unicodeScalars.first?.properties.isIdeographic == true
    }

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

    static func ranking(
        for item: GlobalSearchItem,
        query: String,
        queryTransliteration: NoteTreePresentation.TransliterationKey? = nil
    ) -> GlobalSearchRanking {
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = rawQuery.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        let name = item.title.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )

        if item.kind == .application {
            let weight = name == term ? 0
                : name.hasPrefix(term) ? 2
                : name.contains(term) ? 4 : 13
            return GlobalSearchRanking(
                query: term, spotlightNameRank: 5, spotlightPathRank: 5,
                mergeWeight: weight, contentMatch: false
            )
        }

        let transliterationQuery = queryTransliteration
            ?? WorkspaceSearch.queryTransliterationKey(term)
        let nameRank: Int
        if name == term { nameRank = 0 }
        else if name.hasPrefix(term) { nameRank = 1 }
        else if name.contains(term) { nameRank = 2 }
        else if WorkspaceSearch.transliteratedContains(
            item.title, queryKey: transliterationQuery, useASCIIIndexFastPath: true
        ) { nameRank = 3 }
        else if WorkspaceSearch.fuzzyContains(item.title, term) { nameRank = 4 }
        else { nameRank = 5 }

        let rawPathRank = pathMatchRank(url: item.url, for: term)
        let folder = item.url.deletingLastPathComponent().path
        let pathRank = rawPathRank < 3 ? rawPathRank
            : WorkspaceSearch.transliteratedContains(
                folder, queryKey: transliterationQuery, useASCIIIndexFastPath: true
            ) ? 3
            : WorkspaceSearch.fuzzyContains(folder, term) ? 4 : 5

        let mergeWeight: Int
        if nameRank == 0 { mergeWeight = 1 }
        else if nameRank == 1 { mergeWeight = 3 }
        else if nameRank == 2 { mergeWeight = 5 }
        else if pathRank < 3 { mergeWeight = 6 + pathRank }
        else if nameRank == 3 { mergeWeight = 9 }
        else if pathRank == 3 { mergeWeight = 10 }
        else if nameRank == 4 { mergeWeight = 11 }
        else if pathRank == 4 { mergeWeight = 12 }
        else { mergeWeight = item.isRelated ? 14 : 13 }

        // Spotlight's content badge is true only when the filename and every
        // direct/transliterated/fuzzy path/name signal failed.
        let contentMatch = item.sourceHit == nil
            && !item.title.localizedStandardContains(rawQuery)
            && nameRank == 5 && pathRank == 5
        return GlobalSearchRanking(
            query: term, spotlightNameRank: nameRank, spotlightPathRank: pathRank,
            mergeWeight: mergeWeight, contentMatch: contentMatch
        )
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
        // Filename, path, transliteration and typo ranking are comparatively
        // expensive. Keep them out of the sort comparator: Swift may invoke
        // that comparator O(n log n) times for the same candidate.
        // Spotlight results arrive with the same query-scoped rank used by its
        // top-N projection. Reuse it instead of repeating transliteration and
        // fuzzy path/name matching during the final provider merge.
        let needsDocumentRanking = unique.contains {
            $0.kind != .application && $0.searchRanking?.query != term
        }
        let queryTransliteration = needsDocumentRanking
            ? WorkspaceSearch.queryTransliterationKey(term) : nil
        let ranked = unique.map { item in
            let cached = item.searchRanking
            let ranking = cached?.query == term ? cached!
                : Self.ranking(for: item, query: term, queryTransliteration: queryTransliteration)
            return (item: item.withRanking(ranking), ranking: ranking)
        }.sorted { left, right in
            let a = left.ranking.mergeWeight
            let b = right.ranking.mergeWeight
            if a != b { return a < b }
            if a >= 6 {
                if let leftHit = left.item.sourceHit, let rightHit = right.item.sourceHit {
                    let leftScore = leftHit.score ?? -.infinity
                    let rightScore = rightHit.score ?? -.infinity
                    if leftScore != rightScore { return leftScore > rightScore }
                } else if left.item.sourceHit != nil {
                    // PKS carries a grounded snippet and canonical navigation; its score is not a Spotlight score.
                    return true
                } else if right.item.sourceHit != nil {
                    return false
                } else if left.item.spotlightRelevance != right.item.spotlightRelevance {
                    return left.item.spotlightRelevance > right.item.spotlightRelevance
                }
            }
            if left.item.title.count != right.item.title.count {
                return left.item.title.count < right.item.title.count
            }
            return left.item.title.localizedStandardCompare(right.item.title) == .orderedAscending
        }
        // Keep all direct-result slots. Related suggestions have a separate
        // eight-item budget so a large Spotlight list cannot hide them.
        let direct = ranked.lazy.filter { !$0.item.isRelated }.prefix(max(0, limit))
        let suggestions = ranked.lazy.filter(\.item.isRelated).prefix(8)
        return Array(direct.map(\.item)) + Array(suggestions.map(\.item))
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

    private var applications: [GlobalSearchItem]?
    private var applicationCatalogTask: Task<Void, Never>?
    private var isPresented = false
    private let spotlight = GlobalSpotlightLookup()
    private var appHits: [GlobalSearchItem] = []
    private var pksHits: [SearchHit] = []
    private var workspaceHits: [SearchHit] = []
    private var relatedHits: [GlobalSearchItem] = []
    private var spotlightHits: [GlobalSearchItem] = []
    private var searchTask: Task<Void, Never>?
    private var workspaceSearchTask: Task<Void, Never>?
    private var workspaceCoverage = WorkspaceSearch.Coverage()
    private var librarySearchUnavailable = false
    private var searchGeneration: UInt64 = 0
    private var spotlightSearchPending = false
    private var workspaceSearchPending = false
    private var librarySearchPending = false

    private func updateLoadingState() {
        loading = spotlightSearchPending || workspaceSearchPending || librarySearchPending
    }

    func start() {
        isPresented = true
        cancelPendingSearch()
        query = ""
        items = []
        selectedIndex = 0
        workspaceCoverage = WorkspaceSearch.Coverage()
        librarySearchUnavailable = false
        statusMessage = nil
        loadApplicationCatalogIfNeeded()
    }

    func cancel() {
        isPresented = false
        cancelPendingSearch()
        loading = false
    }

    private func cancelPendingSearch() {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        workspaceSearchTask?.cancel()
        workspaceSearchTask = nil
        spotlight.cancel()
        spotlightSearchPending = false
        workspaceSearchPending = false
        librarySearchPending = false
        updateLoadingState()
    }

    // Bundle discovery touches the filesystem and can be slow on first use.
    // Keep that work off the main actor; publish only if the palette is still open.
    private func loadApplicationCatalogIfNeeded() {
        guard applications == nil, applicationCatalogTask == nil else { return }
        applicationCatalogTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                GlobalApplicationCatalog.installed()
            }.value
            guard let self else { return }
            self.applications = loaded
            self.applicationCatalogTask = nil
            guard self.isPresented else { return }
            self.appHits = GlobalApplicationCatalog.matches(loaded, query: self.query)
            self.publish()
        }
    }

    static func makeStatusMessage(
        coverage: WorkspaceSearch.Coverage,
        libraryUnavailable: Bool,
        language: AppLanguage
    ) -> String? {
        var messages: [String] = []
        if libraryUnavailable {
            messages.append(language.text("Library search unavailable"))
        }
        if coverage.limited {
            messages.append(language.text("Partial workspace results"))
        }
        if coverage.skippedFiles > 0 {
            messages.append(String(
                format: language.text("%d note bodies not searched"),
                coverage.skippedFiles
            ))
        }
        return messages.isEmpty ? nil : messages.joined(separator: " · ")
    }

    private func updateStatusMessage() {
        statusMessage = Self.makeStatusMessage(
            coverage: workspaceCoverage,
            libraryUnavailable: librarySearchUnavailable,
            language: .current
        )
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
        if selected?.id != selectedID { prefetchSelectedFile() }
    }

    private func scheduleSearch() {
        cancelPendingSearch()
        let generation = searchGeneration
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedIndex = 0
        workspaceCoverage = WorkspaceSearch.Coverage()
        librarySearchUnavailable = false
        statusMessage = nil
        appHits = GlobalApplicationCatalog.matches(applications ?? [], query: text)
        pksHits = []
        workspaceHits = []
        relatedHits = []
        spotlightHits = []
        publish()
        guard GlobalSearchRanker.shouldStartDocumentSearch(for: text) else { return }

        let indexedFoldersEnabled = UserDefaults.standard.bool(
            forKey: GlobalSearchPreferences.indexedFoldersEnabledKey
        )
        let notesModel = indexedFoldersEnabled
            ? (NSApp.delegate as? PKSNotesAppDelegate)?.notesModel
            : nil
        spotlightSearchPending = true
        workspaceSearchPending = notesModel != nil
        librarySearchPending = indexedFoldersEnabled
        updateLoadingState()

        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, self.searchGeneration == generation else { return }

            // Spotlight keeps app/file discovery available without a bundled search daemon.
            // Local workspace Markdown uses the existing bounded reader; PKS adds indexed
            // library chunks and semantic matches without becoming a prerequisite.
            self.spotlight.start(text) { [weak self] hits in
                guard let self, self.searchGeneration == generation,
                      self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                self.spotlightHits = hits
                self.spotlightSearchPending = false
                self.updateLoadingState()
                self.publish()
            }
            // A slow or unavailable metadata index must not leave the palette
            // looking stuck. Late Spotlight results are still accepted.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.searchGeneration == generation,
                      self.spotlightSearchPending else { return }
                self.spotlightSearchPending = false
                self.updateLoadingState()
            }

            if let notesModel {
                self.workspaceSearchTask = Task { [weak self] in
                    let result = await notesModel.searchWorkspace(text) { [weak self] partial in
                        guard let self, !Task.isCancelled, self.searchGeneration == generation,
                              self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                        self.workspaceHits = partial.hits
                        self.workspaceCoverage = partial.coverage
                        self.publish()
                    }
                    guard let self, !Task.isCancelled, self.searchGeneration == generation,
                          self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                    self.workspaceHits = result.hits
                    self.workspaceCoverage = result.coverage
                    self.updateStatusMessage()
                    self.publish()
                    self.workspaceSearchPending = false
                    self.workspaceSearchTask = nil
                    self.updateLoadingState()
                }
            }

            guard indexedFoldersEnabled else {
                self.searchTask = nil
                self.updateLoadingState()
                return
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
                guard !Task.isCancelled, self.searchGeneration == generation,
                      (response as? HTTPURLResponse)?.statusCode == 200 else {
                    if !Task.isCancelled { throw URLError(.badServerResponse) }
                    return
                }
                let hits = try JSONDecoder().decode([SearchHit].self, from: data)
                guard !Task.isCancelled, self.searchGeneration == generation,
                      self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                var seen = Set<String>()
                self.pksHits = hits.filter { hit in
                    guard let file = hit.localFileURL else { return false }
                    return seen.insert(file.standardizedFileURL.path).inserted
                }
                self.librarySearchUnavailable = false
                self.updateStatusMessage()
                // Primary results are ready; optional related retrieval must not hold the main spinner.
                self.librarySearchPending = false
                self.updateLoadingState()
                self.publish()

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
                        guard !Task.isCancelled, self.searchGeneration == generation,
                              (relatedResponse as? HTTPURLResponse)?.statusCode == 200 else {
                            throw URLError(.badServerResponse)
                        }
                        let relatedResults = try JSONDecoder().decode([SearchHit].self, from: relatedData)
                        guard !Task.isCancelled, self.searchGeneration == generation,
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
                guard !Task.isCancelled, self.searchGeneration == generation,
                      self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                self.librarySearchUnavailable = true
                self.updateStatusMessage()
                self.librarySearchPending = false
                self.updateLoadingState()
            }
            guard self.searchGeneration == generation else { return }
            self.librarySearchPending = false
            self.updateLoadingState()
            self.searchTask = nil
        }
    }

    func moveSelection(_ offset: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, min(items.count - 1, selectedIndex + offset))
        prefetchSelectedFile()
    }

    var selected: GlobalSearchItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    func select(_ item: GlobalSearchItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            selectedIndex = index
            prefetchSelectedFile()
        }
    }

    private func prefetchSelectedFile() {
        guard let selected, case .file = selected.kind,
              let model = (NSApp.delegate as? PKSNotesAppDelegate)?.notesModel else { return }
        model.prefetchFile(selected.url)
    }
}

@MainActor
final class GlobalSearchController: NSObject, ObservableObject, NSWindowDelegate {
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
        let binding = GlobalSearchKeyBinding.resolved(UserDefaults.standard.string(
            forKey: GlobalSearchPreferences.shortcutKey))
        let identifier = EventHotKeyID(signature: OSType(0x4C465347), id: 1)
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                                         identifier, GetApplicationEventTarget(), 0, &hotKey)
        shortcutStatus = status == noErr
            ? "已启用 " + binding.label
            : "无法注册快捷键，请检查是否被其他应用占用"
    }

    /// A failed registration must not replace the last working global shortcut.
    func applyRecordedShortcut(_ binding: GlobalSearchKeyBinding) -> Bool {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: GlobalSearchPreferences.shortcutKey)
        defaults.set(binding.storedValue, forKey: GlobalSearchPreferences.shortcutKey)
        configure()
        guard hotKey != nil else {
            if let previous {
                defaults.set(previous, forKey: GlobalSearchPreferences.shortcutKey)
            } else {
                defaults.removeObject(forKey: GlobalSearchPreferences.shortcutKey)
            }
            configure()
            shortcutStatus = "该快捷键不可用，请换一个组合"
            return false
        }
        return true
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
        window.delegate = self
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

    func windowWillClose(_ notification: Notification) {
        guard let closingPanel = notification.object as? NSPanel,
              closingPanel === panel else { return }
        results.cancel()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
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
            } else if let model = (NSApp.delegate as? PKSNotesAppDelegate)?.notesModel,
                      GlobalSearchItem.isLeafspanWorkspaceDocument(item, in: model.root) {
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: {
                    $0.isVisible && !($0 is NSPanel)
                })?.makeKeyAndOrderFront(nil)
                // Spotlight results in the active workspace have no PKS hit,
                // but still use the same dirty-draft, PDF and Markdown opener.
                model.openFile(item.url)
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

    func copyName(_ item: GlobalSearchItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.fileName, forType: .string)
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
                Button(AppLanguage.current.resolved == .simplifiedChinese ? "取消" : "Cancel") {
                    GlobalSearchController.shared.dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("leafspan-global-search-cancel")
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
                                        if let snippet = item.snippet, !snippet.isEmpty, snippet != item.subtitle {
                                            Text(snippet).lineLimit(1).font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        } else if item.spotlightContentMatch {
                                            Text(AppLanguage.current.resolved == .simplifiedChinese
                                                 ? "正文匹配" : "Content match")
                                                .lineLimit(1).font(.system(size: 11))
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
                            .onHover { hovering in
                                if hovering { results.select(item) }
                            }
                            .contextMenu {
                                let chinese = AppLanguage.current.resolved == .simplifiedChinese
                                Button(chinese ? "打开" : "Open") { GlobalSearchController.shared.open(item) }
                                Button(chinese ? "在 Finder 中显示" : "Show in Finder") {
                                    GlobalSearchController.shared.reveal(item)
                                }
                                Button(chinese ? "复制路径" : "Copy Path") {
                                    GlobalSearchController.shared.copyPath(item)
                                }
                                Button(chinese ? "复制名称" : "Copy Name") {
                                    GlobalSearchController.shared.copyName(item)
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
                Text(status)
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
    @State private var recording = false
    @State private var recordingMonitor: Any?
    @State private var recordingHint: String?

    private var chinese: Bool { AppLanguage.current.resolved == .simplifiedChinese }

    var body: some View {
        Form {
            Toggle(chinese ? "搜索工作区与 PKS 索引内容" : "Search workspace and PKS indexed content", isOn: $indexedFoldersEnabled)
            Toggle(chinese ? "启用全局快捷键" : "Enable global shortcut", isOn: $enabled)
            HStack {
                Text(chinese ? "全局快捷键" : "Global shortcut")
                Spacer()
                Button(recording
                       ? (chinese ? "按下快捷键…" : "Press shortcut…")
                       : GlobalSearchKeyBinding.resolved(shortcut).label) {
                    if recording { stopRecording() } else { beginRecording() }
                }
                .disabled(!enabled)
                .accessibilityIdentifier("leafspan-global-search-record-shortcut")
            }
            if recording {
                Text(chinese ? "同时按至少两个修饰键和一个键；Esc 取消"
                             : "Press two modifiers and a key; Esc cancels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let recordingHint {
                Text(recordingHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        .onDisappear { stopRecording() }
        .onChange(of: enabled) { _, newValue in
            if !newValue { stopRecording() }
            controller.configure()
        }
    }

    private func beginRecording() {
        stopRecording()
        recordingHint = nil
        recording = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            guard let binding = GlobalSearchKeyBinding.captured(event) else {
                recordingHint = chinese
                    ? "请使用至少两个修饰键，避免与系统快捷键冲突"
                    : "Use at least two modifiers to avoid system shortcuts"
                return nil
            }
            let accepted = controller.applyRecordedShortcut(binding)
            if accepted {
                shortcut = binding.storedValue
                recordingHint = nil
            } else {
                recordingHint = chinese
                    ? "快捷键被占用，原快捷键已保留"
                    : "Shortcut unavailable; previous shortcut retained"
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
            self.recordingMonitor = nil
        }
        recording = false
    }
}
