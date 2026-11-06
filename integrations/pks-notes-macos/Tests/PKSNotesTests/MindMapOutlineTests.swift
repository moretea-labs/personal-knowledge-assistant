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
