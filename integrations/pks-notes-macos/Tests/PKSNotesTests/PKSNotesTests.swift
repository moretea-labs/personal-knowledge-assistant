import Foundation
import XCTest
@testable import PKSNotes

final class PKSNotesTests: XCTestCase {
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

    func testSafeNoteNames() {
        XCTAssertEqual(WorkspaceFiles.safeNewNoteName("中文"), "中文.md")
        XCTAssertEqual(WorkspaceFiles.safeNewNoteName("test.md"), "test.md")
        XCTAssertNil(WorkspaceFiles.safeNewNoteName("../outside"))
        XCTAssertNil(WorkspaceFiles.safeNewNoteName(".private"))
        XCTAssertNil(WorkspaceFiles.safeNewNoteName("/absolute"))
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

    func testMarkdownTreeAndHiddenFiles() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = base.appendingPathComponent("分组")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try "# Root".write(to: base.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Sub".write(to: nested.appendingPathComponent("中文.md"), atomically: true, encoding: .utf8)
        try "hidden".write(to: base.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        try "asset".write(to: nested.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)
        let result = WorkspaceFiles.tree(in: base)
        XCTAssertEqual(result.map { $0.name }, ["分组", "README"])
        XCTAssertEqual(result.first?.children?.map { $0.name }, ["中文"])
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
    func testNewNoteUsesCurrentFolderWithoutOverwritingExisting() throws {
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
        model.newNote(named: "新笔记")
        XCTAssertEqual(model.selected, folder.appendingPathComponent("新笔记.md"))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("新笔记.md").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("新笔记.md").path))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "# Existing")
        model.draft = "# Draft not saved yet"
        model.newNote(named: "不能覆盖", navigationDecision: .cancel)
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("不能覆盖.md").path))
        XCTAssertEqual(model.draft, "# Draft not saved yet")
        XCTAssertTrue(model.isDirty)
    }

    @MainActor
    func testNavigationSaveDiscardCancelAndConflict() throws {
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
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# Pending")
        XCTAssertEqual(model.selected, second)
        model.draft = "# Edited but discarded"
        model.openNote(first, navigationDecision: .discard)
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
    func testCreateNoteInsideSelectedFolderWithSafeCancellation() throws {
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
        model.draft = "# Unsaved"
        model.newNote(named: "draft", in: chosen, navigationDecision: .cancel)
        XCTAssertFalse(fm.fileExists(atPath: chosen.appendingPathComponent("draft.md").path))
        model.newNote(named: "escape", in: outside, navigationDecision: .discard)
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent("escape.md").path))
        XCTAssertEqual(model.draft, "# Unsaved")
        model.newNote(named: "draft", in: chosen, navigationDecision: .discard)
        XCTAssertEqual(model.selected, chosen.appendingPathComponent("draft.md"))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "# Original")
    }

    @MainActor
    func testEditSaveAndExternalModificationConflict() throws {
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
        XCTAssertTrue(model.message?.contains("changed outside") == true)
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
        XCTAssertEqual(model.message, "The original file is not available locally.")
        model.message = nil
        model.openInDefaultApp(missing)
        XCTAssertEqual(model.message, "The original file is not available locally.")
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
    func testSameNoteResultNavigationPreservesUnsavedDraft() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let note = folder.appendingPathComponent("测试.md")
        try "# Section\nOriginal".write(to: note, atomically: true, encoding: .utf8)
        let model = NotesModel()
        model.openWorkspace(folder)
        model.openNote(note)
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
