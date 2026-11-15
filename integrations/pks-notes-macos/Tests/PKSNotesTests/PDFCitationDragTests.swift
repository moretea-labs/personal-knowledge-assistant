import AppKit
import PDFKit
import XCTest
@testable import PKSNotes

final class PDFCitationDragTests: XCTestCase {
    func testWorkspaceFileDropsCreateCanonicalLinksWithoutImportingExternalFiles() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-File-Drop-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Workspace", isDirectory: true)
        let outside = base.appendingPathComponent("Outside.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let note = root.appendingPathComponent("Study (v2).md")
        let pdf = root.appendingPathComponent("Reading (v2).pdf")
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try "Some text".write(to: note, atomically: true, encoding: .utf8)
        try Data().write(to: pdf)
        try Data().write(to: outside)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let noteLink = try XCTUnwrap(WorkspaceFiles.markdownLinkForDrop(for: note, in: root))
        let pdfLink = try XCTUnwrap(WorkspaceFiles.markdownLinkForDrop(for: pdf, in: root))
        XCTAssertEqual(noteLink, "[Study (v2)](/Study%20%28v2%29)")
        XCTAssertEqual(pdfLink, "[Reading (v2).pdf](/Reading%20%28v2%29.pdf)")
        XCTAssertEqual(
            MindMapOutline.linkOccurrences(in: noteLink).first?.link.target,
            "/Study%20%28v2%29"
        )
        XCTAssertNil(WorkspaceFiles.markdownLinkForDrop(for: folder, in: root))
        XCTAssertNil(WorkspaceFiles.markdownLinkForDrop(for: outside, in: root))
        XCTAssertNil(WorkspaceFiles.markdownLinkForDrop(
            for: root.appendingPathComponent("Missing.md"), in: root
        ))
        XCTAssertNil(WorkspaceFiles.markdownLinkForDrop(
            for: URL(string: "https://example.com/test.md")!, in: root
        ))
    }

    func testPDFReferencesEncodeLiteralPercentInWorkspaceFilenames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-PDF-Percent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pdf = root.appendingPathComponent("Reading%20(v2).pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: pdf.path, contents: Data()))
        let markdown = try XCTUnwrap(PDFPageReference.markdown(for: pdf, page: 1, root: root))
        let target = try XCTUnwrap(MindMapOutline.linkOccurrences(in: markdown).first?.link.target)
        let encodedPath = String(target.split(separator: "#", maxSplits: 1)[0])

        XCTAssertTrue(encodedPath.contains("%2520"))
        XCTAssertEqual(encodedPath.removingPercentEncoding, "/Reading%20(v2).pdf")
    }

    @MainActor
    func testSelectedTextDragCreatesPortableMarkdownQuoteWithExactAnchor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-PDF-Drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        source.string = "Important fact from the reading"
        let pdf = root.appendingPathComponent("Reading (v2).pdf")
        let generated = try XCTUnwrap(PDFDocument(data: source.dataWithPDF(inside: source.bounds)))
        XCTAssertTrue(generated.write(to: pdf))
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        let reader = PDFView(frame: source.bounds)
        let controller = PDFReaderController()
        controller.attach(view: reader, document: document, url: pdf,
                          requestedPage: nil, requestedAnchor: nil)
        defer { controller.detach(view: reader) }

        XCTAssertNil(controller.selectedCitationForDrag(pdf: pdf, root: root))
        reader.currentSelection = try XCTUnwrap(document.findString("Important fact", withOptions: []).first)
        let anchor = try XCTUnwrap(controller.selectedSourceAnchor())
        let markdown = try XCTUnwrap(controller.selectedCitationForDrag(pdf: pdf, root: root))
        XCTAssertTrue(markdown.contains(anchor.fragment))
        XCTAssertTrue(markdown.contains("Reading%20%28v2%29.pdf"))
        XCTAssertTrue(markdown.contains("> Important fact"))

        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(markdown, forType: .string))
        XCTAssertTrue(item.setString(markdown, forType: PDFCitationPasteboard.type))
        XCTAssertEqual(item.string(forType: .string), markdown)
        XCTAssertEqual(item.string(forType: PDFCitationPasteboard.type), markdown)
        XCTAssertNil(controller.selectedCitationForDrag(pdf: pdf, root: root.appendingPathComponent("NotTheWorkspace")))
    }

    @MainActor
    func testPDFCitationDropProviderLoadsTheInternalMarkdownPayload() async throws {
        let typeIdentifier = PDFCitationPasteboard.type.rawValue
        let citation = "\n\n[Reading.pdf · p. 1](/Reading.pdf#page=1)\n\n> Important fact\n\n"
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            completion(Data(citation.utf8), nil)
            return nil
        }

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(typeIdentifier))
        let loaded: String? = await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: PDFCitationPasteboard.markdown(from: item))
            }
        }
        XCTAssertEqual(loaded, citation)
        XCTAssertEqual(PDFCitationPasteboard.markdown(from: citation as NSString), citation)
        XCTAssertNil(PDFCitationPasteboard.markdown(from: Data([0xFF, 0xFE])))
        XCTAssertNil(PDFCitationPasteboard.markdown(from: Data()))
        XCTAssertNil(PDFCitationPasteboard.markdown(from: 42))
    }

    func testPDFQuoteContextMenuRequiresAnInWorkspaceMarkdownStudyNote() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-PDF-Quote-Target-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-PDF-Quote-Outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let note = root.appendingPathComponent("Study.MARKDOWN")
        let pdf = root.appendingPathComponent("Reading.pdf")
        let foreignNote = outside.appendingPathComponent("Study.md")
        let externalPDF = outside.appendingPathComponent("Outside.pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: note.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: pdf.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: foreignNote.path, contents: Data()))
        XCTAssertTrue(FileManager.default.createFile(atPath: externalPDF.path, contents: Data()))

        XCTAssertEqual(PDFStudyNoteTarget.resolve(note: note, pdf: pdf, root: root, externalBody: nil), note)
        XCTAssertNil(PDFStudyNoteTarget.resolve(note: pdf, pdf: pdf, root: root, externalBody: nil))
        XCTAssertNil(PDFStudyNoteTarget.resolve(note: foreignNote, pdf: pdf, root: root, externalBody: nil))
        XCTAssertNil(PDFStudyNoteTarget.resolve(note: note, pdf: pdf, root: root, externalBody: "External content"))
        XCTAssertNil(PDFStudyNoteTarget.resolve(note: nil, pdf: pdf, root: root, externalBody: nil))
        XCTAssertNil(PDFStudyNoteTarget.resolve(note: note, pdf: externalPDF, root: root, externalBody: nil))
    }

    @MainActor
    func testPDFContextMenuOffersNativeDirectQuoteOnlyForSelectedText() throws {
        let source = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        source.string = "Selected study evidence"
        let document = try XCTUnwrap(PDFDocument(data: source.dataWithPDF(inside: source.bounds)))
        let reader = StudyPDFView(frame: source.bounds)
        reader.document = document
        reader.quoteTitle = "Add to Study Note"
        var quoteCount = 0
        reader.onQuoteToCurrentNote = { quoteCount += 1 }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))

        XCTAssertNil(reader.menu(for: event)?.items.first {
            $0.title == "Add to Study Note"
        })
        reader.currentSelection = try XCTUnwrap(
            document.findString("Selected study evidence", withOptions: []).first
        )
        let quote = try XCTUnwrap(reader.menu(for: event)?.items.first {
            $0.title == "Add to Study Note"
        })
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(quote.action), to: quote.target, from: quote
        ))
        XCTAssertEqual(quoteCount, 1)
        reader.onQuoteToCurrentNote = nil
        XCTAssertNil(reader.menu(for: event)?.items.first {
            $0.title == "Add to Study Note"
        })
    }

    @MainActor
    func testPDFCitationInsertionAtDropCaretUsesOneStepNativeUndo() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        textView.allowsUndo = true
        window.contentView = textView
        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.string = "Before After"
        textView.undoManager?.removeAllActions()

        let citation = "\n\n[Reading.pdf · p. 1](/Reading.pdf#page=1&rects=...) \n\n> Important fact\n\n"
        let insertionPoint = ("Before " as NSString).length
        textView.setSelectedRange(NSRange(location: insertionPoint, length: 5))
        XCTAssertFalse(MarkdownNativeCommand.insertAtCaret(citation, in: textView))
        XCTAssertEqual(textView.string, "Before After")
        textView.setSelectedRange(NSRange(location: insertionPoint, length: 0))
        XCTAssertTrue(MarkdownNativeCommand.insertAtCaret(citation, in: textView))
        XCTAssertEqual(textView.string, "Before " + citation + "After")

        await Task.yield()
        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.string, "Before After")
    }

    @MainActor
    func testPDFCitationMenuInsertionKeepsHeadingAndListTitlesIntactWithNativeUndo() async throws {
        let citation = "\n\n[Reading.pdf · p. 1](/Reading.pdf#page=1)\n\n> Important fact\n\n"
        for (markdown, titleFragment, nodeTitle) in [
            ("# 😀Root\n## Next\n", "Root", "😀Root"),
            ("# Root\n- 😀Concept\n- Next\n", "Concept", "😀Concept")
        ] {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
                styleMask: [], backing: .buffered, defer: true
            )
            let editor = NSTextView(frame: window.contentView?.bounds ?? .zero)
            editor.allowsUndo = true
            window.contentView = editor
            XCTAssertTrue(window.makeFirstResponder(editor))
            editor.string = markdown
            editor.undoManager?.removeAllActions()
            let caret = (markdown as NSString).range(of: titleFragment).location + 2
            editor.setSelectedRange(NSRange(location: caret, length: 0))

            XCTAssertTrue(PDFCitationDropTarget.insertAtCaret(citation, in: editor))
            let nodes = MindMapOutline.nodes(in: editor.string)
            let node = try XCTUnwrap(nodes.first(where: { $0.title == nodeTitle }))
            let links = MindMapOutline.presentations(in: editor.string, nodes: nodes)
            XCTAssertEqual(links[node.id]?.links.map(\.target), ["/Reading.pdf#page=1"])
            XCTAssertTrue(editor.string.contains("> Important fact"))
            XCTAssertEqual(nodes.count, MindMapOutline.nodes(in: markdown).count)

            await Task.yield()
            let undoManager = try XCTUnwrap(editor.undoManager)
            XCTAssertTrue(undoManager.canUndo)
            undoManager.undo()
            XCTAssertEqual(editor.string, markdown)
        }
    }

    @MainActor
    func testPDFCitationMenuInsertionRejectsSelectedTextAndCode() {
        let editor = NSTextView()
        let markdown = "# Root\n`code`\n"
        editor.string = markdown
        let codeLocation = (markdown as NSString).range(of: "code").location + 1
        editor.setSelectedRange(NSRange(location: codeLocation, length: 0))
        XCTAssertFalse(PDFCitationDropTarget.insertAtCaret("\n\n> Quote\n\n", in: editor))
        editor.setSelectedRange(NSRange(location: 2, length: 2))
        XCTAssertFalse(PDFCitationDropTarget.insertAtCaret("\n\n> Quote\n\n", in: editor))
        XCTAssertEqual(editor.string, markdown)
    }

    func testPDFCitationDropInsideMindMapListKeepsTheGeneratedAnchorMovableWithItsNode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-PDF-Map-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pdf = root.appendingPathComponent("Reading (v2).pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: pdf.path, contents: Data()))
        let fingerprint = try XCTUnwrap(PDFSourceAnchor.fingerprint(for: "Important fact"))
        let anchor = try XCTUnwrap(PDFSourceAnchor(
            page: 1,
            normalizedRects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)],
            fingerprint: fingerprint
        ))
        let snippet = try XCTUnwrap(PDFPageReference.noteSnippet(
            for: pdf, page: 1, root: root, selectedText: "Important fact", anchor: anchor
        ))
        let citation = "\n\n\(snippet)\n\n"
        let markdown = "# Root\n- Parent\n  - Concept\n    Existing text\n- Next\n"
        let offset = (markdown as NSString).range(of: "Existing text").location
            + ("Existing text" as NSString).length

        let formatted = PDFCitationDropTarget.citationForInsertion(
            citation, in: markdown, at: offset
        )
        XCTAssertTrue(formatted.contains("\n    [Reading (v2).pdf · p. 1](/Reading%20%28v2%29.pdf#"))
        XCTAssertTrue(formatted.contains("\n    > Important fact"))

        let inserted = MarkdownEditing.insert(
            formatted, into: markdown, selection: NSRange(location: offset, length: 0)
        ).text
        let nodes = MindMapOutline.nodes(in: inserted)
        let parent = try XCTUnwrap(nodes.first(where: { $0.title == "Parent" }))
        let concept = try XCTUnwrap(nodes.first(where: { $0.title == "Concept" }))
        let presentations = MindMapOutline.presentations(in: inserted, nodes: nodes)
        let expectedTarget = "/Reading%20%28v2%29.pdf#\(anchor.fragment)"

        XCTAssertEqual(presentations[concept.id]?.links.map(\.target), [expectedTarget])
        XCTAssertEqual(presentations[parent.id]?.links, [])
        XCTAssertTrue(MindMapOutline.actionAvailability(in: inserted, nodeID: concept.id).canPromote)
        XCTAssertEqual(
            PDFCitationDropTarget.citationForInsertion(citation, in: "# Root\nSummary\n", at: 10),
            citation
        )
        let trailingList = "# Root\n- Concept\n"
        let trailingOffset = (trailingList as NSString).length
        let trailingInsertion = PDFCitationDropTarget.citationForInsertion(
            citation, in: trailingList, at: trailingOffset
        )
        XCTAssertTrue(trailingInsertion.contains("\n  [Reading (v2).pdf · p. 1](/Reading%20%28v2%29.pdf#"))
        XCTAssertTrue(trailingInsertion.contains("\n  > Important fact"))
    }

    func testPDFCitationInsertedIntoPaddedNumberedListStaysWithinItsMarkdownItem() throws {
        let markdown = "# Root\n10.    Concept\n11. Next\n"
        let citation = "\n\n[Reading.pdf · p. 1](/Reading.pdf#page=1)\n\n> Evidence\n\n"
        let offset = (markdown as NSString).range(of: "Concept").location + 3
        let targetIndex = PDFCitationDropTarget.citationInsertionOffset(in: markdown, at: offset)
        let formatted = PDFCitationDropTarget.citationForInsertion(
            citation, in: markdown, at: targetIndex
        )
        let fromMenu = MarkdownEditing.insert(
            formatted, into: markdown, selection: NSRange(location: targetIndex, length: 0)
        ).text
        let fromMap = try XCTUnwrap(PDFCitationDropTarget.citationForNodeInsertion(
            citation, in: markdown, nodeID: 1
        ))
        for rendered in [fromMenu, fromMap] {
            XCTAssertTrue(rendered.contains("\n       [Reading.pdf · p. 1]"))
            XCTAssertTrue(rendered.contains("\n       > Evidence"))
            let nodes = MindMapOutline.nodes(in: rendered)
            let concept = try XCTUnwrap(nodes.first(where: { $0.title == "Concept" }))
            let links = MindMapOutline.presentations(in: rendered, nodes: nodes)
            XCTAssertEqual(links[concept.id]?.links.map(\.target), ["/Reading.pdf#page=1"])
        }
        XCTAssertEqual(MindMapOutline.listContinuationIndent(in: markdown, nodeID: 1), 7)
    }

    func testPDFCitationInsertedIntoTabPaddedNumberedListStaysWithinItsMarkdownItem() throws {
        let markdown = "# Root\n10.\tConcept\n11.\tNext\n"
        let citation = "\n\n[Reading.pdf · p. 1](/Reading.pdf#page=1)\n\n> Evidence\n\n"
        let offset = (markdown as NSString).range(of: "Concept").location + 3
        let targetIndex = PDFCitationDropTarget.citationInsertionOffset(in: markdown, at: offset)
        let formatted = PDFCitationDropTarget.citationForInsertion(
            citation, in: markdown, at: targetIndex
        )
        let fromMenu = MarkdownEditing.insert(
            formatted, into: markdown, selection: NSRange(location: targetIndex, length: 0)
        ).text
        let fromMap = try XCTUnwrap(PDFCitationDropTarget.citationForNodeInsertion(
            citation, in: markdown, nodeID: 1
        ))
        for rendered in [fromMenu, fromMap] {
            XCTAssertTrue(rendered.contains("\n    [Reading.pdf · p. 1]"))
            XCTAssertTrue(rendered.contains("\n    > Evidence"))
            let nodes = MindMapOutline.nodes(in: rendered)
            let concept = try XCTUnwrap(nodes.first(where: { $0.title == "Concept" }))
            let links = MindMapOutline.presentations(in: rendered, nodes: nodes)
            XCTAssertEqual(links[concept.id]?.links.map(\.target), ["/Reading.pdf#page=1"])
        }
        XCTAssertEqual(MindMapOutline.listContinuationIndent(in: markdown, nodeID: 1), 4)
    }

    func testPDFCitationInsertedIntoNumberedListStaysWithinItsMarkdownItem() throws {
        let markdown = "# Root\n10. Concept\n11. Next\n"
        let citation = "\n\n[Reading.pdf · p. 1](/Reading.pdf#page=1)\n\n> Evidence\n\n"
        let offset = (markdown as NSString).range(of: "Concept").location + 3
        let targetIndex = PDFCitationDropTarget.citationInsertionOffset(in: markdown, at: offset)
        let formatted = PDFCitationDropTarget.citationForInsertion(
            citation, in: markdown, at: targetIndex
        )
        let fromMenu = MarkdownEditing.insert(
            formatted, into: markdown, selection: NSRange(location: targetIndex, length: 0)
        ).text
        let fromMap = try XCTUnwrap(PDFCitationDropTarget.citationForNodeInsertion(
            citation, in: markdown, nodeID: 1
        ))
        for rendered in [fromMenu, fromMap] {
            XCTAssertTrue(rendered.contains("\n    [Reading.pdf · p. 1]"))
            XCTAssertTrue(rendered.contains("\n    > Evidence"))
            XCTAssertTrue(rendered.contains("\n11. Next\n"))
            let nodes = MindMapOutline.nodes(in: rendered)
            let concept = try XCTUnwrap(nodes.first(where: { $0.title == "Concept" }))
            let next = try XCTUnwrap(nodes.first(where: { $0.title == "Next" }))
            let links = MindMapOutline.presentations(in: rendered, nodes: nodes)
            XCTAssertEqual(links[concept.id]?.links.map(\.target), ["/Reading.pdf#page=1"])
            XCTAssertEqual(links[next.id]?.links, [])
        }
        XCTAssertEqual(MindMapOutline.listContinuationIndent(in: markdown, nodeID: 1), 4)
        XCTAssertEqual(MindMapOutline.listContinuationIndent(in: "001. Concept\n", nodeID: 0), 5)
        XCTAssertEqual(MindMapOutline.listContinuationIndent(in: "1) Concept\n", nodeID: 0), 3)
        XCTAssertEqual(MindMapOutline.listContinuationIndent(in: "- Concept\n", nodeID: 0), 2)
    }

    func testPDFCitationDropOnMindMapListNodeAttachesToItsOwnMarkdownBody() throws {
        let citation = "\n\n[Reading (v2).pdf · p. 1](/Reading%20%28v2%29.pdf#page=1&rects=...)\n\n> Important fact\n\n"
        let markdown = "# Root\n- 😀Concept\n  Existing note\n  - Child\n    Child note\n- Next\n"
        let target = "/Reading%20%28v2%29.pdf#page=1&rects=..."

        let inserted = try XCTUnwrap(PDFCitationDropTarget.citationForNodeInsertion(
            citation, in: markdown, nodeID: 1
        ))
        let nodes = MindMapOutline.nodes(in: inserted)
        let concept = try XCTUnwrap(nodes.first(where: { $0.title == "😀Concept" }))
        let child = try XCTUnwrap(nodes.first(where: { $0.title == "Child" }))
        let presentations = MindMapOutline.presentations(in: inserted, nodes: nodes)

        XCTAssertEqual(nodes.map(\.title), ["Root", "😀Concept", "Child", "Next"])
        XCTAssertEqual(presentations[concept.id]?.links.map(\.target), [target])
        XCTAssertTrue(presentations[concept.id]?.body.contains("> Important fact") == true)
        XCTAssertEqual(presentations[child.id]?.links, [])
        XCTAssertTrue(inserted.contains("  Existing note\n\n  [Reading (v2).pdf"))
        XCTAssertLessThan(
            try XCTUnwrap(inserted.range(of: "Important fact")).lowerBound,
            try XCTUnwrap(inserted.range(of: "  - Child")).lowerBound
        )

        let root = try XCTUnwrap(nodes.first(where: { $0.title == "Root" }))
        XCTAssertEqual(presentations[root.id]?.links, [])
    }

    func testPDFCitationDropOnMindMapHeadingAttachesBeforeTheNextHeading() throws {
        let citation = "\n\n[Reading.pdf · p. 2](/Reading.pdf#page=2&rects=...)\n\n> Selected passage\n\n"
        let markdown = "# Root\nOverview\n## Child\nChild text\n"
        let inserted = try XCTUnwrap(PDFCitationDropTarget.citationForNodeInsertion(
            citation, in: markdown, nodeID: 0
        ))
        let nodes = MindMapOutline.nodes(in: inserted)
        let root = try XCTUnwrap(nodes.first(where: { $0.title == "Root" }))
        let child = try XCTUnwrap(nodes.first(where: { $0.title == "Child" }))
        let presentations = MindMapOutline.presentations(in: inserted, nodes: nodes)

        XCTAssertEqual(presentations[root.id]?.links.map(\.target), ["/Reading.pdf#page=2&rects=..."])
        XCTAssertEqual(presentations[child.id]?.links, [])
        XCTAssertTrue(presentations[root.id]?.body.contains("> Selected passage") == true)
        XCTAssertLessThan(
            try XCTUnwrap(inserted.range(of: "Selected passage")).lowerBound,
            try XCTUnwrap(inserted.range(of: "## Child")).lowerBound
        )
    }

    func testMindMapNodeCitationAndWorkspaceLinkPreserveCRLFMarkdown() throws {
        let markdown = "# Root\r\n- Concept\r\n- Next\r\n"
        let citation = "\n\n[Reading.pdf · p. 2](/Reading.pdf#page=2&rects=...)\n\n> Evidence\r\nLine two\n\n"
        let inserted = try XCTUnwrap(PDFCitationDropTarget.citationForNodeInsertion(
            citation, in: markdown, nodeID: 1
        ))
        XCTAssertTrue(inserted.contains("- Concept\r\n\r\n  [Reading.pdf · p. 2]"))
        XCTAssertFalse(
            inserted.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
            "A PDF quote must not add bare LF to an imported CRLF note."
        )
        let nodes = MindMapOutline.nodes(in: inserted)
        let concept = try XCTUnwrap(nodes.first(where: { $0.title == "Concept" }))
        let next = try XCTUnwrap(nodes.first(where: { $0.title == "Next" }))
        let presentations = MindMapOutline.presentations(in: inserted, nodes: nodes)
        XCTAssertEqual(presentations[concept.id]?.links.map(\.target),
                       ["/Reading.pdf#page=2&rects=..."])
        XCTAssertEqual(presentations[next.id]?.links, [])

        let linked = try XCTUnwrap(MindMapOutline.appendMarkdownLinkToNodeBody(
            "[Outline](/Outline.md)", in: markdown, nodeID: 1
        ))
        XCTAssertFalse(
            linked.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
            "A workspace-file link drop must keep the same line-ending convention."
        )
        let linkedNodes = MindMapOutline.nodes(in: linked)
        let linkedConcept = try XCTUnwrap(linkedNodes.first(where: { $0.title == "Concept" }))
        let linkedPresentations = MindMapOutline.presentations(in: linked, nodes: linkedNodes)
        XCTAssertEqual(linkedPresentations[linkedConcept.id]?.links.map(\.target), ["/Outline.md"])
    }

    @MainActor
    func testPDFCitationMarkdownPersistsAndReopensWithExactAnchor() async throws {
        let defaults = UserDefaults.standard
        let previousWorkspace = defaults.object(forKey: "PKSNotesWorkspace")
        let previousBookmark = defaults.object(forKey: "PKSNotesWorkspaceBookmark")
        let previousLastOpened = defaults.object(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let previousWorkspace { defaults.set(previousWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousBookmark { defaults.set(previousBookmark, forKey: "PKSNotesWorkspaceBookmark") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark") }
            if let previousLastOpened { defaults.set(previousLastOpened, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-PDF-Roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(root.path, forKey: "PKSNotesWorkspace")
        defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark")
        defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown")

        let pdf = root.appendingPathComponent("Reading (v2).pdf")
        XCTAssertTrue(FileManager.default.createFile(atPath: pdf.path, contents: Data()))
        let fingerprint = try XCTUnwrap(PDFSourceAnchor.fingerprint(for: "Important fact"))
        let anchor = try XCTUnwrap(PDFSourceAnchor(
            page: 1,
            normalizedRects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)],
            fingerprint: fingerprint
        ))
        let snippet = try XCTUnwrap(PDFPageReference.noteSnippet(for: pdf, page: 1, root: root, selectedText: "Important fact", anchor: anchor))
        let citation = "\n\n\(snippet)\n\n"
        let markdown = "# Root\n- Parent\n  - Concept\n    Existing text\n- Next\n"
        let offset = (markdown as NSString).range(of: "Existing text").location
            + ("Existing text" as NSString).length
        let formatted = PDFCitationDropTarget.citationForInsertion(citation, in: markdown, at: offset)
        let inserted = MarkdownEditing.insert(
            formatted, into: markdown, selection: NSRange(location: offset, length: 0)
        ).text
        let expectedTarget = "/Reading%20%28v2%29.pdf#\(anchor.fragment)"

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let note = try XCTUnwrap(model.newNote(named: "Study", in: root, initialContent: markdown))
        for _ in 0..<400 where model.selected != note || model.loadingNote { await Task.yield() }
        XCTAssertEqual(model.selected, note)
        XCTAssertFalse(model.loadingNote)

        model.draft = inserted
        XCTAssertTrue(model.isDirty)
        model.save()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), inserted)

        let reopened = NotesModel()
        XCTAssertTrue(reopened.openWorkspace(root))
        reopened.openNote(note)
        for _ in 0..<400 where reopened.selected != note || reopened.loadingNote { await Task.yield() }
        XCTAssertEqual(reopened.selected, note)
        XCTAssertFalse(reopened.loadingNote)
        XCTAssertEqual(reopened.draft, inserted)
        let nodes = MindMapOutline.nodes(in: reopened.draft)
        let concept = try XCTUnwrap(nodes.first(where: { $0.title == "Concept" }))
        let links = MindMapOutline.presentations(in: reopened.draft, nodes: nodes)
        XCTAssertEqual(links[concept.id]?.links.map(\.target), [expectedTarget])
    }

    func testPDFCitationDropOnMindMapTitleAttachesToNodeWithoutSplittingTitle() throws {
        let markdown = "# Root\n- 😀Concept\n- Next\n"
        let titleRange = (markdown as NSString).range(of: "Concept")
        let pointerOffset = titleRange.location + 3
        let insertionOffset = PDFCitationDropTarget.citationInsertionOffset(
            in: markdown, at: pointerOffset
        )
        XCTAssertEqual(
            (markdown as NSString).substring(to: insertionOffset),
            "# Root\n- 😀Concept"
        )

        let citation = "\n\n[Reading.pdf · p. 1](/Reading.pdf#page=1)\n\n> Important fact\n\n"
        let formatted = PDFCitationDropTarget.citationForInsertion(
            citation, in: markdown, at: insertionOffset
        )
        let inserted = MarkdownEditing.insert(
            formatted, into: markdown, selection: NSRange(location: insertionOffset, length: 0)
        ).text
        let nodes = MindMapOutline.nodes(in: inserted)
        let concept = try XCTUnwrap(nodes.first(where: { $0.title == "😀Concept" }))
        let next = try XCTUnwrap(nodes.first(where: { $0.title == "Next" }))
        XCTAssertGreaterThan(next.id, concept.id)
        let presentations = MindMapOutline.presentations(in: inserted, nodes: nodes)
        XCTAssertEqual(presentations[concept.id]?.links.map(\.target), ["/Reading.pdf#page=1"])
        XCTAssertTrue(inserted.contains("> Important fact"))
        XCTAssertEqual(
            PDFCitationDropTarget.citationInsertionOffset(
                in: markdown, at: (markdown as NSString).range(of: "Concept").location + 2
            ),
            insertionOffset
        )

        let body = "# Root\n- Parent\n  Existing body\n"
        let bodyOffset = (body as NSString).range(of: "Existing body").location + 3
        XCTAssertEqual(
            PDFCitationDropTarget.citationInsertionOffset(in: body, at: bodyOffset),
            bodyOffset
        )
    }


    func testPDFCitationDropOnCRLFListTitleAttachesToNodeBody() throws {
        let markdown = "# Root\r\n- Concept\r\n- Next\r\n"
        let offset = (markdown as NSString).range(of: "Concept").location + 3
        let targetOffset = PDFCitationDropTarget.citationInsertionOffset(in: markdown, at: offset)
        XCTAssertEqual((markdown as NSString).substring(to: targetOffset), "# Root\r\n- Concept")

        let citation = "\n\n[Reading.pdf · p. 2](/Reading.pdf#page=2)\n\n> Evidence\n\n"
        let formatted = PDFCitationDropTarget.citationForInsertion(citation, in: markdown, at: targetOffset)
        let inserted = MarkdownEditing.insert(
            formatted, into: markdown, selection: NSRange(location: targetOffset, length: 0)
        ).text

        XCTAssertTrue(inserted.contains("\r\n  [Reading.pdf · p. 2]"))
        XCTAssertFalse(inserted.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        let nodes = MindMapOutline.nodes(in: inserted)
        let concept = try XCTUnwrap(nodes.first(where: { $0.title == "Concept" }))
        let next = try XCTUnwrap(nodes.first(where: { $0.title == "Next" }))
        XCTAssertGreaterThan(next.id, concept.id)
        let presentations = MindMapOutline.presentations(in: inserted, nodes: nodes)
        XCTAssertEqual(presentations[concept.id]?.links.map(\.target), ["/Reading.pdf#page=2"])
        XCTAssertEqual(presentations[next.id]?.links, [])
    }

    func testPDFCitationDropRejectsFencedAndInlineCodeRegions() throws {
        let fenced = """
        # Root
        - Parent
          ```swift
          print("do not split this block")
          ```
        - Next
        """
        let fencedOffset = (fenced as NSString).range(of: "do not split").location + 4
        XCTAssertTrue(MindMapOutline.isInsideCode(in: fenced, at: fencedOffset))
        XCTAssertFalse(MindMapOutline.isInsideCode(
            in: fenced, at: (fenced as NSString).range(of: "Parent").location
        ))

        let inline = "# Root\n- Parent with `inline code` and normal text\n"
        let inlineOffset = (inline as NSString).range(of: "inline code").location + 3
        XCTAssertTrue(MindMapOutline.isInsideCode(in: inline, at: inlineOffset))
        XCTAssertFalse(MindMapOutline.isInsideCode(
            in: inline, at: (inline as NSString).range(of: "normal text").location
        ))

        let unclosed = "# Root\n- Parent\n  ```swift\n  print(1)\n"
        let unclosedOffset = (unclosed as NSString).range(of: "print").location + 2
        XCTAssertTrue(MindMapOutline.isInsideCode(in: unclosed, at: unclosedOffset))
    }

    func testPDFCitationDropRejectsIndentedCodeButAllowsNestedList() {
        let markdown = """
        # Root
            [root code link](/root.pdf)
        - Parent
              - nested code node
              [nested code link](/nested.pdf)
          - Real child
        """
        XCTAssertTrue(MindMapOutline.isInsideCode(
            in: markdown, at: (markdown as NSString).range(of: "root code link").location
        ))
        XCTAssertTrue(MindMapOutline.isInsideCode(
            in: markdown, at: (markdown as NSString).range(of: "nested code node").location
        ))
        XCTAssertFalse(MindMapOutline.isInsideCode(
            in: markdown, at: (markdown as NSString).range(of: "Real child").location
        ))
    }

    func testPDFCitationDropOnHeadingTitleAttachesToHeadingBodyWithoutSplittingTitle() throws {
        let markdown = "# 😀Root\n## Next\n"
        let titleRange = (markdown as NSString).range(of: "Root")
        let pointerOffset = titleRange.location + 2
        let insertionOffset = PDFCitationDropTarget.citationInsertionOffset(
            in: markdown, at: pointerOffset
        )
        XCTAssertEqual(
            (markdown as NSString).substring(to: insertionOffset),
            "# 😀Root"
        )

        let citation = "\n\n[Reading.pdf · p. 1](/Reading.pdf#page=1)\n\n> Important fact\n\n"
        let formatted = PDFCitationDropTarget.citationForInsertion(
            citation, in: markdown, at: insertionOffset
        )
        let inserted = MarkdownEditing.insert(
            formatted, into: markdown, selection: NSRange(location: insertionOffset, length: 0)
        ).text
        let nodes = MindMapOutline.nodes(in: inserted)
        let root = try XCTUnwrap(nodes.first(where: { $0.title == "😀Root" }))
        let next = try XCTUnwrap(nodes.first(where: { $0.title == "Next" }))
        let presentations = MindMapOutline.presentations(in: inserted, nodes: nodes)

        XCTAssertEqual(presentations[root.id]?.links.map(\.target), ["/Reading.pdf#page=1"])
        XCTAssertEqual(presentations[next.id]?.links, [])
    }

    @MainActor
    func testPDFCitationDropResolvesTheFrontmostWindowUnderThePointer() throws {
        let backWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let frontWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 0, width: 240, height: 200),
            styleMask: [],
            backing: .buffered,
            defer: true
        )

        XCTAssertTrue(
            PDFCitationDropTarget.window(
                at: NSPoint(x: 150, y: 100),
                in: [frontWindow, backWindow]
            ) === frontWindow
        )
        XCTAssertTrue(
            PDFCitationDropTarget.window(
                at: NSPoint(x: 20, y: 100),
                in: [frontWindow, backWindow]
            ) === backWindow
        )
        XCTAssertNil(
            PDFCitationDropTarget.window(
                at: NSPoint(x: 500, y: 100),
                in: [frontWindow, backWindow]
            )
        )
    }

    @MainActor
    func testPDFCitationDropResolvesTheTextViewUnderThePointer() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        let first = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 180))
        let second = NSTextView(frame: NSRect(x: 220, y: 0, width: 180, height: 180))
        first.isEditable = true
        second.isEditable = true
        root.addSubview(first)
        root.addSubview(second)
        window.contentView = root

        let firstScreenPoint = window.convertPoint(
            toScreen: first.convert(NSPoint(x: 24, y: 24), to: nil)
        )
        let secondScreenPoint = window.convertPoint(
            toScreen: second.convert(NSPoint(x: 24, y: 24), to: nil)
        )

        XCTAssertTrue(
            PDFCitationDropTarget.editableTextView(at: firstScreenPoint, in: window) === first
        )
        XCTAssertTrue(
            PDFCitationDropTarget.editableTextView(at: secondScreenPoint, in: window) === second
        )

        let outsideScreenPoint = window.convertPoint(
            toScreen: NSPoint(x: 500, y: 220)
        )
        XCTAssertNil(PDFCitationDropTarget.editableTextView(at: outsideScreenPoint, in: window))
    }

    @MainActor
    func testPDFCitationDropTargetKeepsTheOriginalNoteRevisionAndCaret() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
        textView.allowsUndo = true
        window.contentView = textView

        textView.string = "Before After"
        textView.undoManager?.removeAllActions()
        let note = URL(fileURLWithPath: "/tmp/Study.md")
        let otherNote = URL(fileURLWithPath: "/tmp/Other.md")
        let textPoint = NSPoint(x: 54, y: 15)
        let screenPoint = window.convertPoint(
            toScreen: textView.convert(textPoint, to: nil)
        )
        let expectedIndex = textView.characterIndexForInsertion(at: textPoint)
        let target = try XCTUnwrap(PDFCitationDropTarget(
            screenPoint: screenPoint,
            note: note,
            draftRevision: 7,
            textView: textView
        ))
        XCTAssertEqual(target.insertionIndex, expectedIndex)

        XCTAssertFalse(target.insert(
            "wrong note", currentNote: otherNote,
            currentDraftRevision: 7, canEdit: true
        ))
        XCTAssertFalse(target.insert(
            "stale draft", currentNote: note,
            currentDraftRevision: 8, canEdit: true
        ))
        XCTAssertEqual(textView.string, "Before After")

        let citation = "\n\n[Reading.pdf · p. 1](/Reading.pdf#page=1)\n\n> Important fact\n\n"
        XCTAssertTrue(target.insert(
            citation, currentNote: note,
            currentDraftRevision: 7, canEdit: true
        ))
        let expected = ("Before After" as NSString).replacingCharacters(
            in: NSRange(location: expectedIndex, length: 0),
            with: citation
        )
        XCTAssertEqual(textView.string, expected)

        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.string, "Before After")

        let fileLink = "[Study](/Study)"
        XCTAssertTrue(target.insert(
            fileLink, currentNote: note,
            currentDraftRevision: 7, canEdit: true, asFileLink: true
        ))
        let expectedFileLink = ("Before After" as NSString).replacingCharacters(
            in: NSRange(location: expectedIndex, length: 0),
            with: fileLink
        )
        XCTAssertEqual(textView.string, expectedFileLink)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.string, "Before After")

        // Provider loading is asynchronous. If the editor changes while the
        // drop payload is being read, the old pointer offset is no longer safe.
        textView.string = "Changed while the drop payload was loading"
        let changedText = textView.string
        XCTAssertFalse(target.insert(
            citation, currentNote: note,
            currentDraftRevision: 7, canEdit: true
        ))
        XCTAssertEqual(textView.string, changedText)
    }

    @MainActor
    func testSelectedMultiPageTextFallsBackToPageLink() async throws {
        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let first = NSTextView(frame: bounds)
        first.string = "Page one quotation"
        let second = NSTextView(frame: bounds)
        second.string = "Page two quotation"
        let document = PDFDocument()
        let firstPDF = try XCTUnwrap(PDFDocument(data: first.dataWithPDF(inside: bounds)))
        let secondPDF = try XCTUnwrap(PDFDocument(data: second.dataWithPDF(inside: bounds)))
        document.insert(try XCTUnwrap(firstPDF.page(at: 0)), at: 0)
        document.insert(try XCTUnwrap(secondPDF.page(at: 0)), at: 1)

        let root = FileManager.default.temporaryDirectory
        let pdf = root.appendingPathComponent("Leafspan-Drag-\(UUID().uuidString).pdf")
        let reader = PDFView(frame: bounds)
        let controller = PDFReaderController()
        controller.attach(view: reader, document: document, url: pdf,
                          requestedPage: nil, requestedAnchor: nil)
        defer { controller.detach(view: reader) }

        let selected = try XCTUnwrap(document.findString("Page one quotation", withOptions: []).first)
        selected.add(try XCTUnwrap(document.findString("Page two quotation", withOptions: []).first))
        reader.currentSelection = selected
        XCTAssertNil(controller.selectedSourceAnchor())
        await Task.yield()
        XCTAssertTrue(controller.selectionNeedsPageOnlyReference)
        let markdown = try XCTUnwrap(controller.selectedCitationForDrag(pdf: pdf, root: root))
        XCTAssertTrue(markdown.contains("#page=1"))
        XCTAssertFalse(markdown.contains("&rects="))
        XCTAssertTrue(markdown.contains("> Page one quotation"))
        XCTAssertTrue(markdown.contains("> Page two quotation"))

        reader.currentSelection = nil
        await Task.yield()
        XCTAssertFalse(controller.selectionNeedsPageOnlyReference)
    }
}


extension PDFCitationDragTests {
    @MainActor
    func testPDFCaptureDuringPendingNoteSwitchLeavesBothNotesUnchanged() async throws {
        let defaults = UserDefaults.standard
        let priorWorkspace = defaults.object(forKey: "PKSNotesWorkspace")
        let priorBookmark = defaults.object(forKey: "PKSNotesWorkspaceBookmark")
        let priorNote = defaults.object(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let priorWorkspace { defaults.set(priorWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let priorBookmark { defaults.set(priorBookmark, forKey: "PKSNotesWorkspaceBookmark") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark") }
            if let priorNote { defaults.set(priorNote, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "Leafspan-Capture-Switch-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        defaults.removeObject(forKey: "PKSNotesWorkspace")
        defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark")
        defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown")

        let oldNote = root.appendingPathComponent("Old.md")
        let nextNote = root.appendingPathComponent("Next.md")
        let pdf = root.appendingPathComponent("Source.pdf")
        try "# Old\n\nKeep existing evidence.\n".write(to: oldNote, atomically: true, encoding: .utf8)
        try "# Next\n\nKeep next note.\n".write(to: nextNote, atomically: true, encoding: .utf8)
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: pdf)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(oldNote)
        for _ in 0..<400 where model.loadingNote {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.selected, oldNote.standardizedFileURL)
        let priorDraft = model.draft

        model.openNote(nextNote)
        XCTAssertTrue(model.loadingNote)
        let saved = await model.appendPDFReference(pdf: pdf, page: 1, to: oldNote)
        XCTAssertFalse(saved, "A stale selected-note capture cannot be saved while navigation is pending")
        XCTAssertEqual(model.draft, priorDraft, "A rejected capture must not alter the current editor")
        XCTAssertEqual(try String(contentsOf: oldNote, encoding: .utf8), priorDraft)

        for _ in 0..<400 where model.loadingNote {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.selected, nextNote.standardizedFileURL)
        XCTAssertEqual(model.draft, "# Next\n\nKeep next note.\n")
        XCTAssertEqual(try String(contentsOf: nextNote, encoding: .utf8), model.draft)
    }

    @MainActor
    func testNewPDFCaptureNoteUsesWorkspaceRootAndPreservesSourcePreview() async throws {
        let defaults = UserDefaults.standard
        let keys = ["PKSNotesWorkspace", "PKSNotesWorkspaceBookmark", "PKSNotesLastOpenedMarkdown"]
        let originals = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                if let original { defaults.set(original, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-PDF-New-Note-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Study", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentNote = nested.appendingPathComponent("Current.md")
        let conflictingName = nested.appendingPathComponent("Reading · p.1.md")
        try "# Current".write(to: currentNote, atomically: true, encoding: .utf8)
        try "# Existing nested note".write(to: conflictingName, atomically: true, encoding: .utf8)

        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let source = NSTextView(frame: bounds)
        source.string = "Key evidence from the reading"
        let pdf = root.appendingPathComponent("Reading.pdf")
        let document = try XCTUnwrap(PDFDocument(data: source.dataWithPDF(inside: bounds)))
        XCTAssertTrue(document.write(to: pdf))
        let view = PDFView(frame: bounds)
        let reader = PDFReaderController()
        reader.attach(view: view, document: document, url: pdf,
                      requestedPage: nil, requestedAnchor: nil)
        defer { reader.detach(view: view) }
        view.currentSelection = try XCTUnwrap(document.findString("Key evidence", withOptions: []).first)
        let quote = try XCTUnwrap(reader.selectedText())
        let anchor = try XCTUnwrap(reader.selectedSourceAnchor())

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(currentNote)
        for _ in 0..<400 where model.selected != currentNote || model.loadingNote {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.selected, currentNote.standardizedFileURL)
        model.openFile(pdf, pdfPage: 1)
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)

        let created = try XCTUnwrap(model.createNoteFromPDFCapture(
            pdf: pdf, page: 1, commentary: "My understanding",
            selectedText: quote, anchor: anchor
        ))
        XCTAssertEqual(created.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: conflictingName, encoding: .utf8), "# Existing nested note")
        for _ in 0..<400 where model.selected != created || model.loadingNote {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.selected, created.standardizedFileURL)
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        let persisted = try String(contentsOf: created, encoding: .utf8)
        XCTAssertEqual(model.draft, persisted)
        XCTAssertTrue(persisted.contains("My understanding"))
        XCTAssertTrue(persisted.contains("> Key evidence"))
        let link = try XCTUnwrap(MindMapOutline.linkOccurrences(in: persisted).first?.link.target)
        XCTAssertEqual(link, "/Reading.pdf#\(anchor.fragment)")
        XCTAssertTrue(model.openKnowledgeLink(link))
        XCTAssertEqual(model.previewPDFPage, 1)
        XCTAssertEqual(model.previewPDFAnchor?.fingerprint, anchor.fingerprint)
    }

    @MainActor
    func testPDFCaptureToSelectedMindMapNodePersistsItsSourceLinkAfterReopen() async throws {
        let defaults = UserDefaults.standard
        let priorWorkspace = defaults.object(forKey: "PKSNotesWorkspace")
        let priorBookmark = defaults.object(forKey: "PKSNotesWorkspaceBookmark")
        let priorNote = defaults.object(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let priorWorkspace { defaults.set(priorWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let priorBookmark { defaults.set(priorBookmark, forKey: "PKSNotesWorkspaceBookmark") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark") }
            if let priorNote { defaults.set(priorNote, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }
        defaults.removeObject(forKey: "PKSNotesWorkspace")
        defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark")
        defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "Leafspan-PDF-MindMap-Quote-\(UUID().uuidString)", isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let note = root.appendingPathComponent("Study.md")
        let pdf = root.appendingPathComponent("Reading.pdf")
        try "# Root\n- Concept\n- Next\n".write(to: note, atomically: true, encoding: .utf8)
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: pdf)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(note)
        for _ in 0..<400 where model.loadingNote {
            try await Task.sleep(for: .milliseconds(5))
        }
        let initialNodes = MindMapOutline.nodes(in: model.draft)
        let concept = try XCTUnwrap(initialNodes.first(where: { $0.title == "Concept" }))
        let added = await model.appendPDFReference(
            pdf: pdf, page: 2, selectedText: "Source evidence",
            to: note, mindMapNodeID: concept.id
        )
        XCTAssertTrue(added, model.message ?? "Mind Map capture was not saved")
        XCTAssertFalse(model.isDirty)
        let saved = try String(contentsOf: note, encoding: .utf8)
        XCTAssertEqual(model.draft, saved)

        let ignored = await model.appendPDFReference(
            pdf: pdf, page: 2, to: note, mindMapNodeID: 999
        )
        XCTAssertFalse(ignored)
        XCTAssertEqual(model.draft, saved, "A stale node selection cannot move the quote elsewhere")

        let reopened = NotesModel()
        XCTAssertTrue(reopened.openWorkspace(root))
        reopened.openNote(note)
        for _ in 0..<400 where reopened.loadingNote {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(reopened.draft, saved)
        let nodes = MindMapOutline.nodes(in: reopened.draft)
        let selected = try XCTUnwrap(nodes.first(where: { $0.title == "Concept" }))
        let sibling = try XCTUnwrap(nodes.first(where: { $0.title == "Next" }))
        let presentations = MindMapOutline.presentations(in: reopened.draft, nodes: nodes)
        XCTAssertEqual(presentations[selected.id]?.links.map(\.target), ["/Reading.pdf#page=2"])
        XCTAssertEqual(presentations[sibling.id]?.links, [])
        XCTAssertTrue(presentations[selected.id]?.body.contains("Source evidence") == true)
    }

    @MainActor
    func testAppendPDFReferencePersistsToActiveAndOtherNotesWithoutChangingActiveDraft() async throws {
        let defaults = UserDefaults.standard
        let previousWorkspace = defaults.object(forKey: "PKSNotesWorkspace")
        let previousBookmark = defaults.object(forKey: "PKSNotesWorkspaceBookmark")
        let previousLastOpened = defaults.object(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let previousWorkspace { defaults.set(previousWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousBookmark { defaults.set(previousBookmark, forKey: "PKSNotesWorkspaceBookmark") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark") }
            if let previousLastOpened { defaults.set(previousLastOpened, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-PDF-Append-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(root.path, forKey: "PKSNotesWorkspace")
        defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark")
        defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown")

        let pdf = root.appendingPathComponent("Reading.pdf")
        let activeNote = root.appendingPathComponent("Active.md")
        let otherNote = root.appendingPathComponent("Other.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: pdf.path, contents: Data()))
        try "# Active\n".write(to: activeNote, atomically: true, encoding: .utf8)
        try "# Other\n".write(to: otherNote, atomically: true, encoding: .utf8)

        let fingerprint = try XCTUnwrap(PDFSourceAnchor.fingerprint(for: "Important fact"))
        let anchor = try XCTUnwrap(PDFSourceAnchor(
            page: 1,
            normalizedRects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)],
            fingerprint: fingerprint
        ))
        let activeSnippet = try XCTUnwrap(PDFPageReference.noteSnippet(
            for: pdf, page: 1, root: root, commentary: "Active observation",
            selectedText: "Important fact", anchor: anchor
        ))
        let otherSnippet = try XCTUnwrap(PDFPageReference.noteSnippet(
            for: pdf, page: 1, root: root, commentary: "Saved for later",
            selectedText: "Important fact", anchor: anchor
        ))

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(activeNote)
        for _ in 0..<400 where model.selected != activeNote || model.loadingNote {
            await Task.yield()
        }
        XCTAssertEqual(model.selected, activeNote)
        XCTAssertFalse(model.loadingNote)

        let activeSaved = await model.appendPDFReference(
            pdf: pdf, page: 1, commentary: "Active observation",
            selectedText: "Important fact", anchor: anchor, to: activeNote
        )
        XCTAssertTrue(activeSaved, model.message ?? "Active-note PDF capture failed")
        let activeContent = try String(contentsOf: activeNote, encoding: .utf8)
        XCTAssertEqual(model.draft, activeContent)
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(activeContent.contains(activeSnippet))
        XCTAssertTrue(activeContent.contains(anchor.fragment))

        let activeDraftBeforeOtherCapture = model.draft
        let otherSaved = await model.appendPDFReference(
            pdf: pdf, page: 1, commentary: "Saved for later",
            selectedText: "Important fact", anchor: anchor, to: otherNote
        )
        XCTAssertTrue(otherSaved, model.message ?? "Other-note PDF capture failed")
        XCTAssertEqual(model.selected, activeNote)
        XCTAssertEqual(model.draft, activeDraftBeforeOtherCapture)
        XCTAssertFalse(model.isDirty)

        let otherContent = try String(contentsOf: otherNote, encoding: .utf8)
        XCTAssertTrue(otherContent.hasPrefix("# Other\n"))
        XCTAssertTrue(otherContent.contains(otherSnippet))
        XCTAssertTrue(otherContent.contains(anchor.fragment))
    }
}
