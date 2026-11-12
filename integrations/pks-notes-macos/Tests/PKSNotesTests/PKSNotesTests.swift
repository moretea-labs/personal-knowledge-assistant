import Foundation
import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import PKSNotes

private final class UnavailableSearchURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 503,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PKSNotesTests: XCTestCase {
    @MainActor
    func testConflictedDraftCanBeRecoveredWithoutOverwritingExternalEdit() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "PKSNotesWorkspace")
        defer {
            if let previous { defaults.set(previous, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("研究.md")
        try "baseline".write(to: original, atomically: true, encoding: .utf8)
        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(original)
        await waitForNote(model, original)
        model.draft = "My unsaved research draft 📝"
        try "External editor version".write(to: original, atomically: true, encoding: .utf8)
        model.save()
        XCTAssertTrue(model.isDirty)
        let recovered = try XCTUnwrap(model.saveDraftCopy())
        XCTAssertEqual(try String(contentsOf: recovered, encoding: .utf8), model.draft)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "External editor version")
        XCTAssertEqual(model.selected, original)
        XCTAssertTrue(model.isDirty, "Recovery never silently discards the active draft")
        let another = try XCTUnwrap(model.saveDraftCopy())
        XCTAssertNotEqual(another, recovered)
        XCTAssertEqual(try String(contentsOf: recovered, encoding: .utf8), "My unsaved research draft 📝")
    }

    @MainActor
    func testSymlinkReplacementStopsAutosaveAndPreservesDraftWithVisibleError() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "PKSNotesWorkspace")
        defer {
            if let previous { defaults.set(previous, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Note.md")
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: outside) }
        try "baseline".write(to: original, atomically: true, encoding: .utf8)
        try "External file".write(to: outside, atomically: true, encoding: .utf8)
        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(original)
        await waitForNote(model, original)
        model.draft = "Preserve this draft"
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        model.save()
        XCTAssertFalse(model.autoSavePending)
        XCTAssertTrue(model.isDirty)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "External file")
        let recovered = try XCTUnwrap(model.saveDraftCopy())
        XCTAssertEqual(try String(contentsOf: recovered, encoding: .utf8), "Preserve this draft")
    }

    @MainActor
    func testWorkspaceSearchFallsBackWhenRelatedKnowledgeServiceIsUnavailable() async throws {
        let defaults = UserDefaults.standard
        let previousWorkspace = defaults.object(forKey: "PKSNotesWorkspace")
        let previousBookmark = defaults.object(forKey: "PKSNotesWorkspaceBookmark")
        let previousLanguage = defaults.object(forKey: AppLanguage.defaultsKey)
        defer {
            if let previousWorkspace { defaults.set(previousWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousBookmark { defaults.set(previousBookmark, forKey: "PKSNotesWorkspaceBookmark") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark") }
            if let previousLanguage { defaults.set(previousLanguage, forKey: AppLanguage.defaultsKey) }
            else { defaults.removeObject(forKey: AppLanguage.defaultsKey) }
        }
        defaults.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("Plant.md")
        try "龟背竹换盆后减少浇水".write(to: note, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnavailableSearchURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        model.query = "龟背竹"
        model.search(using: session)
        for _ in 0..<250 {
            if !model.searching { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(model.searching, "Workspace search should finish even when the optional service is offline.")
        XCTAssertEqual(model.hits.map(\.uri), [note.path])
        XCTAssertFalse(model.searchFailed, "The optional service must not make local search fail.")
        XCTAssertTrue(model.searchStatus.contains("Workspace"))
        XCTAssertTrue(model.searchStatus.contains("Library search unavailable"))
    }

    @MainActor
    private func waitForNote(_ model: NotesModel, _ url: URL) async {
        for _ in 0..<150 {
            if model.selected == url && !model.loadingNote { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for Markdown to open: \(url.path) — \(model.message ?? "no error")")
    }


    func testWorkspaceTitleHidesICloudInternalFolderName() {
        XCTAssertEqual(
            NotesGeometry.workspaceTitle(
                URL(fileURLWithPath: "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs"),
                language: .english
            ), "iCloud Drive"
        )
        XCTAssertEqual(
            NotesGeometry.workspaceTitle(URL(fileURLWithPath: "/tmp/学习笔记管理"), language: .english),
            "学习笔记管理"
        )
        XCTAssertEqual(NotesGeometry.workspaceTitle(nil, language: .english), "Knowledge Library")
        XCTAssertEqual(NotesGeometry.workspaceTitle(nil, language: .simplifiedChinese), "知识资料库")
    }

    func testBackgroundMarkdownPreviewParsingAndSearchHeadingNavigation() async {
        let source = """
        # Overview

        A [local link](assets/example.md) with **formatted text**.

        ## 第二节

        Search target text and a footnote.[^ref]

        [^ref]: Keep whole-document footnotes.
        """
        let full = await Task.detached {
            MarkdownPreviewParsing.prepare(source, match: nil)
        }.value
        XCTAssertEqual(full.count, 1, "Regular previews preserve cross-section links and footnotes.")
        XCTAssertEqual(full.first?.source.markdown, source)
        XCTAssertTrue(full[0].content.renderMarkdown().contains("local link"))

        let hit = SearchHit(documentId: "example", chunkId: "heading-2", title: "example.md",
                            uri: "/tmp/example.md", sourceType: "local",
                            snippet: "Search target text", score: nil, headingPath: "Overview > 第二节")
        let pieces = await Task.detached {
            MarkdownPreviewParsing.prepare(source, match: hit)
        }.value
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces.map(\.source.heading), ["Overview", "第二节"])
        XCTAssertEqual(MarkdownSection.targetIndex(in: pieces.map(\.source),
                                                  headingPath: hit.headingPath,
                                                  snippet: hit.snippet, query: "Search"), 1)

        let anchored = await Task.detached {
            MarkdownPreviewParsing.prepare(
                source,
                match: nil,
                anchorFragment: "%E7%AC%AC%E4%BA%8C%E8%8A%82"
            )
        }.value
        XCTAssertEqual(anchored.count, 2)
        XCTAssertEqual(anchored.map(\.source.heading), ["Overview", "第二节"])
    }

    @MainActor
    func testDebouncedAutosaveFlushesOnNavigationAndNeverOverwritesExternalChanges() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let previous { defaults.set(previous, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.md")
        let second = folder.appendingPathComponent("second.md")
        try "# First".write(to: first, atomically: true, encoding: .utf8)
        try "# Second".write(to: second, atomically: true, encoding: .utf8)

        let model = NotesModel()
        model.openWorkspace(folder)
        model.openNote(first)
        await waitForNote(model, first)

        model.draft = "# Updated automatically"
        XCTAssertTrue(model.autoSavePending)
        for _ in 0..<100 {
            if !model.autoSavePending { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.autoSavePending)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# Updated automatically")
        XCTAssertFalse(model.message?.contains("Saved to") == true)

        model.draft = "# Flush before leaving"
        model.openNote(second)
        await waitForNote(model, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# Flush before leaving")

        model.openNote(first)
        await waitForNote(model, first)
        model.draft = "# Local pending"
        try "# External revision".write(to: first, atomically: true, encoding: .utf8)
        for _ in 0..<100 {
            if !model.autoSavePending { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.autoSavePending)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.draft, "# Local pending")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# External revision")
        XCTAssertTrue(model.message?.contains(AppLanguage.current.text("The file changed outside Leafspan. Reopen it before saving to avoid overwriting edits.")) == true)
    }

    func testPDFDocumentLoadingCompletesForLocalPDF() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let url = folder.appendingPathComponent("Local.pdf")
        await MainActor.run {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
            view.string = "Local PDF loading regression"
            try? view.dataWithPDF(inside: view.bounds).write(to: url)
        }

        let document = await PDFDocumentLoading.load(url)
        XCTAssertNotNil(document)
        XCTAssertEqual(document?.pageCount, 1)
    }

    @MainActor
    func testPDFReaderAttachDoesNotReconfigureUnchangedNativeView() {
        let controller = PDFReaderController()
        let view = PDFView()
        let document = PDFDocument()
        let url = URL(fileURLWithPath: "/tmp/pks-idempotent-preview.pdf")

        controller.attach(
            view: view,
            document: document,
            url: url,
            requestedPage: nil,
            requestedAnchor: nil
        )
        XCTAssertEqual(view.displayMode, .singlePageContinuous)
        XCTAssertTrue(view.displaysPageBreaks)

        // Model a later SwiftUI update after PDFKit/user interaction has changed native
        // view presentation. An unchanged attach must read/sync state, not write it again.
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        controller.attach(
            view: view,
            document: document,
            url: url,
            requestedPage: nil,
            requestedAnchor: nil
        )

        XCTAssertEqual(view.displayMode, .singlePage)
        XCTAssertFalse(view.displaysPageBreaks)
        controller.detach(view: view)
    }

    @MainActor
    func testEditorLineEndingNormalizationDoesNotCreateFalseDirtyState() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let previous { defaults.set(previous, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let first = folder.appendingPathComponent("windows-line-endings.md")
        let second = folder.appendingPathComponent("second.md")
        let original = "# First\r\n\r\nBody\r\n"
        try Data(original.utf8).write(to: first)
        try "# Second".write(to: second, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(folder))
        model.openNote(first)
        await waitForNote(model, first)

        XCTAssertEqual(model.draft, "# First\n\nBody\n")
        XCTAssertEqual(model.baseline, model.draft)
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(model.confirmLeavingNote(decision: .cancel))

        model.openNote(second, navigationDecision: .cancel)
        await waitForNote(model, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), original)
    }

    @MainActor
    func testMetadataOnlyStampChangeDoesNotBlockSafeSave() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let previous { defaults.set(previous, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let note = folder.appendingPathComponent("metadata.md")
        try "# Original".write(to: note, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(folder))
        model.openNote(note)
        await waitForNote(model, note)

        let loadedStamp = WorkspaceFiles.fileStamp(note)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: note.path)
        let metadataStamp = WorkspaceFiles.fileStamp(note)
        XCTAssertNotEqual(loadedStamp, metadataStamp)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "# Original")

        model.draft = "# Safe local edit"
        model.save()

        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "# Safe local edit")
        XCTAssertFalse(model.message?.contains(
            AppLanguage.current.text("The file changed outside Leafspan. Reopen it before saving to avoid overwriting edits.")
        ) == true)
    }

    @MainActor
    func testIntentHydrationNeverOverridesNewerMarkdownContent() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let previous { defaults.set(previous, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let note = folder.appendingPathComponent("prefetch.md")
        try "# Before prefetch".write(to: note, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(folder))
        model.prefetchFile(note)

        // Race the warmup with a real external replacement. Regardless of which
        // read wins, the fresh file stamp at open time must keep the file authoritative.
        try "# Newer file content".write(to: note, atomically: true, encoding: .utf8)
        model.openNote(note)
        await waitForNote(model, note)

        XCTAssertEqual(model.draft, "# Newer file content")
        XCTAssertEqual(model.baseline, "# Newer file content")
        XCTAssertFalse(model.isDirty)
    }

    func testTypographyThemesChangeLayoutNotOnlyBackgrounds() {
        let profiles = NotesTheme.allCases.map(\.typography)
        XCTAssertEqual(profiles.count, 5)
        XCTAssertEqual(Set(profiles.map(\.bodySize)).count, 5)
        XCTAssertEqual(Set(profiles.map(\.heading1)).count, 5)
        XCTAssertEqual(Set(profiles.map(\.paragraphSpacing)).count, 5)
        XCTAssertEqual(Set(profiles.map(\.lineSpacing)).count, 5)
        XCTAssertEqual(Set(profiles.map(\.pageWidth)).count, 5)
        XCTAssertEqual(Set(profiles.map(\.codeCorner)).count, 5)
        XCTAssertGreaterThan(NotesTheme.warm.typography.paragraphSpacing,
                             NotesTheme.midnight.typography.paragraphSpacing)
        XCTAssertLessThan(NotesTheme.warm.typography.pageWidth,
                          NotesTheme.midnight.typography.pageWidth)
        XCTAssertTrue(profiles.allSatisfy { $0.heading1 > $0.heading2 && $0.heading2 > $0.heading3 })
        XCTAssertTrue(profiles.allSatisfy { $0.bodySize >= 14 && $0.pageWidth >= 600 })
    }

    func testReadingThemesRespectApplicationLightAndDarkAppearance() {
        func luminance(_ color: Color, appearanceName: NSAppearance.Name) -> CGFloat {
            guard let appearance = NSAppearance(named: appearanceName) else {
                XCTFail("Missing appearance \(appearanceName)")
                return 0
            }
            var value: CGFloat = 0
            appearance.performAsCurrentDrawingAppearance {
                guard let resolved = NSColor(color).usingColorSpace(.sRGB) else {
                    XCTFail("Could not resolve theme color")
                    return
                }
                value = 0.2126 * resolved.redComponent
                    + 0.7152 * resolved.greenComponent
                    + 0.0722 * resolved.blueComponent
            }
            return value
        }

        for theme in NotesTheme.allCases {
            let lightCanvas = luminance(theme.canvas, appearanceName: .aqua)
            let darkCanvas = luminance(theme.canvas, appearanceName: .darkAqua)
            let lightInk = luminance(theme.ink, appearanceName: .aqua)
            let darkInk = luminance(theme.ink, appearanceName: .darkAqua)

            XCTAssertGreaterThan(lightCanvas, 0.72, "\(theme) must stay light in Light appearance")
            XCTAssertLessThan(darkCanvas, 0.32, "\(theme) must stay dark in Dark appearance")
            XCTAssertLessThan(lightInk, 0.48, "\(theme) must use readable dark ink in Light appearance")
            XCTAssertGreaterThan(darkInk, 0.62, "\(theme) must use readable light ink in Dark appearance")
        }
    }

    func testMarkdownShortcutMappingUsesOneExplicitModifierContract() {
        XCTAssertEqual(MarkdownShortcut.command(key: "b", modifiers: .command), "bold")
        XCTAssertEqual(MarkdownShortcut.command(key: "i", modifiers: .command), "italic")
        XCTAssertEqual(MarkdownShortcut.command(key: "e", modifiers: .command), "code")
        XCTAssertEqual(MarkdownShortcut.command(key: "k", modifiers: .command), "link")
        XCTAssertEqual(MarkdownShortcut.command(key: "1", modifiers: [.command, .shift]), "h1")
        XCTAssertEqual(MarkdownShortcut.command(key: "8", modifiers: [.command, .shift]), "bullet")
        XCTAssertEqual(MarkdownShortcut.command(key: "9", modifiers: [.command, .shift]), "task")
        XCTAssertNil(MarkdownShortcut.command(key: "b", modifiers: [.command, .option]))
        XCTAssertNil(MarkdownShortcut.command(key: "x", modifiers: .command))
    }

    func testApplicationAppearanceAndLanguagePreferencesAreIndependent() {
        XCTAssertEqual(AppAppearance.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(AppAppearance.restored("unknown"), .system)
        XCTAssertNil(AppAppearance.system.colorScheme)
        XCTAssertEqual(AppAppearance.light.colorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.colorScheme, .dark)

        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), ["system", "zh-Hans", "en"])
        XCTAssertEqual(AppLanguage.restored("unknown"), .system)
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Search"), "搜索")
        XCTAssertEqual(AppLanguage.english.text("Search"), "Search")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Markdown"), "Markdown")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("On"), "开启")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Off"), "关闭")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Lists and Document Outline"), "列表与文档大纲")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("List presentation"), "列表显示方式")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Side Pane"), "侧边栏")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Large Sheet"), "大尺寸弹窗")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Document Outline"), "文档大纲")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Links and related notes"), "链接与相关笔记")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Linked notes for this PDF"), "查看关联到此 PDF 的笔记")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Add to Favorites"), "添加到收藏")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Remove from Favorites"), "从收藏中移除")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("File actions and workspace options"), "文件操作与工作区选项")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Close"), "关闭")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("New Note"), "新建笔记")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Saving"), "正在保存")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Toggle branch"), "展开／折叠分支")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Preparing mind map…"), "正在准备思维导图…")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Reveal selected node in Markdown"), "在 Markdown 中定位所选节点")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Selected"), "已选择")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Show in Markdown"), "在 Markdown 中显示")
    }

    func testReadingThemeDefaultsAndParsedPreviewCacheIdentity() {
        XCTAssertEqual(NotesTheme.allCases.map(\.rawValue),
                       ["system", "paper", "warm", "midnight", "graphite"])
        XCTAssertEqual(NotesTheme.restored("nonexistent"), .system)
        XCTAssertEqual(NotesTheme.restored("warm"), .warm)
        XCTAssertEqual(NotesTheme.restored("graphite"), .graphite)
        XCTAssertEqual(NotesTheme.graphite.readingFont, .default)

        let markdown = "# 标题\n\nSome **bold** Markdown and a [link](x.md)."
        let blocks = MarkdownPreviewParsing.prepare(markdown, match: nil)
        let cache = MarkdownPreviewSnapshot(
            identity: "/vault/one.md", revision: 7,
            matchID: nil, sections: blocks
        )
        XCTAssertEqual(cache.sections.count, 1)
        XCTAssertTrue(cache.matches(identity: "/vault/one.md", revision: 7, matchID: nil))
        // Theme and Edit/Split/Read mode intentionally do NOT participate in parse identity.
        for _ in NotesTheme.allCases {
            XCTAssertTrue(cache.matches(identity: "/vault/one.md", revision: 7, matchID: nil))
        }
        XCTAssertFalse(cache.matches(identity: "/vault/two.md", revision: 7, matchID: nil))
        XCTAssertFalse(cache.matches(identity: "/vault/one.md", revision: 8, matchID: nil))
        XCTAssertFalse(cache.matches(identity: "/vault/one.md", revision: 7, matchID: "new-hit"))
    }

    func testLargeMarkdownUsesLazySectionsWithoutBreakingDocumentReferences() {
        let section = "## Section\n\n" + String(repeating: "A normal paragraph with **bold** text.\n\n", count: 65)
        let source = "# Introduction\n\n" + String(repeating: section, count: 12)
        XCTAssertGreaterThan(source.utf8.count, 12_000)

        let parts = MarkdownPreviewParsing.prepare(source, match: nil)
        XCTAssertGreaterThan(parts.count, 10, "Large documents should render in lazy section-sized views.")
        XCTAssertEqual(parts.first?.source.heading, "Introduction")
        XCTAssertTrue(parts[1].source.markdown.hasPrefix("## Section"))
        XCTAssertTrue(parts.last?.source.markdown.contains("bold") == true)

        // Cross-section link reference definitions and footnotes still require
        // a single document parse so their destinations remain resolvable.
        let withReference = source + "\n[reference]: https://example.com\n"
        XCTAssertEqual(MarkdownPreviewParsing.prepare(withReference, match: nil).count, 1)
        let footnote = source + "\n[^1]: A shared footnote.\n"
        XCTAssertEqual(MarkdownPreviewParsing.prepare(footnote, match: nil).count, 1)
    }

    func testChineseSearchDecoding() throws {
        let json = Data("""
        [{"documentId":"doc_test","chunkId":"chunk_test","title":"中文学习.md",
          "uri":"/tmp/vault/中文学习.md","sourceType":"local",
          "snippet":"测试中文搜索","score":0.9,"headingPath":"一级标题"}]
        """.utf8)
        let results = try JSONDecoder().decode([SearchHit].self, from: json)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "中文学习.md")
        XCTAssertEqual(results[0].id, "chunk_test")
    }

    func testSafeNoteNames() throws {
        XCTAssertEqual(WorkspaceFiles.safeNewNoteName("中文"), "中文.md")
        XCTAssertEqual(WorkspaceFiles.safeNewNoteName("test.md"), "test.md")
        XCTAssertNil(WorkspaceFiles.safeNewNoteName("../outside"))
        XCTAssertNil(WorkspaceFiles.safeNewNoteName(".private"))
        XCTAssertNil(WorkspaceFiles.safeNewNoteName("/absolute"))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try Data().write(to: folder.appendingPathComponent("Book · p.4.md"))
        XCTAssertEqual(
            WorkspaceFiles.nextAvailableNoteName(basedOn: "Book · p.4", in: folder),
            "Book · p.4 2.md"
        )
        XCTAssertEqual(WorkspaceFiles.nextUntitledName(in: folder), "Untitled.md")
    }

    func testPathContainmentAndSymlinkEscape() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let notes = sandbox.appendingPathComponent("notes")
        let sibling = sandbox.appendingPathComponent("notes-private")
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        XCTAssertTrue(WorkspaceFiles.contains(notes.appendingPathComponent("中文.md"), in: notes))
        XCTAssertFalse(WorkspaceFiles.contains(sibling.appendingPathComponent("secret.md"), in: notes))

        try fm.createSymbolicLink(at: notes.appendingPathComponent("private"),
                                  withDestinationURL: sibling)
        XCTAssertFalse(WorkspaceFiles.contains(notes.appendingPathComponent("private/secret.md"), in: notes))
    }

    func testMixedFileTreeAndHiddenFiles() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = base.appendingPathComponent("分组")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try "# Root".write(to: base.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Sub".write(to: nested.appendingPathComponent("中文.md"), atomically: true, encoding: .utf8)
        try "hidden".write(to: base.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        try "asset".write(to: nested.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)
        try "%PDF-1.4\n".write(to: base.appendingPathComponent("Guide.pdf"), atomically: true, encoding: .utf8)
        try "hidden".write(to: base.appendingPathComponent(".private.pdf"), atomically: true, encoding: .utf8)
        let result = WorkspaceFiles.tree(in: base)
        XCTAssertEqual(result.map { $0.name }, ["分组", "Guide.pdf", "README"])
        XCTAssertEqual(result.first?.children?.map { $0.name }, ["image.png", "中文"])
        XCTAssertTrue(result[1].isPDF)
        XCTAssertFalse(result[1].isMarkdown)
        XCTAssertTrue(result[2].isMarkdown)
        XCTAssertEqual(result.first?.children?.first?.iconName, "doc")

        let shallow = WorkspaceFiles.tree(in: base, recursive: false)
        XCTAssertEqual(shallow.map { $0.name }, ["分组", "Guide.pdf", "README"])
        XCTAssertEqual(shallow.first?.children?.count, 0,
                       "Progressive loading should expose top-level folders before recursive scanning.")
    }

    func testLinkCandidateIndexPrecomputesMarkdownFilesAndBasenames() {
        let root = URL(fileURLWithPath: "/tmp/pks-link-candidates")
        let a = root.appendingPathComponent("A/Same.md")
        let b = root.appendingPathComponent("B/Same.markdown")
        let pdf = root.appendingPathComponent("Book.pdf")
        let files = [
            NoteItem(url: a, children: nil),
            NoteItem(url: b, children: nil),
            NoteItem(url: pdf, children: nil)
        ]

        let index = WorkspaceLinkCandidateIndex(
            markdownFiles: WorkspaceBacklinks.markdownFiles(files)
        )
        XCTAssertEqual(Set(index.markdownFiles), Set([a.standardizedFileURL, b.standardizedFileURL]))
        XCTAssertEqual(Set(index.byBasename["Same"] ?? []), Set([a.standardizedFileURL, b.standardizedFileURL]))
        XCTAssertNil(index.byBasename["Book"])
    }

    func testFlatVaultScanAndLoadedSubtreeReplacement() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let nested = parent.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let rootNote = root.appendingPathComponent("Root.md")
        let parentNote = parent.appendingPathComponent("Parent.md")
        let deepNote = nested.appendingPathComponent("Deep.md")
        try "# Root".write(to: rootNote, atomically: true, encoding: .utf8)
        try "# Parent".write(to: parentNote, atomically: true, encoding: .utf8)
        try "# Deep".write(to: deepNote, atomically: true, encoding: .utf8)
        try "hidden".write(
            to: nested.appendingPathComponent(".hidden.md"),
            atomically: true,
            encoding: .utf8
        )

        let flat = WorkspaceFiles.flatFiles(in: root)
        XCTAssertEqual(Set(flat.map { $0.url.standardizedFileURL }), Set([
            rootNote.standardizedFileURL,
            parentNote.standardizedFileURL,
            deepNote.standardizedFileURL
        ]))
        XCTAssertFalse(flat.contains(where: \.isFolder))

        var visited: [URL] = []
        WorkspaceFiles.visitFlatFiles(in: root) { visited.append($0.standardizedFileURL) }
        XCTAssertEqual(
            Set(visited),
            Set(flat.map { $0.url.standardizedFileURL }),
            "The shared flat visitor must preserve the compatibility flatFiles scan."
        )

        let shallowRoot = WorkspaceFiles.tree(in: root, recursive: false)
        let parentChildren = WorkspaceFiles.tree(in: parent, recursive: false)
        let withParent = WorkspaceFiles.replacingChildren(
            in: shallowRoot,
            folder: parent,
            with: parentChildren
        )
        let loadedParent = try XCTUnwrap(withParent.first(where: { $0.url == parent }))
        XCTAssertEqual(loadedParent.children?.map(\.name), ["Nested", "Parent"])
        XCTAssertEqual(
            loadedParent.children?.first(where: { $0.url == nested })?.children?.count,
            0,
            "Loading Parent must not recursively load Nested."
        )

        let nestedChildren = WorkspaceFiles.tree(in: nested, recursive: false)
        let withNested = WorkspaceFiles.replacingChildren(
            in: withParent,
            folder: nested,
            with: nestedChildren
        )
        let reloadedParent = try XCTUnwrap(withNested.first(where: { $0.url == parent }))
        let loadedNested = try XCTUnwrap(reloadedParent.children?.first(where: { $0.url == nested }))
        XCTAssertEqual(loadedNested.children?.map(\.name), ["Deep"])
    }

    func testShallowReconciliationPreservesLoadedDescendants() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let nested = parent.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let deep = nested.appendingPathComponent("Deep.md")
        try "# Deep".write(to: deep, atomically: true, encoding: .utf8)

        let shallowRoot = WorkspaceFiles.tree(in: root, recursive: false)
        let withParent = WorkspaceFiles.replacingChildren(
            in: shallowRoot,
            folder: parent,
            with: WorkspaceFiles.tree(in: parent, recursive: false)
        )
        let fullyLoaded = WorkspaceFiles.replacingChildren(
            in: withParent,
            folder: nested,
            with: WorkspaceFiles.tree(in: nested, recursive: false)
        )

        let newRoot = root.appendingPathComponent("New.md")
        try "# New".write(to: newRoot, atomically: true, encoding: .utf8)
        let reconciled = WorkspaceFiles.preservingLoadedChildren(
            WorkspaceFiles.tree(in: root, recursive: false),
            from: fullyLoaded
        )

        XCTAssertNotNil(reconciled.first(where: { $0.url == newRoot }))
        let loadedParent = try XCTUnwrap(reconciled.first(where: { $0.url == parent }))
        let loadedNested = try XCTUnwrap(
            loadedParent.children?.first(where: { $0.url == nested })
        )
        XCTAssertEqual(loadedNested.children?.map(\.url), [deep])
    }

    @MainActor
    func testLocalMutationKeepsLoadedTreeAndLazilyInvalidatesGlobalIndex() async throws {
        func find(_ url: URL, in items: [NoteItem]) -> NoteItem? {
            for item in items {
                if item.url.standardizedFileURL == url.standardizedFileURL { return item }
                if let children = item.children, let match = find(url, in: children) {
                    return match
                }
            }
            return nil
        }

        let defaults = UserDefaults.standard
        let priorWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let priorWorkspace { defaults.set(priorWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let nested = parent.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let deep = nested.appendingPathComponent("Deep.md")
        try "# Deep".write(to: deep, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        for _ in 0..<200 {
            if !model.loadingFiles { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.loadExpandedFolder(parent)
        for _ in 0..<200 {
            if find(nested, in: model.files) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.loadExpandedFolder(nested)
        for _ in 0..<200 {
            if find(deep, in: model.files) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        model.prepareGlobalFileIndex()
        for _ in 0..<300 {
            if model.globalFileIndexReady { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.globalFileIndexReady)

        let created = try XCTUnwrap(model.newNote(named: "Root New", in: root))
        for _ in 0..<200 {
            if find(created, in: model.files) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertNotNil(find(created, in: model.files))
        XCTAssertNotNil(find(deep, in: model.files),
                        "A root-level mutation must not discard loaded descendants.")
        XCTAssertFalse(model.globalFileIndexReady,
                       "The complete index should become stale, not rebuild eagerly.")

        model.prepareGlobalFileIndex()
        for _ in 0..<300 {
            if model.globalFileIndexReady { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.globalFileIndexReady)
        XCTAssertTrue(model.globalFiles.contains { $0.url.standardizedFileURL == created.standardizedFileURL })
    }

    @MainActor
    func testBatchExpandedFolderSchedulerLoadsManyPathsWithoutRepeatedRefeed() async throws {
        let defaults = UserDefaults.standard
        let priorWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let priorWorkspace { defaults.set(priorWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var expanded: Set<String> = []
        var expectedNotes: [URL] = []
        for index in 0..<24 {
            let folder = root.appendingPathComponent(String(format: "Folder-%02d", index), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let note = folder.appendingPathComponent("Note.md")
            try "# \(index)".write(to: note, atomically: true, encoding: .utf8)
            expanded.insert(folder.path)
            expectedNotes.append(note.standardizedFileURL)
        }

        func flatten(_ items: [NoteItem]) -> Set<URL> {
            var urls: Set<URL> = []
            func visit(_ nodes: [NoteItem]) {
                for item in nodes {
                    if let children = item.children { visit(children) }
                    else { urls.insert(item.url.standardizedFileURL) }
                }
            }
            visit(items)
            return urls
        }

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        for _ in 0..<200 where model.loadingFiles {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.loadExpandedFolders(expanded)

        for _ in 0..<600 {
            let loaded = flatten(model.files)
            if expectedNotes.allSatisfy(loaded.contains) { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let loaded = flatten(model.files)
        XCTAssertTrue(expectedNotes.allSatisfy(loaded.contains))
    }

    @MainActor
    func testCurrentFilePathPriorityWalksAncestorsBeforeUnrelatedExpandedFolders() {
        let root = URL(fileURLWithPath: "/tmp/PKS-Vault", isDirectory: true)
        let level1 = root.appendingPathComponent("Course", isDirectory: true)
        let level2 = level1.appendingPathComponent("Term", isDirectory: true)
        let leaf = level2.appendingPathComponent("Week", isDirectory: true)
        let unrelated = root.appendingPathComponent("Archive", isDirectory: true)

        var pending: Set<String> = [
            unrelated.path,
            leaf.path,
            level2.path,
            level1.path
        ]

        XCTAssertEqual(
            NotesModel.preferredPendingFolder(in: pending, toward: leaf.path),
            level1.path
        )
        pending.remove(level1.path)
        XCTAssertEqual(
            NotesModel.preferredPendingFolder(in: pending, toward: leaf.path),
            level2.path
        )
        pending.remove(level2.path)
        XCTAssertEqual(
            NotesModel.preferredPendingFolder(in: pending, toward: leaf.path),
            leaf.path
        )
        pending.remove(leaf.path)
        XCTAssertNil(NotesModel.preferredPendingFolder(in: pending, toward: leaf.path))
    }

    @MainActor
    func testLargeWorkspaceInitialRefreshStaysShallow() async throws {
        let defaults = UserDefaults.standard
        let priorWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        let priorBookmark = defaults.data(forKey: "PKSNotesWorkspaceBookmark")
        defaults.removeObject(forKey: "PKSNotesWorkspace")
        defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark")
        defer {
            if let priorWorkspace { defaults.set(priorWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let priorBookmark { defaults.set(priorBookmark, forKey: "PKSNotesWorkspaceBookmark") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let folderCount = 1_000
        for index in 0..<folderCount {
            let folder = root.appendingPathComponent(String(format: "Folder-%04d", index), isDirectory: true)
            let nested = folder.appendingPathComponent("Nested", isDirectory: true)
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            try "# Deep".write(
                to: nested.appendingPathComponent("Deep.md"),
                atomically: true,
                encoding: .utf8
            )
        }

        let model = NotesModel()
        let clock = ContinuousClock()
        let started = clock.now
        XCTAssertTrue(model.openWorkspace(root))
        for _ in 0..<1_000 where model.loadingFiles {
            try await Task.sleep(for: .milliseconds(5))
        }
        let elapsed = started.duration(to: clock.now)

        XCTAssertFalse(model.loadingFiles)
        XCTAssertEqual(model.files.count, folderCount)
        XCTAssertTrue(model.files.allSatisfy { $0.isFolder && $0.children?.isEmpty == true })
        XCTAssertFalse(model.globalFileIndexReady)
        XCTAssertTrue(model.globalFiles.isEmpty)
        XCTAssertLessThan(elapsed, .seconds(5), "Initial shallow refresh should not scale with nested file count.")
        print("PKS_PERF large_workspace_shallow_root_1000=\(elapsed)")
    }

    @MainActor
    func testWorkspaceRefreshAndFolderExpansionAreLazy() async throws {
        let defaults = UserDefaults.standard
        let priorWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let priorWorkspace { defaults.set(priorWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let nested = parent.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let rootNote = root.appendingPathComponent("Root.md")
        let parentNote = parent.appendingPathComponent("Parent.md")
        let deepNote = nested.appendingPathComponent("Deep.md")
        try "# Root".write(to: rootNote, atomically: true, encoding: .utf8)
        try "# Parent".write(to: parentNote, atomically: true, encoding: .utf8)
        try "# Deep".write(to: deepNote, atomically: true, encoding: .utf8)

        func item(_ url: URL, in items: [NoteItem]) -> NoteItem? {
            for candidate in items {
                if candidate.url.standardizedFileURL == url.standardizedFileURL { return candidate }
                if let children = candidate.children, let found = item(url, in: children) {
                    return found
                }
            }
            return nil
        }

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        for _ in 0..<200 where model.loadingFiles {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.loadingFiles)
        XCTAssertFalse(model.globalFileIndexReady)
        XCTAssertTrue(model.globalFiles.isEmpty)
        XCTAssertEqual(item(parent, in: model.files)?.children?.count, 0)
        XCTAssertNil(item(deepNote, in: model.files))

        model.loadExpandedFolder(parent)
        for _ in 0..<200 {
            if item(parentNote, in: model.files) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(item(parentNote, in: model.files))
        XCTAssertEqual(item(nested, in: model.files)?.children?.count, 0)
        XCTAssertNil(item(deepNote, in: model.files))

        model.loadExpandedFolders([parent.path, nested.path])
        for _ in 0..<200 {
            if item(deepNote, in: model.files) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(item(deepNote, in: model.files))
        XCTAssertFalse(model.globalFileIndexReady)
    }

    @MainActor
    func testGlobalVaultIndexAndBacklinksAreOnDemandAndComplete() async throws {
        let defaults = UserDefaults.standard
        let priorWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let priorWorkspace { defaults.set(priorWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let deepFolder = root.appendingPathComponent("Archive/Deep", isDirectory: true)
        try fm.createDirectory(at: deepFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let target = root.appendingPathComponent("Target.md")
        let deep = deepFolder.appendingPathComponent("Source.md")
        let deepPDF = deepFolder.appendingPathComponent("Source.pdf")
        try "# Target".write(to: target, atomically: true, encoding: .utf8)
        try "[Target](/Target.md)".write(to: deep, atomically: true, encoding: .utf8)
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: deepPDF)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        for _ in 0..<200 where model.loadingFiles {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.globalFileIndexReady)
        XCTAssertFalse(NoteTreePresentation.openableFiles(model.files).contains { $0.url == deep })

        model.prepareGlobalFileIndex()
        for _ in 0..<300 where !model.globalFileIndexReady {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.globalFileIndexReady)
        XCTAssertTrue(model.globalFiles.contains { $0.url.standardizedFileURL == deep.standardizedFileURL })
        let sourceMatches = NoteTreePresentation.quickOpen(model.globalQuickOpenEntries, query: "source")
        XCTAssertTrue(sourceMatches.contains { $0.url.standardizedFileURL == deep.standardizedFileURL })
        XCTAssertTrue(sourceMatches.contains { $0.url.standardizedFileURL == deepPDF.standardizedFileURL })

        // External/iCloud mutations do not pass through NotesModel's writer. The
        // cached snapshot stays unchanged until Quick Open explicitly requests its
        // one-shot fallback refresh after a zero-result query.
        let latePDF = deepFolder.appendingPathComponent("Late Arrival.pdf")
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: latePDF)
        XCTAssertTrue(NoteTreePresentation.quickOpen(model.globalQuickOpenEntries, query: "late arrival").isEmpty)
        model.refreshGlobalFileIndex()
        for _ in 0..<300 where !model.globalFileIndexReady {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.globalFileIndexReady)
        XCTAssertEqual(
            NoteTreePresentation.quickOpen(model.globalQuickOpenEntries, query: "late arrival").first?.url.standardizedFileURL,
            latePDF.standardizedFileURL
        )

        // A new model proves backlinks themselves can trigger the complete scan
        // even when the sidebar still contains only shallow root entries.
        let backlinkModel = NotesModel()
        XCTAssertTrue(backlinkModel.openWorkspace(root))
        for _ in 0..<200 where backlinkModel.loadingFiles {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(backlinkModel.globalFileIndexReady)
        backlinkModel.openNote(target)
        await waitForNote(backlinkModel, target)
        backlinkModel.loadBacklinks()
        for _ in 0..<400 where backlinkModel.loadingBacklinks {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(backlinkModel.globalFileIndexReady)
        XCTAssertEqual(backlinkModel.backlinks.map { $0.source.standardizedFileURL }, [deep.standardizedFileURL])
    }

    @MainActor
    func testRestoringLastNoteRequiresExistingFileInSameWorkspace() async throws {
        let defaults = UserDefaults.standard
        let previousWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        let previousNote = defaults.string(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let previousWorkspace { defaults.set(previousWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousNote { defaults.set(previousNote, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folderA = temp.appendingPathComponent("A", isDirectory: true)
        let folderB = temp.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let note = folderA.appendingPathComponent("笔记.md")
        try "# Original".write(to: note, atomically: true, encoding: .utf8)

        defaults.set(note.path, forKey: "PKSNotesLastOpenedMarkdown")
        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(folderA))
        await waitForNote(model, note)
        XCTAssertEqual(model.draft, "# Original")
        XCTAssertEqual(defaults.string(forKey: "PKSNotesLastOpenedMarkdown"), note.path)

        // Do not open the same basename from another vault; stay empty instead.
        XCTAssertTrue(model.openWorkspace(folderB))
        XCTAssertNil(model.selected)
        XCTAssertFalse(model.loadingNote)

        // A missing file cannot become the active note on restore.
        let missing = folderA.appendingPathComponent("deleted.md")
        defaults.set(missing.path, forKey: "PKSNotesLastOpenedMarkdown")
        XCTAssertTrue(model.openWorkspace(folderA))
        XCTAssertNil(model.selected)
        XCTAssertFalse(model.loadingNote)
        XCTAssertNil(defaults.string(forKey: "PKSNotesLastOpenedMarkdown"))
        XCTAssertEqual(
            model.message,
            AppLanguage.current.text("Last opened note is no longer available. Choose another note.")
        )
    }

    @MainActor
    func testAutomaticRestoreFailureReportsRetryAndExplicitOpenStillReportsError() async throws {
        let defaults = UserDefaults.standard
        let previousWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        let previousNote = defaults.string(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let previousWorkspace { defaults.set(previousWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousNote { defaults.set(previousNote, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let invalid = folder.appendingPathComponent("dataless-like.md")
        try Data([0xFF, 0xFE, 0xFD]).write(to: invalid)
        defaults.set(invalid.path, forKey: "PKSNotesLastOpenedMarkdown")

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(folder))
        for _ in 0..<100 where model.loadingNote {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.selected)
        XCTAssertFalse(model.loadingNote)
        XCTAssertEqual(model.message,
                       AppLanguage.current.text("Could not reopen the last note. Select it again to retry."))
        XCTAssertEqual(defaults.string(forKey: "PKSNotesLastOpenedMarkdown"), invalid.path)

        model.openNote(invalid)
        for _ in 0..<100 where model.loadingNote {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.selected)
        XCTAssertTrue(model.message?.contains(AppLanguage.current.text("Cannot open the note")) == true)
    }

    func testCanonicalWikiTargetEscapesParenthesesForMarkdownDestinations() throws {
        let root = URL(fileURLWithPath: "/tmp/Vault", isDirectory: true)
        let target = root.appendingPathComponent("Research (draft).md")
        XCTAssertEqual(
            WorkspaceFiles.canonicalWikiTarget(for: target, in: root),
            "/Research%20%28draft%29"
        )
    }

    func testCanonicalWikiTargetIsRootRelativeEncodedAndRoundTrips() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Reference Notes", isDirectory: true)
        let target = folder.appendingPathComponent("Design #1.md")
        let source = root.appendingPathComponent("Current.md")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)
        try "# Current".write(to: source, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: root) }

        let wikiTarget = try XCTUnwrap(WorkspaceFiles.canonicalWikiTarget(for: target, in: root))
        XCTAssertEqual(wikiTarget, "/Reference%20Notes/Design%20%231")
        XCTAssertEqual(
            WorkspaceFiles.resolveKnowledgeTarget(wikiTarget, from: source, in: root),
            target.standardizedFileURL
        )

        try "# Overview\n## Café & 数据\n## Duplicate\n## duplicate".write(
            to: target,
            atomically: true,
            encoding: .utf8
        )
        let sectionTarget = try XCTUnwrap(
            WorkspaceFiles.canonicalWikiTarget(for: target, in: root, heading: "Café & 数据")
        )
        XCTAssertEqual(
            sectionTarget,
            "/Reference%20Notes/Design%20%231#Caf%C3%A9%20&%20%E6%95%B0%E6%8D%AE"
        )
        XCTAssertEqual(WorkspaceFiles.knowledgeFragment(in: sectionTarget), "Café & 数据")
        XCTAssertEqual(
            WorkspaceFiles.resolveKnowledgeTarget(sectionTarget, from: source, in: root),
            target.standardizedFileURL
        )
        XCTAssertEqual(
            WorkspaceFiles.linkableMarkdownHeadings(at: target, in: root)?.map(\.title),
            ["Overview", "Café & 数据"]
        )
    }

    @MainActor
    func testMarkdownLinkHeadingFragmentProducesPreviewAnchorRequest() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let previous { defaults.set(previous, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let current = root.appendingPathComponent("Current.md")
        let target = root.appendingPathComponent("Target.md")
        try "# Current".write(to: current, atomically: true, encoding: .utf8)
        try "# Intro\n\n## Details\nBody".write(to: target, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(current)
        await waitForNote(model, current)

        XCTAssertTrue(model.openInternalLink(URL(string: "Target.md#Details")!))
        await waitForNote(model, target)
        let first = try XCTUnwrap(model.markdownAnchorRequest)
        XCTAssertEqual(first.note.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(first.fragment, "Details")

        XCTAssertTrue(model.openKnowledgeLink("#Intro"))
        let second = try XCTUnwrap(model.markdownAnchorRequest)
        XCTAssertEqual(second.note.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(second.fragment, "Intro")
        XCTAssertGreaterThan(second.sequence, first.sequence)
    }

    func testQuickOpenSearchIsDerivedRankedAndIncludesNestedFiles() {
        let root = URL(fileURLWithPath: "/tmp/pks-quickopen")
        let docs = root.appendingPathComponent("Documents")
        let chinese = docs.appendingPathComponent("中文笔记.md")
        let nested = docs.appendingPathComponent("README.md")
        let top = root.appendingPathComponent("Readme Guide.md")
        let pdf = root.appendingPathComponent("Report.pdf")
        let tree = [
            NoteItem(url: docs, children: [
                NoteItem(url: chinese, children: nil),
                NoteItem(url: nested, children: nil)
            ]),
            NoteItem(url: top, children: nil),
            NoteItem(url: pdf, children: nil)
        ]
        let flat = NoteTreePresentation.openableFiles(tree)
        let entries = NoteTreePresentation.quickOpenEntries(tree)
        XCTAssertEqual(flat.count, 4)
        XCTAssertEqual(entries.count, 4)
        XCTAssertFalse(flat.contains { $0.isFolder })
        XCTAssertEqual(NoteTreePresentation.quickOpen(entries, query: "README").map(\.url),
                       [nested, top])
        XCTAssertEqual(NoteTreePresentation.quickOpen(entries, query: "中文").first?.url, chinese)
        XCTAssertEqual(NoteTreePresentation.quickOpen(entries, query: "report").first?.url, pdf)
        XCTAssertEqual(NoteTreePresentation.quickOpen(entries, query: "documents").count, 2)
        XCTAssertEqual(NoteTreePresentation.quickOpen(entries, query: "documents", limit: 1).count, 1)
        XCTAssertTrue(NoteTreePresentation.quickOpen(entries, query: "   ").isEmpty)
        XCTAssertTrue(NoteTreePresentation.quickOpen(entries, query: "impossible").isEmpty)
        XCTAssertEqual(NoteTreePresentation.quickOpen(flat, query: "README").map(\.url),
                       [nested, top], "Compatibility overload must retain ranking.")
    }

    func testQuickOpenPreSortsOnceAndKeepsQueryResultsBounded() {
        let root = URL(fileURLWithPath: "/tmp/pks-quickopen-large")
        let files = (0..<1_000).reversed().map { index in
            NoteItem(
                url: root.appendingPathComponent(String(format: "Note %04d.md", index)),
                children: nil
            )
        }
        let entries = NoteTreePresentation.quickOpenEntries(files)
        XCTAssertEqual(entries.first?.item.name, "Note 0000")
        XCTAssertEqual(entries.last?.item.name, "Note 0999")

        let matches = NoteTreePresentation.quickOpen(entries, query: "note", limit: 24)
        XCTAssertEqual(matches.count, 24)
        XCTAssertEqual(matches.first?.name, "Note 0000")
        XCTAssertEqual(matches.last?.name, "Note 0023")
    }

    func testQuickOpenPrefixRangeKeepsRankingAndDiacriticFolding() {
        let root = URL(fileURLWithPath: "/tmp/pks-quickopen-prefix")
        let files = [
            NoteItem(url: root.appendingPathComponent("Álpha.md"), children: nil),
            NoteItem(url: root.appendingPathComponent("Alpha Notes.md"), children: nil),
            NoteItem(url: root.appendingPathComponent("My Alpha.md"), children: nil),
            NoteItem(url: root.appendingPathComponent("Archive/Alpha Folder/Other.md"), children: nil),
            NoteItem(url: root.appendingPathComponent("Zulu.md"), children: nil)
        ]
        let entries = NoteTreePresentation.quickOpenEntries(files)

        XCTAssertEqual(
            NoteTreePresentation.quickOpen(entries, query: "alpha", limit: 2).map(\.name),
            ["Álpha", "Alpha Notes"],
            "Prefix matches should satisfy the bounded result before substring/path fallback."
        )
        XCTAssertEqual(
            NoteTreePresentation.quickOpen(entries, query: "alpha").map(\.name),
            ["Álpha", "Alpha Notes", "My Alpha", "Other"],
            "Name substring matches must stay ahead of folder-path matches."
        )
        XCTAssertEqual(
            NoteTreePresentation.quickOpen(entries, query: "my alpha").first?.name,
            "My Alpha",
            "Name substring fallback must remain available."
        )
        XCTAssertEqual(
            NoteTreePresentation.quickOpen(entries, query: "alpha folder").first?.name,
            "Other",
            "Folder substring fallback must remain available."
        )
    }

    func testQuickOpenNumericPrefixMatchesOutrankSubstringMatches() {
        let root = URL(fileURLWithPath: "/tmp/pks-quickopen-natural-prefix")
        let substring = NoteItem(
            url: root.appendingPathComponent("Note 2 - Note 1.md"),
            children: nil
        )
        let prefix = NoteItem(
            url: root.appendingPathComponent("Note 10.md"),
            children: nil
        )
        let entries = NoteTreePresentation.quickOpenEntries([substring, prefix])

        XCTAssertEqual(
            NoteTreePresentation.quickOpen(entries, query: "note 1", limit: 1).map(\.name),
            ["Note 10"],
            "A literal prefix match must outrank a substring match even when natural numeric collation puts the substring first."
        )
    }

    func testQuickOpenPreservesNaturalNumericOrderingWithinPrefixMatches() {
        let root = URL(fileURLWithPath: "/tmp/pks-quickopen-natural-order")
        let files = [
            NoteItem(url: root.appendingPathComponent("Note 10.md"), children: nil),
            NoteItem(url: root.appendingPathComponent("Note 2.md"), children: nil)
        ]
        let entries = NoteTreePresentation.quickOpenEntries(files)

        XCTAssertEqual(
            NoteTreePresentation.quickOpen(entries, query: "note").map(\.name),
            ["Note 2", "Note 10"],
            "Quick Open should keep Finder-style natural numeric ordering within the same match rank."
        )
    }

    func testQuickOpenLocalSeedIncludesDeepKnownNotesWithoutDuplicates() {
        let root = URL(fileURLWithPath: "/tmp/pks-quickopen-seed")
        let visible = root.appendingPathComponent("Visible.md")
        let deepRecent = root.appendingPathComponent("Archive/2026/Deep Recent.md")
        let tree = [NoteItem(url: visible, children: nil)]

        let entries = NoteTreePresentation.quickOpenEntries(
            tree,
            prioritizedFiles: [deepRecent, visible]
        )

        XCTAssertEqual(entries.count, 2, "Known navigation URLs must not duplicate loaded tree items.")
        XCTAssertEqual(
            NoteTreePresentation.quickOpen(entries, query: "deep recent").first?.url,
            deepRecent.standardizedFileURL,
            "A deep recent/favorite note should be searchable before its folder is expanded."
        )
    }

    func testFolderExpansionShowsOnlyVisibleDescendants() {
        let root = URL(fileURLWithPath: "/tmp/pks-ui-test")
        let parent = root.appendingPathComponent("Projects", isDirectory: true)
        let folder = parent.appendingPathComponent("Ideas", isDirectory: true)
        let note = folder.appendingPathComponent("draft.md")
        let tree = [
            NoteItem(url: parent, children: [
                NoteItem(url: folder, children: [NoteItem(url: note, children: nil)])
            ]),
            NoteItem(url: root.appendingPathComponent("README.md"), children: nil)
        ]
        XCTAssertEqual(NoteTreePresentation.visibleRows(tree, expandedPaths: []).map(\.depth), [0, 0])
        XCTAssertEqual(NoteTreePresentation.visibleRows(tree, expandedPaths: [parent.path]).map(\.depth), [0, 1, 0])
        XCTAssertEqual(NoteTreePresentation.visibleRows(tree, expandedPaths: [parent.path, folder.path]).map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(NoteTreePresentation.ancestorPaths(for: note, in: root), [parent.path, folder.path])
    }

    func testKeyboardTreeNavigationHonorsVisibleRowsAndParentDisclosure() {
        let root = URL(fileURLWithPath: "/tmp/pks-nav-test")
        let folder = root.appendingPathComponent("Projects")
        let subfolder = folder.appendingPathComponent("Nested")
        let file = subfolder.appendingPathComponent("note.md")
        let sibling = root.appendingPathComponent("Root.md")
        let tree = [
            NoteItem(url: folder, children: [
                NoteItem(url: subfolder, children: [NoteItem(url: file, children: nil)])
            ]),
            NoteItem(url: sibling, children: nil)
        ]
        let collapsed = NoteTreePresentation.visibleRows(tree, expandedPaths: [])
        XCTAssertEqual(NoteTreePresentation.navigate(.down, rows: collapsed,
                                                      focusedPath: nil, expandedPaths: [])?.path, folder.path)
        let expandedParent = NoteTreePresentation.navigate(.right, rows: collapsed,
                                                           focusedPath: folder.path, expandedPaths: [])
        XCTAssertEqual(expandedParent?.expanded, [folder.path])
        let rows = NoteTreePresentation.visibleRows(tree, expandedPaths: [folder.path])
        XCTAssertEqual(NoteTreePresentation.navigate(.right, rows: rows, focusedPath: folder.path,
                                                      expandedPaths: [folder.path])?.path, subfolder.path)
        XCTAssertEqual(NoteTreePresentation.navigate(.left, rows: rows, focusedPath: subfolder.path,
                                                      expandedPaths: [folder.path])?.path, folder.path)
        XCTAssertEqual(NoteTreePresentation.navigate(.down, rows: rows, focusedPath: subfolder.path,
                                                      expandedPaths: [folder.path])?.path, sibling.path)
        XCTAssertEqual(NoteTreePresentation.navigate(.up, rows: rows, focusedPath: folder.path,
                                                      expandedPaths: [folder.path])?.path, folder.path)
        XCTAssertEqual(NoteTreePresentation.navigate(.left, rows: rows, focusedPath: folder.path,
                                                      expandedPaths: [folder.path])?.expanded, [])
    }

    func testEmptyFolderRemainsNavigable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let folder = try XCTUnwrap(WorkspaceFiles.tree(in: root).first)
        XCTAssertTrue(folder.isFolder)
        XCTAssertEqual(folder.name, "Empty")
        XCTAssertEqual(folder.children?.count, 0)
    }

    @MainActor
    func testPDFPreviewHonorsUnsavedNoteAndMarkdownReopens() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let note = root.appendingPathComponent("draft.md")
        let pdf = root.appendingPathComponent("manual.pdf")
        let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try "# Original".write(to: note, atomically: true, encoding: .utf8)
        try "%PDF-1.4".write(to: pdf, atomically: true, encoding: .utf8)
        try "%PDF-1.4".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: outside) }

        let model = NotesModel()
        model.openWorkspace(root)
        model.openFile(note)
        await waitForNote(model, note)
        model.draft = "# Unsaved"
        model.openFile(pdf, navigationDecision: .cancel)
        XCTAssertEqual(model.selected, note)
        XCTAssertNil(model.previewPDF)
        model.openFile(outside, navigationDecision: .discard)
        XCTAssertEqual(model.selected, note)
        XCTAssertNil(model.previewPDF)
        model.openFile(pdf, navigationDecision: .discard)
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.previewPDF, pdf)
        XCTAssertFalse(model.isDirty)
        model.openFile(note)
        await waitForNote(model, note)
        XCTAssertNil(model.previewPDF)
        XCTAssertEqual(model.draft, "# Original")
    }

    @MainActor
    func testOneClickNewNoteCreatesBlankEditorAndNeverOverwritesExistingFile() async throws {
        let defaults = UserDefaults.standard
        let previousRoot = defaults.string(forKey: "PKSNotesWorkspace")
        let previousNote = defaults.string(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let previousRoot { defaults.set(previousRoot, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousNote { defaults.set(previousNote, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = folder.appendingPathComponent("中文文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Untitled.md")
        try "# Do not overwrite me".write(to: original, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(folder))
        let first = model.newNote()
        XCTAssertEqual(first?.lastPathComponent, "Untitled 2.md")
        guard let first else { return XCTFail("Expected a new blank note") }
        await waitForNote(model, first)
        XCTAssertEqual(model.selected, first)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "# Do not overwrite me")

        model.draft = "# Direct writing\n\nFirst paragraph"
        for _ in 0..<120 {
            if !model.isDirty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isDirty, "Typing into a one-click note must autosave.")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8),
                       "# Direct writing\n\nFirst paragraph")

        let second = model.newNote()
        XCTAssertEqual(second?.lastPathComponent, "Untitled 3.md")
        guard let second else { return XCTFail("Expected a collision-free second note") }
        await waitForNote(model, second)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "")

        let nested = model.newNote(in: child)
        XCTAssertEqual(nested?.lastPathComponent, "Untitled.md")
        guard let nested else { return XCTFail("Expected a note in the chosen folder") }
        await waitForNote(model, nested)
        XCTAssertEqual(nested.deletingLastPathComponent(), child)

        model.draft = "Unsaved but protected"
        XCTAssertNil(model.newNote(navigationDecision: .cancel))
        XCTAssertEqual(model.draft, "Unsaved but protected")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: child.appendingPathComponent("Untitled 2.md").path
        ))
    }

    @MainActor
    func testCreateFolderStaysInsideWorkspaceAndNeverOverwritesExistingItem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: outside)
        }

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))

        let created = try XCTUnwrap(model.newFolder(named: "Research", in: parent))
        XCTAssertEqual(created, parent.appendingPathComponent("Research", isDirectory: true))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: created.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let sentinel = parent.appendingPathComponent("Existing", isDirectory: true)
        try fm.createDirectory(at: sentinel, withIntermediateDirectories: false)
        XCTAssertNil(model.newFolder(named: "Existing", in: parent))
        XCTAssertTrue(fm.fileExists(atPath: sentinel.path))

        XCTAssertNil(model.newFolder(named: "../Escape", in: parent))
        XCTAssertNil(model.newFolder(named: ".hidden", in: parent))
        XCTAssertNil(model.newFolder(named: "Outside", in: outside))
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("Outside").path))
    }

    @MainActor
    func testInactiveNewNoteCreationKeepsCurrentMarkdownAuthority() async throws {
        let defaults = UserDefaults.standard
        let previousRoot = defaults.string(forKey: "PKSNotesWorkspace")
        let previousNote = defaults.string(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let previousRoot { defaults.set(previousRoot, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousNote { defaults.set(previousNote, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let current = root.appendingPathComponent("Map.md")
        try "# Map\n- Topic".write(to: current, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(current)
        await waitForNote(model, current)

        let created = try XCTUnwrap(model.newNote(
            named: "Topic.md",
            in: root,
            initialContent: "# Topic\n\n",
            activateAfterCreation: false
        ))

        XCTAssertEqual(model.selected?.standardizedFileURL, current.standardizedFileURL)
        XCTAssertEqual(model.draft, "# Map\n- Topic")
        XCTAssertFalse(model.loadingNote)
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), "# Topic\n\n")

        let target = try XCTUnwrap(WorkspaceFiles.canonicalWikiTarget(for: created, in: root))
        let updated = try XCTUnwrap(MindMapOutline.appendWikiLink(
            in: model.draft,
            nodeID: 1,
            target: target,
            label: "Topic"
        ))
        model.draft = updated
        model.save()

        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(
            try String(contentsOf: current, encoding: .utf8),
            "# Map\n- Topic [[/Topic|Topic]]"
        )
        XCTAssertEqual(model.selected?.standardizedFileURL, current.standardizedFileURL)
    }

    @MainActor
    func testRenameAndTrashPreserveOriginalDataAndCurrentNoteSafety() async throws {
        let defaults = UserDefaults.standard
        let oldVault = defaults.string(forKey: "PKSNotesWorkspace")
        let oldNote = defaults.string(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let oldVault { defaults.set(oldVault, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let oldNote { defaults.set(oldNote, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }
        let fm = FileManager.default
        let vault = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        let original = vault.appendingPathComponent("First.md")
        let renamed = vault.appendingPathComponent("Renamed.md")
        let other = vault.appendingPathComponent("Taken.md")
        try "# Initial".write(to: original, atomically: true, encoding: .utf8)
        try "# Other".write(to: other, atomically: true, encoding: .utf8)
        var trashed: URL?
        defer {
            if let trashed, fm.fileExists(atPath: trashed.path) {
                try? fm.moveItem(at: trashed, to: renamed)
            }
            try? fm.removeItem(at: vault)
        }
        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(vault))
        model.openNote(original)
        await waitForNote(model, original)

        model.draft = "# Changes saved before rename"
        let collisionRename = await model.renameItem(original, to: "Taken")
        XCTAssertNil(collisionRename)
        XCTAssertTrue(fm.fileExists(atPath: original.path))
        XCTAssertEqual(model.draft, "# Changes saved before rename")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "# Other")

        let renameResult = await model.renameItem(original, to: "Renamed")
        XCTAssertEqual(renameResult, renamed)
        await waitForNote(model, renamed)
        XCTAssertEqual(model.selected, renamed)
        XCTAssertEqual(model.draft, "# Changes saved before rename")
        XCTAssertFalse(fm.fileExists(atPath: original.path))
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8),
                       "# Changes saved before rename")

        model.draft = "# Still editing"
        XCTAssertNil(model.moveToTrash(renamed, navigationDecision: .cancel))
        XCTAssertTrue(fm.fileExists(atPath: renamed.path))
        XCTAssertEqual(model.draft, "# Still editing")

        trashed = model.moveToTrash(renamed, navigationDecision: .save)
        XCTAssertNotNil(trashed)
        XCTAssertNil(model.selected)
        XCTAssertFalse(fm.fileExists(atPath: renamed.path))
        XCTAssertEqual(try String(contentsOf: trashed!, encoding: .utf8), "# Still editing")
        XCTAssertNil(UserDefaults.standard.string(forKey: "PKSNotesLastOpenedMarkdown"))
    }

    @MainActor
    func testFolderTrashAndRenameRespectVaultBoundaryAndSymlinks() async throws {
        let defaults = UserDefaults.standard
        let oldVault = defaults.string(forKey: "PKSNotesWorkspace")
        let oldNote = defaults.string(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let oldVault { defaults.set(oldVault, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let oldNote { defaults.set(oldNote, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }
        let fm = FileManager.default
        let vault = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = vault.appendingPathComponent("Docs", isDirectory: true)
        let renamed = vault.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let markdown = folder.appendingPathComponent("Note.md")
        try "# Folder note".write(to: markdown, atomically: true, encoding: .utf8)
        let outsideNote = outside.appendingPathComponent("External.md")
        try "# Not ours".write(to: outsideNote, atomically: true, encoding: .utf8)
        let link = vault.appendingPathComponent("shortcut")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        var trashed: URL?
        defer {
            if let trashed, fm.fileExists(atPath: trashed.path) {
                try? fm.moveItem(at: trashed, to: renamed)
            }
            try? fm.removeItem(at: vault)
            try? fm.removeItem(at: outside)
        }

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(vault))
        XCTAssertFalse(model.canManage(outsideNote))
        XCTAssertFalse(model.canManage(link))
        XCTAssertFalse(model.canManage(vault))
        XCTAssertNil(model.moveToTrash(outsideNote))
        XCTAssertNil(model.moveToTrash(link))
        XCTAssertNil(model.moveToTrash(vault))
        let invalidRename = await model.renameItem(folder, to: "../Escape")
        XCTAssertNil(invalidRename)
        XCTAssertTrue(fm.fileExists(atPath: markdown.path))
        XCTAssertTrue(fm.fileExists(atPath: outsideNote.path))

        model.openNote(markdown)
        await waitForNote(model, markdown)
        let folderRename = await model.renameItem(folder, to: "Archive")
        XCTAssertEqual(folderRename?.path, renamed.path)
        let movedNote = renamed.appendingPathComponent("Note.md")
        await waitForNote(model, movedNote)
        XCTAssertEqual(model.selected, movedNote)
        XCTAssertEqual(try String(contentsOf: movedNote, encoding: .utf8), "# Folder note")
        trashed = model.moveToTrash(renamed)
        XCTAssertNotNil(trashed)
        XCTAssertNil(model.selected)
        XCTAssertFalse(fm.fileExists(atPath: renamed.path))
        XCTAssertTrue(fm.fileExists(atPath: outsideNote.path))
    }

    func testQuickOpenDisplaysWorkspaceRelativeFoldersToDisambiguateCopies() {
        let root = URL(fileURLWithPath: "/tmp/Notes")
        let canonical = root.appendingPathComponent("技术学习/大数据学习路线.md")
        let backup = root.appendingPathComponent("导入暂存/backup/技术学习/大数据学习路线.md")
        XCTAssertEqual(NoteTreePresentation.quickOpenFolder(for: canonical, in: root), "技术学习")
        XCTAssertEqual(NoteTreePresentation.quickOpenFolder(for: backup, in: root),
                       "导入暂存/backup/技术学习")
        XCTAssertEqual(NoteTreePresentation.quickOpenFolder(
            for: root.appendingPathComponent("Home.md"), in: root), "Workspace Root")
        XCTAssertEqual(NoteTreePresentation.quickOpenFolder(for: canonical, in: nil), "技术学习")
    }

    @MainActor
    func testNewNoteUsesCurrentFolderWithoutOverwritingExisting() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("工作")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let existing = folder.appendingPathComponent("已有.md")
        try "# Existing".write(to: existing, atomically: true, encoding: .utf8)

        let model = NotesModel()
        model.openWorkspace(root)
        XCTAssertNil(model.message)
        model.openNote(existing)
        await waitForNote(model, existing)
        model.newNote(named: "新笔记")
        await waitForNote(model, folder.appendingPathComponent("新笔记.md"))
        XCTAssertEqual(model.selected, folder.appendingPathComponent("新笔记.md"))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("新笔记.md").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("新笔记.md").path))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "# Existing")
        // Import uses the one canonical note writer; loadNote cannot race to
        // overwrite a newly assigned draft with a stale blank template.
        let imported = "# Imported map\n- Alpha\n- Beta\n"
        let importedURL = model.newNote(named: "Imported OPML", initialContent: imported)
        XCTAssertEqual(importedURL?.lastPathComponent, "Imported OPML.md")
        if let importedURL {
            await waitForNote(model, importedURL)
            XCTAssertEqual(model.draft, imported)
            XCTAssertEqual(try String(contentsOf: importedURL, encoding: .utf8), imported)
        }
        model.draft = "# Draft not saved yet"
        model.newNote(named: "不能覆盖", navigationDecision: .cancel)
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("不能覆盖.md").path))
        XCTAssertEqual(model.draft, "# Draft not saved yet")
        XCTAssertTrue(model.isDirty)
    }

    @MainActor
    func testNavigationSaveDiscardCancelAndConflict() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let another = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: another, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: another) }
        let first = root.appendingPathComponent("first.md")
        let second = root.appendingPathComponent("second.md")
        try "# First".write(to: first, atomically: true, encoding: .utf8)
        try "# Second".write(to: second, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(first)
        await waitForNote(model, first)
        model.draft = "# Pending"
        model.openNote(first) // No false dirty warning on the selected note.
        XCTAssertEqual(model.draft, "# Pending")
        model.openNote(second, navigationDecision: .cancel)
        XCTAssertEqual(model.selected, first)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# First")
        let savedWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        XCTAssertFalse(model.openWorkspace(another, navigationDecision: .cancel))
        XCTAssertEqual(defaults.string(forKey: "PKSNotesWorkspace"), savedWorkspace)
        XCTAssertEqual(model.root, root.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(model.draft, "# Pending")

        model.openNote(second, navigationDecision: .save)
        await waitForNote(model, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# Pending")
        XCTAssertEqual(model.selected, second)
        model.draft = "# Edited but discarded"
        model.openNote(first, navigationDecision: .discard)
        await waitForNote(model, first)
        XCTAssertEqual(model.selected, first)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "# Second")

        model.draft = "# Conflicting edit"
        try "# External".write(to: first, atomically: true, encoding: .utf8)
        model.openNote(second, navigationDecision: .save)
        XCTAssertEqual(model.selected, first)
        XCTAssertEqual(model.draft, "# Conflicting edit")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# External")
        XCTAssertTrue(model.isDirty)
    }

    @MainActor
    func testCreateNoteInsideSelectedFolderWithSafeCancellation() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let chosen = root.appendingPathComponent("Projects")
        let elsewhere = root.appendingPathComponent("Other")
        let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        let existing = elsewhere.appendingPathComponent("old.md")
        try "# Original".write(to: existing, atomically: true, encoding: .utf8)
        let model = NotesModel()
        model.openWorkspace(root)
        model.openNote(existing)
        await waitForNote(model, existing)
        model.draft = "# Unsaved"
        model.newNote(named: "draft", in: chosen, navigationDecision: .cancel)
        XCTAssertFalse(fm.fileExists(atPath: chosen.appendingPathComponent("draft.md").path))
        model.newNote(named: "escape", in: outside, navigationDecision: .discard)
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("escape.md").path))
        XCTAssertEqual(model.draft, "# Unsaved")
        model.newNote(named: "draft", in: chosen, navigationDecision: .discard)
        await waitForNote(model, chosen.appendingPathComponent("draft.md"))
        XCTAssertEqual(model.selected, chosen.appendingPathComponent("draft.md"))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "# Original")
    }

    @MainActor
    func testEditSaveAndExternalModificationConflict() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent("中文.md")
        try "# Original".write(to: file, atomically: true, encoding: .utf8)

        let model = NotesModel()
        model.openWorkspace(folder)
        model.openNote(file)
        await waitForNote(model, file)
        XCTAssertEqual(model.draft, "# Original")
        model.draft = "# First saved edit"
        model.save()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# First saved edit")
        XCTAssertFalse(model.isDirty)

        let mtime = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        model.draft = "# My pending edit"
        try "# Changed externally".write(to: file, atomically: true, encoding: .utf8)
        if let mtime {
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
        model.save()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Changed externally")
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.message?.contains(AppLanguage.current.text("The file changed outside Leafspan. Reopen it before saving to avoid overwriting edits.")) == true)
    }

    func testRelativeMarkdownLinkAndAttachmentResolveInsideWorkspace() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = folder.appendingPathComponent("分组")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let note = folder.appendingPathComponent("中文测试.md")
        let linked = nested.appendingPathComponent("链接.md")
        let attachment = folder.appendingPathComponent("附件/test.png")
        XCTAssertEqual(WorkspaceFiles.resolve(URL(string: "分组/链接.md")!, from: note, in: folder), linked)
        XCTAssertEqual(WorkspaceFiles.resolve(URL(string: "附件/test.png")!, from: note, in: folder), attachment)
        XCTAssertNil(WorkspaceFiles.resolve(URL(string: "../other/私密.md")!, from: note, in: folder))
        XCTAssertNil(WorkspaceFiles.resolve(URL(string: "https://example.org")!, from: note, in: folder))
    }

    func testLocalAttachmentImageMetadataInvalidatesDerivedCacheWhenFileChanges() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let image = folder.appendingPathComponent("diagram.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let first = try XCTUnwrap(LocalAttachmentImageMetadata.inspect(image))
        XCTAssertEqual(first.byteCount, 4)

        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: image)
        let second = try XCTUnwrap(LocalAttachmentImageMetadata.inspect(image))
        XCTAssertEqual(second.byteCount, 6)
        XCTAssertNotEqual(first.cacheKey, second.cacheKey)

        let unsupported = folder.appendingPathComponent("diagram.txt")
        try Data("text".utf8).write(to: unsupported)
        XCTAssertNil(LocalAttachmentImageMetadata.inspect(unsupported))
    }
    func testSearchResultSourceLocationsAreTypedAndNotGuessed() throws {
        func hit(uri: String, type: String) -> SearchHit {
            SearchHit(documentId: "doc", chunkId: nil, title: "Test", uri: uri,
                      sourceType: type, snippet: nil, score: nil, headingPath: nil)
        }

        let icloud = hit(uri: "/Users/test/Library/Mobile Documents/iCloud/中文笔记.md", type: "local")
        XCTAssertEqual(icloud.localFileURL?.lastPathComponent, "中文笔记.md")
        XCTAssertEqual(icloud.sourceLabel, "iCloud Drive")
        XCTAssertNil(icloud.webURL)

        let managed = hit(uri: "/Users/test/Documents/Archive/notes.md", type: "managed")
        XCTAssertEqual(managed.localFileURL?.path, "/Users/test/Documents/Archive/notes.md")
        XCTAssertEqual(managed.sourceLabel, "Local file")
        XCTAssertEqual(managed.sourceLocation, "Archive")

        let webpage = hit(uri: "https://example.com/docs?id=1", type: "web")
        XCTAssertNil(webpage.localFileURL)
        XCTAssertEqual(webpage.webURL?.host, "example.com")
        XCTAssertEqual(webpage.sourceLabel, "Web page")

        XCTAssertNil(hit(uri: "javascript:alert(1)", type: "web").webURL)
        XCTAssertNil(hit(uri: "https://example.com", type: "managed").localFileURL)
        XCTAssertNil(hit(uri: "//remote/share/notes.md", type: "local").localFileURL)
        XCTAssertNil(hit(uri: "/tmp/local.md", type: "web").localFileURL)
        XCTAssertNil(hit(uri: "opaque:ref-42", type: "other").localFileURL)
    }

    @MainActor
    func testMissingFileActionsReportErrorWithoutLaunchingAnything() throws {
        let model = NotesModel()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("pks-notes-missing-\(UUID().uuidString).md")
        model.revealInFinder(missing)
        XCTAssertEqual(model.message, AppLanguage.current.text("The original file is not available locally."))
        model.message = nil
        model.openInDefaultApp(missing)
        XCTAssertEqual(model.message, AppLanguage.current.text("The original file is not available locally."))
    }

    func testPKSDocumentGroupingPreservesRankAndIndividualHits() {
        func hit(_ doc: String, _ uri: String, _ section: String) -> SearchHit {
            SearchHit(documentId: doc, chunkId: section, title: doc, uri: uri,
                      sourceType: "local", snippet: section, score: nil, headingPath: section)
        }
        let result = SearchResultGroup.group([
            hit("A", "/notes/a.md", "intro"),
            hit("B", "/notes/b.md", "summary"),
            hit("A", "/notes/a.md", "details"),
            hit("A", "/other/a.md", "other location")
        ])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map { $0.primary.documentId }, ["A", "B", "A"])
        XCTAssertEqual(result[0].hits.map { $0.headingPath }, ["intro", "details"])
        XCTAssertEqual(result[1].hits.count, 1)
    }

    func testLiteralUnicodeHighlightingAndNoRegexInterpretation() {
        let pieces = MatchHighlighter.pieces(in: "学习 Markdown, markdown 和 md.", query: "MARKDOWN")
        XCTAssertEqual(pieces.filter { $0.matched }.map { $0.text }, ["Markdown", "markdown"])
        XCTAssertEqual(pieces.map { $0.text }.joined(), "学习 Markdown, markdown 和 md.")
        XCTAssertEqual(MatchHighlighter.pieces(in: "a.b a-b", query: "a.b")
            .filter { $0.matched }.count, 1)
        XCTAssertEqual(MatchHighlighter.pieces(in: "中文 文", query: "文")
            .filter { $0.matched }.count, 2)
    }

    func testMarkdownHeadingNavigationIgnoresCodeFences() {
        let source = "# Intro\nHello\n\n~~~swift\n# Not a heading\n~~~\n## 中文段落\nParagraph here\n"
        let sections = MarkdownSection.sections(in: source)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.map { $0.heading }, ["Intro", "中文段落"])
        XCTAssertEqual(MarkdownSection.targetIndex(in: sections, headingPath: "Intro > 中文段落",
                                                   snippet: nil, query: ""), 1)
        XCTAssertEqual(MarkdownSection.targetIndex(in: sections, headingPath: nil, snippet: nil,
                                                   query: "Paragraph"), 1)
    }

    @MainActor
    func testLargeMarkdownLoadLatestSelectionAndFailurePreservesDraft() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let large = root.appendingPathComponent("large.md")
        let latest = root.appendingPathComponent("latest.md")
        let missing = root.appendingPathComponent("missing.md")
        try String(repeating: "# Long section\nbody content\n", count: 200_000)
            .write(to: large, atomically: true, encoding: .utf8)
        try "# Latest".write(to: latest, atomically: true, encoding: .utf8)

        let model = NotesModel()
        model.openWorkspace(root)
        model.openNote(large)
        XCTAssertTrue(model.loadingNote)
        XCTAssertEqual(model.requestedNote, large)
        model.openNote(latest)
        XCTAssertEqual(model.requestedNote, latest)
        await waitForNote(model, latest)
        XCTAssertNil(model.requestedNote)
        XCTAssertEqual(model.draft, "# Latest")
        try? await Task.sleep(nanoseconds: 130_000_000)
        XCTAssertEqual(model.selected, latest)
        XCTAssertEqual(model.draft, "# Latest")

        model.draft = "# Preserve unsaved source"
        model.openNote(missing, navigationDecision: .discard)
        for _ in 0..<100 {
            if !model.loadingNote { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.loadingNote)
        XCTAssertEqual(model.selected, latest)
        XCTAssertEqual(model.draft, "# Preserve unsaved source")
        XCTAssertEqual(try String(contentsOf: latest, encoding: .utf8), "# Latest")
        XCTAssertTrue(model.message?.contains(AppLanguage.current.text("Cannot open the note")) == true)
    }

    @MainActor
    func testSameNoteResultNavigationPreservesUnsavedDraft() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let note = folder.appendingPathComponent("测试.md")
        try "# Section\nOriginal".write(to: note, atomically: true, encoding: .utf8)
        let model = NotesModel()
        model.openWorkspace(folder)
        model.openNote(note)
        await waitForNote(model, note)
        model.draft = "# Section\nUncommitted changes"
        model.query = "Section"
        let hit = SearchHit(documentId: "doc", chunkId: "chunk", title: "测试",
                            uri: note.path, sourceType: "local", snippet: "Section",
                            score: 1, headingPath: "Section")
        model.openResult(hit)
        XCTAssertEqual(model.selected, note)
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.draft.contains("Uncommitted changes"))
        XCTAssertEqual(model.activeMatch?.headingPath, "Section")
        XCTAssertGreaterThan(model.matchJumpSequence, 0)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "# Section\nOriginal")
    }

}


extension PKSNotesTests {
    func testKnowledgeTargetResolutionPrefersExactAndRejectsAmbiguousBasename() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let current = a.appendingPathComponent("Current.md")
        let relative = a.appendingPathComponent("Design.md")
        let duplicate = b.appendingPathComponent("Design.md")
        let unique = b.appendingPathComponent("Spec.md")
        for file in [current, relative, duplicate, unique] {
            try "# test".write(to: file, atomically: true, encoding: .utf8)
        }

        XCTAssertEqual(WorkspaceFiles.resolveKnowledgeTarget("Design", from: current, in: root), relative)
        XCTAssertEqual(WorkspaceFiles.resolveKnowledgeTarget("B/Spec", from: current, in: root), unique)
        XCTAssertEqual(WorkspaceFiles.resolveKnowledgeTarget("Spec#Section", from: current, in: root), unique)
        XCTAssertNil(WorkspaceFiles.resolveKnowledgeTarget("https://example.com", from: current, in: root))

        try fm.removeItem(at: relative)
        XCTAssertEqual(WorkspaceFiles.resolveKnowledgeTarget("Design", from: current, in: root), duplicate)
        try "# duplicate".write(to: relative, atomically: true, encoding: .utf8)
        let second = root.appendingPathComponent("C", isDirectory: true)
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        let another = second.appendingPathComponent("Loose.md")
        let another2 = b.appendingPathComponent("Loose.md")
        try "# x".write(to: another, atomically: true, encoding: .utf8)
        try "# y".write(to: another2, atomically: true, encoding: .utf8)
        XCTAssertNil(WorkspaceFiles.resolveKnowledgeTarget("Loose", from: current, in: root))
    }
}


extension PKSNotesTests {
    func testWorkspaceBacklinksFindWikiAndMarkdownLinksWithoutDuplicateIndex() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let target = root.appendingPathComponent("Target.md")
        let wiki = root.appendingPathComponent("Wiki.md")
        let markdown = root.appendingPathComponent("Markdown.md")
        let unrelated = root.appendingPathComponent("Other.md")
        try "# Target".write(to: target, atomically: true, encoding: .utf8)
        try "# Wiki\n- [[Target]]\n- [[Target|again]]".write(to: wiki, atomically: true, encoding: .utf8)
        try "# Markdown\n[go](Target.md)".write(to: markdown, atomically: true, encoding: .utf8)
        try "# Other\n[[Missing]]".write(to: unrelated, atomically: true, encoding: .utf8)

        let tree = WorkspaceFiles.tree(in: root)
        let backlinks = WorkspaceBacklinks.find(target: target, root: root, files: tree)
        XCTAssertEqual(backlinks.map(\.source), [wiki, markdown])
        XCTAssertEqual(backlinks.map(\.count), [2, 1])
    }

    func testKnowledgeTargetResolverUsesSuppliedCandidatesForUniqueBasename() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let current = root.appendingPathComponent("Current.md")
        let target = folder.appendingPathComponent("Target.md")
        try "# Current".write(to: current, atomically: true, encoding: .utf8)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            WorkspaceFiles.resolveKnowledgeTarget("Target", from: current, in: root, candidates: [current, target]),
            target
        )
    }

    @MainActor
    func testKnowledgeLinkBasenameFallbackUsesOnDemandGlobalIndex() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Archive/Deep", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let current = root.appendingPathComponent("Current.md")
        let target = folder.appendingPathComponent("Target.md")
        try "# Current\n[[Target]]".write(to: current, atomically: true, encoding: .utf8)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        for _ in 0..<200 where model.loadingFiles {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.globalFileIndexReady)
        XCTAssertFalse(NoteTreePresentation.openableFiles(model.files).contains {
            $0.url.standardizedFileURL == target.standardizedFileURL
        })

        model.openNote(current)
        await waitForNote(model, current)
        XCTAssertTrue(model.openKnowledgeLink("Target"))

        for _ in 0..<400 {
            if model.selected?.standardizedFileURL == target.standardizedFileURL,
               !model.loadingNote {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.globalFileIndexReady)
        XCTAssertEqual(model.selected?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(model.draft, "# Target")
    }
}


extension PKSNotesTests {
    @MainActor
    func testNativeMarkdownFormattingPreservesUnicodeSelectionInTextView() async throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        textView.string = "中文测试"
        textView.setSelectedRange(NSRange(location: 2, length: 2))

        XCTAssertTrue(MarkdownNativeCommand.perform("bold", in: textView))
        XCTAssertEqual(textView.string, "中文**测试**")

        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 2))
    }

    func testMarkdownEditingWrapsSelectionAndPrefixesLines() {
        XCTAssertEqual(
            MarkdownEditing.apply(.bold, to: "hello world", selection: NSRange(location: 0, length: 5)),
            MarkdownEditResult(text: "**hello** world", selection: NSRange(location: 2, length: 5))
        )
        XCTAssertEqual(
            MarkdownEditing.apply(.italic, to: "hello", selection: NSRange(location: 5, length: 0)),
            MarkdownEditResult(text: "hello**", selection: NSRange(location: 6, length: 0))
        )
        XCTAssertEqual(
            MarkdownEditing.apply(.link, to: "hello", selection: NSRange(location: 0, length: 5)),
            MarkdownEditResult(text: "[hello](url)", selection: NSRange(location: 8, length: 3))
        )
        XCTAssertEqual(
            MarkdownEditing.apply(.heading(2), to: "one\ntwo", selection: NSRange(location: 0, length: 7)).text,
            "## one\n## two"
        )
        XCTAssertEqual(
            MarkdownEditing.apply(.task, to: "one\ntwo", selection: NSRange(location: 0, length: 7)).text,
            "- [ ] one\n- [ ] two"
        )
    }

    func testMarkdownEditingQuotesLinesAndInsertsEditableTable() {
        XCTAssertEqual(
            MarkdownEditing.apply(.quote, to: "one\ntwo", selection: NSRange(location: 0, length: 7)).text,
            "> one\n> two"
        )

        XCTAssertEqual(
            MarkdownEditing.apply(.table, to: "Heading\n", selection: NSRange(location: 8, length: 0)),
            MarkdownEditResult(
                text: "Heading\n\n| Column 1 | Column 2 |\n| --- | --- |\n| Cell | Cell |",
                selection: NSRange(location: 11, length: 8)
            )
        )
    }

    func testMarkdownReplacementPreservesUnchangedTextAndUnicodeOffsets() {
        XCTAssertEqual(
            MarkdownEditing.minimalChange(from: "alpha beta", to: "alpha **beta**"),
            MarkdownReplacement(range: NSRange(location: 6, length: 4), text: "**beta**")
        )
        XCTAssertEqual(
            MarkdownEditing.minimalChange(from: "中文测试", to: "中文**测试**"),
            MarkdownReplacement(range: NSRange(location: 2, length: 2), text: "**测试**")
        )
        XCTAssertNil(MarkdownEditing.minimalChange(from: "same", to: "same"))
    }

    func testMarkdownEditingInsertsAtSelection() {
        XCTAssertEqual(
            MarkdownEditing.insert("![Pasted image](attachments/a.png)",
                                   into: "before after",
                                   selection: NSRange(location: 7, length: 5)),
            MarkdownEditResult(
                text: "before ![Pasted image](attachments/a.png)",
                selection: NSRange(location: 41, length: 0)
            )
        )
    }

    func testPastedPNGUsesWorkspaceLocalAttachmentAndCollisionSafeName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let note = root.appendingPathComponent("Note.md")
        try "# Note".write(to: note, atomically: true, encoding: .utf8)

        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let first = WorkspaceFiles.storePastedPNG(bytes, for: note, in: root)
        let second = WorkspaceFiles.storePastedPNG(bytes, for: note, in: root)
        XCTAssertEqual(first, "attachments/pasted-image.png")
        XCTAssertEqual(second, "attachments/pasted-image-2.png")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(first!)), bytes)
        XCTAssertNil(
            WorkspaceFiles.storePastedPNG(bytes,
                                          for: fm.temporaryDirectory.appendingPathComponent("Outside.md"),
                                          in: root)
        )
    }

    @MainActor
    func testCopyAndMoveItemsStayInsideWorkspaceAndRebaseOpenNote() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        let copies = root.appendingPathComponent("Copies", isDirectory: true)
        let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        try fm.createDirectory(at: copies, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: outside)
        }

        let note = root.appendingPathComponent("Note.md")
        try "# Original".write(to: note, atomically: true, encoding: .utf8)

        let model = NotesModel()
        model.openWorkspace(root)
        model.openNote(note)
        await waitForNote(model, note)

        let copied = await model.copyItem(note, to: copies)
        XCTAssertEqual(copied, copies.appendingPathComponent("Note.md"))
        XCTAssertEqual(try String(contentsOf: copied!, encoding: .utf8), "# Original")
        let outsideCopy = await model.copyItem(note, to: outside)
        XCTAssertNil(outsideCopy)

        let moved = await model.moveItem(note, to: archive, navigationDecision: .discard)
        XCTAssertEqual(moved, archive.appendingPathComponent("Note.md"))
        await waitForNote(model, archive.appendingPathComponent("Note.md"))
        XCTAssertFalse(fm.fileExists(atPath: note.path))
        XCTAssertEqual(model.selected, archive.appendingPathComponent("Note.md"))

        // The workspace root is a valid destination even though path containment
        // intentionally excludes root itself when validating document paths.
        let copiedToRoot = await model.copyItem(copied!, to: root)
        XCTAssertEqual(copiedToRoot, note)
        XCTAssertEqual(try String(contentsOf: copiedToRoot!, encoding: .utf8), "# Original")
        try fm.removeItem(at: copiedToRoot!)

        let returned = await model.moveItem(moved!, to: root, navigationDecision: .discard)
        XCTAssertEqual(returned, note)
        await waitForNote(model, note)
        XCTAssertEqual(model.selected, note)
    }
}


extension PKSNotesTests {
    @MainActor
    func testMoveAndCopyFolderRejectDescendantDestination() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parent = root.appendingPathComponent("Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let model = NotesModel()
        model.openWorkspace(root)
        let descendantMove = await model.moveItem(parent, to: child, navigationDecision: .discard)
        XCTAssertNil(descendantMove)
        XCTAssertTrue(fm.fileExists(atPath: parent.path))
        let descendantCopy = await model.copyItem(parent, to: child)
        XCTAssertNil(descendantCopy)
        XCTAssertTrue(fm.fileExists(atPath: parent.path))
    }
}

extension PKSNotesTests {
    func testPDFReadingPositionIsPerDocumentAndClamped() throws {
        let suite = "PKSNotesPDFPositionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }

        let first = URL(fileURLWithPath: "/tmp/a.pdf")
        let second = URL(fileURLWithPath: "/tmp/b.pdf")

        PDFReadingPositionStore.save(pageIndex: 7, for: first, defaults: defaults)
        PDFReadingPositionStore.save(pageIndex: 2, for: second, defaults: defaults)

        XCTAssertEqual(PDFReadingPositionStore.pageIndex(for: first, pageCount: 20, defaults: defaults), 7)
        XCTAssertEqual(PDFReadingPositionStore.pageIndex(for: second, pageCount: 20, defaults: defaults), 2)
        XCTAssertEqual(PDFReadingPositionStore.pageIndex(for: first, pageCount: 4, defaults: defaults), 3)
        XCTAssertNil(PDFReadingPositionStore.pageIndex(for: first, pageCount: 0, defaults: defaults))
    }

    func testPDFPageReferenceIsPortableAndKeepsPageAnchor() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("资料", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let pdf = folder.appendingPathComponent("Study #1.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)

        let markdown = try XCTUnwrap(PDFPageReference.markdown(for: pdf, page: 7, root: root))
        XCTAssertTrue(markdown.contains("Study #1.pdf · p. 7"))
        XCTAssertTrue(markdown.contains("Study%20%231.pdf#page=7"))

        let link = try XCTUnwrap(URL(string: "/%E8%B5%84%E6%96%99/Study%20%231.pdf#page=7"))
        XCTAssertEqual(PDFPageReference.page(from: link), 7)
        XCTAssertEqual(
            WorkspaceFiles.resolve(link, from: root.appendingPathComponent("Note.md"), in: root),
            pdf.standardizedFileURL
        )
    }

    @MainActor
    func testPDFManualPageJumpRejectsOutOfRangeInsteadOfClampingSilently() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        textView.string = "PDF Page One"
        let pdf = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        let controller = PDFReaderController()
        let uniqueURL = URL(fileURLWithPath: "/tmp/PKS-PDF-Page-\(UUID().uuidString).pdf")

        controller.attach(view: view, document: pdf, url: uniqueURL,
                          requestedPage: nil, requestedAnchor: nil)
        XCTAssertEqual(controller.pageCount, 1)
        XCTAssertEqual(controller.currentPageIndex, 0)

        controller.goToPage(0)
        XCTAssertEqual(controller.invalidRequestedPage, 0)
        XCTAssertEqual(controller.currentPageIndex, 0)

        controller.goToPage(100)
        XCTAssertEqual(controller.invalidRequestedPage, 100)
        XCTAssertEqual(controller.currentPageIndex, 0)

        controller.goToPage(1)
        XCTAssertNil(controller.invalidRequestedPage)
        XCTAssertEqual(controller.currentPageIndex, 0)
        controller.detach(view: view)
    }

    func testPDFReferenceEscapesParenthesesAndKeepsExactFileDestination() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let pdf = root.appendingPathComponent("Research (final) [v2].pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)
        let markdown = try XCTUnwrap(PDFPageReference.markdown(for: pdf, page: 3, root: root))
        XCTAssertTrue(markdown.contains("Research%20%28final%29%20%5Bv2%5D.pdf#page=3"),
                      "A literal ')' inside a Markdown link target is interpreted as the end of the link.")
        let occurrences = MindMapOutline.linkOccurrences(in: markdown)
        let link = try XCTUnwrap(occurrences.first?.link.target)
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(PDFPageReference.page(from: try XCTUnwrap(URL(string: link))), 3)
        XCTAssertEqual(
            WorkspaceFiles.resolveLinkedTarget(link, from: root.appendingPathComponent("Note.md"), in: root),
            pdf.standardizedFileURL
        )
    }

    func testPDFSelectionAnchorRoundTripsWithoutChangingPageOnlyLinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let pdf = root.appendingPathComponent("Book.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)

        let fingerprint = try XCTUnwrap(PDFSourceAnchor.fingerprint(for: "Quoted\n  fact"))
        XCTAssertEqual(fingerprint, PDFSourceAnchor.fingerprint(for: "Quoted fact"))

        let anchor = try XCTUnwrap(PDFSourceAnchor(
            page: 7,
            normalizedRects: [
                CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
                CGRect(x: 0.1, y: 0.25, width: 0.2, height: 0.04)
            ],
            fingerprint: fingerprint
        ))
        XCTAssertTrue(anchor.matches(text: "Quoted   fact"))
        XCTAssertFalse(anchor.matches(text: "Quoted changed fact"),
                       "A stale PDF selection must fail fingerprint validation.")

        let markdown = try XCTUnwrap(PDFPageReference.markdown(
            for: pdf,
            page: 7,
            root: root,
            anchor: anchor
        ))
        XCTAssertTrue(markdown.contains("#page=7&rects=0.10000,0.20000,0.30000,0.04000~0.10000,0.25000,0.20000,0.04000&fp=\(fingerprint)"))

        let link = try XCTUnwrap(URL(string: "/Book.pdf#\(anchor.fragment)"))
        XCTAssertEqual(PDFPageReference.page(from: link), 7)
        XCTAssertEqual(PDFPageReference.anchor(from: link), anchor)
        XCTAssertNil(PDFPageReference.anchor(from: try XCTUnwrap(URL(string: "/Book.pdf#page=7"))))
        XCTAssertNil(PDFSourceAnchor.parse(fragment: "page=7&rects=2,0,1,1&fp=\(fingerprint)"))

        XCTAssertEqual(
            PDFPageReference.markdown(for: pdf, page: 7, root: root),
            "[Book.pdf · p. 7](/Book.pdf#page=7)"
        )
    }

    func testBacklinksTreatPDFPageLinksAsTheSameWorkspaceFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let pdf = root.appendingPathComponent("Book.pdf")
        let note = root.appendingPathComponent("Reading.md")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)
        try "# Reading\n[Book · p. 3](/Book.pdf#page=3)\n[Again](/Book.pdf#page=9)".write(
            to: note,
            atomically: true,
            encoding: .utf8
        )

        let found = WorkspaceBacklinks.find(target: pdf, root: root, files: WorkspaceFiles.tree(in: root))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.source, note.standardizedFileURL)
        XCTAssertEqual(found.first?.count, 2)
        XCTAssertEqual(
            found.first?.locations,
            [
                NoteBacklinkLocation(lineIndex: 1, count: 1),
                NoteBacklinkLocation(lineIndex: 2, count: 1)
            ]
        )
    }

    @MainActor
    func testPDFRelationshipsFindCanonicalCitationThroughNotesModel() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let materials = root.appendingPathComponent("Materials", isDirectory: true)
        try fm.createDirectory(at: materials, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = root.appendingPathComponent("Study.md")
        let pdf = materials.appendingPathComponent("Source.pdf")
        try "# Study\n\n[Source.pdf · p. 1](/Materials/Source.pdf#page=1)\n".write(
            to: note,
            atomically: true,
            encoding: .utf8
        )
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: pdf)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        for _ in 0..<200 where model.loadingFiles {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.openNote(note)
        await waitForNote(model, note)
        model.openFile(pdf)
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)

        model.loadRelationships()
        for _ in 0..<400 where model.loadingBacklinks {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(model.loadingBacklinks)
        XCTAssertEqual(model.backlinks.count, 1)
        XCTAssertEqual(model.backlinks.first?.source, note.standardizedFileURL)
        XCTAssertEqual(
            model.backlinks.first?.locations,
            [NoteBacklinkLocation(lineIndex: 2, count: 1)]
        )
    }

    @MainActor
    func testInternalPDFLinkOpensRequestedPageThroughSingleFileAuthority() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = root.appendingPathComponent("Note.md")
        let pdf = root.appendingPathComponent("Book.pdf")
        try "# Note".write(to: note, atomically: true, encoding: .utf8)
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)

        let model = NotesModel()
        model.openWorkspace(root)
        model.openNote(note)
        await waitForNote(model, note)

        let link = try XCTUnwrap(URL(string: "/Book.pdf#page=7"))
        XCTAssertTrue(model.openInternalLink(link))
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        XCTAssertEqual(model.previewPDFPage, 7)
        XCTAssertEqual(model.selected, note.standardizedFileURL)
        XCTAssertEqual(model.draft, "# Note")
    }

    @MainActor
    func testInternalRelativeEncodedPDFLinkOpensRequestedPage() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = root.appendingPathComponent("PDF QA.md")
        let pdf = root.appendingPathComponent("PDF QA.pdf")
        try "# PDF QA".write(to: note, atomically: true, encoding: .utf8)
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)

        let model = NotesModel()
        model.openWorkspace(root)
        model.openNote(note)
        await waitForNote(model, note)

        let link = try XCTUnwrap(URL(string: "PDF%20QA.pdf#page=2"))
        XCTAssertTrue(model.openInternalLink(link))
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        XCTAssertEqual(model.previewPDFPage, 2)
        XCTAssertEqual(model.selected, note.standardizedFileURL)
        XCTAssertEqual(model.draft, "# PDF QA")
    }

    @MainActor
    func testInternalPDFSelectionLinkCarriesExactAnchorThroughFileAuthority() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = root.appendingPathComponent("Note.md")
        let pdf = root.appendingPathComponent("Book.pdf")
        try "# Note".write(to: note, atomically: true, encoding: .utf8)
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)

        let fingerprint = try XCTUnwrap(PDFSourceAnchor.fingerprint(for: "Exact evidence"))
        let anchor = try XCTUnwrap(PDFSourceAnchor(
            page: 4,
            normalizedRects: [CGRect(x: 0.12, y: 0.4, width: 0.33, height: 0.05)],
            fingerprint: fingerprint
        ))

        let model = NotesModel()
        model.openWorkspace(root)
        model.openNote(note)
        await waitForNote(model, note)

        let link = try XCTUnwrap(URL(string: "/Book.pdf#\(anchor.fragment)"))
        XCTAssertTrue(model.openInternalLink(link))
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        XCTAssertEqual(model.previewPDFPage, 4)
        XCTAssertEqual(model.previewPDFAnchor, anchor)
        XCTAssertEqual(model.selected, note.standardizedFileURL)

        let firstNavigation = model.previewPDFNavigationSequence
        XCTAssertTrue(model.openInternalLink(link))
        XCTAssertEqual(model.previewPDFNavigationSequence, firstNavigation + 1)
        XCTAssertEqual(model.previewPDFAnchor, anchor)

        model.closePDFPreview()
        XCTAssertNil(model.previewPDFAnchor)
    }

    @MainActor
    func testPDFAndMarkdownShareOneCanonicalStudySession() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = root.appendingPathComponent("Study.md")
        let pdf = root.appendingPathComponent("Book.pdf")
        try "# Study\nOriginal".write(to: note, atomically: true, encoding: .utf8)
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)

        let model = NotesModel()
        model.openWorkspace(root)
        model.openNote(note)
        await waitForNote(model, note)

        model.openFile(pdf, pdfPage: 3)
        XCTAssertEqual(model.selected, note.standardizedFileURL)
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        XCTAssertEqual(model.previewPDFPage, 3)
        XCTAssertEqual(model.draft, "# Study\nOriginal")

        model.draft += "\nWorking note"
        model.save()
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("Working note"))

        model.closePDFPreview()
        XCTAssertNil(model.previewPDF)
        XCTAssertEqual(model.selected, note.standardizedFileURL)
        XCTAssertTrue(model.draft.contains("Working note"))
    }

    @MainActor
    func testStudyNoteLoadAndNewNotePreservePDFSource() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = root.appendingPathComponent("Existing.md")
        let pdf = root.appendingPathComponent("Book.pdf")
        try "# Existing".write(to: note, atomically: true, encoding: .utf8)
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)

        let model = NotesModel()
        model.openWorkspace(root)
        model.openFile(pdf, pdfPage: 5)
        model.openStudyNote(note)
        await waitForNote(model, note)
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        XCTAssertEqual(model.previewPDFPage, 5)
        XCTAssertEqual(model.selected, note.standardizedFileURL)

        let appendedToCurrentNote = await model.appendPDFReference(
            pdf: pdf, page: 5, commentary: "Remember this", to: note
        )
        XCTAssertTrue(appendedToCurrentNote)
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(model.draft.contains("Remember this"))
        XCTAssertTrue(model.draft.contains("[Book.pdf · p. 5](/Book.pdf#page=5)"))

        let created = try XCTUnwrap(model.newNote(
            named: "Second.md",
            initialContent: "# Second\n",
            preservePDFPreview: true
        ))
        await waitForNote(model, created)
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        XCTAssertEqual(model.previewPDFPage, 5)
        XCTAssertEqual(model.selected, created.standardizedFileURL)
    }

    func testPDFPageCommentaryIsOptionalAndPortable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let pdf = root.appendingPathComponent("Book.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)

        XCTAssertEqual(
            PDFPageReference.noteSnippet(for: pdf, page: 2, root: root, commentary: "  \n "),
            "[Book.pdf · p. 2](/Book.pdf#page=2)"
        )
        let quoteFingerprint = try XCTUnwrap(PDFSourceAnchor.fingerprint(for: "Quoted fact"))
        let quoteAnchor = try XCTUnwrap(PDFSourceAnchor(
            page: 2,
            normalizedRects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)],
            fingerprint: quoteFingerprint
        ))
        XCTAssertEqual(
            PDFPageReference.noteSnippet(
                for: pdf,
                page: 2,
                root: root,
                commentary: "My interpretation\n- remember this",
                selectedText: "Quoted fact",
                anchor: quoteAnchor
            ),
            "My interpretation\n- remember this\n\n[Book.pdf · p. 2](/Book.pdf#\(quoteAnchor.fragment))\n\n> Quoted fact"
        )
        XCTAssertNil(PDFPageReference.noteSnippet(
            for: pdf, page: 2, root: root, selectedText: "Quoted fact"
        ))
        let staleFingerprint = try XCTUnwrap(PDFSourceAnchor.fingerprint(for: "Different fact"))
        let staleAnchor = try XCTUnwrap(PDFSourceAnchor(
            page: 2,
            normalizedRects: quoteAnchor.normalizedRects,
            fingerprint: staleFingerprint
        ))
        XCTAssertNil(PDFPageReference.noteSnippet(
            for: pdf, page: 2, root: root, selectedText: "Quoted fact", anchor: staleAnchor
        ))
    }

    @MainActor
    func testPDFPageCanAppendToMarkdownNoteWithoutLeavingPDF() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let prior { defaults.set(prior, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = root.appendingPathComponent("Study.md")
        let pdf = root.appendingPathComponent("Book.pdf")
        try "# Study\n".write(to: note, atomically: true, encoding: .utf8)
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)

        let model = NotesModel()
        model.openWorkspace(root)
        for _ in 0..<100 where model.loadingFiles {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.loadingFiles)
        model.openFile(pdf, pdfPage: 4)

        let rejectedUnanchoredSelection = await model.appendPDFReference(
            pdf: pdf,
            page: 4,
            selectedText: "Unanchored quote",
            to: note
        )
        XCTAssertFalse(rejectedUnanchoredSelection)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "# Study\n")

        let fingerprint = try XCTUnwrap(PDFSourceAnchor.fingerprint(for: "Important fact\nSecond line"))
        let anchor = try XCTUnwrap(PDFSourceAnchor(
            page: 4,
            normalizedRects: [CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.08)],
            fingerprint: fingerprint
        ))
        let appendedToOtherNote = await model.appendPDFReference(
            pdf: pdf,
            page: 4,
            commentary: "My interpretation",
            selectedText: "Important fact\nSecond line",
            anchor: anchor,
            to: note
        )
        XCTAssertTrue(appendedToOtherNote)
        XCTAssertFalse(model.loadingFiles, "Appending to an existing note must not rescan the workspace tree.")
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        XCTAssertEqual(model.previewPDFPage, 4)
        XCTAssertNil(model.selected)

        let content = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(content.contains("My interpretation\n\n[Book.pdf · p. 4](/Book.pdf#\(anchor.fragment))"))
        XCTAssertTrue(content.contains("> Important fact\n> Second line"))
    }
}


extension PKSNotesTests {
    func testTargetSpecificBacklinkResolutionPreservesExactBasenamePDFAndSymlinkRules() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let source = root.appendingPathComponent("Source.md")
        let target = nested.appendingPathComponent("Target.md")
        let pdf = root.appendingPathComponent("Book.pdf")
        let alias = root.appendingPathComponent("Alias.md")
        try "# Source".write(to: source, atomically: true, encoding: .utf8)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)
        try fm.createSymbolicLink(at: alias, withDestinationURL: target)

        let candidates = WorkspaceBacklinks.markdownFiles(WorkspaceFiles.tree(in: root))
        let basenames = Dictionary(grouping: candidates) {
            $0.deletingPathExtension().lastPathComponent
        }

        XCTAssertTrue(WorkspaceFiles.linkedTargetMatches(
            "Nested/Target.md#section",
            from: source,
            target: target,
            in: root,
            candidateBasenames: basenames
        ))
        XCTAssertTrue(WorkspaceFiles.linkedTargetMatches(
            "Target",
            from: source,
            target: target,
            in: root,
            candidateBasenames: basenames
        ))
        XCTAssertTrue(WorkspaceFiles.linkedTargetMatches(
            "/Book.pdf#page=2",
            from: source,
            target: pdf,
            in: root,
            candidateBasenames: basenames
        ))
        XCTAssertFalse(WorkspaceFiles.linkedTargetMatches(
            "Alias.md",
            from: source,
            target: target,
            in: root,
            candidateBasenames: basenames
        ), "A symlink alias is not present in the secure candidate index.")
        XCTAssertFalse(WorkspaceFiles.linkedTargetMatches(
            "../Outside.md",
            from: source,
            target: target,
            in: root,
            candidateBasenames: basenames
        ))
    }

    func testBacklinkScanResultAndBasenameLookupStayDerived() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let current = root.appendingPathComponent("Current.md")
        let target = nested.appendingPathComponent("Target.md")
        let source = root.appendingPathComponent("Source.md")
        try "# Current".write(to: current, atomically: true, encoding: .utf8)
        try "# Target".write(to: target, atomically: true, encoding: .utf8)
        try "[[Target]]\n[again](Nested/Target.md)".write(to: source, atomically: true, encoding: .utf8)

        let tree = WorkspaceFiles.tree(in: root)
        let candidates = WorkspaceBacklinks.markdownFiles(tree)
        let basenames = Dictionary(grouping: candidates) {
            $0.deletingPathExtension().lastPathComponent
        }
        XCTAssertEqual(
            WorkspaceFiles.resolveKnowledgeTarget(
                "Target",
                from: current,
                in: root,
                candidates: candidates,
                candidateBasenames: basenames
            ),
            target.standardizedFileURL
        )

        let cache = WorkspaceBacklinkParseCache(capacity: 8)
        let scan = WorkspaceBacklinks.scan(
            target: target,
            root: root,
            files: tree,
            parseCache: cache
        )
        XCTAssertEqual(scan.backlinks.count, 1)
        XCTAssertEqual(scan.backlinks.first?.source, source.standardizedFileURL)
        XCTAssertEqual(scan.backlinks.first?.count, 2)
        XCTAssertEqual(
            scan.backlinks.first?.locations,
            [
                NoteBacklinkLocation(lineIndex: 0, count: 1),
                NoteBacklinkLocation(lineIndex: 1, count: 1)
            ]
        )
        XCTAssertEqual(scan.skippedDatalessFiles, 0)
        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertFalse(WorkspaceFiles.isDataless(source))
    }

    func testKnowledgeLinksKeepLargePlainTextAndFencedCodeCheapAndCorrect() {
        let plain = Array(repeating: "ordinary prose without any link syntax", count: 2_000)
            .joined(separator: "\n")
        let markdown = """
        \(plain)
        ~~~swift
        [[Ignored]]
        [Ignored too](/Ignored.md)
        ~~~
        [[Kept|Visible]]
        [Again](/Kept.md)
        """

        XCTAssertEqual(
            MindMapOutline.knowledgeLinks(in: markdown),
            [
                MindMapLink(label: "Visible", target: "Kept"),
                MindMapLink(label: "Again", target: "/Kept.md")
            ]
        )
    }

    func testBacklinkOccurrencesGroupMultipleReferencesOnTheSameSourceLine() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let target = root.appendingPathComponent("Beta.md")
        let source = root.appendingPathComponent("Source.md")
        try "# Beta".write(to: target, atomically: true, encoding: .utf8)
        try "[B](/Beta.md) and [B2](/Beta.md)\n[B3](/Beta.md)".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )

        let files = [
            NoteItem(url: source, children: nil),
            NoteItem(url: target, children: nil)
        ]
        let index = WorkspaceLinkCandidateIndex(markdownFiles: [source, target])
        let scan = WorkspaceBacklinks.scan(
            target: target,
            root: root,
            files: files,
            candidateIndex: index,
            parseCache: WorkspaceBacklinkParseCache(capacity: 4)
        )

        let backlink = try XCTUnwrap(scan.backlinks.first)
        XCTAssertEqual(backlink.source, source.standardizedFileURL)
        XCTAssertEqual(backlink.sourceStamp, WorkspaceFiles.fileStamp(source))
        XCTAssertEqual(backlink.count, 3)
        XCTAssertEqual(
            backlink.locations,
            [
                NoteBacklinkLocation(lineIndex: 0, count: 2),
                NoteBacklinkLocation(lineIndex: 1, count: 1)
            ]
        )
    }

    func testBacklinkParseCacheReusesUnchangedLinksAndInvalidatesReplacement() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let source = root.appendingPathComponent("Source.md")
        try "[Alpha](/Alpha.md)".write(to: source, atomically: true, encoding: .utf8)

        let cache = WorkspaceBacklinkParseCache(capacity: 2)
        let first = try XCTUnwrap(cache.lookup(source))
        XCTAssertFalse(first.hit)
        XCTAssertEqual(first.links.map(\.target), ["/Alpha.md"])
        XCTAssertEqual(first.occurrences.map(\.lineIndex), [0])
        XCTAssertEqual(cache.entryCount, 1)

        let second = try XCTUnwrap(cache.lookup(source))
        XCTAssertTrue(second.hit)
        XCTAssertEqual(second.links, first.links)

        // Atomic replacement changes inode/ctime even if a filesystem happens to
        // preserve a coarse modification timestamp. The old parse must not win.
        try "[Beta](/Beta.md)".write(to: source, atomically: true, encoding: .utf8)
        let third = try XCTUnwrap(cache.lookup(source))
        XCTAssertFalse(third.hit)
        XCTAssertEqual(third.links.map(\.target), ["/Beta.md"])
        XCTAssertEqual(third.occurrences.map(\.lineIndex), [0])
        XCTAssertEqual(cache.entryCount, 1)

        let another = root.appendingPathComponent("Another.md")
        let thirdFile = root.appendingPathComponent("Third.md")
        try "[A](/A.md)".write(to: another, atomically: true, encoding: .utf8)
        try "[T](/T.md)".write(to: thirdFile, atomically: true, encoding: .utf8)
        _ = cache.lookup(another)
        XCTAssertTrue(try XCTUnwrap(cache.lookup(source)).hit,
                      "Touching Source should make it the most recently used entry.")
        _ = cache.lookup(thirdFile)
        XCTAssertTrue(try XCTUnwrap(cache.lookup(source)).hit,
                      "The most recently used entry must survive capacity eviction.")
        XCTAssertFalse(try XCTUnwrap(cache.lookup(another)).hit,
                       "The least recently used entry should be evicted in O(1).")
        XCTAssertLessThanOrEqual(cache.entryCount, 2)

        cache.removeAll()
        XCTAssertEqual(cache.entryCount, 0)
    }

    func testLinkOccurrencesSkipFencedCodeBlocks() {
        let markdown = """
        [Real](/Beta.md)

        ```markdown
        [Example](/Beta.md)
        [[Beta]]
        ```

        [Also real](/Beta.md)
        """

        let occurrences = MindMapOutline.linkOccurrences(in: markdown)
        XCTAssertEqual(occurrences.map(\.lineIndex), [0, 7])
        XCTAssertEqual(occurrences.map(\.link.target), ["/Beta.md", "/Beta.md"])
    }

    func testBacklinksIgnoreLinksInsideFencedCodeBlocks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let target = root.appendingPathComponent("Beta.md")
        let source = root.appendingPathComponent("Source.md")
        try "# Beta".write(to: target, atomically: true, encoding: .utf8)
        try """
        Intro line.

        ```markdown
        [Example](/Beta.md)
        [[Beta]]
        ```

        [Real](/Beta.md)
        """.write(to: source, atomically: true, encoding: .utf8)

        let files = [
            NoteItem(url: source, children: nil),
            NoteItem(url: target, children: nil)
        ]
        let index = WorkspaceLinkCandidateIndex(markdownFiles: [source, target])
        let scan = WorkspaceBacklinks.scan(
            target: target,
            root: root,
            files: files,
            candidateIndex: index
        )

        // Only the real link below the fence is a backlink; the fenced example
        // markup must not be reported as a reference to Beta.
        let backlink = try XCTUnwrap(scan.backlinks.first)
        XCTAssertEqual(backlink.source, source.standardizedFileURL)
        XCTAssertEqual(backlink.count, 1)
        XCTAssertEqual(backlink.locations, [NoteBacklinkLocation(lineIndex: 7, count: 1)])
    }
}


extension PKSNotesTests {
    @MainActor
    func testSaveRejectsExternalReplacementEvenWhenMtimeIsRestored() async throws {
        let defaults = UserDefaults.standard
        let priorWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let priorWorkspace { defaults.set(priorWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = root.appendingPathComponent("Conflict.md")
        try "# Original".write(to: note, atomically: true, encoding: .utf8)
        let originalModification = try XCTUnwrap(
            try fm.attributesOfItem(atPath: note.path)[.modificationDate] as? Date
        )
        let originalStamp = try XCTUnwrap(WorkspaceFiles.fileStamp(note))

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(note)
        await waitForNote(model, note)
        XCTAssertEqual(model.draft, "# Original")

        model.draft = "# Mine"

        // Simulate another editor replacing the file, then restoring the old mtime.
        // The POSIX stamp must still change through inode/ctime and block our save.
        try "# External".write(to: note, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: originalModification], ofItemAtPath: note.path)
        let externalStamp = try XCTUnwrap(WorkspaceFiles.fileStamp(note))
        XCTAssertNotEqual(externalStamp, originalStamp)

        model.save()

        XCTAssertTrue(model.isDirty)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "# External")
    }

    @MainActor
    func testNormalSaveRefreshesFileStampAndReopenCache() async throws {
        let defaults = UserDefaults.standard
        let priorWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        defer {
            if let priorWorkspace { defaults.set(priorWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let first = root.appendingPathComponent("First.md")
        let second = root.appendingPathComponent("Second.md")
        try "# First".write(to: first, atomically: true, encoding: .utf8)
        try "# Second".write(to: second, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(first)
        await waitForNote(model, first)

        model.draft = "# First\nSaved"
        model.save()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# First\nSaved")

        model.openNote(second)
        await waitForNote(model, second)
        model.openNote(first)
        await waitForNote(model, first)
        XCTAssertEqual(model.draft, "# First\nSaved")
    }
    @MainActor
    func testFirstOpenOfMaterializedMarkdownReadsWithoutCloudHandshake() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let first = root.appendingPathComponent("第一篇.md")
        let expected = "# 第一篇\nHello, Leafspan.\n"
        try expected.write(to: first, atomically: true, encoding: .utf8)
        XCTAssertFalse(WorkspaceFiles.isDataless(first))

        let loaded = try await WorkspaceFiles.readUTF8ForOpening(first)
        XCTAssertEqual(loaded.content, expected)
        XCTAssertEqual(loaded.stamp, WorkspaceFiles.fileStamp(first))

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(first)
        await waitForNote(model, first)
        XCTAssertFalse(model.loadingNote)
        XCTAssertEqual(model.draft, expected)
        XCTAssertNil(model.message)
    }

    @MainActor
    func testMissingLastOpenedNoteIsReportedAndClearsStalePath() async throws {
        let defaults = UserDefaults.standard
        let previousWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        let previousLast = defaults.string(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let previousWorkspace { defaults.set(previousWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousLast { defaults.set(previousLast, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }

        let missing = folder.appendingPathComponent("Missing.md")
        defaults.set(missing.path, forKey: "PKSNotesLastOpenedMarkdown")
        let missingModel = NotesModel()
        XCTAssertTrue(missingModel.openWorkspace(folder))
        XCTAssertNil(missingModel.selected)
        XCTAssertEqual(missingModel.message,
                       AppLanguage.current.text("Last opened note is no longer available. Choose another note."))
        XCTAssertNil(defaults.string(forKey: "PKSNotesLastOpenedMarkdown"))

    }

}


extension PKSNotesTests {
    func testPDFSelectionAnchorSurvivesMindMapProjectionAndResolvesExactPDFTarget() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let pdf = root.appendingPathComponent("Book.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)
        let fingerprint = try XCTUnwrap(PDFSourceAnchor.fingerprint(for: "Quoted fact"))
        let anchor = try XCTUnwrap(PDFSourceAnchor(
            page: 7,
            normalizedRects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)],
            fingerprint: fingerprint
        ))

        let reference = try XCTUnwrap(PDFPageReference.markdown(
            for: pdf, page: anchor.page, root: root, anchor: anchor
        ))
        let markdown = """
        # Study

        My interpretation

        \(reference)

        > Quoted fact

        - Next topic
        """
        let nodes = MindMapOutline.nodes(in: markdown)
        let presentation = try XCTUnwrap(
            MindMapOutline.presentations(in: markdown, nodes: nodes)[0]
        )

        XCTAssertEqual(presentation.title, "Study")
        XCTAssertEqual(presentation.links, [
            MindMapLink(label: "Book.pdf · p. 7", target: "/Book.pdf#\(anchor.fragment)")
        ])

        let link = try XCTUnwrap(URL(string: presentation.links[0].target))
        XCTAssertEqual(PDFPageReference.page(from: link), 7)
        XCTAssertEqual(PDFPageReference.anchor(from: link), anchor)
        XCTAssertEqual(
            WorkspaceFiles.resolve(link, from: root.appendingPathComponent("Study.md"), in: root),
            pdf.standardizedFileURL
        )
    }

    func testMarkdownLinkCommandEscapesSpecialCharactersInSelectedLabel() throws {
        let source = #"before Research [v2] & <notes> \end after"#
        let selected = #"Research [v2] & <notes> \end"#
        let range = (source as NSString).range(of: selected)
        let result = MarkdownEditing.apply(.link, to: source, selection: range)

        XCTAssertEqual(
            result.text,
            #"before [Research &#91;v2&#93; &amp; &lt;notes&gt; &#92;end](url) after"#
        )
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "url")

        let occurrences = MindMapOutline.linkOccurrences(in: result.text)
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(occurrences.first?.link.target, "url")

        let replacement = try XCTUnwrap(MarkdownEditing.minimalChange(from: source, to: result.text))
        XCTAssertEqual(
            (source as NSString).replacingCharacters(in: replacement.range, with: replacement.text),
            result.text
        )
    }

    func testMarkdownBoldPreservesUTF16SelectionForCJKAndEmoji() {
        let source = "中文😀 note"
        let range = (source as NSString).range(of: "😀 note")
        let result = MarkdownEditing.apply(.bold, to: source, selection: range)

        XCTAssertEqual(result.text, "中文**😀 note**")
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), "😀 note")
    }

    func testMarkdownTaskCommandPrefixesEverySelectedLine() {
        let source = "one\ntwo\n"
        let result = MarkdownEditing.apply(
            .task,
            to: source,
            selection: NSRange(location: 0, length: (source as NSString).length)
        )

        XCTAssertEqual(result.text, "- [ ] one\n- [ ] two\n")
    }

    @MainActor
    func testMarkdownToolbarEditUsesOneStepAppKitUndo() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        textView.allowsUndo = true
        window.contentView = textView
        window.makeFirstResponder(textView)
        textView.string = "Hello"
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        textView.undoManager?.removeAllActions()

        XCTAssertTrue(MarkdownNativeCommand.perform("bold", in: textView))
        XCTAssertEqual(textView.string, "**Hello**")
        await Task.yield()
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "Hello")

        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.string, "Hello")
    }
}
