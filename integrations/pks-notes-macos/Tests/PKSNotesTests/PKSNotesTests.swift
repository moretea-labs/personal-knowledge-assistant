import Foundation
import AppKit
import SwiftUI
import XCTest
@testable import PKSNotes

final class PKSNotesTests: XCTestCase {
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
        XCTAssertEqual(NotesGeometry.workspaceTitle(nil, language: .english), "PKS Library")
        XCTAssertEqual(NotesGeometry.workspaceTitle(nil, language: .simplifiedChinese), "PKS 资料库")
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
        XCTAssertTrue(model.message?.contains(AppLanguage.current.text("The file changed outside PKS Notes. Reopen it before saving to avoid overwriting edits.")) == true)
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
        XCTAssertNil(model.renameItem(original, to: "Taken"))
        XCTAssertTrue(fm.fileExists(atPath: original.path))
        XCTAssertEqual(model.draft, "# Changes saved before rename")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "# Other")

        XCTAssertEqual(model.renameItem(original, to: "Renamed"), renamed)
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
        XCTAssertNil(model.renameItem(folder, to: "../Escape"))
        XCTAssertTrue(fm.fileExists(atPath: markdown.path))
        XCTAssertTrue(fm.fileExists(atPath: outsideNote.path))

        model.openNote(markdown)
        await waitForNote(model, markdown)
        XCTAssertEqual(model.renameItem(folder, to: "Archive")?.path, renamed.path)
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
        XCTAssertTrue(model.message?.contains(AppLanguage.current.text("The file changed outside PKS Notes. Reopen it before saving to avoid overwriting edits.")) == true)
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
        model.openNote(latest)
        await waitForNote(model, latest)
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
}


extension PKSNotesTests {
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

        let copied = model.copyItem(note, to: copies)
        XCTAssertEqual(copied, copies.appendingPathComponent("Note.md"))
        XCTAssertEqual(try String(contentsOf: copied!, encoding: .utf8), "# Original")
        XCTAssertNil(model.copyItem(note, to: outside))

        let moved = model.moveItem(note, to: archive, navigationDecision: .discard)
        XCTAssertEqual(moved, archive.appendingPathComponent("Note.md"))
        await waitForNote(model, archive.appendingPathComponent("Note.md"))
        XCTAssertFalse(fm.fileExists(atPath: note.path))
        XCTAssertEqual(model.selected, archive.appendingPathComponent("Note.md"))

        // The workspace root is a valid destination even though path containment
        // intentionally excludes root itself when validating document paths.
        let copiedToRoot = model.copyItem(copied!, to: root)
        XCTAssertEqual(copiedToRoot, note)
        XCTAssertEqual(try String(contentsOf: copiedToRoot!, encoding: .utf8), "# Original")
        try fm.removeItem(at: copiedToRoot!)

        let returned = model.moveItem(moved!, to: root, navigationDecision: .discard)
        XCTAssertEqual(returned, note)
        await waitForNote(model, note)
        XCTAssertEqual(model.selected, note)
    }
}


extension PKSNotesTests {
    @MainActor
    func testMoveAndCopyFolderRejectDescendantDestination() throws {
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
        XCTAssertNil(model.moveItem(parent, to: child, navigationDecision: .discard))
        XCTAssertTrue(fm.fileExists(atPath: parent.path))
        XCTAssertNil(model.copyItem(parent, to: child))
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
        XCTAssertEqual(found, [NoteBacklink(source: note.standardizedFileURL, count: 2)])
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

        XCTAssertTrue(model.appendPDFReference(pdf: pdf, page: 5, commentary: "Remember this", to: note))
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
        XCTAssertEqual(
            PDFPageReference.noteSnippet(
                for: pdf,
                page: 2,
                root: root,
                commentary: "My interpretation\n- remember this",
                selectedText: "Quoted fact"
            ),
            "My interpretation\n- remember this\n\n[Book.pdf · p. 2](/Book.pdf#page=2)\n\n> Quoted fact"
        )
    }

    @MainActor
    func testPDFPageCanAppendToMarkdownNoteWithoutLeavingPDF() throws {
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
        model.openFile(pdf, pdfPage: 4)

        XCTAssertTrue(model.appendPDFReference(
            pdf: pdf,
            page: 4,
            commentary: "My interpretation",
            selectedText: "Important fact\nSecond line",
            to: note
        ))
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        XCTAssertEqual(model.previewPDFPage, 4)
        XCTAssertNil(model.selected)

        let content = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(content.contains("My interpretation\n\n[Book.pdf · p. 4](/Book.pdf#page=4)"))
        XCTAssertTrue(content.contains("> Important fact\n> Second line"))
    }
}
