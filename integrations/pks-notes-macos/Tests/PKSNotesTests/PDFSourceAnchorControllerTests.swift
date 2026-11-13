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
    func testPartialTextSelectionAnchorRestoresOnlyTheSelectedText() throws {
        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let textView = NSTextView(frame: bounds)
        textView.string = "Important fact from the reading"
        let generated = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: bounds)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Partial-Anchor-\(UUID().uuidString).pdf")
        XCTAssertTrue(generated.write(to: url))
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try XCTUnwrap(PDFDocument(url: url))
        let view = PDFView(frame: bounds)
        let controller = PDFReaderController()
        controller.attach(view: view, document: document, url: url,
                          requestedPage: nil, requestedAnchor: nil)
        view.currentSelection = try XCTUnwrap(
            document.findString("fact", withOptions: []).first
        )
        XCTAssertEqual(controller.selectedText(), "fact")

        let anchor = try XCTUnwrap(controller.selectedSourceAnchor())
        let restoredView = PDFView(frame: bounds)
        let restoredController = PDFReaderController()
        defer {
            controller.detach(view: view)
            restoredController.detach(view: restoredView)
        }
        restoredController.attach(view: restoredView, document: document, url: url,
                                  requestedPage: nil, requestedAnchor: anchor)

        XCTAssertFalse(restoredController.invalidRequestedSelection)
        XCTAssertEqual(restoredView.currentSelection?.string, "fact")
    }

    @MainActor
    func testPartialMultiLineSelectionAnchorRestoresOnlyTheSelectedPassage() throws {
        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let textView = NSTextView(frame: bounds)
        textView.string = "Prefix fact from\nreading the source suffix"
        let generated = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: bounds)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Partial-Multiline-Anchor-\(UUID().uuidString).pdf")
        XCTAssertTrue(generated.write(to: url))
        defer { try? FileManager.default.removeItem(at: url) }

        let sourceDocument = try XCTUnwrap(PDFDocument(url: url))
        let selection = try XCTUnwrap(sourceDocument.findString("fact from", withOptions: []).first)
        selection.add(try XCTUnwrap(sourceDocument.findString("reading the", withOptions: []).first))
        let selectedText = try XCTUnwrap(selection.string)
        let normalized = selectedText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertEqual(normalized, "fact from reading the")

        let sourceView = PDFView(frame: bounds)
        let sourceController = PDFReaderController()
        sourceController.attach(view: sourceView, document: sourceDocument, url: url,
                                requestedPage: nil, requestedAnchor: nil)
        sourceView.currentSelection = selection
        XCTAssertEqual(sourceController.selectedText(), selectedText)

        let anchor = try XCTUnwrap(sourceController.selectedSourceAnchor())
        XCTAssertEqual(anchor.normalizedRects.count, 2)
        let citation = try XCTUnwrap(sourceController.selectedCitationForDrag(
            pdf: url, root: url.deletingLastPathComponent()
        ))
        XCTAssertTrue(citation.contains(anchor.fragment))
        XCTAssertTrue(citation.contains("> fact from\n> reading the"))

        let restoredDocument = try XCTUnwrap(PDFDocument(url: url))
        let restoredView = PDFView(frame: bounds)
        let restoredController = PDFReaderController()
        defer {
            sourceController.detach(view: sourceView)
            restoredController.detach(view: restoredView)
        }
        restoredController.attach(view: restoredView, document: restoredDocument, url: url,
                                  requestedPage: nil, requestedAnchor: anchor)

        XCTAssertFalse(restoredController.invalidRequestedSelection)
        let restoredText = try XCTUnwrap(restoredView.currentSelection?.string)
        XCTAssertEqual(
            restoredText.split(whereSeparator: \.isWhitespace).joined(separator: " "),
            "fact from reading the"
        )
        XCTAssertTrue(anchor.matches(text: restoredText))
        XCTAssertFalse(restoredText.contains("Prefix"))
        XCTAssertFalse(restoredText.contains("suffix"))
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

        let sourcePage = try XCTUnwrap(controller.selectedSourcePage())
        XCTAssertEqual(sourcePage, 1, "A multi-page quote should use its first source page for a page-only link.")
        let snippet = try XCTUnwrap(
            PDFPageReference.noteSnippet(
                for: url,
                page: sourcePage,
                root: url.deletingLastPathComponent(),
                commentary: "My observation",
                selectedText: selectedText
            )
        )
        XCTAssertTrue(snippet.contains("My observation"))
        XCTAssertTrue(snippet.contains("#page=1"))
        XCTAssertTrue(snippet.contains("> First page evidence"))
        XCTAssertTrue(snippet.contains("> Second page evidence"))
    }

    @MainActor
    func testPDFSelectionHitTestingUsesIndividualLineBounds() throws {
        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let textView = NSTextView(frame: bounds)
        textView.string = "Top selection\n\n\n\nBottom selection"
        let document = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: bounds)))
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(document.findString("Top selection", withOptions: []).first)
        selection.add(try XCTUnwrap(document.findString("Bottom selection", withOptions: []).first))

        let lineBounds = selection.selectionsByLine().map { $0.bounds(for: page).standardized }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            .sorted { $0.midY < $1.midY }
        XCTAssertGreaterThanOrEqual(lineBounds.count, 2)

        let first = lineBounds[0]
        let second = lineBounds[1]
        XCTAssertLessThanOrEqual(first.maxY, second.minY, "The fixture must leave whitespace between the selected lines.")
        let overlapMinX = max(first.minX, second.minX)
        let overlapMaxX = min(first.maxX, second.maxX)
        XCTAssertLessThan(overlapMinX, overlapMaxX)
        let gapPoint = CGPoint(
            x: (overlapMinX + overlapMaxX) / 2,
            y: (first.maxY + second.minY) / 2
        )

        XCTAssertTrue(
            selection.bounds(for: page).insetBy(dx: -3, dy: -3).contains(gapPoint),
            "The old union-rectangle hit test incorrectly includes the blank gap."
        )
        XCTAssertFalse(PDFSelectionHitTesting.contains(gapPoint, in: selection, on: page))

        for line in lineBounds {
            XCTAssertTrue(
                PDFSelectionHitTesting.contains(
                    CGPoint(x: line.midX, y: line.midY),
                    in: selection,
                    on: page
                )
            )
        }
    }

    private func removeStoredReadingPosition(for url: URL) {
        var positions = UserDefaults.standard.dictionary(
            forKey: PDFReadingPositionStore.defaultsKey
        ) ?? [:]
        positions.removeValue(forKey: url.standardizedFileURL.path)
        UserDefaults.standard.set(positions, forKey: PDFReadingPositionStore.defaultsKey)
    }

    func testPDFReadingPositionStoreRetainsNewestEntryWhenCapacityIsFull() throws {
        let suite = "PKSNotesPDFPositionCapacity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let existing = Dictionary(uniqueKeysWithValues: (0..<PDFReadingPositionStore.maxEntries).map {
            ("/tmp/z-\($0).pdf", $0)
        })
        defaults.set(existing, forKey: PDFReadingPositionStore.defaultsKey)

        let newest = URL(fileURLWithPath: "/tmp/a-new.pdf")
        PDFReadingPositionStore.save(pageIndex: 7, for: newest, defaults: defaults)

        let positions = try XCTUnwrap(defaults.dictionary(forKey: PDFReadingPositionStore.defaultsKey))
        XCTAssertEqual(positions.count, PDFReadingPositionStore.maxEntries)
        XCTAssertEqual(positions[newest.standardizedFileURL.path] as? Int, 7)
    }

    func testPDFReadingPositionStoreDoesNotEvictHistoryForDefaultPageZero() throws {
        let suite = "PKSNotesPDFPositionDefault-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let remembered = URL(fileURLWithPath: "/tmp/remembered.pdf")
        let firstPage = URL(fileURLWithPath: "/tmp/new-document.pdf")
        PDFReadingPositionStore.save(pageIndex: 6, for: remembered, defaults: defaults)
        PDFReadingPositionStore.save(pageIndex: 0, for: firstPage, defaults: defaults)

        XCTAssertEqual(PDFReadingPositionStore.pageIndex(
            for: remembered, pageCount: 10, defaults: defaults
        ), 6)
        XCTAssertNil(PDFReadingPositionStore.pageIndex(
            for: firstPage, pageCount: 10, defaults: defaults
        ))
    }

    @MainActor
    func testPDFReaderDetachPersistsLastPageBeforeDeferredPageChangeSync() throws {
        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let document = PDFDocument()
        for text in ["First page", "Last page read"] {
            let textView = NSTextView(frame: bounds)
            textView.string = text
            let pageDocument = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: bounds)))
            document.insert(try XCTUnwrap(pageDocument.page(at: 0)), at: document.pageCount)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Detach-Position-\(UUID().uuidString).pdf")
        defer { removeStoredReadingPosition(for: url) }
        let view = PDFView(frame: bounds)
        let controller = PDFReaderController()
        controller.attach(view: view, document: document, url: url,
                          requestedPage: nil, requestedAnchor: nil)

        view.go(to: try XCTUnwrap(document.page(at: 1)))
        XCTAssertEqual(document.index(for: try XCTUnwrap(view.currentPage)), 1)

        // Do not yield to the asynchronous PDFViewPageChanged observer.
        controller.detach(view: view)
        XCTAssertEqual(PDFReadingPositionStore.pageIndex(for: url, pageCount: 2), 1)
    }

    @MainActor
    func testReplacingPDFDocumentPersistsOutgoingPageBeforeRebindingTheView() throws {
        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        func makeDocument(_ texts: [String]) throws -> PDFDocument {
            let document = PDFDocument()
            for text in texts {
                let textView = NSTextView(frame: bounds)
                textView.string = text
                let pageDocument = try XCTUnwrap(
                    PDFDocument(data: textView.dataWithPDF(inside: bounds))
                )
                document.insert(try XCTUnwrap(pageDocument.page(at: 0)), at: document.pageCount)
            }
            return document
        }

        let outgoing = try makeDocument(["First page", "Last page read"])
        let incoming = try makeDocument(["New PDF"])
        let outgoingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Switch-Outgoing-\(UUID().uuidString).pdf")
        let incomingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Switch-Incoming-\(UUID().uuidString).pdf")
        defer {
            removeStoredReadingPosition(for: outgoingURL)
            removeStoredReadingPosition(for: incomingURL)
        }
        let view = PDFView(frame: bounds)
        let controller = PDFReaderController()
        controller.attach(view: view, document: outgoing, url: outgoingURL,
                          requestedPage: nil, requestedAnchor: nil)

        view.go(to: try XCTUnwrap(outgoing.page(at: 1)))
        XCTAssertEqual(outgoing.index(for: try XCTUnwrap(view.currentPage)), 1)

        controller.attach(view: view, document: incoming, url: incomingURL,
                          requestedPage: nil, requestedAnchor: nil)
        XCTAssertEqual(
            PDFReadingPositionStore.pageIndex(for: outgoingURL, pageCount: 2),
            1
        )
        controller.detach(view: view)
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

    @MainActor
    func testPDFDocumentLoadingReadsReplacementAtTheSamePath() async throws {
        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        func makeDocument(_ text: String) throws -> PDFDocument {
            let textView = NSTextView(frame: bounds)
            textView.string = text
            return try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PKS-PDF-Reload-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(try makeDocument("Original PDF source").write(to: url))
        let originalResult = await PDFDocumentLoading.load(url)
        let original = try XCTUnwrap(originalResult)
        XCTAssertNotNil(original.findString("Original PDF source", withOptions: []).first)

        XCTAssertTrue(try makeDocument("Updated PDF source").write(to: url))
        let refreshedResult = await PDFDocumentLoading.load(url)
        let refreshed = try XCTUnwrap(refreshedResult)
        XCTAssertFalse(original === refreshed)
        XCTAssertNotNil(refreshed.findString("Updated PDF source", withOptions: []).first)
        XCTAssertNil(refreshed.findString("Original PDF source", withOptions: []).first)
    }

    @MainActor
    func testExternalPDFChangeReloadsPreviewAndRejectsItsStaleSelectionAnchor() async throws {
        let defaults = UserDefaults.standard
        let priorWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        let priorBookmark = defaults.data(forKey: "PKSNotesWorkspaceBookmark")
        defer {
            if let priorWorkspace { defaults.set(priorWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let priorBookmark { defaults.set(priorBookmark, forKey: "PKSNotesWorkspaceBookmark") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark") }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanPDFExternal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        func makeDocument(_ text: String) throws -> PDFDocument {
            let textView = NSTextView(frame: bounds)
            textView.string = text
            return try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
        }

        let pdf = root.appendingPathComponent("Source.pdf")
        let originalData = try XCTUnwrap(makeDocument("Original PDF source").dataRepresentation())
        try originalData.write(to: pdf, options: .atomic)
        let originalDocument = try XCTUnwrap(PDFDocument(url: pdf))
        let reader = PDFView(frame: bounds)
        let controller = PDFReaderController()
        defer { controller.detach(view: reader) }
        controller.attach(
            view: reader, document: originalDocument, url: pdf,
            requestedPage: nil, requestedAnchor: nil
        )
        reader.currentSelection = try XCTUnwrap(
            originalDocument.findString("Original PDF source", withOptions: []).first
        )
        let anchor = try XCTUnwrap(controller.selectedSourceAnchor())

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openFile(pdf, pdfPage: anchor.page, pdfAnchor: anchor)
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        XCTAssertEqual(model.previewPDFAnchor, anchor)
        let initialReload = model.previewPDFReloadSequence

        // Exercise the actual FSEvents monitor installed by openWorkspace.
        let updatedData = try XCTUnwrap(makeDocument("Updated PDF source").dataRepresentation())
        try updatedData.write(to: pdf, options: .atomic)
        for _ in 0..<120 where model.previewPDFReloadSequence == initialReload {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(model.previewPDFReloadSequence, initialReload + 1, "Preview: \(model.previewPDF?.path ?? "nil"); source: \(pdf.path); canonical source: \(pdf.resolvingSymlinksInPath().path)")
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        XCTAssertEqual(model.previewPDFPage, anchor.page)
        XCTAssertEqual(model.previewPDFAnchor, anchor, "Reload keeps the original citation so the reader can validate it against the new PDF.")

        let refreshedResult = await PDFDocumentLoading.load(pdf)
        let refreshed = try XCTUnwrap(refreshedResult)
        XCTAssertFalse(originalDocument === refreshed)
        XCTAssertNotNil(refreshed.findString("Updated PDF source", withOptions: []).first)
        XCTAssertNil(refreshed.findString("Original PDF source", withOptions: []).first)
        controller.attach(
            view: reader, document: refreshed, url: pdf,
            requestedPage: model.previewPDFPage,
            requestedAnchor: model.previewPDFAnchor,
            navigationSequence: model.previewPDFNavigationSequence
        )
        XCTAssertTrue(controller.invalidRequestedSelection)
        XCTAssertNil(reader.currentSelection, "A stale citation must never highlight different text after refresh.")
        XCTAssertEqual(controller.currentPageIndex, anchor.page - 1)
    }

    func testPDFPageReferenceEscapesSelectedTextAsLiteralMarkdown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pdf = root.appendingPathComponent("Source.pdf")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: pdf)
        let selectedText = "Important *fact* _under_ `code` &amp; <script>\n- list item\n1. ordered item\n1) alternate item\n> block quote\n![remote](https://example.com/track.png)"
        let fingerprint = try XCTUnwrap(PDFSourceAnchor.fingerprint(for: selectedText))
        let anchor = try XCTUnwrap(PDFSourceAnchor(
            page: 2,
            normalizedRects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)],
            fingerprint: fingerprint
        ))
        let snippet = try XCTUnwrap(PDFPageReference.noteSnippet(
            for: pdf, page: 2, root: root, selectedText: selectedText, anchor: anchor
        ))
        let expectedQuote = """
        > Important \\*fact\\* \\_under\\_ \\`code\\` &amp;amp; &lt;script&gt;
        > \\- list item
        > 1\\. ordered item
        > 1\\) alternate item
        > &gt; block quote
        > \\!\\[remote\\](https://example.com/track.png)
        """
        XCTAssertTrue(snippet.hasSuffix(expectedQuote))

        let rendered = try AttributedString(markdown: expectedQuote)
        let normalizedRendered = String(rendered.characters)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let normalizedSelected = selectedText
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertEqual(normalizedRendered, normalizedSelected)
    }

    @MainActor
    func testWorkspaceChangeMonitorEmitsFileLevelEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanFSEvents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("Source.pdf")
        try Data("original".utf8).write(to: file)
        let event = expectation(description: "FSEvents reports the changed file path")
        let canonicalFile = file.standardizedFileURL.resolvingSymlinksInPath()
        var observedPaths: [String] = []
        let monitor = try XCTUnwrap(WorkspaceChangeMonitor(root: root) { paths in
            observedPaths.append(contentsOf: paths)
            if paths.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() == canonicalFile }) { event.fulfill() }
        })

        try Data("updated".utf8).write(to: file, options: .atomic)
        await fulfillment(of: [event], timeout: 3)
        XCTAssertTrue(observedPaths.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() == canonicalFile }), "Observed paths: \(observedPaths); file: \(file.path)")
        withExtendedLifetime(monitor) {}
    }
}


extension PDFSourceAnchorControllerTests {
    func testSourceAnchorParserRejectsMalformedAndUnboundedFragments() throws {
        let fingerprint = "0123456789abcdef"
        let rect = "0.10000,0.20000,0.30000,0.04000"
        let valid = "page=7&rects=\(rect)&fp=\(fingerprint)"

        XCTAssertNotNil(PDFSourceAnchor.parse(fragment: valid))
        XCTAssertNil(PDFSourceAnchor.parse(fragment: "page=7&page=8&rects=\(rect)&fp=\(fingerprint)"))
        XCTAssertNil(PDFSourceAnchor.parse(fragment: "page=7&rects=\(rect)&rects=\(rect)&fp=\(fingerprint)"))
        XCTAssertNil(PDFSourceAnchor.parse(fragment: "page=7&rects=\(rect)~~\(rect)&fp=\(fingerprint)"))
        XCTAssertNil(PDFSourceAnchor.parse(fragment: "page=7&rects=\(rect)&fp=\(fingerprint)&"))
        XCTAssertNil(PDFSourceAnchor.parse(fragment: "page=7&rects=\(Array(repeating: rect, count: PDFSourceAnchor.maxRects + 1).joined(separator: "~"))&fp=\(fingerprint)"))
        for malformedRect in [
            "0.50000,0.20000,-0.30000,0.04000",
            "0.10000,0.50000,0.30000,-0.04000",
            "0.80000,0.20000,0.30000,0.04000",
            "0.10000,0.98000,0.30000,0.04000"
        ] {
            XCTAssertNil(
                PDFSourceAnchor.parse(fragment: "page=7&rects=\(malformedRect)&fp=\(fingerprint)"),
                "Malformed normalized rectangle should be rejected: \(malformedRect)"
            )
        }
        XCTAssertNil(PDFSourceAnchor.parse(fragment: String(repeating: "x", count: PDFSourceAnchor.maxFragmentBytes + 1)))
    }

    func testSourceAnchorInitializerRejectsNegativeRectangleDimensionsBeforeStandardizing() {
        let fingerprint = "0123456789abcdef"
        XCTAssertNil(PDFSourceAnchor(
            page: 1,
            normalizedRects: [CGRect(x: 0.5, y: 0.2, width: -0.3, height: 0.04)],
            fingerprint: fingerprint
        ))
        XCTAssertNil(PDFSourceAnchor(
            page: 1,
            normalizedRects: [CGRect(x: 0.1, y: 0.5, width: 0.3, height: -0.04)],
            fingerprint: fingerprint
        ))
        XCTAssertNotNil(PDFSourceAnchor(
            page: 1,
            normalizedRects: [CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)],
            fingerprint: fingerprint
        ))
    }
}
