import CoreGraphics
import XCTest
@testable import PKSNotes

final class MindMapViewportTests: XCTestCase {
    func testSelectionCanBeCenteredBeyondAnyCanvasEdge() {
        let map = CGSize(width: 4800, height: 9200)
        let node = CGPoint(x: 4770, y: 9140)
        let offset = MindMapViewportGeometry.centeredOffset(
            for: node, mapSize: map, zoom: 1.4
        )
        XCTAssertEqual(2400 - offset.width / 1.4, node.x, accuracy: 0.001)
        XCTAssertEqual(4600 - offset.height / 1.4, node.y, accuracy: 0.001)
    }

    func testInitialRootViewUsesActualSizeAndLeavesRoomForChildren() {
        let viewport = CGSize(width: 1000, height: 680)
        let map = CGSize(width: 8400, height: 50000)
        let root = CGPoint(x: 150, y: 25000)
        let offset = MindMapViewportGeometry.initialRootOffset(
            root: root, mapSize: map, viewport: viewport
        )
        let screenX = viewport.width / 2 + offset.width + root.x - map.width / 2
        let screenY = viewport.height / 2 + offset.height + root.y - map.height / 2
        XCTAssertEqual(screenX, 320, accuracy: 0.001)
        XCTAssertEqual(screenY, 340, accuracy: 0.001)
    }

    func testPinchKeepsContentPointUnderAnchor() {
        let screen = CGSize(width: 900, height: 640)
        let anchor = CGPoint(x: 710, y: 130)
        let origin = CGSize(width: -390, height: 250)
        let adjusted = MindMapViewportGeometry.offsetPreservingAnchor(
            origin, from: 1.25, to: 2.5, anchor: anchor, viewport: screen
        )
        let oldX = (anchor.x - screen.width / 2 - origin.width) / 1.25
        let oldY = (anchor.y - screen.height / 2 - origin.height) / 1.25
        let newX = (anchor.x - screen.width / 2 - adjusted.width) / 2.5
        let newY = (anchor.y - screen.height / 2 - adjusted.height) / 2.5
        XCTAssertEqual(newX, oldX, accuracy: 0.001)
        XCTAssertEqual(newY, oldY, accuracy: 0.001)
    }

    func testFitCanShowMapsFarLargerThanTheViewport() {
        let scale = MindMapViewportGeometry.fittingZoom(
            mapSize: CGSize(width: 20000, height: 150000),
            viewport: CGSize(width: 800, height: 650)
        )
        XCTAssertGreaterThan(scale, 0)
        XCTAssertLessThanOrEqual(150000 * scale, 650 - 36 + 0.01)
        XCTAssertLessThanOrEqual(20000 * scale, 800 - 36 + 0.01)
        XCTAssertEqual(MindMapViewportGeometry.fittingZoom(
            mapSize: CGSize(width: 400, height: 300),
            viewport: CGSize(width: 1000, height: 800)
        ), 1.25)
    }

    func testNodeDetailsUseOnlyAttachedMarkdownBody() throws {
        let source = """
        # Parent
        A note for parent.
        [[Reference|source]]
        - Child
          Child note line
          > Quoted detail
        - Sibling
        Sibling-only details
        """
        let nodes = MindMapOutline.nodes(in: source)
        let parent = try XCTUnwrap(nodes.first(where: { $0.title == "Parent" }))
        let child = try XCTUnwrap(nodes.first(where: { $0.title == "Child" }))
        let sibling = try XCTUnwrap(nodes.first(where: { $0.title == "Sibling" }))
        let parentBody = MindMapOutline.attachedBody(in: source, nodeID: parent.id, nodes: nodes)
        let childBody = MindMapOutline.attachedBody(in: source, nodeID: child.id, nodes: nodes)
        XCTAssertTrue(parentBody.contains("A note for parent."))
        XCTAssertTrue(parentBody.contains("[[Reference|source]]"))
        XCTAssertFalse(parentBody.contains("Child note line"))
        XCTAssertTrue(childBody.contains("Quoted detail"))
        XCTAssertFalse(childBody.contains("Sibling-only"))
        XCTAssertEqual(
            MindMapOutline.attachedBody(in: source, nodeID: sibling.id, nodes: nodes),
            "Sibling-only details"
        )
    }
}
