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
    }
}
