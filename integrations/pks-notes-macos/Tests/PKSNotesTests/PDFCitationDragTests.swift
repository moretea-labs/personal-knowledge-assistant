import AppKit
import PDFKit
import XCTest
@testable import PKSNotes

final class PDFCitationDragTests: XCTestCase {
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
        XCTAssertEqual(item.string(forType: .string), markdown)
        XCTAssertNil(controller.selectedCitationForDrag(pdf: pdf, root: root.appendingPathComponent("NotTheWorkspace")))
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
    func testSelectedMultiPageTextFallsBackToPageLink() throws {
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
        let markdown = try XCTUnwrap(controller.selectedCitationForDrag(pdf: pdf, root: root))
        XCTAssertTrue(markdown.contains("#page=1"))
        XCTAssertFalse(markdown.contains("&rects="))
        XCTAssertTrue(markdown.contains("> Page one quotation"))
        XCTAssertTrue(markdown.contains("> Page two quotation"))
    }
}
