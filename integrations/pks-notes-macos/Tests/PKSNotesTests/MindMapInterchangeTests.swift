import Foundation
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
        let markdown = "# Root & Friends\n- A <B>\n  - C \"quote\"\n- D\n"
        let data = try MindMapInterchange.exportOPML(markdown)
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(xml.contains("Root &amp; Friends"))
        XCTAssertTrue(xml.contains("A &lt;B&gt;"))
        XCTAssertTrue(xml.contains("C &quot;quote&quot;"))
        XCTAssertEqual(try MindMapInterchange.importOPML(data), markdown)
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
        XCTAssertEqual(markdown, "# First # Not a heading\n")
    }

    func testExportSkipsFencedCodeInMarkdown() throws {
        let source = "# Root\n~~~md\n- hidden\n~~~\n- Visible"
        let xml = String(decoding: try MindMapInterchange.exportOPML(source), as: UTF8.self)
        XCTAssertFalse(xml.contains("hidden"))
        XCTAssertTrue(xml.contains("Visible"))
    }
}
