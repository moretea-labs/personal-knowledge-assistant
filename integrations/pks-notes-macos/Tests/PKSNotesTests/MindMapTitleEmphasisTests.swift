import XCTest
@testable import PKSNotes

final class MindMapTitleEmphasisTests: XCTestCase {
    func testBoldAndItalicMarkersToggleWithoutLosingExistingEmphasis() {
        XCTAssertEqual(MindMapTitleEmphasis.toggle("Important", marker: "**"),
                       "**Important**")
        XCTAssertEqual(MindMapTitleEmphasis.toggle("**Important**", marker: "**"),
                       "Important")
        XCTAssertEqual(MindMapTitleEmphasis.toggle("Important", marker: "*"),
                       "*Important*")
        XCTAssertEqual(MindMapTitleEmphasis.toggle("*Important*", marker: "*"),
                       "Important")
        let combined = MindMapTitleEmphasis.toggle("*Important*", marker: "**")
        XCTAssertEqual(combined, "***Important***")
        XCTAssertEqual(MindMapTitleEmphasis.toggle("**Important**", marker: "*"),
                       "***Important***")
        XCTAssertEqual(MindMapTitleEmphasis.toggle(combined, marker: "**"), "*Important*")
        XCTAssertEqual(MindMapTitleEmphasis.toggle(combined, marker: "*"), "**Important**")
    }

    func testDisplayRendersEmphasisInsteadOfShowingRawMarkdownMarkers() {
        let styled = MindMapTitleEmphasis.display("**Important** and *optional*")
        XCTAssertEqual(String(styled.characters), "Important and optional")
        XCTAssertEqual(String(MindMapTitleEmphasis.display("Ordinary title").characters),
                       "Ordinary title")
    }

    func testNodeStyleEditsOnlyCanonicalMarkdownTitleAndPreservesLinkTargets() throws {
        let markdown = "# Topic\n- [Linked note](/Docs/Reference.md)\n  - Another node\n"
        let originalNodes = MindMapOutline.nodes(in: markdown)
        let first = try XCTUnwrap(originalNodes.first(where: { $0.depth == 1 }))
        let changedTitle = MindMapTitleEmphasis.toggle(first.title, marker: "**")
        let modified = try XCTUnwrap(MindMapOutline.rename(
            in: markdown, nodeID: first.id, to: changedTitle
        ))
        XCTAssertEqual(modified,
                       "# Topic\n- **[Linked note](/Docs/Reference.md)**\n  - Another node\n")
        XCTAssertEqual(MindMapOutline.links(in: changedTitle).map(\.target),
                       ["/Docs/Reference.md"])
        XCTAssertEqual(String(MindMapTitleEmphasis.display(
            MindMapOutline.presentation(for: changedTitle).title
        ).characters), "Linked note")
        XCTAssertEqual(MindMapOutline.nodes(in: modified).map(\.depth),
                       originalNodes.map(\.depth))
        XCTAssertEqual(MindMapOutline.rename(
            in: modified, nodeID: first.id,
            to: MindMapTitleEmphasis.toggle(changedTitle, marker: "**")
        ), markdown)
    }
}
