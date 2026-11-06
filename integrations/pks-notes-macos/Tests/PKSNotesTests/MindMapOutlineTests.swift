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
