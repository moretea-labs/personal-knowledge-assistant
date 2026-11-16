import AppKit
import PDFKit
import XCTest
@testable import PKSNotes

@MainActor
private final class BoundDraftTextViewDelegate: NSObject, NSTextViewDelegate {
    let model: NotesModel

    init(model: NotesModel) {
        self.model = model
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView else { return }
        model.draft = editor.string
    }
}

@MainActor
final class PDFCitationDropFlowTests: XCTestCase {
    func testNativePDFCitationDropPersistsAndReopensExactAnchor() async throws {
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
            .appendingPathComponent("Leafspan-Native-PDF-Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(root.path, forKey: "PKSNotesWorkspace")
        defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark")
        defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown")

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let markdown = "# Study\n- Concept\n  Existing text\n"
        let note = try XCTUnwrap(model.newNote(named: "Study", in: root, initialContent: markdown))
        for _ in 0..<200 where model.selected != note || model.loadingNote {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.selected, note)
        XCTAssertFalse(model.loadingNote)
        XCTAssertEqual(model.draft, markdown)

        let pdf = root.appendingPathComponent("Reading (v2).pdf")
        let pageBounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let sourceText = NSTextView(frame: pageBounds)
        sourceText.string = "Important fact from the reading"
        let sourceDocument = try XCTUnwrap(
            PDFDocument(data: sourceText.dataWithPDF(inside: pageBounds))
        )
        XCTAssertTrue(sourceDocument.write(to: pdf))

        let sourceView = PDFView(frame: pageBounds)
        let sourceController = PDFReaderController()
        sourceController.attach(
            view: sourceView, document: sourceDocument, url: pdf,
            requestedPage: nil, requestedAnchor: nil
        )
        defer { sourceController.detach(view: sourceView) }
        sourceView.currentSelection = try XCTUnwrap(
            sourceDocument.findString("Important fact", withOptions: []).first
        )
        let selectedText = try XCTUnwrap(sourceController.selectedText())
        let citation = try XCTUnwrap(sourceController.selectedCitationForDrag(pdf: pdf, root: root))
        XCTAssertEqual(selectedText, "Important fact")
        XCTAssertTrue(citation.contains("> Important fact"))

        // Exercise the native NSTextView drop target used by the Markdown editor.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        scroll.hasVerticalScroller = true
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 34))
        editor.isVerticallyResizable = false
        editor.isEditable = true
        editor.string = model.draft
        let delegate = BoundDraftTextViewDelegate(model: model)
        editor.delegate = delegate
        scroll.documentView = editor
        window.contentView = scroll

        let blankEditorPoint = NSPoint(x: 140, y: 170)
        let screenPoint = window.convertPoint(
            toScreen: scroll.convert(blankEditorPoint, to: nil)
        )
        let resolvedEditor = try XCTUnwrap(
            PDFCitationDropTarget.editableTextView(at: screenPoint, in: window)
        )
        XCTAssertTrue(resolvedEditor === editor)
        let end = (editor.string as NSString).length
        let target = try XCTUnwrap(PDFCitationDropTarget(
            screenPoint: screenPoint,
            note: note,
            draftRevision: model.draftRevision,
            textView: resolvedEditor
        ))
        XCTAssertEqual(target.insertionIndex, end)
        XCTAssertTrue(target.insert(
            citation,
            currentNote: model.selected,
            currentDraftRevision: model.draftRevision,
            canEdit: true
        ))

        XCTAssertEqual(editor.string, model.draft)
        XCTAssertTrue(model.draft.contains("> Important fact"))
        XCTAssertTrue(model.draft.contains("Reading%20%28v2%29.pdf#page=1&rects="))
        XCTAssertNotEqual(model.draft, markdown)
        XCTAssertTrue(model.isDirty)
        model.save()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), model.draft)

        let reopened = NotesModel()
        XCTAssertTrue(reopened.openWorkspace(root))
        reopened.openNote(note)
        for _ in 0..<200 where reopened.selected != note || reopened.loadingNote {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(reopened.selected, note)
        XCTAssertFalse(reopened.loadingNote)

        let nodes = MindMapOutline.nodes(in: reopened.draft)
        let concept = try XCTUnwrap(nodes.first(where: { $0.title == "Concept" }))
        let link = try XCTUnwrap(
            MindMapOutline.presentations(in: reopened.draft, nodes: nodes)[concept.id]?.links.first?.target
        )
        let linkedURL = try XCTUnwrap(URL(string: link))
        let anchor = try XCTUnwrap(PDFPageReference.anchor(from: linkedURL))
        XCTAssertEqual(PDFPageReference.page(from: linkedURL), 1)

        let reopenedPDF = try XCTUnwrap(PDFDocument(url: pdf))
        let reopenedPDFView = PDFView(frame: pageBounds)
        let reopenedPDFController = PDFReaderController()
        reopenedPDFController.attach(
            view: reopenedPDFView, document: reopenedPDF, url: pdf,
            requestedPage: anchor.page, requestedAnchor: anchor
        )
        defer { reopenedPDFController.detach(view: reopenedPDFView) }
        XCTAssertFalse(reopenedPDFController.invalidRequestedSelection)
        XCTAssertEqual(reopenedPDFController.selectedText(), selectedText)
    }
}
