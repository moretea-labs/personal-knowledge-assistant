import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PKSNotes

final class MindMapInterchangeTests: XCTestCase {
    func testEmptyMapCanStartWithOneCanonicalMarkdownHeading() {
        XCTAssertEqual(MindMapOutline.createMap(), "# New Mind Map\n")
        XCTAssertEqual(MindMapOutline.nodes(in: MindMapOutline.createMap()).map(\.title), ["New Mind Map"])
    }

    func testSiblingInsertionPreservesChildSubtree() {
        let input = "# Root\n- A\n  - A1\n- B"
        XCTAssertEqual(MindMapOutline.addSibling(in: input, nodeID: 1),
                       "# Root\n- A\n  - A1\n- New idea\n- B")
        XCTAssertEqual(MindMapOutline.addSibling(in: input, nodeID: 0),
                       "# Root\n- New idea\n- A\n  - A1\n- B")
    }

    func testExportImportRoundTripPreservesHierarchyAndXMLCharacters() throws {
        let markdown = "# Root & Friends\n- A <B> *literal*\n  - C \"quote\" [Link](https://example.com)\n- D\n"
        let data = try MindMapInterchange.exportOPML(markdown)
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(xml.contains("Root &amp; Friends"))
        XCTAssertTrue(xml.contains("A &lt;B&gt; *literal*"))
        XCTAssertTrue(xml.contains("C &quot;quote&quot; [Link](https://example.com)"))
        let imported = try MindMapInterchange.importOPML(data)
        let titles = try MindMapOutline.nodes(in: imported).map { node in
            String(try AttributedString(markdown: node.title).characters)
        }
        XCTAssertEqual(titles, ["Root & Friends", "A <B> *literal*", "C \"quote\" [Link](https://example.com)", "D"])
    }

    func testImportMultipleRootsRetainsEveryTopic() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><body>
          <outline text="One"><outline text="Sub"/></outline>
          <outline text="Two"/>
        </body></opml>
        """
        let markdown = try MindMapInterchange.importOPML(Data(xml.utf8))
        XCTAssertEqual(markdown, "# Mind Map\n- One\n  - Sub\n- Two\n")
    }

    func testExternalOPMLTitlesRemainLiteralMarkdownText() throws {
        let title = "*Important* & [Link](https://example.com) ![Image](https://example.com/a.png) <tag>"
        let xml = """
        <opml version="2.0"><head><title>External</title></head><body>
          <outline text="*Important* &amp; [Link](https://example.com) ![Image](https://example.com/a.png) &lt;tag&gt;"/>
        </body></opml>
        """
        let markdown = try MindMapInterchange.importOPML(Data(xml.utf8))
        let node = try XCTUnwrap(MindMapOutline.nodes(in: markdown).first)
        let rendered = try AttributedString(markdown: node.title)

        XCTAssertEqual(String(rendered.characters), title)
        XCTAssertEqual(
            markdown,
            "# \\*Important\\* & \\[Link\\](https://example.com) \\!\\[Image\\](https://example.com/a.png) &lt;tag&gt;\n"
        )
    }

    func testInvalidOPMLAndEmptyMapAreRejected() {
        XCTAssertThrowsError(try MindMapInterchange.importOPML(Data("""
        <!DOCTYPE opml [<!ENTITY expand "bad">]>
        <opml><body><outline text="&expand;"/></body></opml>
        """.utf8)))
        XCTAssertThrowsError(try MindMapInterchange.importOPML(Data("<not-opml/>".utf8)))
        XCTAssertThrowsError(try MindMapInterchange.importOPML(Data("<opml><body/></opml>".utf8)))
        XCTAssertThrowsError(try MindMapInterchange.importOPML(Data(repeating: 65, count: 5 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try MindMapInterchange.exportOPML("This is plain prose"))
    }

    func testImportEscapedNewlineDoesNotInjectMarkdownHeading() throws {
        let xml = "<opml><body><outline text=\"First&#10;# Not a heading\"/></body></opml>"
        let markdown = try MindMapInterchange.importOPML(Data(xml.utf8))
        XCTAssertEqual(markdown, "# First \\# Not a heading\n")
    }

    func testOPMLRoundTripPreservesDeepHierarchyAndRejectsUnimportableDepth() throws {
        let fortyLevels = (1...40).map { depth in
            String(repeating: " ", count: (depth - 1) * 2) + "- Level \(depth)"
        }.joined(separator: "\n")
        let source = "# Root\n\(fortyLevels)\n"
        let exported = try MindMapInterchange.exportOPML(source)
        XCTAssertEqual(try MindMapInterchange.importOPML(exported), source)

        let sixtyFourLevels = (1...64).map { depth in
            String(repeating: " ", count: (depth - 1) * 2) + "- Level \(depth)"
        }.joined(separator: "\n")
        let tooDeep = "# Root\n\(sixtyFourLevels)\n"
        XCTAssertThrowsError(try MindMapInterchange.exportOPML(tooDeep)) { error in
            guard case MindMapInterchange.Failure.tooDeep = error else {
                return XCTFail("Expected the explicit maximum-depth error, got: \(error)")
            }
        }
    }

    func testExportSkipsFencedCodeInMarkdown() throws {
        let source = "# Root\n~~~md\n- hidden\n~~~\n- Visible"
        let xml = String(decoding: try MindMapInterchange.exportOPML(source), as: UTF8.self)
        XCTAssertFalse(xml.contains("hidden"))
        XCTAssertTrue(xml.contains("Visible"))
    }

    func testMindMapNodesInheritAttachedPDFCitationsWithoutCrossingNodeBoundaries() throws {
        let chapterTarget = "/Books/Study%20Guide.pdf#page=4&rects=0.1,0.2,0.3,0.04&fp=0123456789abcdef"
        let conceptTarget = "/Books/Diagram.pdf#page=7&rects=0.2,0.3,0.4,0.05&fp=abcdef0123456789"
        let nextTarget = "/Books/Next.pdf#page=1"
        let markdown = """
        # Chapter
        Summary
        [Textbook · p. 4](\(chapterTarget))
        > Selected passage
        ~~~markdown
        [Example only](\(conceptTarget))
        ~~~
        - Concept
          Supporting note
          [Diagram · p. 7](\(conceptTarget))
        - Another
        # Next Chapter
        [Next · p. 1](\(nextTarget))
        """

        let nodes = MindMapOutline.nodes(in: markdown)
        let presentations = MindMapOutline.presentations(in: markdown, nodes: nodes)
        let chapter = try XCTUnwrap(nodes.first(where: { $0.title == "Chapter" }))
        let concept = try XCTUnwrap(nodes.first(where: { $0.title == "Concept" }))
        let another = try XCTUnwrap(nodes.first(where: { $0.title == "Another" }))
        let next = try XCTUnwrap(nodes.first(where: { $0.title == "Next Chapter" }))

        XCTAssertEqual(try XCTUnwrap(presentations[chapter.id]).links.map(\.target), [chapterTarget])
        XCTAssertEqual(try XCTUnwrap(presentations[concept.id]).links.map(\.target), [conceptTarget])
        XCTAssertEqual(try XCTUnwrap(presentations[another.id]).links, [])
        XCTAssertEqual(try XCTUnwrap(presentations[next.id]).links.map(\.target), [nextTarget])
    }


    @MainActor
    func testPDFCitationDropSurvivesMarkdownMindMapProjectionAndReturnsExactSourceAnchor() throws {
        let bounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let textView = NSTextView(frame: bounds)
        textView.string = """
        Introduction

        Important fact
        Second line

        Conclusion
        """
        let generatedDocument = try XCTUnwrap(
            PDFDocument(data: textView.dataWithPDF(inside: textView.bounds))
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanPDFMindMap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pdf = root.appendingPathComponent("Study Guide.pdf")
        XCTAssertTrue(generatedDocument.write(to: pdf))
        let sourceDocument = try XCTUnwrap(PDFDocument(url: pdf))
        let selected = try XCTUnwrap(
            sourceDocument.findString("Important fact", withOptions: []).first
        )
        selected.add(try XCTUnwrap(
            sourceDocument.findString("Second line", withOptions: []).first
        ))

        let pdfView = PDFView(frame: bounds)
        let controller = PDFReaderController()
        defer { controller.detach(view: pdfView) }
        controller.attach(
            view: pdfView,
            document: sourceDocument,
            url: pdf,
            requestedPage: nil,
            requestedAnchor: nil
        )
        pdfView.currentSelection = selected

        let anchor = try XCTUnwrap(controller.selectedSourceAnchor())
        let selectedText = try XCTUnwrap(controller.selectedText())
        let citation = try XCTUnwrap(controller.selectedCitationForDrag(pdf: pdf, root: root))
        XCTAssertTrue(citation.contains(anchor.fragment))
        XCTAssertTrue(citation.contains("> Important fact"))

        let sourceMarkdown = "# Study Guide\n- Concept\n- Next\n"
        let titleOffset = (sourceMarkdown as NSString).range(of: "Concept").location
        let insertionOffset = PDFCitationDropTarget.citationInsertionOffset(
            in: sourceMarkdown, at: titleOffset
        )
        let formattedCitation = PDFCitationDropTarget.citationForInsertion(
            citation, in: sourceMarkdown, at: titleOffset
        )
        let markdown = (sourceMarkdown as NSString).replacingCharacters(
            in: NSRange(location: insertionOffset, length: 0),
            with: formattedCitation
        )

        let nodes = MindMapOutline.nodes(in: markdown)
        let presentations = MindMapOutline.presentations(in: markdown, nodes: nodes)
        let concept = try XCTUnwrap(nodes.first(where: { $0.title == "Concept" }))
        let next = try XCTUnwrap(nodes.first(where: { $0.title == "Next" }))
        let conceptLinks = try XCTUnwrap(presentations[concept.id]).links
        XCTAssertEqual(conceptLinks.count, 1)
        XCTAssertTrue(try XCTUnwrap(presentations[next.id]).links.isEmpty)
        XCTAssertTrue(markdown.contains("Important fact"))
        XCTAssertTrue(markdown.contains("Second line"))

        let referenceURL = try XCTUnwrap(URL(string: conceptLinks[0].target))
        XCTAssertEqual(PDFPageReference.page(from: referenceURL), anchor.page)
        let restoredAnchor = try XCTUnwrap(PDFPageReference.anchor(from: referenceURL))
        XCTAssertEqual(restoredAnchor.page, anchor.page)
        XCTAssertEqual(restoredAnchor.fingerprint, anchor.fingerprint)
        XCTAssertEqual(restoredAnchor.fragment, anchor.fragment)
        XCTAssertTrue(restoredAnchor.matches(text: selectedText))
    }

}
