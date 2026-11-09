import XCTest
@testable import PKSNotes

final class MindMapDragTargetSafetyTests: XCTestCase {
    func testRejectsAttachedParagraphQuoteAndCodeAtDropTarget() {
        let cases = [
            "# Plan\n- Move me\n- Target\n  Context belongs to Target.\n  - Existing child\n",
            "# Plan\n- Move me\n- Target\n  > Target quotation.\n  - Existing child\n",
            "# Plan\n- Move me\n- Target\n  ~~~swift\n  print(\"original target\")\n  ~~~\n  - Existing child\n",
            "# Plan\n- Move me\n- Target\n  Attached trailing paragraph.\n",
            "# Plan\n- Move me\n# Target\nAn introduction belonging to the heading.\n- Existing child\n"
        ]
        for source in cases {
            let nodes = MindMapOutline.nodes(in: source)
            guard let moved = nodes.first(where: { $0.title == "Move me" }),
                  let target = nodes.first(where: { $0.title == "Target" }) else {
                XCTFail("Malformed test fixture")
                continue
            }
            XCTAssertNil(
                MindMapOutline.moveListSubtreeWithOutcome(
                    in: source, nodeID: moved.id, asChildOf: target.id
                ),
                "Dropping ahead of attached Markdown must fail closed."
            )
            XCTAssertNil(
                MindMapOutline.addChild(in: source, parentID: target.id),
                "Add Child must share the same target-content safety rule."
            )
        }
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.text(
                "Cannot move this branch without changing attached Markdown. Use the editor."
            ),
            "移动会改变节点关联的 Markdown 正文或代码，请在编辑器中调整。"
        )
    }

    func testPureListSubtreeReparentKeepsLinksExistingChildrenAndSelection() throws {
        let source = """
        # Plan
        - Move [me](Docs/One.md)
          - [[Nested.md]]
        - Target
          - Old child
            Existing child prose.
        """
        let nodes = MindMapOutline.nodes(in: source)
        let movedID = try XCTUnwrap(nodes.first(where: {
            $0.title == "Move [me](Docs/One.md)"
        })?.id)
        let targetID = try XCTUnwrap(nodes.first(where: { $0.title == "Target" })?.id)
        let outcome = try XCTUnwrap(
            MindMapOutline.moveListSubtreeWithOutcome(
                in: source, nodeID: movedID, asChildOf: targetID
            )
        )
        let expected = """
        # Plan
        - Target
          - Move [me](Docs/One.md)
            - [[Nested.md]]
          - Old child
            Existing child prose.
        """
        XCTAssertEqual(outcome.source, expected)
        XCTAssertEqual(outcome.movedNodeID, 2)
        XCTAssertEqual(MindMapOutline.nodes(in: expected).first(where: {
            $0.id == outcome.movedNodeID
        })?.title, "Move [me](Docs/One.md)")
        XCTAssertEqual(
            MindMapOutline.knowledgeLinks(in: outcome.source),
            MindMapOutline.knowledgeLinks(in: source)
        )
        XCTAssertTrue(outcome.source.contains("    Existing child prose."))
    }

    func testBlankSpacingBeforeTargetChildDoesNotBlockSafeMove() {
        let source = "# Plan\n- Move me\n- Target\n\n  - Old child\n"
        XCTAssertEqual(
            MindMapOutline.moveListSubtree(in: source, nodeID: 1, asChildOf: 2),
            "# Plan\n- Target\n  - Move me\n\n  - Old child\n"
        )
    }
}
