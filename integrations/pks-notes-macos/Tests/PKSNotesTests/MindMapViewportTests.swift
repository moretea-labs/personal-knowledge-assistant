import CoreGraphics
import XCTest
@testable import PKSNotes

final class MindMapViewportTests: XCTestCase {
    @MainActor
    func testWheelCaptureHitTestingConvertsWindowCoordinatesToScreenCoordinates() {
        let frame = NSRect(x: 460, y: 270, width: 600, height: 400)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = content
        let canvas = NSView(frame: NSRect(x: 80, y: 60, width: 320, height: 220))
        content.addSubview(canvas)

        let insideScreen = canvas.convert(NSPoint(x: 120, y: 100), to: nil)
        let insideWindow = window.convertPoint(fromScreen: insideScreen)
        XCTAssertTrue(MindMapWheelCapture.contains(insideWindow, in: canvas, window: window))

        let outsideScreen = canvas.convert(NSPoint(x: -10, y: 100), to: nil)
        let outsideWindow = window.convertPoint(fromScreen: outsideScreen)
        XCTAssertFalse(MindMapWheelCapture.contains(outsideWindow, in: canvas, window: window))
    }

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
        let layout = MindMapLayoutSnapshot(
            placements: placements, size: CGSize(width: 1_000, height: 1_000)
        )
        let visible = MindMapViewportGeometry.visibleNodeIDs(
            in: layout,
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
        let layout = MindMapLayoutSnapshot(
            placements: placements, size: CGSize(width: 1_000, height: 1_000)
        )
        let visible = MindMapViewportGeometry.visibleNodeIDs(
            in: layout,
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

        let layout = MindMapLayoutSnapshot(
            placements: placements, size: CGSize(width: 1_000, height: 1_000)
        )
        XCTAssertEqual(
            MindMapViewportGeometry.visibleNodeIDs(
                in: layout,
                viewport: .zero,
                offset: .zero,
                zoom: 1
            ),
            Set([1, 2])
        )
        XCTAssertEqual(
            MindMapViewportGeometry.visibleNodeIDs(
                in: layout,
                viewport: CGSize(width: 400, height: 300),
                offset: .zero,
                zoom: 0
            ),
            Set([1, 2])
        )
    }

    func testLargeMapInitialFocusKeepsEveryNodeExpandedAndRootReadable() throws {
        let nodes = (0..<1_000).map { index in
            MindMapNode(id: index, depth: index == 0 ? 0 : 1, title: "Node \(index)")
        }
        let layout = MindMapSpatialLayout.layout(nodes)
        let root = layout.placements[0]
        let viewport = CGSize(width: 1_000, height: 700)
        let initial = MindMapViewportGeometry.initialRootViewport(
            root: root,
            visiblePlacements: [root],
            mapSize: layout.size,
            viewport: viewport
        )
        let fitted = try XCTUnwrap(MindMapViewportGeometry.fittingViewport(
            placements: layout.placements, mapSize: layout.size, viewport: viewport
        ))

        XCTAssertEqual(initial.zoom, 1, accuracy: 0.001)
        XCTAssertGreaterThan(fitted.zoom, 0)
        XCTAssertLessThan(fitted.zoom, 0.05)
        XCTAssertEqual(layout.placements.count, nodes.count)
        XCTAssertEqual(layout.placements.map(\.node), nodes)
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
        let layout = MindMapLayoutSnapshot(
            placements: placements, size: CGSize(width: 1_000, height: 60_000)
        )
        let visible = MindMapViewportGeometry.visibleNodeIDs(
            in: layout,
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

    func testLargeMapNodeIndexMatchesLinearViewportCulling() {
        let placements = (0..<1_000).map { index in
            let column = index % 24
            let row = index / 24
            return MindMapPlacement(
                node: MindMapNode(id: index, depth: 0, title: "Node \(index)"),
                parentID: nil,
                center: CGPoint(
                    x: 120 + CGFloat(column) * 520,
                    y: 100 + CGFloat(row) * 150
                ),
                size: CGSize(width: 210, height: 60)
            )
        }
        let layout = MindMapLayoutSnapshot(
            placements: placements, size: CGSize(width: 13_000, height: 8_000)
        )
        let viewports: [(CGSize, CGSize, CGFloat, CGFloat, Set<Int>)] = [
            (CGSize(width: 640, height: 480), .zero, 1, 120, [999]),
            (CGSize(width: 520, height: 360), CGSize(width: -2_200, height: 800), 1.25, 200, []),
            (CGSize(width: 900, height: 700), CGSize(width: 3_000, height: -1_400), 0.75, 100, [0, 512])
        ]

        for (viewport, offset, zoom, overscan, pinned) in viewports {
            let rect = MindMapViewportGeometry.visibleRect(
                mapSize: layout.size, viewport: viewport, offset: offset,
                zoom: zoom, overscan: overscan
            )
            let expected = Set(placements.compactMap { placement -> Int? in
                guard let rect else { return placement.id }
                let bounds = CGRect(
                    x: placement.center.x - placement.size.width / 2,
                    y: placement.center.y - placement.size.height / 2,
                    width: placement.size.width,
                    height: placement.size.height
                )
                return bounds.intersects(rect) ? placement.id : nil
            }).union(pinned)
            XCTAssertEqual(
                MindMapViewportGeometry.visibleNodeIDs(
                    in: layout, viewport: viewport, offset: offset,
                    zoom: zoom, overscan: overscan, pinnedIDs: pinned
                ),
                expected
            )
        }
    }

    func testNodeSpatialIndexKeepsOversizedAndUnrepresentableBoundsQueryable() {
        let placements = [
            MindMapPlacement(
                node: MindMapNode(id: 1, depth: 0, title: "Oversized"),
                parentID: nil,
                center: CGPoint(x: 500_000, y: 100),
                size: CGSize(width: 1_000_000, height: 60)
            ),
            MindMapPlacement(
                node: MindMapNode(id: 2, depth: 0, title: "Unrepresentable"),
                parentID: nil,
                center: CGPoint(x: 1e20, y: 100),
                size: CGSize(width: 1e10, height: 60)
            )
        ]
        let layout = MindMapLayoutSnapshot(
            placements: placements, size: CGSize(width: 1e20, height: 1_000)
        )

        XCTAssertTrue(
            layout.visiblePlacementIDs(in: CGRect(x: 999_000, y: 0, width: 2_000, height: 200))
                .contains(1)
        )
        XCTAssertTrue(
            layout.visiblePlacementIDs(in: CGRect(x: 1e20, y: 0, width: 1e10, height: 200))
                .contains(2)
        )
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
        let root = MindMapPlacement(
            node: MindMapNode(id: 0, depth: 0, title: "Root"),
            parentID: nil,
            center: CGPoint(x: 150, y: 25000),
            size: CGSize(width: 230, height: 60)
        )
        let child = MindMapPlacement(
            node: MindMapNode(id: 1, depth: 1, title: "Child"),
            parentID: root.id,
            center: CGPoint(x: 474, y: 25000),
            size: CGSize(width: 244, height: 56)
        )
        let initial = MindMapViewportGeometry.initialRootViewport(
            root: root, visiblePlacements: [child], mapSize: map, viewport: viewport
        )
        let screenX = viewport.width / 2 + initial.offset.width
            + (root.center.x - map.width / 2) * initial.zoom
        let screenY = viewport.height / 2 + initial.offset.height
            + (root.center.y - map.height / 2) * initial.zoom
        XCTAssertEqual(initial.zoom, 1, accuracy: 0.001)
        XCTAssertEqual(screenX, 320, accuracy: 0.001)
        XCTAssertEqual(screenY, 340, accuracy: 0.001)
    }

    func testInitialViewportResizeDetectionPreservesOnlyUntouchedOverview() throws {
        let nodes = [
            MindMapNode(id: 0, depth: 0, title: "Root"),
            MindMapNode(id: 1, depth: 1, title: "First branch"),
            MindMapNode(id: 2, depth: 1, title: "Second branch"),
            MindMapNode(id: 3, depth: 1, title: "Third branch")
        ]
        let layout = MindMapSpatialLayout.layout(nodes)
        let root = try XCTUnwrap(layout.placements.first { $0.parentID == nil })
        let firstLevel = layout.placements.filter { $0.parentID == root.id }
        let viewport = CGSize(width: 1000, height: 680)
        XCTAssertTrue(MindMapViewportGeometry.isAtInitialRootViewport(
            root: root, visiblePlacements: firstLevel,
            mapSize: layout.size, viewport: .zero,
            zoom: 1, offset: .zero
        ), "An unlaid-out canvas with its untouched transform must still receive its opening overview.")
        XCTAssertFalse(MindMapViewportGeometry.isAtInitialRootViewport(
            root: root, visiblePlacements: firstLevel,
            mapSize: layout.size, viewport: .zero,
            zoom: 0.9, offset: .zero
        ), "A user zoom made before a zero-size transition must be preserved.")
        XCTAssertFalse(MindMapViewportGeometry.isAtInitialRootViewport(
            root: root, visiblePlacements: firstLevel,
            mapSize: layout.size, viewport: .zero,
            zoom: 1, offset: CGSize(width: 2, height: 0)
        ), "A user pan made before a zero-size transition must be preserved.")
        let initial = MindMapViewportGeometry.initialRootViewport(
            root: root, visiblePlacements: firstLevel,
            mapSize: layout.size, viewport: viewport
        )

        XCTAssertTrue(MindMapViewportGeometry.isAtInitialRootViewport(
            root: root, visiblePlacements: firstLevel,
            mapSize: layout.size, viewport: viewport,
            zoom: initial.zoom, offset: initial.offset
        ))
        XCTAssertFalse(MindMapViewportGeometry.isAtInitialRootViewport(
            root: root, visiblePlacements: firstLevel,
            mapSize: layout.size, viewport: viewport,
            zoom: initial.zoom, offset: CGSize(
                width: initial.offset.width + 24, height: initial.offset.height
            )
        ))
        XCTAssertFalse(MindMapViewportGeometry.isAtInitialRootViewport(
            root: root, visiblePlacements: firstLevel,
            mapSize: layout.size, viewport: viewport,
            zoom: initial.zoom * 0.9, offset: initial.offset
        ))
    }

    func testCompactViewportsKeepRootAndFirstLevelBranchesVisible() throws {
        let nodes = [
            MindMapNode(id: 0, depth: 0, title: "Root"),
            MindMapNode(id: 1, depth: 1, title: "First branch"),
            MindMapNode(id: 2, depth: 1, title: "Second branch"),
            MindMapNode(id: 3, depth: 1, title: "Third branch")
        ]

        for density in [MindMapLayoutDensity.standard, .compact] {
            let layout = MindMapSpatialLayout.layout(nodes, density: density)
            let root = try XCTUnwrap(layout.placements.first { $0.parentID == nil })
            let firstLevel = layout.placements.filter { $0.parentID == root.id }

            for width: CGFloat in [450, 500, 600] {
                let viewport = CGSize(width: width, height: 680)
                let initial = MindMapViewportGeometry.initialRootViewport(
                    root: root, visiblePlacements: firstLevel,
                    mapSize: layout.size, viewport: viewport
                )
                let visible = MindMapViewportGeometry.visibleNodeIDs(
                    in: layout, viewport: viewport, offset: initial.offset,
                    zoom: initial.zoom, overscan: 0
                )
                XCTAssertEqual(visible, Set(nodes.map(\.id)),
                               "density=\(density), width=\(width)")
                XCTAssertLessThanOrEqual(initial.zoom, 1)
                XCTAssertGreaterThanOrEqual(initial.zoom, 0.68)
            }
        }
    }

    func testInitialRootViewportFitsManyFirstLevelBranchesVertically() {
        let root = MindMapPlacement(
            node: MindMapNode(id: 0, depth: 0, title: "Root"),
            parentID: nil,
            center: CGPoint(x: 150, y: 1100),
            size: CGSize(width: 230, height: 60)
        )
        let children = (1...7).map { id in
            MindMapPlacement(
                node: MindMapNode(id: id, depth: 1, title: "Branch \(id)"),
                parentID: root.id,
                center: CGPoint(x: 474, y: CGFloat(800 + (id - 1) * 100)),
                size: CGSize(width: 244, height: 56)
            )
        }
        let layout = MindMapLayoutSnapshot(
            placements: [root] + children,
            size: CGSize(width: 800, height: 2400)
        )
        let viewport = CGSize(width: 450, height: 500)
        let initial = MindMapViewportGeometry.initialRootViewport(
            root: root, visiblePlacements: children,
            mapSize: layout.size, viewport: viewport
        )

        XCTAssertLessThan(initial.zoom, 0.738)
        XCTAssertGreaterThanOrEqual(initial.zoom, 0.68)
        XCTAssertEqual(
            MindMapViewportGeometry.visibleNodeIDs(
                in: layout, viewport: viewport,
                offset: initial.offset, zoom: initial.zoom, overscan: 0
            ),
            Set(0...7)
        )
    }

    func testInitialOverviewFitsVisibleCardsWhenPreferredZoomFloorWouldClip() throws {
        let nodes = [
            MindMapNode(id: 0, depth: 0, title: "Root"),
            MindMapNode(id: 1, depth: 1, title: "Long branch"),
            MindMapNode(id: 82, depth: 1, title: "Short branch"),
            MindMapNode(id: 83, depth: 2, title: "One visible child")
        ]
        let layout = MindMapSpatialLayout.layout(nodes)
        let root = try XCTUnwrap(layout.placements.first { $0.parentID == nil })
        let viewport = CGSize(width: 600, height: 645)
        let initial = MindMapViewportGeometry.initialRootViewport(
            root: root, visiblePlacements: layout.placements,
            mapSize: layout.size, viewport: viewport
        )
        let inset = MindMapViewportGeometry.initialInset(for: viewport.width)
        let verticalInset = MindMapViewportGeometry.initialInset(for: viewport.height)
        XCTAssertLessThan(initial.zoom, MindMapViewportGeometry.minimumInitialZoom)
        let cardBounds = layout.placements.map { placement in
            let center = CGPoint(
                x: viewport.width / 2 + initial.offset.width
                    + (placement.center.x - layout.size.width / 2) * initial.zoom,
                y: viewport.height / 2 + initial.offset.height
                    + (placement.center.y - layout.size.height / 2) * initial.zoom
            )
            return CGRect(
                x: center.x - placement.size.width * initial.zoom / 2,
                y: center.y - placement.size.height * initial.zoom / 2,
                width: placement.size.width * initial.zoom,
                height: placement.size.height * initial.zoom
            )
        }
        XCTAssertTrue(cardBounds.allSatisfy {
            $0.minX >= inset - 0.5 && $0.maxX <= viewport.width - inset + 0.5
                && $0.minY >= verticalInset - 0.5
                && $0.maxY <= viewport.height - verticalInset + 0.5
        })
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

    func testFitCanShowMapsFarLargerThanTheViewport() throws {
        let placement = MindMapPlacement(
            node: MindMapNode(id: 0, depth: 0, title: "Large map"),
            parentID: nil,
            center: CGPoint(x: 10_000, y: 75_000),
            size: CGSize(width: 20_000, height: 150_000)
        )
        let fitted = try XCTUnwrap(MindMapViewportGeometry.fittingViewport(
            placements: [placement],
            mapSize: CGSize(width: 20_000, height: 150_000),
            viewport: CGSize(width: 800, height: 650)
        ))
        XCTAssertGreaterThan(fitted.zoom, 0)
        XCTAssertLessThanOrEqual(150_000 * fitted.zoom, 650 - 36 + 0.01)
        XCTAssertLessThanOrEqual(20_000 * fitted.zoom, 800 - 36 + 0.01)
    }

    func testFitUsesVisibleNodeBoundsInsteadOfPaddedCanvasBounds() throws {
        let placements = [
            MindMapPlacement(
                node: MindMapNode(id: 0, depth: 0, title: "Root"),
                parentID: nil,
                center: CGPoint(x: 140, y: 160),
                size: CGSize(width: 220, height: 64)
            ),
            MindMapPlacement(
                node: MindMapNode(id: 1, depth: 1, title: "Branch"),
                parentID: 0,
                center: CGPoint(x: 430, y: 160),
                size: CGSize(width: 240, height: 60)
            )
        ]
        let mapSize = CGSize(width: 1_000, height: 1_000)
        let viewport = CGSize(width: 800, height: 600)
        let fitted = try XCTUnwrap(MindMapViewportGeometry.fittingViewport(
            placements: placements,
            mapSize: mapSize,
            viewport: viewport
        ))
        let contentBounds = CGRect(x: 30, y: 128, width: 520, height: 64)
        let screenMinX = viewport.width / 2 + fitted.offset.width
            + (contentBounds.minX - mapSize.width / 2) * fitted.zoom
        let screenMinY = viewport.height / 2 + fitted.offset.height
            + (contentBounds.minY - mapSize.height / 2) * fitted.zoom

        XCTAssertEqual(fitted.zoom, 1.25, accuracy: 0.001)
        XCTAssertEqual(screenMinX, (viewport.width - contentBounds.width * fitted.zoom) / 2, accuracy: 0.001)
        XCTAssertEqual(screenMinY, (viewport.height - contentBounds.height * fitted.zoom) / 2, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(screenMinX, 18)
        XCTAssertGreaterThanOrEqual(screenMinY, 18)
        XCTAssertLessThanOrEqual(screenMinX + contentBounds.width * fitted.zoom, viewport.width - 18)
        XCTAssertLessThanOrEqual(screenMinY + contentBounds.height * fitted.zoom, viewport.height - 18)
    }

    func testDenseSiblingFanOutDrawsOneSharedSpineInsteadOfOverlappingCurves() throws {
        let nodes = [
            MindMapNode(id: 0, depth: 0, title: "Root"),
            MindMapNode(id: 1, depth: 1, title: "Long branch")
        ] + (2..<82).map {
            MindMapNode(id: $0, depth: 2, title: "Detail \($0)")
        }
        let layout = MindMapSpatialLayout.layout(nodes, style: .classic)
        XCTAssertEqual(layout.placements.count, nodes.count)
        XCTAssertEqual(layout.connectors.count, 83) // 81 logical edges + 2 shared segments

        let parent = try XCTUnwrap(layout.placementsByID[1])
        let parentExit = CGPoint(
            x: parent.center.x + parent.size.width / 2,
            y: parent.center.y
        )
        let outgoing = layout.connectors.filter {
            abs($0.start.x - parentExit.x) < 0.001
                && abs($0.start.y - parentExit.y) < 0.001
        }
        XCTAssertEqual(outgoing.count, 1, "Dense children must not repaint the parent port 80 times.")
        let spineX = try XCTUnwrap(outgoing.first?.end.x)
        let vertical = layout.connectors.filter {
            $0.angular && abs($0.start.x - spineX) < 0.001
                && abs($0.end.x - spineX) < 0.001
                && abs($0.end.y - $0.start.y) > 1
        }
        XCTAssertEqual(vertical.count, 1, "Only one shared vertical stroke should be rendered.")
        let spurs = layout.connectors.filter {
            $0.angular && abs($0.start.x - spineX) < 0.001
                && abs($0.start.y - $0.end.y) < 0.001
                && $0.end.x > spineX
        }
        XCTAssertEqual(spurs.count, 80)
        XCTAssertEqual(Set(spurs.map { $0.end.y }).count, 80)
        let middle = try XCTUnwrap(layout.placementsByID[42])
        let viewport = CGRect(
            x: spineX - 3, y: middle.center.y - 10, width: 12, height: 20
        )
        let spine = try XCTUnwrap(vertical.first)
        XCTAssertTrue(layout.visibleConnectors(in: viewport).contains(spine),
                      "Viewport culling must retain the shared spine when panning along it.")
    }

    func testMultipleDenseBranchesKeepStableMarkdownConnectorPaintOrder() throws {
        let nodes = [
            MindMapNode(id: 0, depth: 0, title: "Root"),
            MindMapNode(id: 1, depth: 1, title: "First")
        ] + (2..<14).map {
            MindMapNode(id: $0, depth: 2, title: "First child \($0)")
        } + [
            MindMapNode(id: 14, depth: 1, title: "Second")
        ] + (15..<27).map {
            MindMapNode(id: $0, depth: 2, title: "Second child \($0)")
        }
        let layout = MindMapSpatialLayout.layout(nodes, style: .classic)
        let first = try XCTUnwrap(layout.placementsByID[1])
        let second = try XCTUnwrap(layout.placementsByID[14])
        let firstExit = CGPoint(x: first.center.x + first.size.width / 2, y: first.center.y)
        let secondExit = CGPoint(x: second.center.x + second.size.width / 2, y: second.center.y)

        XCTAssertEqual(layout.connectors.count, 30) // 26 logical edges + 4 shared segments
        XCTAssertEqual(layout.connectors[0].start, firstExit)
        XCTAssertEqual(layout.connectors[1].start.x, layout.connectors[0].end.x)
        XCTAssertEqual(layout.connectors[2].start, secondExit)
        XCTAssertEqual(layout.connectors[3].start.x, layout.connectors[2].end.x)
        XCTAssertEqual(
            MindMapSpatialLayout.layout(nodes, style: .classic).connectors,
            layout.connectors,
            "The same Markdown must produce identical connector geometry and draw order."
        )
    }

    func testOrdinaryBranchesKeepOriginalCurvesAndColorfulRootsStayDistinct() {
        let small = [
            MindMapNode(id: 0, depth: 0, title: "Root"),
            MindMapNode(id: 1, depth: 1, title: "First"),
            MindMapNode(id: 2, depth: 1, title: "Second")
        ]
        XCTAssertTrue(MindMapSpatialLayout.layout(small, style: .classic).connectors.allSatisfy {
            !$0.angular
        })
        let manyRootChildren = [MindMapNode(id: 0, depth: 0, title: "Root")]
            + (1...20).map { MindMapNode(id: $0, depth: 1, title: "Branch \($0)") }
        let colorful = MindMapSpatialLayout.layout(manyRootChildren, style: .colorful)
        XCTAssertEqual(colorful.connectors.count, 20)
        XCTAssertTrue(colorful.connectors.allSatisfy { !$0.angular })
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


extension MindMapViewportTests {
    func testNineLevelKeyboardNavigationKeepsOffscreenSelectionMountedAndCenterable() throws {
        let markdown = (0..<9).map { depth in
            String(repeating: " ", count: depth * 2) + "- Level \(depth + 1)"
        }.joined(separator: "\n")
        let nodes = MindMapOutline.nodes(in: markdown)
        XCTAssertEqual(nodes.map(\.depth), Array(0..<9))
        var selectedID = try XCTUnwrap(nodes.first).id
        for child in nodes.dropFirst() {
            XCTAssertEqual(
                MindMapKeyboard.selection(from: selectedID, in: nodes, moving: .childOrExpand),
                child.id
            )
            selectedID = child.id
        }
        XCTAssertEqual(
            MindMapKeyboard.selection(from: selectedID, in: nodes, moving: .parentOrCollapse),
            nodes[nodes.count - 2].id
        )

        let layout = MindMapSpatialLayout.layout(nodes)
        let viewport = CGSize(width: 600, height: 420)
        let deepest = try XCTUnwrap(layout.placements.first { $0.id == selectedID })
        let offscreen = MindMapViewportGeometry.visibleNodeIDs(
            in: layout, viewport: viewport, offset: .zero, zoom: 1, overscan: 0
        )
        XCTAssertFalse(offscreen.contains(selectedID))
        XCTAssertTrue(MindMapViewportGeometry.visibleNodeIDs(
            in: layout, viewport: viewport, offset: .zero, zoom: 1,
            overscan: 0, pinnedIDs: [selectedID]
        ).contains(selectedID))
        let offset = MindMapViewportGeometry.centeredOffset(
            for: deepest.center, mapSize: layout.size, zoom: 1
        )
        XCTAssertEqual(viewport.width / 2 + offset.width + deepest.center.x - layout.size.width / 2,
                       viewport.width / 2, accuracy: 0.001)
        XCTAssertEqual(viewport.height / 2 + offset.height + deepest.center.y - layout.size.height / 2,
                       viewport.height / 2, accuracy: 0.001)
    }
}
