import CoreGraphics
import XCTest
@testable import PKSNotes

final class MindMapViewportTests: XCTestCase {
    func testVisibleNodeCullingUsesViewportTransformAndScreenSpaceOverscan() {
        func placement(_ id: Int, x: CGFloat, y: CGFloat) -> MindMapPlacement {
            MindMapPlacement(
                node: MindMapNode(id: id, depth: 0, title: "Node \(id)"),
                parentID: nil,
                center: CGPoint(x: x, y: y),
                size: CGSize(width: 100, height: 60)
            )
        }

        let placements = [
            placement(1, x: 500, y: 500),
            placement(2, x: 180, y: 500),
            placement(3, x: 820, y: 500),
            placement(4, x: 900, y: 500),
            placement(5, x: 500, y: 100),
            placement(6, x: 500, y: 730)
        ]
        let visible = MindMapViewportGeometry.visibleNodeIDs(
            in: placements,
            mapSize: CGSize(width: 1_000, height: 1_000),
            viewport: CGSize(width: 400, height: 300),
            offset: .zero,
            zoom: 1,
            overscan: 100
        )

        XCTAssertEqual(visible, Set([1, 2, 3, 6]))
    }

    func testVisibleNodeCullingTracksPanAndZoomAndPinsActiveNodes() {
        let placements = [
            MindMapPlacement(
                node: MindMapNode(id: 1, depth: 0, title: "Near"),
                parentID: nil,
                center: CGPoint(x: 400, y: 500),
                size: CGSize(width: 100, height: 60)
            ),
            MindMapPlacement(
                node: MindMapNode(id: 2, depth: 0, title: "Far"),
                parentID: nil,
                center: CGPoint(x: 900, y: 900),
                size: CGSize(width: 100, height: 60)
            )
        ]
        let visible = MindMapViewportGeometry.visibleNodeIDs(
            in: placements,
            mapSize: CGSize(width: 1_000, height: 1_000),
            viewport: CGSize(width: 400, height: 300),
            offset: CGSize(width: 200, height: 0),
            zoom: 2,
            overscan: 0,
            pinnedIDs: [2]
        )

        XCTAssertEqual(visible, Set([1, 2]))
    }

    func testInvalidViewportKeepsAllNodeCardsMounted() {
        let placements = [
            MindMapPlacement(
                node: MindMapNode(id: 1, depth: 0, title: "One"),
                parentID: nil,
                center: CGPoint(x: 100, y: 100),
                size: CGSize(width: 100, height: 60)
            ),
            MindMapPlacement(
                node: MindMapNode(id: 2, depth: 0, title: "Two"),
                parentID: nil,
                center: CGPoint(x: 900, y: 900),
                size: CGSize(width: 100, height: 60)
            )
        ]

        XCTAssertEqual(
            MindMapViewportGeometry.visibleNodeIDs(
                in: placements,
                mapSize: CGSize(width: 1_000, height: 1_000),
                viewport: .zero,
                offset: .zero,
                zoom: 1
            ),
            Set([1, 2])
        )
        XCTAssertEqual(
            MindMapViewportGeometry.visibleNodeIDs(
                in: placements,
                mapSize: CGSize(width: 1_000, height: 1_000),
                viewport: CGSize(width: 400, height: 300),
                offset: .zero,
                zoom: 0
            ),
            Set([1, 2])
        )
    }

    func testLargeMapCullingKeepsVisibleCardCountBoundedAndPreservesSelection() {
        let placements = (0..<600).map { index in
            MindMapPlacement(
                node: MindMapNode(id: index, depth: 0, title: "Node \(index)"),
                parentID: nil,
                center: CGPoint(x: 500, y: 30 + CGFloat(index) * 100),
                size: CGSize(width: 210, height: 60)
            )
        }
        let visible = MindMapViewportGeometry.visibleNodeIDs(
            in: placements,
            mapSize: CGSize(width: 1_000, height: 60_000),
            viewport: CGSize(width: 400, height: 300),
            offset: .zero,
            zoom: 1,
            overscan: 320,
            pinnedIDs: [599]
        )

        XCTAssertLessThan(visible.count, 20)
        XCTAssertTrue(visible.contains(599))
        XCTAssertTrue(visible.contains(300))
    }

    func testConnectorCullingKeepsCrossingCurvesAndStrokeCaps() {
        let viewport = CGRect(x: 400, y: 200, width: 200, height: 200)

        XCTAssertTrue(MindMapViewportGeometry.connectorIntersectsViewport(
            start: CGPoint(x: 100, y: 300),
            end: CGPoint(x: 900, y: 300),
            control1: CGPoint(x: 250, y: 300),
            control2: CGPoint(x: 750, y: 300),
            viewport: viewport,
            lineWidth: 2
        ))
        XCTAssertFalse(MindMapViewportGeometry.connectorIntersectsViewport(
            start: CGPoint(x: 100, y: 700),
            end: CGPoint(x: 900, y: 700),
            control1: CGPoint(x: 250, y: 700),
            control2: CGPoint(x: 750, y: 700),
            viewport: viewport,
            lineWidth: 2
        ))
        XCTAssertTrue(MindMapViewportGeometry.connectorIntersectsViewport(
            start: CGPoint(x: 410, y: 189),
            end: CGPoint(x: 600, y: 189),
            control1: CGPoint(x: 450, y: 189),
            control2: CGPoint(x: 550, y: 189),
            viewport: viewport,
            lineWidth: 24
        ))
    }

    func testConnectorSpatialIndexQueriesVisibleCellsAndDeduplicatesLongEdges() throws {
        func placement(_ id: Int, parentID: Int?, x: CGFloat, y: CGFloat) -> MindMapPlacement {
            MindMapPlacement(
                node: MindMapNode(id: id, depth: parentID == nil ? 0 : 1, title: "Node \(id)"),
                parentID: parentID,
                center: CGPoint(x: x, y: y),
                size: CGSize(width: 100, height: 60)
            )
        }

        let layout = MindMapLayoutSnapshot(
            placements: [
                placement(1, parentID: nil, x: 100, y: 100),
                placement(2, parentID: 1, x: 1_500, y: 100),
                placement(3, parentID: nil, x: 4_000, y: 100),
                placement(4, parentID: 3, x: 4_500, y: 100)
            ],
            size: CGSize(width: 5_000, height: 1_000)
        )

        let visible = layout.visibleConnectors(
            in: CGRect(x: 300, y: 0, width: 1_000, height: 300)
        )
        let connector = try XCTUnwrap(visible.first)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(connector.end.x, 1_450, accuracy: 0.001)
        XCTAssertEqual(layout.visibleConnectors(in: nil).count, 2)
        XCTAssertEqual(
            layout.visibleConnectors(in: CGRect(x: 0, y: 0, width: 5_000, height: 1_000)).count,
            2
        )
    }

    func testConnectorSpatialIndexBoundsExpansionForVeryLongEdges() throws {
        func placement(_ id: Int, parentID: Int?, x: CGFloat) -> MindMapPlacement {
            MindMapPlacement(
                node: MindMapNode(id: id, depth: parentID == nil ? 0 : 1, title: "Node \(id)"),
                parentID: parentID,
                center: CGPoint(x: x, y: 100),
                size: CGSize(width: 100, height: 60)
            )
        }

        let layout = MindMapLayoutSnapshot(
            placements: [
                placement(1, parentID: nil, x: 100),
                placement(2, parentID: 1, x: 1_000_000_000_000)
            ],
            size: CGSize(width: 1_000_000_001_000, height: 1_000)
        )

        XCTAssertEqual(
            layout.visibleConnectors(
                in: CGRect(x: 999_999_999_000, y: 0, width: 500, height: 300)
            ).count,
            1
        )
        XCTAssertEqual(
            layout.visibleConnectors(
                in: CGRect(x: 1e100, y: 0, width: 500, height: 300)
            ).count,
            0
        )
    }

    func testConnectorSpatialIndexKeepsInvalidGeometryVisible() {
        func placement(_ id: Int, parentID: Int?, x: CGFloat) -> MindMapPlacement {
            MindMapPlacement(
                node: MindMapNode(id: id, depth: parentID == nil ? 0 : 1, title: "Node \(id)"),
                parentID: parentID,
                center: CGPoint(x: x, y: 100),
                size: CGSize(width: 100, height: 60)
            )
        }

        let layout = MindMapLayoutSnapshot(
            placements: [
                placement(1, parentID: nil, x: .nan),
                placement(2, parentID: 1, x: 5_000),
                placement(3, parentID: nil, x: 5_000),
                placement(4, parentID: 3, x: 7_000)
            ],
            size: CGSize(width: 8_000, height: 1_000)
        )

        XCTAssertEqual(
            layout.visibleConnectors(in: CGRect(x: 0, y: 0, width: 200, height: 200)).count,
            1
        )
    }

    func testInvalidConnectorGeometryFailsOpenToPreserveDrawing() {
        XCTAssertTrue(MindMapViewportGeometry.connectorIntersectsViewport(
            start: CGPoint(x: CGFloat.nan, y: 10),
            end: CGPoint(x: 100, y: 10),
            control1: CGPoint(x: 20, y: 10),
            control2: CGPoint(x: 80, y: 10),
            viewport: CGRect(x: 0, y: 0, width: 200, height: 200),
            lineWidth: 2
        ))
        XCTAssertTrue(MindMapViewportGeometry.connectorIntersectsViewport(
            start: .zero,
            end: CGPoint(x: 100, y: 10),
            control1: CGPoint(x: 20, y: 10),
            control2: CGPoint(x: 80, y: 10),
            viewport: .zero,
            lineWidth: 2
        ))
    }

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

    func testInspectorBodyTracksMarkdownRevisionWithoutSeparateAuthority() throws {
        let base = "# Root\nSummary\n- Child\n  Original detail\n"
        let changed = "# Root\nUpdated summary\n- Child\n  Updated detail\n"
        let originalNodes = MindMapOutline.nodes(in: base)
        let original = MindMapOutline.presentations(in: base, nodes: originalNodes)
        let changedNodes = MindMapOutline.nodes(in: changed)
        let updated = MindMapOutline.presentations(in: changed, nodes: changedNodes)
        XCTAssertEqual(original[0]?.body, "Summary")
        XCTAssertEqual(updated[0]?.body, "Updated summary")
        XCTAssertEqual(original[2]?.body, "Original detail")
        XCTAssertEqual(updated[2]?.body, "Updated detail")
        XCTAssertEqual(original[0]?.links, updated[0]?.links)
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

    func testLayoutSnapshotPrecomputesStyleAwareConnectorGeometryAndStrokeBounds() throws {
        let nodes = [
            MindMapNode(id: 20, depth: 0, title: "Root"),
            MindMapNode(id: 8, depth: 1, title: "First child"),
            MindMapNode(id: 11, depth: 1, title: "Second child")
        ]
        let layout = MindMapSpatialLayout.layout(nodes, style: .minimal)
        let connector = try XCTUnwrap(layout.connectors.first)

        XCTAssertEqual(layout.connectors.count, 2)
        XCTAssertEqual(connector.branch, 1)
        XCTAssertTrue(connector.angular)
        XCTAssertEqual(connector.lineWidth, MindMapVisualStyle.minimal.connectorWidth)
        XCTAssertEqual(connector.control1.x, (connector.start.x + connector.end.x) / 2, accuracy: 0.001)
        XCTAssertEqual(connector.control1.y, connector.start.y, accuracy: 0.001)
        XCTAssertEqual(connector.control2.x, connector.control1.x, accuracy: 0.001)
        XCTAssertEqual(connector.control2.y, connector.end.y, accuracy: 0.001)
        XCTAssertTrue(connector.bounds.contains(connector.start))
        XCTAssertTrue(connector.bounds.contains(connector.end))
    }

    func testVisiblePlacementsPreserveSourceOrderAndReuseLayoutRelationships() {
        let layout = MindMapSpatialLayout.layout([
            MindMapNode(id: 20, depth: 0, title: "Root"),
            MindMapNode(id: 8, depth: 1, title: "First child"),
            MindMapNode(id: 11, depth: 2, title: "Nested child"),
            MindMapNode(id: 3, depth: 1, title: "Second child")
        ])

        XCTAssertEqual(layout.parentIDs, Set([20, 8]))
        XCTAssertEqual(layout.visiblePlacements(for: Set([3, 999, 11])).map(\.id), [11, 3])
        XCTAssertEqual(layout.visiblePlacements(for: Set<Int>()).map(\.id), [])
        XCTAssertEqual(layout.visiblePlacements(for: nil).map(\.id), [20, 8, 11, 3])
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
        let projected = MindMapOutline.presentations(in: source, nodes: nodes)
        let parentBody = try XCTUnwrap(projected[parent.id]?.body)
        let childBody = try XCTUnwrap(projected[child.id]?.body)
        XCTAssertTrue(parentBody.contains("A note for parent."))
        XCTAssertTrue(parentBody.contains("[[Reference|source]]"))
        XCTAssertFalse(parentBody.contains("Child note line"))
        XCTAssertTrue(childBody.contains("Quoted detail"))
        XCTAssertFalse(childBody.contains("Sibling-only"))
        XCTAssertEqual(
            projected[sibling.id]?.body,
            "Sibling-only details"
        )
    }
}
