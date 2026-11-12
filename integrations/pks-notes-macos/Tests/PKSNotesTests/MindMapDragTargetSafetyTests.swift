import XCTest
@testable import PKSNotes

final class MindMapDragTargetSafetyTests: XCTestCase {
    func testAddChildAndReparentPreserveAttachedMarkdownAtSafeBoundaries() throws {
        let cases: [(source: String, expectedMove: String, expectedAdd: String)] = [
            (
                "# Plan\n- Move me\n- Target\n  Context belongs to Target.\n  - Existing child\n",
                "# Plan\n- Target\n  Context belongs to Target.\n  - Move me\n  - Existing child\n",
                "# Plan\n- Move me\n- Target\n  Context belongs to Target.\n  - New idea\n  - Existing child\n"
            ),
            (
                "# Plan\n- Move me\n- Target\n  > Target quotation.\n  - Existing child\n",
                "# Plan\n- Target\n  > Target quotation.\n  - Move me\n  - Existing child\n",
                "# Plan\n- Move me\n- Target\n  > Target quotation.\n  - New idea\n  - Existing child\n"
            ),
            (
                "# Plan\n- Move me\n- Target\n  ~~~swift\n  print(\"original target\")\n  ~~~\n  - Existing child\n",
                "# Plan\n- Target\n  ~~~swift\n  print(\"original target\")\n  ~~~\n  - Move me\n  - Existing child\n",
                "# Plan\n- Move me\n- Target\n  ~~~swift\n  print(\"original target\")\n  ~~~\n  - New idea\n  - Existing child\n"
            ),
            (
                "# Plan\n- Move me\n- Target\n  Attached trailing paragraph.\n",
                "# Plan\n- Target\n  Attached trailing paragraph.\n  - Move me\n",
                "# Plan\n- Move me\n- Target\n  Attached trailing paragraph.\n  - New idea\n"
            ),
            (
                "# Plan\n- Move me\n# Target\nAn introduction belonging to the heading.\n- Existing child\n",
                "# Plan\n# Target\nAn introduction belonging to the heading.\n- Move me\n- Existing child\n",
                "# Plan\n- Move me\n# Target\nAn introduction belonging to the heading.\n- New idea\n- Existing child\n"
            )
        ]

        for fixture in cases {
            let nodes = MindMapOutline.nodes(in: fixture.source)
            let moved = try XCTUnwrap(nodes.first(where: { $0.title == "Move me" }))
            let target = try XCTUnwrap(nodes.first(where: { $0.title == "Target" }))

            let move = try XCTUnwrap(MindMapOutline.moveListSubtreeWithOutcome(
                in: fixture.source, nodeID: moved.id, asChildOf: target.id
            ))
            XCTAssertEqual(move.source, fixture.expectedMove)

            let add = try XCTUnwrap(MindMapOutline.addChildWithOutcome(
                in: fixture.source, parentID: target.id
            ))
            XCTAssertEqual(add.source, fixture.expectedAdd)
            XCTAssertEqual(
                MindMapOutline.nodes(in: add.source).first(where: { $0.id == add.nodeID })?.title,
                "New idea"
            )
        }
    }

    func testDeletingLeafRebasesCollapsedBranchesAfterItsLine() throws {
        let source = "# Plan\n- A\n  - A1\n- Delete me\n- B\n  - B1\n"
        let nodes = MindMapOutline.nodes(in: source)
        let a = try XCTUnwrap(nodes.first(where: { $0.title == "A" }))
        let deleted = try XCTUnwrap(nodes.first(where: { $0.title == "Delete me" }))
        let b = try XCTUnwrap(nodes.first(where: { $0.title == "B" }))
        let collapsed = Set([a.id, b.id])

        let updated = try XCTUnwrap(MindMapOutline.deleteLeaf(in: source, nodeID: deleted.id))
        let rebased = MindMapOutline.rebasedLineIndexes(collapsed, afterDeletingLine: deleted.id)
        let updatedB = try XCTUnwrap(MindMapOutline.nodes(in: updated).first(where: { $0.title == "B" }))

        XCTAssertEqual(rebased, Set([a.id, updatedB.id]))
        XCTAssertEqual(updatedB.id, b.id - 1)
    }

    func testUnsafeUnindentedTextStillRejectsChildInsertionAndReparenting() throws {
        let source = "# Plan\n- Move me\n- Target\nUnindented text outside the list.\n- Existing child\n"
        let nodes = MindMapOutline.nodes(in: source)
        let moved = try XCTUnwrap(nodes.first(where: { $0.title == "Move me" }))
        let target = try XCTUnwrap(nodes.first(where: { $0.title == "Target" }))

        XCTAssertNil(MindMapOutline.moveListSubtreeWithOutcome(
            in: source, nodeID: moved.id, asChildOf: target.id
        ))
        XCTAssertNil(MindMapOutline.addChild(in: source, parentID: target.id))
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.text(
                "Cannot move this branch without changing attached Markdown. Use the editor."
            ),
            "移动会改变节点关联的 Markdown 正文或代码，请在编辑器中调整。"
        )
    }

    func testDragDropReordersSiblingsBeforeAndAfterWholeSubtrees() throws {
        let source = "# Plan\n- A\n  - A1\n- B\n- C"
        let nodes = MindMapOutline.nodes(in: source)
        let a = try XCTUnwrap(nodes.first(where: { $0.title == "A" }))
        let c = try XCTUnwrap(nodes.first(where: { $0.title == "C" }))

        let before = try XCTUnwrap(MindMapOutline.moveListSubtreeWithOutcome(
            in: source, nodeID: c.id, relativeTo: a.id, placement: .before
        ))
        XCTAssertEqual(before.source, "# Plan\n- C\n- A\n  - A1\n- B")
        XCTAssertEqual(before.movedNodeID, 1)

        let after = try XCTUnwrap(MindMapOutline.moveListSubtreeWithOutcome(
            in: source, nodeID: c.id, relativeTo: a.id, placement: .after
        ))
        XCTAssertEqual(after.source, "# Plan\n- A\n  - A1\n- C\n- B")
        XCTAssertEqual(after.movedNodeID, 3)

        let citation = "/Books/Study.pdf#page=4&rects=0.1,0.2,0.3,0.04&fp=0123456789abcdef"
        let citedSource = "# Plan\n- A\n  [Textbook · p. 4](\(citation))\n- B\n- C"
        let citedNodes = MindMapOutline.nodes(in: citedSource)
        let citedA = try XCTUnwrap(citedNodes.first(where: { $0.title == "A" }))
        let citedC = try XCTUnwrap(citedNodes.first(where: { $0.title == "C" }))
        let citedAfter = try XCTUnwrap(MindMapOutline.moveListSubtreeWithOutcome(
            in: citedSource, nodeID: citedC.id, relativeTo: citedA.id, placement: .after
        ))
        XCTAssertEqual(
            citedAfter.source,
            "# Plan\n- A\n  [Textbook · p. 4](\(citation))\n- C\n- B"
        )
        let reorderedNodes = MindMapOutline.nodes(in: citedAfter.source)
        let aPresentation = try XCTUnwrap(
            MindMapOutline.presentations(in: citedAfter.source, nodes: reorderedNodes)[citedA.id]
        )
        XCTAssertEqual(aPresentation.links.map(\.target), [citation])
    }

    func testAddChildKeepsTheParentsPDFCitationOnTheParentNode() throws {
        let citation = "/Books/Study.pdf#page=3&rects=0.2,0.3,0.4,0.05&fp=abcdef0123456789"
        let source = "# Plan\n- Parent\n  [Textbook · p. 3](\(citation))\n  - Existing child\n"
        let parent = try XCTUnwrap(
            MindMapOutline.nodes(in: source).first(where: { $0.title == "Parent" })
        )
        let outcome = try XCTUnwrap(
            MindMapOutline.addChildWithOutcome(in: source, parentID: parent.id)
        )
        XCTAssertEqual(
            outcome.source,
            "# Plan\n- Parent\n  [Textbook · p. 3](\(citation))\n  - New idea\n  - Existing child\n"
        )

        let nodes = MindMapOutline.nodes(in: outcome.source)
        let updatedParent = try XCTUnwrap(nodes.first(where: { $0.title == "Parent" }))
        let newChild = try XCTUnwrap(nodes.first(where: { $0.id == outcome.nodeID }))
        let presentations = MindMapOutline.presentations(in: outcome.source, nodes: nodes)
        XCTAssertEqual(presentations[updatedParent.id]?.links.map(\.target), [citation])
        XCTAssertEqual(presentations[newChild.id]?.links, [])
    }

    func testMoveKeepsPDFCitationQuoteAndFencedCodeWithItsNode() throws {
        let citation = "/Books/Study%20Guide.pdf#page=4&rects=0.1,0.2,0.3,0.04&fp=0123456789abcdef"
        let source = """
        # Plan
        - A
          - A1
            [Textbook · p. 4](\(citation))
            > Selected passage
            ~~~swift
            let value = 1
            ~~~
        - B
        """
        let nodes = MindMapOutline.nodes(in: source)
        let moved = try XCTUnwrap(nodes.first(where: { $0.title == "A1" }))
        let target = try XCTUnwrap(nodes.first(where: { $0.title == "B" }))
        let outcome = try XCTUnwrap(MindMapOutline.moveListSubtreeWithOutcome(
            in: source, nodeID: moved.id, asChildOf: target.id
        ))

        XCTAssertEqual(outcome.source, """
        # Plan
        - A
        - B
          - A1
            [Textbook · p. 4](\(citation))
            > Selected passage
            ~~~swift
            let value = 1
            ~~~
        """)
        let movedNodes = MindMapOutline.nodes(in: outcome.source)
        let movedNode = try XCTUnwrap(movedNodes.first(where: { $0.title == "A1" }))
        let presentation = try XCTUnwrap(
            MindMapOutline.presentations(in: outcome.source, nodes: movedNodes)[movedNode.id]
        )
        XCTAssertEqual(presentation.links.map(\.target), [citation])
    }

    func testPromoteAndDemoteKeepAttachedCitationAndQuoteBlocks() throws {
        let citation = "/Books/Study.pdf#page=2"
        let source = """
        # Plan
        - Before
        - A
          [Textbook · p. 2](\(citation))
          > Keep this note attached.
          - A1
        - B
        """
        let nodeID = try XCTUnwrap(MindMapOutline.nodes(in: source).first(where: {
            $0.title == "A"
        })?.id)
        let demoted = try XCTUnwrap(
            MindMapOutline.shiftListSubtree(in: source, nodeID: nodeID, deeper: true)
        )
        XCTAssertTrue(demoted.contains("    [Textbook · p. 2](\(citation))"))
        XCTAssertTrue(demoted.contains("    > Keep this note attached."))

        let promoted = try XCTUnwrap(
            MindMapOutline.shiftListSubtree(in: demoted, nodeID: nodeID, deeper: false)
        )
        XCTAssertEqual(promoted, source)
    }

    func testBlankSpacingBeforeTargetChildDoesNotBlockSafeMove() {
        let source = "# Plan\n- Move me\n- Target\n\n  - Old child\n"
        XCTAssertEqual(
            MindMapOutline.moveListSubtree(in: source, nodeID: 1, asChildOf: 2),
            "# Plan\n- Target\n\n  - Move me\n  - Old child\n"
        )
    }
}
