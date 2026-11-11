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
}
