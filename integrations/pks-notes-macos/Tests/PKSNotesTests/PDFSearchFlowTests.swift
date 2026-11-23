import AppKit
import PDFKit
import XCTest
@testable import PKSNotes

@MainActor
final class PDFSearchFlowTests: XCTestCase {
    private func makeDocument(text: String) throws -> PDFDocument {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        textView.string = text
        let document = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
        XCTAssertEqual(document.pageCount, 1)
        return document
    }


    private func makeDocument(pages: [String]) throws -> PDFDocument {
        let document = PDFDocument()
        for text in pages {
            let singlePage = try makeDocument(text: text)
            document.insert(try XCTUnwrap(singlePage.page(at: 0)), at: document.pageCount)
        }
        XCTAssertEqual(document.pageCount, pages.count)
        return document
    }

    private func finishSearch(_ controller: PDFReaderController) async throws {
        for _ in 0..<250 {
            if !controller.isSearching { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("PDF search did not complete within a bounded test window")
    }

    func testSearchHitEmptyQueryAndDocumentSwitchDoNotLeakOldResults() async throws {
        let first = try makeDocument(text: "Unique alpha evidence. Alpha appears twice.")
        let second = try makeDocument(text: "Only beta evidence, no first-document marker.")
        XCTAssertGreaterThan(first.findString("alpha", withOptions: .caseInsensitive).count, 0)

        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        let controller = PDFReaderController()
        let root = FileManager.default.temporaryDirectory
        let firstURL = root.appendingPathComponent("pks-search-first-\(UUID().uuidString).pdf")
        let secondURL = root.appendingPathComponent("pks-search-second-\(UUID().uuidString).pdf")
        controller.attach(view: view, document: first, url: firstURL,
                          requestedPage: nil, requestedAnchor: nil)

        controller.search("Alpha")
        try await finishSearch(controller)
        XCTAssertEqual(controller.completedSearchQuery, "Alpha")
        XCTAssertGreaterThan(controller.searchMatchCount, 0)
        XCTAssertNotNil(view.currentSelection)
        controller.nextSearchMatch()
        XCTAssertGreaterThan(controller.searchMatchCount, 0)

        controller.search("not-a-real-token-987")
        try await finishSearch(controller)
        XCTAssertEqual(controller.searchMatchCount, 0)
        XCTAssertEqual(controller.completedSearchQuery, "not-a-real-token-987")
        XCTAssertNil(view.currentSelection,
                     "An old highlighted result cannot remain after a zero-match search.")

        controller.search("")
        XCTAssertEqual(controller.completedSearchQuery, "")
        XCTAssertEqual(controller.searchMatchCount, 0)
        XCTAssertNil(view.currentSelection)

        controller.search("alpha")
        // Replace the document while its detached search may still be running.
        controller.attach(view: view, document: second, url: secondURL,
                          requestedPage: nil, requestedAnchor: nil)
        XCTAssertFalse(controller.isSearching)
        XCTAssertEqual(controller.completedSearchQuery, "")
        XCTAssertEqual(controller.searchMatchCount, 0)

        // A new document's results must not be overwritten by the prior search.
        controller.search("beta")
        try await finishSearch(controller)
        XCTAssertEqual(controller.completedSearchQuery, "beta")
        XCTAssertGreaterThan(controller.searchMatchCount, 0)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.completedSearchQuery, "beta")
        controller.detach(view: view)
    }


    func testEditingSubmittedQueryClearsStaleMatchesUntilNewSearchIsSubmitted() async throws {
        let document = try makeDocument(text: "Alpha source evidence. Beta source evidence.")
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        let controller = PDFReaderController()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pks-search-edit-\(UUID().uuidString).pdf")
        controller.attach(view: view, document: document, url: url,
                          requestedPage: nil, requestedAnchor: nil)

        controller.search("alpha")
        try await finishSearch(controller)
        XCTAssertGreaterThan(controller.searchMatchCount, 0)
        XCTAssertNotNil(view.currentSelection)

        controller.invalidateSearchIfQueryChanged("beta")
        XCTAssertFalse(controller.isSearching)
        XCTAssertEqual(controller.completedSearchQuery, "")
        XCTAssertEqual(controller.searchMatchCount, 0)
        XCTAssertNil(view.currentSelection,
                     "Editing the query must not leave a highlight for the previous search.")

        controller.search("beta")
        try await finishSearch(controller)
        XCTAssertEqual(controller.completedSearchQuery, "beta")
        XCTAssertGreaterThan(controller.searchMatchCount, 0)
        controller.detach(view: view)
    }

    func testEditingSubmittedQueryPreservesManualSourceSelection() async throws {
        let document = try makeDocument(
            text: "Alpha search result. Important source passage. Beta search result."
        )
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        let controller = PDFReaderController()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pks-search-selection-\(UUID().uuidString).pdf")
        controller.attach(view: view, document: document, url: url,
                          requestedPage: nil, requestedAnchor: nil)

        controller.search("alpha")
        try await finishSearch(controller)
        XCTAssertEqual(controller.selectedText(), "Alpha")

        let manualSelection = try XCTUnwrap(
            document.findString("Important source passage", withOptions: []).first
        )
        view.currentSelection = manualSelection
        await Task.yield()

        controller.invalidateSearchIfQueryChanged("beta")

        XCTAssertEqual(
            controller.selectedText(),
            "Important source passage",
            "Invalidating stale search results must preserve the user's newer source selection."
        )
        XCTAssertEqual(controller.searchMatchCount, 0)
        controller.detach(view: view)
    }

    func testEditingSubmittedQueryPreservesPageOnlyWarningForMultiPageSelection() async throws {
        let document = try makeDocument(pages: [
            "Alpha search result. First page source evidence.",
            "Second page source evidence."
        ])
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        let controller = PDFReaderController()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pks-search-multipage-selection-\(UUID().uuidString).pdf")
        controller.attach(view: view, document: document, url: url,
                          requestedPage: nil, requestedAnchor: nil)

        controller.search("alpha")
        try await finishSearch(controller)

        let selection = try XCTUnwrap(
            document.findString("First page source evidence", withOptions: []).first
        )
        selection.add(try XCTUnwrap(
            document.findString("Second page source evidence", withOptions: []).first
        ))
        view.currentSelection = selection
        await Task.yield()
        XCTAssertTrue(controller.selectionNeedsPageOnlyReference)

        controller.invalidateSearchIfQueryChanged("beta")

        let selectedText = try XCTUnwrap(controller.selectedText())
        XCTAssertTrue(selectedText.contains("First page source evidence"))
        XCTAssertTrue(selectedText.contains("Second page source evidence"))
        XCTAssertTrue(controller.selectionNeedsPageOnlyReference)
        controller.detach(view: view)
    }

    func testCrossPageSearchUpdatesCanonicalPageIndex() async throws {
        let document = try makeDocument(pages: [
            "Opening evidence.",
            "Middle navigation.",
            "Unique page three search evidence."
        ])
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        let controller = PDFReaderController()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pks-search-pages-\(UUID().uuidString).pdf")
        controller.attach(view: view, document: document, url: url,
                          requestedPage: nil, requestedAnchor: nil)
        controller.goToPage(2)
        XCTAssertEqual(controller.currentPageIndex, 1)

        controller.search("unique page three")
        try await finishSearch(controller)

        XCTAssertEqual(controller.searchMatchCount, 1)
        XCTAssertEqual(controller.currentPageIndex, 2,
                       "Search navigation must update the canonical toolbar page.")
        XCTAssertTrue(view.currentPage === document.page(at: 2))
        controller.detach(view: view)
    }

    func testPDFSelectedTextAnchorReopensExactEvidence() throws {
        let document = try makeDocument(text: "An important unique anchor phrase for Leafspan.")
        let selection = try XCTUnwrap(
            document.findString("unique anchor phrase", withOptions: .caseInsensitive).first
        )
        let controller = PDFReaderController()
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 750, height: 850))
        let url = URL(fileURLWithPath: "/tmp/pks-anchor-\(UUID().uuidString).pdf")
        controller.attach(view: view, document: document, url: url,
                          requestedPage: nil, requestedAnchor: nil)

        view.currentSelection = selection
        let anchor = try XCTUnwrap(controller.selectedSourceAnchor())
        XCTAssertEqual(anchor.page, 1)
        XCTAssertTrue(anchor.matches(text: "unique anchor phrase"))

        // A captured source location should survive a note→PDF navigation.
        view.currentSelection = nil
        controller.attach(view: view, document: document, url: url,
                          requestedPage: anchor.page, requestedAnchor: anchor)
        XCTAssertFalse(controller.invalidRequestedSelection)
        XCTAssertNil(controller.invalidRequestedPage)
        XCTAssertEqual(controller.selectedText()?.lowercased(), "unique anchor phrase")
        controller.detach(view: view)
    }

}

extension PDFSearchFlowTests {
    func testSearchProgressAccessibilityLabelIsLocalized() {
        XCTAssertEqual(AppLanguage.english.text("Searching PDF"), "Searching PDF")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Searching PDF"), "正在搜索 PDF")
    }
}
