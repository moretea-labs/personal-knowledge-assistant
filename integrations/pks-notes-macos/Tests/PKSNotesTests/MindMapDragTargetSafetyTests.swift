import XCTest
@testable import PKSNotes

final class MindMapDragTargetSafetyTests: XCTestCase {
    private func rebaseCollapsed(_ indexes: Set<Int>, from oldSource: String, to newSource: String) -> Set<Int> {
        let oldNodes = MindMapOutline.nodes(in: oldSource)
        let newNodes = MindMapOutline.nodes(in: newSource)
        let lineIndexMap = MindMapOutline.lineIndexMap(from: oldNodes, to: newNodes)
        return Set(indexes.compactMap { lineIndexMap[$0] })
    }

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

            let move = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
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

    func testAddingHeadingSiblingRebasesCollapsedBranchesWithoutChangingTheirHierarchy() throws {
        let source = "# Root\n## A\n### A1\n## B\n"
        let nodes = MindMapOutline.nodes(in: source)
        let a = try XCTUnwrap(nodes.first { $0.title == "A" })
        let a1 = try XCTUnwrap(nodes.first { $0.title == "A1" })
        let collapsed = Set([a.id, a1.id])

        let outcome = try XCTUnwrap(
            MindMapOutline.addSiblingWithOutcome(in: source, nodeID: a.id)
        )
        let rebased = rebaseCollapsed(collapsed, from: source, to: outcome.source)
        let updatedNodes = MindMapOutline.nodes(in: outcome.source)
        let expected = Set(try ["A", "A1"].map { title in
            try XCTUnwrap(updatedNodes.first { $0.title == title }?.id)
        })
        XCTAssertEqual(rebased, expected)
    }

    func testDeletingLeafRebasesCollapsedBranchesAfterItsLine() throws {
        let source = "# Plan\n- A\n  - A1\n- Delete me\n- B\n  - B1\n"
        let nodes = MindMapOutline.nodes(in: source)
        let a = try XCTUnwrap(nodes.first(where: { $0.title == "A" }))
        let deleted = try XCTUnwrap(nodes.first(where: { $0.title == "Delete me" }))
        let b = try XCTUnwrap(nodes.first(where: { $0.title == "B" }))
        let collapsed = Set([a.id, b.id])

        let updated = try XCTUnwrap(MindMapOutline.deleteLeaf(in: source, nodeID: deleted.id))
        let rebased = rebaseCollapsed(collapsed, from: source, to: updated)
        let updatedB = try XCTUnwrap(MindMapOutline.nodes(in: updated).first(where: { $0.title == "B" }))

        XCTAssertEqual(rebased, Set([a.id, updatedB.id]))
        XCTAssertEqual(updatedB.id, b.id - 1)
    }

    func testDragSelectionUsesOriginalNodeIDUntilProjectionRebasesIt() throws {
        let source = "# Plan\n- A\n  - A1\n- B\n- C\n"
        let oldNodes = MindMapOutline.nodes(in: source)
        let dragged = try XCTUnwrap(oldNodes.first(where: { $0.title == "C" }))
        let target = try XCTUnwrap(oldNodes.first(where: { $0.title == "A" }))

        let outcome = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: dragged.id, relativeTo: target.id, placement: .child
        ))
        let newNodes = MindMapOutline.nodes(in: outcome.source)
        let movedNode = try XCTUnwrap(newNodes.first(where: { $0.title == "C" }))
        let lineIndexMap = MindMapOutline.lineIndexMap(from: oldNodes, to: newNodes)

        XCTAssertEqual(outcome.movedNodeID, movedNode.id)
        XCTAssertEqual(lineIndexMap[dragged.id], movedNode.id)
        XCTAssertNotEqual(
            lineIndexMap[outcome.movedNodeID],
            outcome.movedNodeID,
            "The new line index collides with the old A1 ID and must not be rebased twice."
        )
    }

    func testDragReparentPreservesCollapsedBranchesAcrossForwardAndBackwardMoves() throws {
        let source = """
        # Plan
        - A
          - A1
            - A1a
        - B
          - B1
        - C
          - C1
        """
        let nodes = MindMapOutline.nodes(in: source)
        let collapsedTitles = ["A", "A1", "B", "C"]
        let collapsed = Set(try collapsedTitles.map { title in
            try XCTUnwrap(nodes.first(where: { $0.title == title })?.id)
        })

        let a = try XCTUnwrap(nodes.first(where: { $0.title == "A" }))
        let c = try XCTUnwrap(nodes.first(where: { $0.title == "C" }))
        let forward = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: c.id, relativeTo: a.id, placement: .child
        ))
        var forwardCollapsed = rebaseCollapsed(collapsed, from: source, to: forward.source)
        forwardCollapsed.remove(a.id)
        let forwardNodes = MindMapOutline.nodes(in: forward.source)
        let expectedForward = Set(try ["A1", "B", "C"].map { title in
            try XCTUnwrap(forwardNodes.first(where: { $0.title == title })?.id)
        })
        XCTAssertEqual(forwardCollapsed, expectedForward)
        XCTAssertFalse(forwardCollapsed.contains(a.id), "The child-drop target must expand to reveal the moved branch.")

        let backward = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: a.id, relativeTo: c.id, placement: .after
        ))
        let backwardCollapsed = rebaseCollapsed(collapsed, from: source, to: backward.source)
        let backwardNodes = MindMapOutline.nodes(in: backward.source)
        let expectedBackward = Set(try collapsedTitles.map { title in
            try XCTUnwrap(backwardNodes.first(where: { $0.title == title })?.id)
        })
        XCTAssertEqual(backwardCollapsed, expectedBackward)
    }

    func testCollapsedDuplicateBranchesFollowTheirOriginalParentsAfterReparent() throws {
        let source = """
        # Plan
        - A
          - Duplicate
            - Leaf
        - B
          - Duplicate
            - Leaf
        - C
        """
        let oldNodes = MindMapOutline.nodes(in: source)
        let oldA = try XCTUnwrap(oldNodes.first(where: { $0.title == "A" }))
        let oldB = try XCTUnwrap(oldNodes.first(where: { $0.title == "B" }))
        let oldDuplicates = oldNodes.filter { $0.title == "Duplicate" }
        let oldLeaves = oldNodes.filter { $0.title == "Leaf" }
        XCTAssertEqual(oldDuplicates.count, 2)

        let move = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: oldB.id, relativeTo: oldA.id, placement: .child
        ))
        let newNodes = MindMapOutline.nodes(in: move.source)
        let newA = try XCTUnwrap(newNodes.first(where: { $0.title == "A" }))
        let newB = try XCTUnwrap(newNodes.first(where: { $0.title == "B" }))
        let newDuplicates = newNodes.filter { $0.title == "Duplicate" }
        let newLeaves = newNodes.filter { $0.title == "Leaf" }
        let lineIndexMap = MindMapOutline.lineIndexMap(from: oldNodes, to: newNodes)

        XCTAssertEqual(lineIndexMap[oldA.id], newA.id)
        XCTAssertEqual(lineIndexMap[oldB.id], newB.id)
        XCTAssertEqual(lineIndexMap[oldDuplicates[0].id], newDuplicates[1].id)
        XCTAssertEqual(lineIndexMap[oldDuplicates[1].id], newDuplicates[0].id)
        XCTAssertEqual(lineIndexMap[oldLeaves[0].id], newLeaves[1].id)
        XCTAssertEqual(lineIndexMap[oldLeaves[1].id], newLeaves[0].id)
        let collapsed = Set([oldDuplicates[0].id, oldDuplicates[1].id])
        XCTAssertEqual(rebaseCollapsed(collapsed, from: source, to: move.source), Set(newDuplicates.map(\.id)))
    }

    func testCollapsedDuplicateNodeFollowsItsBodyWhenReparentedAcrossParents() throws {
        let source = """
        # Plan
        - Parent
          - Duplicate
            Evidence alpha.
            - Child
          - Group
            - Duplicate
              Evidence beta.
              - Child
        """
        let oldNodes = MindMapOutline.nodes(in: source)
        let oldDuplicates = oldNodes.filter { $0.title == "Duplicate" }
        let oldChildren = oldNodes.filter { $0.title == "Child" }
        XCTAssertEqual(oldDuplicates.count, 2)
        XCTAssertEqual(oldChildren.count, 2)

        let move = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: oldDuplicates[1].id,
            relativeTo: oldDuplicates[0].id, placement: .after
        ))
        let newNodes = MindMapOutline.nodes(in: move.source)
        let newDuplicates = newNodes.filter { $0.title == "Duplicate" }
        let newChildren = newNodes.filter { $0.title == "Child" }
        XCTAssertEqual(newDuplicates.count, 2)
        XCTAssertEqual(newChildren.count, 2)

        let lineIndexMap = MindMapOutline.lineIndexMap(from: oldNodes, to: newNodes)
        XCTAssertEqual(lineIndexMap[oldDuplicates[0].id], newDuplicates[0].id)
        XCTAssertEqual(lineIndexMap[oldDuplicates[1].id], newDuplicates[1].id)
        XCTAssertEqual(lineIndexMap[oldChildren[0].id], newChildren[0].id)
        XCTAssertEqual(lineIndexMap[oldChildren[1].id], newChildren[1].id)
        XCTAssertEqual(
            rebaseCollapsed([oldDuplicates[1].id], from: source, to: move.source),
            [newDuplicates[1].id]
        )
    }

    func testCollapsedDuplicateSiblingBranchesFollowTheirSubtreesAfterReorder() throws {
        let source = """
        # Plan
        - Parent
          - Duplicate
            - Alpha
          - Duplicate
            - Beta
        """
        let oldNodes = MindMapOutline.nodes(in: source)
        let oldDuplicates = oldNodes.filter { $0.title == "Duplicate" }
        let oldAlpha = try XCTUnwrap(oldNodes.first(where: { $0.title == "Alpha" }))
        let oldBeta = try XCTUnwrap(oldNodes.first(where: { $0.title == "Beta" }))
        XCTAssertEqual(oldDuplicates.count, 2)

        let reorder = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source,
            nodeID: oldDuplicates[1].id,
            relativeTo: oldDuplicates[0].id,
            placement: .before
        ))
        let newNodes = MindMapOutline.nodes(in: reorder.source)
        let newDuplicates = newNodes.filter { $0.title == "Duplicate" }
        let newAlpha = try XCTUnwrap(newNodes.first(where: { $0.title == "Alpha" }))
        let newBeta = try XCTUnwrap(newNodes.first(where: { $0.title == "Beta" }))
        let lineIndexMap = MindMapOutline.lineIndexMap(from: oldNodes, to: newNodes)

        XCTAssertEqual(lineIndexMap[oldDuplicates[0].id], newDuplicates[1].id)
        XCTAssertEqual(lineIndexMap[oldDuplicates[1].id], newDuplicates[0].id)
        XCTAssertEqual(lineIndexMap[oldAlpha.id], newAlpha.id)
        XCTAssertEqual(lineIndexMap[oldBeta.id], newBeta.id)
        XCTAssertEqual(
            rebaseCollapsed([oldDuplicates[0].id], from: source, to: reorder.source),
            [newDuplicates[1].id]
        )
    }

    func testDuplicateBranchesUseSubtreeShapeWhenTitleSequenceIsUnchanged() throws {
        let source = "# Plan\n- Parent\n  - Duplicate\n    - Child\n      - Leaf\n  - Duplicate\n    - Child\n    - Leaf\n"
        let oldNodes = MindMapOutline.nodes(in: source)
        let duplicates = oldNodes.filter { $0.title == "Duplicate" }
        let moved = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: duplicates[1].id, relativeTo: duplicates[0].id, placement: .before
        ))
        let newNodes = MindMapOutline.nodes(in: moved.source)
        let newDuplicates = newNodes.filter { $0.title == "Duplicate" }
        XCTAssertEqual(oldNodes.map(\.title), newNodes.map(\.title))
        let map = MindMapOutline.lineIndexMap(from: oldNodes, to: newNodes)
        XCTAssertEqual(map[duplicates[0].id], newDuplicates[1].id)
        XCTAssertEqual(map[duplicates[1].id], newDuplicates[0].id)
        XCTAssertEqual(rebaseCollapsed([duplicates[0].id], from: source, to: moved.source), [newDuplicates[1].id])
    }

    func testCollapsedDuplicateSiblingBranchesFollowAttachedMarkdownWhenOutlineShapeIsIdentical() throws {
        let source = """
        # Plan
        - Parent
          - Duplicate
            Evidence alpha.
            - Child
          - Duplicate
            Evidence beta.
            - Child
        """
        let oldNodes = MindMapOutline.nodes(in: source)
        let oldDuplicates = oldNodes.filter { $0.title == "Duplicate" }
        let oldChildren = oldNodes.filter { $0.title == "Child" }
        XCTAssertEqual(oldDuplicates.count, 2)
        XCTAssertEqual(oldChildren.count, 2)

        let reorder = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: oldDuplicates[1].id,
            relativeTo: oldDuplicates[0].id, placement: .before
        ))
        let newNodes = MindMapOutline.nodes(in: reorder.source)
        let newDuplicates = newNodes.filter { $0.title == "Duplicate" }
        let newChildren = newNodes.filter { $0.title == "Child" }
        XCTAssertEqual(oldNodes.map(\.title), newNodes.map(\.title))
        XCTAssertEqual(oldNodes.map(\.depth), newNodes.map(\.depth))

        let lineIndexMap = MindMapOutline.lineIndexMap(from: oldNodes, to: newNodes)
        XCTAssertEqual(lineIndexMap[oldDuplicates[0].id], newDuplicates[1].id)
        XCTAssertEqual(lineIndexMap[oldDuplicates[1].id], newDuplicates[0].id)
        XCTAssertEqual(lineIndexMap[oldChildren[0].id], newChildren[1].id)
        XCTAssertEqual(lineIndexMap[oldChildren[1].id], newChildren[0].id)
        XCTAssertEqual(
            rebaseCollapsed([oldDuplicates[0].id], from: source, to: reorder.source),
            [newDuplicates[1].id]
        )
    }

    func testAddingNodesRebasesOnlyAffectedCollapsedBranches() throws {
        let source = "# Plan\n- A\n  - A1\n- B\n  - B1\n- C\n  - C1\n"
        let nodes = MindMapOutline.nodes(in: source)
        let collapsed = Set(try ["A", "B", "C"].map { title in
            try XCTUnwrap(nodes.first(where: { $0.title == title })?.id)
        })
        let a = try XCTUnwrap(nodes.first(where: { $0.title == "A" }))

        let child = try XCTUnwrap(MindMapOutline.addChildWithOutcome(in: source, parentID: a.id))
        var childCollapsed = rebaseCollapsed(collapsed, from: source, to: child.source)
        childCollapsed.remove(a.id)
        let childNodes = MindMapOutline.nodes(in: child.source)
        let expectedChildCollapsed = Set(try ["B", "C"].map { title in
            try XCTUnwrap(childNodes.first(where: { $0.title == title })?.id)
        })
        XCTAssertEqual(childCollapsed, expectedChildCollapsed)

        let sibling = try XCTUnwrap(MindMapOutline.addSiblingWithOutcome(in: source, nodeID: a.id))
        let siblingCollapsed = rebaseCollapsed(collapsed, from: source, to: sibling.source)
        let siblingNodes = MindMapOutline.nodes(in: sibling.source)
        let expectedSiblingCollapsed = Set(try ["A", "B", "C"].map { title in
            try XCTUnwrap(siblingNodes.first(where: { $0.title == title })?.id)
        })
        XCTAssertEqual(siblingCollapsed, expectedSiblingCollapsed)
    }

    func testDeletingBranchRebasesOnlySurvivingCollapsedBranches() throws {
        let source = "# Plan\n- A\n  - A1\n- B\n  - B1\n- C\n  - C1\n"
        let nodes = MindMapOutline.nodes(in: source)
        let collapsed = Set(try ["A", "B", "C"].map { title in
            try XCTUnwrap(nodes.first(where: { $0.title == title })?.id)
        })
        let b = try XCTUnwrap(nodes.first(where: { $0.title == "B" }))

        let updated = try XCTUnwrap(MindMapOutline.deleteNodeSubtree(in: source, nodeID: b.id))
        let rebased = rebaseCollapsed(collapsed, from: source, to: updated)
        let updatedNodes = MindMapOutline.nodes(in: updated)
        let expected = Set(try ["A", "C"].map { title in
            try XCTUnwrap(updatedNodes.first(where: { $0.title == title })?.id)
        })
        XCTAssertEqual(updated, "# Plan\n- A\n  - A1\n- C\n  - C1\n")
        XCTAssertEqual(rebased, expected)
    }

    func testUnsafeUnindentedTextStillRejectsChildInsertionAndReparenting() throws {
        let source = "# Plan\n- Move me\n- Target\nUnindented text outside the list.\n- Existing child\n"
        let nodes = MindMapOutline.nodes(in: source)
        let moved = try XCTUnwrap(nodes.first(where: { $0.title == "Move me" }))
        let target = try XCTUnwrap(nodes.first(where: { $0.title == "Target" }))

        XCTAssertNil(MindMapOutline.moveNodeSubtreeWithOutcome(
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

        let before = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: c.id, relativeTo: a.id, placement: .before
        ))
        XCTAssertEqual(before.source, "# Plan\n- C\n- A\n  - A1\n- B")
        XCTAssertEqual(before.movedNodeID, 1)

        let after = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: c.id, relativeTo: a.id, placement: .after
        ))
        XCTAssertEqual(after.source, "# Plan\n- A\n  - A1\n- C\n- B")
        XCTAssertEqual(after.movedNodeID, 3)

        let citation = "/Books/Study.pdf#page=4&rects=0.1,0.2,0.3,0.04&fp=0123456789abcdef"
        let citedSource = "# Plan\n- A\n  [Textbook · p. 4](\(citation))\n- B\n- C"
        let citedNodes = MindMapOutline.nodes(in: citedSource)
        let citedA = try XCTUnwrap(citedNodes.first(where: { $0.title == "A" }))
        let citedC = try XCTUnwrap(citedNodes.first(where: { $0.title == "C" }))
        let citedAfter = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
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

    func testHeadingSectionsCanBeReparentedAndPreserveNestedMarkdownAndPDFEvidence() throws {
        let citation = "/Books/Study.pdf#page=4&rects=0.1,0.2,0.3,0.04&fp=0123456789abcdef"
        let source = """
        # Plan
        ## Reading
        Introduction belongs to Reading.
        [Textbook · p. 4](\(citation))
        > Selected passage
        ### Detail
        Details stay with the section.
        - Claim
        ## Target
        Target introduction.
        ### Existing
        Existing child.
        ## Keep
        """
        let oldNodes = MindMapOutline.nodes(in: source)
        let reading = try XCTUnwrap(oldNodes.first { $0.title == "Reading" })
        let detail = try XCTUnwrap(oldNodes.first { $0.title == "Detail" })
        let target = try XCTUnwrap(oldNodes.first { $0.title == "Target" })

        let outcome = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: reading.id, relativeTo: target.id, placement: .child
        ))
        XCTAssertEqual(outcome.source, """
        # Plan
        ## Target
        Target introduction.
        ### Reading
        Introduction belongs to Reading.
        [Textbook · p. 4](\(citation))
        > Selected passage
        #### Detail
        Details stay with the section.
        - Claim
        ### Existing
        Existing child.
        ## Keep
        """)

        let newNodes = MindMapOutline.nodes(in: outcome.source)
        let movedReading = try XCTUnwrap(newNodes.first { $0.title == "Reading" })
        let movedDetail = try XCTUnwrap(newNodes.first { $0.title == "Detail" })
        let mapping = MindMapOutline.lineIndexMap(from: oldNodes, to: newNodes)
        XCTAssertEqual(mapping[reading.id], movedReading.id)
        XCTAssertEqual(mapping[detail.id], movedDetail.id)
        XCTAssertEqual(
            MindMapOutline.presentations(in: outcome.source, nodes: newNodes)[movedReading.id]?.links.map(\.target),
            [citation]
        )
    }

    func testHeadingSectionsReorderAndRejectCyclesUnsupportedTargetsAndDepthOverflow() throws {
        let source = """
        # Root
        ## A
        A body.
        ### A1
        - Claim
        ## B
        B body.
        ### B1
        ## C
        C body.
        """
        let nodes = MindMapOutline.nodes(in: source)
        let a = try XCTUnwrap(nodes.first { $0.title == "A" })
        let b = try XCTUnwrap(nodes.first { $0.title == "B" })
        let c = try XCTUnwrap(nodes.first { $0.title == "C" })

        let before = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: c.id, relativeTo: a.id, placement: .before
        ))
        XCTAssertEqual(before.source, """
        # Root
        ## C
        C body.
        ## A
        A body.
        ### A1
        - Claim
        ## B
        B body.
        ### B1
        """)

        let after = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: source, nodeID: a.id, relativeTo: b.id, placement: .after
        ))
        XCTAssertEqual(after.source, """
        # Root
        ## B
        B body.
        ### B1
        ## A
        A body.
        ### A1
        - Claim
        ## C
        C body.
        """)

        let nested = "# Root\n## Parent\n### Child\n"
        let nestedNodes = MindMapOutline.nodes(in: nested)
        let parent = try XCTUnwrap(nestedNodes.first { $0.title == "Parent" })
        let child = try XCTUnwrap(nestedNodes.first { $0.title == "Child" })
        XCTAssertNil(MindMapOutline.moveNodeSubtree(in: nested, nodeID: parent.id, asChildOf: child.id))

        let deep = "# Root\n###### Last\n## Candidate\n"
        let deepNodes = MindMapOutline.nodes(in: deep)
        let last = try XCTUnwrap(deepNodes.first { $0.title == "Last" })
        let candidate = try XCTUnwrap(deepNodes.first { $0.title == "Candidate" })
        XCTAssertNil(MindMapOutline.moveNodeSubtree(in: deep, nodeID: candidate.id, asChildOf: last.id))

        let mixed = "# Root\n- List\n## Section\n"
        let mixedNodes = MindMapOutline.nodes(in: mixed)
        let list = try XCTUnwrap(mixedNodes.first { $0.title == "List" })
        let section = try XCTUnwrap(mixedNodes.first { $0.title == "Section" })
        XCTAssertNil(MindMapOutline.moveNodeSubtree(in: mixed, nodeID: section.id, asChildOf: list.id))
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
        let outcome = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
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
            MindMapOutline.shiftNodeSubtree(in: source, nodeID: nodeID, deeper: true)
        )
        XCTAssertTrue(demoted.contains("    [Textbook · p. 2](\(citation))"))
        XCTAssertTrue(demoted.contains("    > Keep this note attached."))

        let promoted = try XCTUnwrap(
            MindMapOutline.shiftNodeSubtree(in: demoted, nodeID: nodeID, deeper: false)
        )
        XCTAssertEqual(promoted, source)
    }

    func testBlankSpacingBeforeTargetChildDoesNotBlockSafeMove() {
        let source = "# Plan\n- Move me\n- Target\n\n  - Old child\n"
        XCTAssertEqual(
            MindMapOutline.moveNodeSubtree(in: source, nodeID: 1, asChildOf: 2),
            "# Plan\n- Target\n\n  - Move me\n  - Old child\n"
        )
    }
}


extension MindMapDragTargetSafetyTests {
    func testNodeDragPayloadRejectsStaleDraftForeignCanvasAndMissingNodes() throws {
        let nodes = MindMapOutline.nodes(in: "# Plan\n- Move me\n- Target\n")
        let moved = try XCTUnwrap(nodes.first(where: { $0.title == "Move me" }))
        let target = try XCTUnwrap(nodes.first(where: { $0.title == "Target" }))
        let ids = Set(nodes.map(\.id))
        let canvasSessionID = UUID()
        let otherCanvasSessionID = UUID()
        let payload = MindMapNodeDragPayload(
            canvasSessionID: canvasSessionID,
            revision: 41,
            nodeID: moved.id
        )
        XCTAssertEqual(
            payload.resolve(
                in: ids, target: target.id,
                canvasSessionID: canvasSessionID, revision: 41
            ),
            moved.id
        )
        XCTAssertNil(payload.resolve(
            in: ids, target: target.id,
            canvasSessionID: canvasSessionID, revision: 42
        ))
        XCTAssertNil(payload.resolve(
            in: ids, target: target.id,
            canvasSessionID: otherCanvasSessionID, revision: 41
        ), "A drag from another window must never mutate this canvas.")
        XCTAssertNil(payload.resolve(
            in: Set([target.id]), target: target.id,
            canvasSessionID: canvasSessionID, revision: 41
        ))
        XCTAssertNil(payload.resolve(
            in: Set([moved.id]), target: target.id,
            canvasSessionID: canvasSessionID, revision: 41
        ))
    }

    func testDragFromStaleProjectionIsRejectedWhenItsLineIndexNowNamesAnotherNode() throws {
        let oldSource = "# Plan\n- A\n  - A1\n- B\n- C\n"
        let newSource = "# Plan\n- A\n  - C\n  - A1\n- B\n"
        let oldNodes = MindMapOutline.nodes(in: oldSource)
        let currentNodes = MindMapOutline.nodes(in: newSource)
        let staleNode = try XCTUnwrap(oldNodes.first(where: { $0.title == "A1" }))
        let currentNodeAtSameLine = try XCTUnwrap(currentNodes.first(where: { $0.title == "C" }))
        let currentTarget = try XCTUnwrap(currentNodes.first(where: { $0.title == "B" }))
        let canvasSessionID = UUID()
        let staleProjectionRevision: UInt64 = 41
        let currentMarkdownRevision: UInt64 = 42

        XCTAssertEqual(staleNode.id, currentNodeAtSameLine.id)

        let payload = MindMapNodeDragPayload(
            canvasSessionID: canvasSessionID,
            revision: staleProjectionRevision,
            nodeID: staleNode.id
        )
        XCTAssertNil(payload.resolve(
            in: Set(currentNodes.map(\.id)),
            target: currentTarget.id,
            canvasSessionID: canvasSessionID,
            revision: currentMarkdownRevision
        ), "A stale card must not mutate the different node now occupying its old line index.")
    }
}
