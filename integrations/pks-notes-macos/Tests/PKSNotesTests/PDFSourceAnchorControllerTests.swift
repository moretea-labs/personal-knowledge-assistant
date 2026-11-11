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
