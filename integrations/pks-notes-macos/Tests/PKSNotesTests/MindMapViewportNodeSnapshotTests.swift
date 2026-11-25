import AppKit
import SwiftUI
import XCTest

@testable import PKSNotes

@MainActor
final class MindMapViewportNodeSnapshotTests: XCTestCase {
    func testOverviewNodeGlyphRasterizesAtFullMapZoom() throws {
        let root = MindMapPlacement(
            node: MindMapNode(id: 0, depth: 0, title: "Root"),
            parentID: nil,
            center: CGPoint(x: 5_000, y: 5_000),
            size: CGSize(width: 210, height: 60)
        )
        let viewport = CGSize(width: 800, height: 600)
        let mapSize = CGSize(width: 10_000, height: 10_000)
        let zoom: CGFloat = 0.0095
        let offset = MindMapViewportGeometry.centeredOffset(
            for: root.center, mapSize: mapSize, zoom: zoom
        )
        let snapshot = MindMapViewportNodeSnapshot(
            size: viewport,
            placements: [root],
            branchByID: [root.id: 0],
            style: .classic,
            colorScheme: .light,
            mapSize: mapSize,
            viewportOffset: offset,
            zoom: zoom,
            selectedID: nil,
            totalNodeCount: 1,
            accessibilityLabel: "Mind Map overview",
            accessibilityValue: "1 node",
            accessibilityHint: "Tap a node to zoom in.",
            onActivate: {},
            layoutVersion: 1
        )
        let renderer = ImageRenderer(
            content: snapshot.background(Color.white).environment(\.colorScheme, .light)
        )
        renderer.scale = 1
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: viewport.width, height: viewport.height)
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let center = MindMapViewportConnectorSnapshot.mapToScreen(
            root.center,
            mapSize: mapSize,
            viewportSize: viewport,
            offset: offset,
            zoom: zoom
        )
        let pixel = try XCTUnwrap(
            bitmap.colorAt(x: Int(center.x.rounded()), y: Int(center.y.rounded()))?
                .usingColorSpace(.deviceRGB)
        )

        XCTAssertLessThan(
            pixel.redComponent, 0.98,
            "A node glyph must remain visible when the complete map is fitted to the viewport."
        )
    }

    func testOverviewNodeSnapshotKeepsItsBackingSurfaceViewportSized() {
        let viewport = CGSize(width: 800, height: 600)
        let mapSize = CGSize(width: 2_686, height: 1_000_000)
        let snapshot = MindMapViewportNodeSnapshot(
            size: viewport,
            placements: [],
            branchByID: [:],
            style: .classic,
            colorScheme: .light,
            mapSize: mapSize,
            viewportOffset: .zero,
            zoom: 0.001,
            selectedID: nil,
            totalNodeCount: 3_073,
            accessibilityLabel: "Mind Map overview",
            accessibilityValue: "3073 nodes",
            accessibilityHint: "Tap a node to zoom in.",
            onActivate: {},
            layoutVersion: 1
        )

        XCTAssertGreaterThan(mapSize.height, viewport.height * 1_000)
        XCTAssertEqual(snapshot.size, viewport)
        XCTAssertEqual(snapshot.size.width * snapshot.size.height, 480_000)
    }
}
