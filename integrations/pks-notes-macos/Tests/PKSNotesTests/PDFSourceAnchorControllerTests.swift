import AppKit
import PDFKit
import XCTest
@testable import PKSNotes

final class PDFSourceAnchorControllerTests: XCTestCase {
    @MainActor
    func testPDFKitSelectionAnchorCapturesAndRestoresTheExactSelection() throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        textView.string = """
        Introduction

        Important fact
        Second line

        Conclusion
        """
        let generatedDocument = try XCTUnwrap(
            PDFDocument(data: textView.dataWithPDF(inside: textView.bounds))
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Anchor-\(UUID().uuidString).pdf")
        XCTAssertTrue(generatedDocument.write(to: url))
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceDocument = try XCTUnwrap(PDFDocument(url: url))
        let firstLine = try XCTUnwrap(sourceDocument.findString("Important fact", withOptions: []).first)
        let secondLine = try XCTUnwrap(sourceDocument.findString("Second line", withOptions: []).first)
        firstLine.add(secondLine)

        let originalText = try XCTUnwrap(firstLine.string)
        XCTAssertTrue(originalText.contains("Important fact"))
        XCTAssertTrue(originalText.contains("Second line"))

        let sourceView = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        let sourceController = PDFReaderController()
        sourceController.attach(
            view: sourceView,
            document: sourceDocument,
            url: url,
            requestedPage: nil,
            requestedAnchor: nil
        )
        sourceView.currentSelection = firstLine

        let anchor = try XCTUnwrap(sourceController.selectedSourceAnchor())
        XCTAssertEqual(anchor.page, 1)
        XCTAssertGreaterThanOrEqual(anchor.normalizedRects.count, 2)
        XCTAssertTrue(anchor.matches(text: originalText))

        let markdownReference = try XCTUnwrap(
            PDFPageReference.markdown(
                for: url,
                page: anchor.page,
                root: url.deletingLastPathComponent(),
                anchor: anchor
            )
        )
        XCTAssertTrue(markdownReference.contains(anchor.fragment))
        let referenceURL = try XCTUnwrap(URL(string: "\(url.absoluteString)#\(anchor.fragment)"))
        let encodedAnchor = try XCTUnwrap(PDFPageReference.anchor(from: referenceURL))
        XCTAssertEqual(encodedAnchor.page, anchor.page)
        XCTAssertEqual(encodedAnchor.fingerprint, anchor.fingerprint)
        XCTAssertEqual(encodedAnchor.normalizedRects.count, anchor.normalizedRects.count)
        for (encoded, original) in zip(encodedAnchor.normalizedRects, anchor.normalizedRects) {
            XCTAssertEqual(encoded.minX, original.minX, accuracy: 0.00001)
            XCTAssertEqual(encoded.minY, original.minY, accuracy: 0.00001)
            XCTAssertEqual(encoded.width, original.width, accuracy: 0.00001)
            XCTAssertEqual(encoded.height, original.height, accuracy: 0.00001)
        }

        let restoredDocument = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertFalse(restoredDocument === sourceDocument, "Restoration must use a fresh PDFKit document instance.")
        let restoredView = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        let restoredController = PDFReaderController()
        restoredController.attach(
            view: restoredView,
            document: restoredDocument,
            url: url,
            requestedPage: nil,
            requestedAnchor: anchor
        )

        XCTAssertFalse(restoredController.invalidRequestedSelection)
        let restoredText = try XCTUnwrap(restoredView.currentSelection?.string)
        XCTAssertEqual(PDFSourceAnchor.fingerprint(for: restoredText), anchor.fingerprint)
        XCTAssertEqual(restoredView.currentSelection?.pages.count, 1)

        // Normal SwiftUI updates must not steal PDF scrolling or selection.
        // A second click on the same Markdown source link is a new navigation
        // intent, even though both the page and anchor values are identical.
        restoredView.currentSelection = nil
        restoredController.attach(
            view: restoredView, document: restoredDocument, url: url,
            requestedPage: nil, requestedAnchor: anchor, navigationSequence: 0
        )
        XCTAssertNil(restoredView.currentSelection)
        restoredController.attach(
            view: restoredView, document: restoredDocument, url: url,
            requestedPage: nil, requestedAnchor: anchor, navigationSequence: 1
        )
        let repeatedSelection = try XCTUnwrap(restoredView.currentSelection?.string)
        XCTAssertEqual(PDFSourceAnchor.fingerprint(for: repeatedSelection), anchor.fingerprint)
    }

    @MainActor
    func testStalePDFSelectionAnchorNeverSelectsDifferentText() throws {
        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let originalTextView = NSTextView(frame: bounds)
        originalTextView.string = "Original exact evidence"
        let originalDocument = try XCTUnwrap(
            PDFDocument(data: originalTextView.dataWithPDF(inside: bounds))
        )
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Stale-Anchor-\(UUID().uuidString).pdf")
        let sourceView = PDFView(frame: bounds)
        let sourceController = PDFReaderController()
        sourceController.attach(
            view: sourceView, document: originalDocument, url: sourceURL,
            requestedPage: nil, requestedAnchor: nil
        )
        sourceView.currentSelection = try XCTUnwrap(
            originalDocument.findString("Original exact evidence", withOptions: []).first
        )
        let anchor = try XCTUnwrap(sourceController.selectedSourceAnchor())

        // Simulate the same PDF path being replaced while the Markdown link
        // still carries its previous text fingerprint and selection geometry.
        let changedTextView = NSTextView(frame: bounds)
        changedTextView.string = "Original exact Evidence"
        let changedDocument = try XCTUnwrap(
            PDFDocument(data: changedTextView.dataWithPDF(inside: bounds))
        )
        let restoredView = PDFView(frame: bounds)
        let restoredController = PDFReaderController()
        defer {
            sourceController.detach(view: sourceView)
            restoredController.detach(view: restoredView)
        }

        restoredController.attach(
            view: restoredView, document: changedDocument, url: sourceURL,
            requestedPage: nil, requestedAnchor: anchor
        )

        XCTAssertTrue(restoredController.invalidRequestedSelection)
        XCTAssertNil(restoredController.invalidRequestedPage)
        XCTAssertNil(restoredView.currentSelection)
        XCTAssertEqual(restoredController.currentPageIndex, 0)
    }

    @MainActor
    func testMultiPagePDFSelectionCannotProduceASinglePageAnchor() throws {
        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let firstText = NSTextView(frame: bounds)
        firstText.string = "First page evidence"
        let secondText = NSTextView(frame: bounds)
        secondText.string = "Second page evidence"
        let first = try XCTUnwrap(PDFDocument(data: firstText.dataWithPDF(inside: bounds)))
        let second = try XCTUnwrap(PDFDocument(data: secondText.dataWithPDF(inside: bounds)))
        let document = PDFDocument()
        document.insert(try XCTUnwrap(first.page(at: 0)), at: 0)
        document.insert(try XCTUnwrap(second.page(at: 0)), at: 1)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Multi-Page-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(document.write(to: url))
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(reopened.pageCount, 2)

        let view = PDFView(frame: bounds)
        let controller = PDFReaderController()
        defer { controller.detach(view: view) }
        controller.attach(
            view: view, document: reopened, url: url,
            requestedPage: nil, requestedAnchor: nil
        )

        let selection = try XCTUnwrap(
            reopened.findString("First page evidence", withOptions: []).first
        )
        selection.add(try XCTUnwrap(
            reopened.findString("Second page evidence", withOptions: []).first
        ))
        XCTAssertEqual(selection.pages.count, 2)
        view.currentSelection = selection

        let selectedText = try XCTUnwrap(controller.selectedText())
        XCTAssertTrue(selectedText.contains("First page evidence"))
        XCTAssertTrue(selectedText.contains("Second page evidence"))
        XCTAssertNil(controller.selectedSourceAnchor())
    }

    @MainActor
    func testRepeatedPDFSelectionAnchorReturnsToPageTwoAfterPageOne() throws {
        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let firstText = NSTextView(frame: bounds)
        firstText.string = "First page"
        let secondText = NSTextView(frame: bounds)
        secondText.string = "Second page exact evidence"
        let first = try XCTUnwrap(PDFDocument(data: firstText.dataWithPDF(inside: bounds)))
        let second = try XCTUnwrap(PDFDocument(data: secondText.dataWithPDF(inside: bounds)))
        let document = PDFDocument()
        document.insert(try XCTUnwrap(first.page(at: 0)), at: 0)
        document.insert(try XCTUnwrap(second.page(at: 0)), at: 1)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Repeat-Page-Two-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(document.write(to: url))
        let reopened = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(reopened.pageCount, 2)

        let sourceView = PDFView(frame: bounds)
        let source = PDFReaderController()
        source.attach(view: sourceView, document: reopened, url: url,
                      requestedPage: nil, requestedAnchor: nil)
        sourceView.currentSelection = try XCTUnwrap(
            reopened.findString("Second page exact evidence", withOptions: []).first
        )
        let anchor = try XCTUnwrap(source.selectedSourceAnchor())
        XCTAssertEqual(anchor.page, 2)

        let view = PDFView(frame: bounds)
        let controller = PDFReaderController()
        defer { source.detach(view: sourceView); controller.detach(view: view) }
        controller.attach(view: view, document: reopened, url: url,
                          requestedPage: nil, requestedAnchor: anchor, navigationSequence: 0)
        XCTAssertEqual(controller.currentPageIndex, 1)
        XCTAssertEqual(reopened.index(for: try XCTUnwrap(view.currentPage)), 1)

        controller.goToPage(1)
        XCTAssertEqual(controller.currentPageIndex, 0)
        XCTAssertEqual(reopened.index(for: try XCTUnwrap(view.currentPage)), 0)

        // Reopening the same exact Markdown link is a new navigation intent.
        controller.attach(view: view, document: reopened, url: url,
                          requestedPage: nil, requestedAnchor: anchor, navigationSequence: 1)
        XCTAssertEqual(controller.currentPageIndex, 1)
        XCTAssertEqual(reopened.index(for: try XCTUnwrap(view.currentPage)), 1)
        XCTAssertEqual(
            PDFSourceAnchor.fingerprint(for: try XCTUnwrap(view.currentSelection?.string)),
            anchor.fingerprint
        )
    }

    @MainActor
    func testPDFReaderSearchFindsAndClearsMatches() async throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        textView.string = "PDF search fixture\nFirst page content\nSecond page navigation fixture."
        let document = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        let controller = PDFReaderController()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Search-\(UUID().uuidString).pdf")
        defer { controller.detach(view: view) }

        controller.attach(view: view, document: document, url: url,
                          requestedPage: nil, requestedAnchor: nil)
        controller.search("Second page navigation fixture")
        for _ in 0..<400 where controller.isSearching {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(controller.isSearching)
        XCTAssertEqual(controller.completedSearchQuery, "Second page navigation fixture")
        XCTAssertEqual(controller.searchMatchCount, 1)
        XCTAssertEqual(controller.searchMatchIndex, 0)
        XCTAssertTrue(try XCTUnwrap(controller.selectedText()).contains("Second page navigation fixture"))

        controller.search("")
        XCTAssertEqual(controller.completedSearchQuery, "")
        XCTAssertEqual(controller.searchMatchCount, 0)
        XCTAssertNil(controller.selectedText())
    }

    @MainActor
    func testPDFReaderSearchNavigatesMultipleMatchesAndWraps() async throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        textView.string = "target alpha target beta target"
        let document = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
        let page = try XCTUnwrap(document.page(at: 0))
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        let controller = PDFReaderController()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Search-Navigation-\(UUID().uuidString).pdf")
        defer { controller.detach(view: view) }

        controller.attach(view: view, document: document, url: url,
                          requestedPage: nil, requestedAnchor: nil)
        controller.search(" target ")
        for _ in 0..<400 where controller.isSearching {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(controller.isSearching)
        XCTAssertEqual(controller.completedSearchQuery, "target")
        XCTAssertEqual(controller.searchMatchCount, 3)
        XCTAssertEqual(controller.searchMatchIndex, 0)
        let firstBounds = try XCTUnwrap(view.currentSelection).bounds(for: page)

        controller.nextSearchMatch()
        XCTAssertEqual(controller.searchMatchIndex, 1)
        let secondBounds = try XCTUnwrap(view.currentSelection).bounds(for: page)
        XCTAssertNotEqual(firstBounds.minX, secondBounds.minX, accuracy: 0.5)

        controller.previousSearchMatch()
        XCTAssertEqual(controller.searchMatchIndex, 0)
        controller.previousSearchMatch()
        XCTAssertEqual(controller.searchMatchIndex, 2)
        XCTAssertTrue(try XCTUnwrap(controller.selectedText()).contains("target"))

        controller.nextSearchMatch()
        XCTAssertEqual(controller.searchMatchIndex, 0)
    }
}
