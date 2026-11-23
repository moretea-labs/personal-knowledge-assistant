import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import PKSNotes

@MainActor
final class MindMapViewportConnectorSnapshotTests: XCTestCase {
    func testMapPointsUseTheSameCenteredZoomAndOffsetTransformAsNodeCards() {
        let mapSize = CGSize(width: 2_686, height: 41_822)
        let viewport = CGSize(width: 800, height: 600)
        let offset = CGSize(width: 18, height: -24)
        let zoom: CGFloat = 0.42
        let point = CGPoint(
            x: mapSize.width / 2 + 100,
            y: mapSize.height / 2 - 50
        )

        let screen = MindMapViewportConnectorSnapshot.mapToScreen(
            point,
            mapSize: mapSize,
            viewportSize: viewport,
            offset: offset,
            zoom: zoom
        )

        XCTAssertEqual(screen.x, viewport.width / 2 + offset.width + 42, accuracy: 0.001)
        XCTAssertEqual(screen.y, viewport.height / 2 + offset.height - 21, accuracy: 0.001)
    }

    func testCanvasSurfaceRemainsViewportSizedForAFullHeightRedisMap() {
        let mapSize = CGSize(width: 2_686, height: 41_822)
        let viewport = CGSize(width: 800, height: 600)
        let snapshot = MindMapViewportConnectorSnapshot(
            size: viewport,
            connectors: [],
            style: .classic,
            mapSize: mapSize,
            viewportOffset: .zero,
            zoom: 0.42,
            layoutVersion: 1
        )

        XCTAssertGreaterThan(mapSize.height, viewport.height * 50)
        XCTAssertEqual(snapshot.size, viewport)
        XCTAssertEqual(snapshot.size.width * snapshot.size.height, 480_000)
    }

    func testCanvasPDFUsesViewportBoundsForVeryTallMap() throws {
        let viewport = CGSize(width: 800, height: 600)
        let mapSize = CGSize(width: 2_686, height: 41_822)
        let parent = MindMapPlacement(
            node: MindMapNode(id: 0, depth: 0, title: "Root"),
            parentID: nil,
            center: CGPoint(x: 1_000, y: 20_900),
            size: CGSize(width: 230, height: 60)
        )
        let child = MindMapPlacement(
            node: MindMapNode(id: 1, depth: 1, title: "Child"),
            parentID: 0,
            center: CGPoint(x: 1_310, y: 21_000),
            size: CGSize(width: 244, height: 56)
        )
        let connector = MindMapConnector(
            parent: parent, child: child, style: .classic, branch: 0
        )
        let snapshot = MindMapViewportConnectorSnapshot(
            size: viewport,
            connectors: [connector],
            style: .classic,
            mapSize: mapSize,
            viewportOffset: .zero,
            zoom: 0.42,
            layoutVersion: 1
        )
        let host = NSHostingView(rootView: snapshot)
        host.frame = NSRect(origin: .zero, size: viewport)
        host.layoutSubtreeIfNeeded()

        let pdf = host.dataWithPDF(inside: host.bounds)
        let page = try XCTUnwrap(PDFDocument(data: pdf)?.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)

        XCTAssertEqual(bounds.width, viewport.width, accuracy: 1)
        XCTAssertEqual(bounds.height, viewport.height, accuracy: 1)
        XCTAssertLessThan(bounds.height, mapSize.height / 50)
    }

    func testConnectorStrokeStaysVisibleAtOverviewZoomWithoutGrowingUnbounded() {
        let parent = MindMapPlacement(
            node: MindMapNode(id: 0, depth: 0, title: "Root"),
            parentID: nil,
            center: CGPoint(x: 150, y: 200),
            size: CGSize(width: 230, height: 60)
        )
        let child = MindMapPlacement(
            node: MindMapNode(id: 1, depth: 1, title: "Child"),
            parentID: 0,
            center: CGPoint(x: 460, y: 260),
            size: CGSize(width: 244, height: 56)
        )
        let connector = MindMapConnector(
            parent: parent, child: child, style: .classic, branch: 0
        )

        XCTAssertEqual(
            MindMapViewportConnectorSnapshot.screenLineWidth(for: connector, zoom: 0.42),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MindMapViewportConnectorSnapshot.screenLineWidth(for: connector, zoom: 1),
            1.25,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MindMapViewportConnectorSnapshot.screenLineWidth(for: connector, zoom: 2.5),
            2,
            accuracy: 0.001
        )
    }
}
