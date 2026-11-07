import XCTest
@testable import PKSNotes

final class MindMapOutlineTests: XCTestCase {
    func testHeadingsAndNestedLists() {
        let nodes = MindMapOutline.nodes(in: "# Root\n- Child\n  - Grandchild\n## Another\n- Next")
        XCTAssertEqual(nodes.map(\.title), ["Root", "Child", "Grandchild", "Another", "Next"])
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 2, 1, 2])
    }

    func testFencedCodeIgnored() {
        let nodes = MindMapOutline.nodes(in: "# Root\n```md\n# Not heading\n- Not node\n```\n- Real")
        XCTAssertEqual(nodes.map(\.title), ["Root", "Real"])
    }
}

extension MindMapOutlineTests {
    func testRenamePreservesMarkdownSyntax() {
        XCTAssertEqual(MindMapOutline.rename(in: "# Root\n  - Child", nodeID: 1, to: "Updated"), "# Root\n  - Updated")
        XCTAssertEqual(MindMapOutline.rename(in: "# Root", nodeID: 0, to: "Changed"), "# Changed")
        XCTAssertNil(MindMapOutline.rename(in: "# Root", nodeID: 0, to: ""))
    }

    func testAddingChildPreservesHierarchy() {
        XCTAssertEqual(MindMapOutline.addChild(in: "# Root\n- Existing", parentID: 0), "# Root\n- New idea\n- Existing")
        XCTAssertEqual(MindMapOutline.addChild(in: "# Root\n- Existing", parentID: 1), "# Root\n- Existing\n  - New idea")
    }
}

extension MindMapOutlineTests {
    func testDeleteListSubtreeKeepsUnrelatedHeadingsAndSiblings() {
        XCTAssertEqual(MindMapOutline.deleteListSubtree(
            in: "# Root\n- Parent\n  - Child A\n    - Grandchild\n  - Child B\n- Another",
            nodeID: 1
        ), "# Root\n- Another")
        XCTAssertEqual(MindMapOutline.deleteListSubtree(
            in: "# Root\n- Parent\n  - Child\n", nodeID: 1
        ), "# Root\n")
        XCTAssertEqual(MindMapOutline.deleteListSubtree(
            in: "# Root\n- Parent\n  - Child\n- Another", nodeID: 2
        ), "# Root\n- Parent\n- Another")
        XCTAssertNil(MindMapOutline.deleteListSubtree(
            in: "# Root\n- Child", nodeID: 0
        ))
    }

    func testDeleteListSubtreeRejectsNonListContentInsideBranch() {
        for source in [
            "# Root\n- Parent\n  - Child\n  Attached notes\n- Next",
            "# Root\n- Parent\n  ~~~swift\n  print(1)\n  ~~~\n  - Child\n- Next",
            "# Root\n- Parent\n  - Child\n  ![photo](photo.png)\n- Next",
            "# Root\n- Parent\n  - Child\n  - \n- Next"
        ] {
            XCTAssertNil(MindMapOutline.deleteListSubtree(in: source, nodeID: 1), source)
        }
    }

    func testDeleteLeafRejectsProseAndCodeThatBelongToTheItem() {
        for source in [
            "# Root\n- A\n  Explanation belongs to A\n- B",
            "# Root\n- A\n\n    A second paragraph\n- B",
            "# Root\n- A\n  ```swift\n  print(1)\n  ```\n- B",
            "# Root\n- A\n  ![Image](attachments/a.png)\n- B"
        ] {
            XCTAssertNil(MindMapOutline.deleteLeaf(in: source, nodeID: 1), source)
        }
        XCTAssertEqual(
            MindMapOutline.deleteLeaf(in: "# Root\n- A\n\n- B", nodeID: 1),
            "# Root\n\n- B"
        )
    }

    func testAddChildRejectsReparentingExistingMarkdownProse() {
        let heading = "# Root\nThis is a paragraph.\n- Existing"
        XCTAssertNil(MindMapOutline.addChild(in: heading, parentID: 0))
        let list = "# Root\n- A\n  Attached paragraph\n- B"
        XCTAssertNil(MindMapOutline.addChild(in: list, parentID: 1))
        XCTAssertEqual(MindMapOutline.addChild(
            in: "# Root\n\n- A", parentID: 0
        ), "# Root\n- New idea\n\n- A")
    }

    func testLeafDeletionDoesNotDiscardDescendantsOrHeadings() {
        XCTAssertEqual(MindMapOutline.deleteLeaf(in: "# Root\n- A\n- B", nodeID: 1), "# Root\n- B")
        XCTAssertNil(MindMapOutline.deleteLeaf(in: "# Root\n- Parent\n  - Child", nodeID: 1))
        XCTAssertNil(MindMapOutline.deleteLeaf(in: "# Root\n- Child", nodeID: 0))
    }
}


extension MindMapOutlineTests {
    func testWikiAndMarkdownLinksRemainCanonical() {
        let source = "# Project\n- [[Notes/Design|Design notes]]\n- [Spec](../spec.md)"
        let nodes = MindMapOutline.nodes(in: source)
        XCTAssertEqual(MindMapOutline.links(in: nodes[1].title), [.init(label: "Design notes", target: "Notes/Design")])
        XCTAssertEqual(MindMapOutline.links(in: nodes[2].title), [.init(label: "Spec", target: "../spec.md")])
        XCTAssertEqual(MindMapOutline.rename(in: source, nodeID: 1, to: "[[Notes/Architecture]]"), "# Project\n- [[Notes/Architecture]]\n- [Spec](../spec.md)")
    }
}


extension MindMapOutlineTests {
    func testShiftListSubtreeChangesHierarchyWithoutLosingChildren() {
        let source = "# Root\n- A\n- B\n  - B1\n- C"
        let deeper = MindMapOutline.shiftListSubtree(in: source, nodeID: 2, deeper: true)
        XCTAssertEqual(deeper, "# Root\n- A\n  - B\n    - B1\n- C")
        XCTAssertEqual(
            MindMapOutline.shiftListSubtree(in: deeper!, nodeID: 2, deeper: false),
            source
        )
    }

    func testShiftListSubtreeRejectsUnsafeOrImpossibleChanges() {
        XCTAssertNil(MindMapOutline.shiftListSubtree(in: "# Root\n- First", nodeID: 1, deeper: true))
        XCTAssertNil(MindMapOutline.shiftListSubtree(in: "# Root\n- Parent\nparagraph\n- Next", nodeID: 1, deeper: true))
        XCTAssertNil(MindMapOutline.shiftListSubtree(in: "# Root\n- Root item", nodeID: 1, deeper: false))
    }
}


extension MindMapOutlineTests {
    func testMoveListSubtreeReparentsWholeBranch() {
        let source = "# Root\n- A\n  - A1\n- B\n- C"
        XCTAssertEqual(
            MindMapOutline.moveListSubtree(in: source, nodeID: 1, asChildOf: 3),
            "# Root\n- B\n  - A\n    - A1\n- C"
        )
        XCTAssertEqual(
            MindMapOutline.moveListSubtree(in: source, nodeID: 4, asChildOf: 1),
            "# Root\n- A\n  - C\n  - A1\n- B"
        )
    }

    func testMoveListSubtreeCanAttachToHeadingAndRejectCycles() {
        let source = "# Root\n- A\n  - A1\n- B"
        XCTAssertEqual(
            MindMapOutline.moveListSubtree(in: source, nodeID: 3, asChildOf: 0),
            "# Root\n- B\n- A\n  - A1"
        )
        XCTAssertNil(MindMapOutline.moveListSubtree(in: source, nodeID: 1, asChildOf: 2))
        XCTAssertNil(MindMapOutline.moveListSubtree(in: source, nodeID: 0, asChildOf: 3))
    }
}


extension MindMapOutlineTests {
    func testKnowledgeLinksIgnoreFencedCodeAndDeduplicate() {
        let source = """
        # Root
        [[Alpha]]
        [Beta](Beta.md)
        [[Alpha]]
        ~~~
        [[Hidden]]
        ~~~
        """
        XCTAssertEqual(
            MindMapOutline.knowledgeLinks(in: source),
            [
                .init(label: "Alpha", target: "Alpha"),
                .init(label: "Beta", target: "Beta.md")
            ]
        )
    }
}

extension MindMapOutlineTests {
    func testSpatialLayoutInfersParentsAndSeparatesDepthColumns() {
        let nodes = MindMapOutline.nodes(in: "# Root\n- A\n  - A1\n- B")
        let layout = MindMapSpatialLayout.layout(nodes)
        let byID = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })

        XCTAssertEqual(byID[0]?.parentID, nil)
        XCTAssertEqual(byID[1]?.parentID, 0)
        XCTAssertEqual(byID[2]?.parentID, 1)
        XCTAssertEqual(byID[3]?.parentID, 0)
        XCTAssertGreaterThan(byID[1]!.center.x, byID[0]!.center.x)
        XCTAssertGreaterThan(byID[2]!.center.x, byID[1]!.center.x)
        XCTAssertLessThan(byID[1]!.center.y, byID[3]!.center.y)
        XCTAssertGreaterThan(layout.size.width, 560)
    }

    func testSpatialLayoutHandlesSixHundredSiblingsWithoutRepeatedPlacementLookup() {
        let nodes = [MindMapNode(id: 0, depth: 0, title: "Root")]
            + (1...600).map { MindMapNode(id: $0, depth: 1, title: "Child \($0)") }
        let snapshot = MindMapSpatialLayout.layout(nodes)
        XCTAssertEqual(snapshot.placements.count, 601)
        XCTAssertEqual(snapshot.placements.first?.id, 0)
        let leaves = Array(snapshot.placements.dropFirst())
        XCTAssertTrue(leaves.allSatisfy { $0.parentID == 0 })
        XCTAssertEqual(snapshot.placements[0].center.y,
                       (leaves[0].center.y + leaves[599].center.y) / 2,
                       accuracy: 0.001)
        XCTAssertTrue(zip(leaves, leaves.dropFirst()).allSatisfy {
            $1.center.y > $0.center.y + $0.size.height
        })
    }

    func testSpatialLayoutSupportsMultipleRoots() {
        let nodes = MindMapOutline.nodes(in: "# One\n- A\n# Two\n- B")
        let layout = MindMapSpatialLayout.layout(nodes)
        let roots = layout.placements.filter { $0.parentID == nil }
        XCTAssertEqual(roots.map(\.node.title), ["One", "Two"])
        XCTAssertLessThan(roots[0].center.y, roots[1].center.y)
    }
}


extension MindMapOutlineTests {
    func testSourceLineRangeUsesUTF16AndExactMarkdownLine() {
        let source = "# 根节点\n- Alpha 😀\n  - Child\nParagraph"
        XCTAssertEqual(
            MindMapOutline.sourceLineRange(in: source, nodeID: 1),
            NSRange(location: 6, length: 10)
        )
        XCTAssertEqual(
            MindMapOutline.sourceLineRange(in: source, nodeID: 2),
            NSRange(location: 17, length: 9)
        )
        XCTAssertNil(MindMapOutline.sourceLineRange(in: source, nodeID: 3))
    }

    func testCaretResolvesToNearestPrecedingMindMapNode() {
        let source = "# Root\nIntro paragraph\n- Topic\n  supporting prose\n  - Child"
        let ns = source as NSString
        XCTAssertEqual(MindMapOutline.nodeID(atUTF16Offset: 0, in: source), 0)
        XCTAssertEqual(
            MindMapOutline.nodeID(atUTF16Offset: ns.range(of: "Intro").location, in: source),
            0
        )
        XCTAssertEqual(
            MindMapOutline.nodeID(atUTF16Offset: ns.range(of: "supporting").location, in: source),
            2
        )
        XCTAssertEqual(
            MindMapOutline.nodeID(atUTF16Offset: ns.range(of: "Child").location, in: source),
            4
        )
    }
}
