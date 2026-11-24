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

  func testVisibleConnectorIsRasterizedAtItsTransformedScreenPosition() throws {
    let parent = MindMapPlacement(
      node: MindMapNode(id: 0, depth: 0, title: "Root"),
      parentID: nil, center: CGPoint(x: 300, y: 500),
      size: CGSize(width: 100, height: 60)
    )
    let child = MindMapPlacement(
      node: MindMapNode(id: 1, depth: 1, title: "Child"),
      parentID: 0, center: CGPoint(x: 700, y: 500),
      size: CGSize(width: 100, height: 60)
    )
    let mapSize = CGSize(width: 1_000, height: 1_000)
    let viewport = CGSize(width: 800, height: 600)
    let layout = MindMapLayoutSnapshot(
      placements: [parent, child], size: mapSize, style: .classic
    )
    let rect = try XCTUnwrap(
      MindMapViewportGeometry.visibleRect(
        mapSize: mapSize, viewport: viewport, offset: .zero, zoom: 1, overscan: 0
      ))
    let connectors = layout.visibleConnectors(in: rect)
    XCTAssertEqual(connectors.count, 1)
    let runs = MindMapViewportConnectorSnapshot.strokeRuns(
      connectors: connectors, style: .classic, mapSize: mapSize,
      viewportSize: viewport, offset: .zero, zoom: 1
    )
    XCTAssertEqual(runs.count, 1)
    XCTAssertFalse(runs[0].path.isEmpty)

    let snapshot = MindMapViewportConnectorSnapshot(
      size: viewport, connectors: connectors, style: .classic,
      mapSize: mapSize, viewportOffset: .zero, zoom: 1, layoutVersion: 1
    )
    let renderer = ImageRenderer(
      content: snapshot.background(Color.white).environment(\.colorScheme, .light)
    )
    renderer.scale = 1
    renderer.isOpaque = true
    renderer.proposedSize = ProposedViewSize(width: viewport.width, height: viewport.height)
    let cgImage = try XCTUnwrap(renderer.cgImage)
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    let pixel = try XCTUnwrap(bitmap.colorAt(x: 400, y: 300)?.usingColorSpace(.deviceRGB))
    XCTAssertLessThan(
      pixel.redComponent, 0.98,
      "The viewport Canvas must rasterize the connector at the expected screen point.")
  }

  func testClassicConnectorsAreBatchedIntoOneOrderedStrokeRun() {
    let nodes =
      [MindMapNode(id: 0, depth: 0, title: "Root")]
      + (1...40).map { MindMapNode(id: $0, depth: 1, title: "Branch \($0)") }
    let layout = MindMapSpatialLayout.layout(nodes, style: .classic)
    let runs = MindMapViewportConnectorSnapshot.strokeRuns(
      connectors: layout.connectors, style: .classic, mapSize: layout.size,
      viewportSize: CGSize(width: 1_024, height: 768), offset: .zero, zoom: 1
    )
    XCTAssertEqual(layout.connectors.count, 42)
    XCTAssertEqual(runs.count, 1, "Monochrome maps should require one Canvas stroke call.")
    XCTAssertEqual(runs.first?.lineWidth ?? 0, 1.25, accuracy: 0.001)
  }

  func testDenseMapBatchedPathRasterizesAVisibleBranchSpur() throws {
    var nodes = [MindMapNode(id: 0, depth: 0, title: "Root")]
    var nextID = 1
    for branch in 0..<96 {
      nodes.append(MindMapNode(id: nextID, depth: 1, title: "Branch \(branch)"))
      nextID += 1
      for child in 0..<31 {
        nodes.append(MindMapNode(id: nextID, depth: 2, title: "Detail \(branch)-\(child)"))
        nextID += 1
      }
    }
    let layout = MindMapSpatialLayout.layout(nodes, style: .classic)
    XCTAssertGreaterThan(layout.connectors.count, 3_200)
    let root = try XCTUnwrap(layout.placements.first(where: { $0.id == 0 }))
    let rootRight = root.center.x + root.size.width / 2
    let target = try XCTUnwrap(
      layout.connectors.first(where: {
        $0.angular && abs($0.start.y - $0.end.y) < 0.001
          && $0.end.x > $0.start.x && $0.start.x > rootRight + 1
      })
    )
    let targetPoint = CGPoint(
      x: (target.start.x + target.end.x) / 2, y: target.start.y
    )
    let viewport = CGSize(width: 1_024, height: 768)
    let zoom: CGFloat = 0.68
    let offset = MindMapViewportGeometry.centeredOffset(
      for: targetPoint, mapSize: layout.size, zoom: zoom
    )
    let rect = try XCTUnwrap(
      MindMapViewportGeometry.visibleRect(
        mapSize: layout.size, viewport: viewport, offset: offset,
        zoom: zoom, overscan: 320
      )
    )
    let visible = layout.visibleConnectors(in: rect)
    XCTAssertTrue(visible.contains(target))
    let runs = MindMapViewportConnectorSnapshot.strokeRuns(
      connectors: visible, style: .classic, mapSize: layout.size,
      viewportSize: viewport, offset: offset, zoom: zoom
    )
    XCTAssertEqual(runs.count, 1)

    let snapshot = MindMapViewportConnectorSnapshot(
      size: viewport, connectors: visible, style: .classic,
      mapSize: layout.size, viewportOffset: offset, zoom: zoom, layoutVersion: 1
    )
    let renderer = ImageRenderer(
      content: snapshot.background(Color.white).environment(\.colorScheme, .light)
    )
    renderer.scale = 1
    renderer.isOpaque = true
    renderer.proposedSize = ProposedViewSize(width: viewport.width, height: viewport.height)
    let cgImage = try XCTUnwrap(renderer.cgImage)
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    let pixel = try XCTUnwrap(
      bitmap.colorAt(x: Int(viewport.width / 2), y: Int(viewport.height / 2))?
        .usingColorSpace(.deviceRGB)
    )
    XCTAssertLessThan(
      pixel.redComponent, 0.98,
      "A visible dense-map spur disappeared during Canvas rasterization."
    )
  }

  func testFullOverviewRasterizesAllDenseMapConnectorSubpaths() throws {
    var nodes = [MindMapNode(id: 0, depth: 0, title: "Root")]
    var nextID = 1
    for branch in 0..<96 {
      nodes.append(MindMapNode(id: nextID, depth: 1, title: "Branch \(branch)"))
      nextID += 1
      for child in 0..<31 {
        nodes.append(MindMapNode(id: nextID, depth: 2, title: "Detail \(branch)-\(child)"))
        nextID += 1
      }
    }
    let layout = MindMapSpatialLayout.layout(nodes, style: .classic)
    let viewport = CGSize(width: 1_024, height: 2_048)
    let zoom: CGFloat = 0.0095
    let rect = try XCTUnwrap(
      MindMapViewportGeometry.visibleRect(
        mapSize: layout.size, viewport: viewport, offset: .zero,
        zoom: zoom, overscan: 320
      )
    )
    let visible = layout.visibleConnectors(in: rect)
    XCTAssertEqual(visible.count, layout.connectors.count)
    let runs = MindMapViewportConnectorSnapshot.strokeRuns(
      connectors: visible, style: .classic, mapSize: layout.size,
      viewportSize: viewport, offset: .zero, zoom: zoom
    )
    XCTAssertEqual(runs.count, 1)

    var moveCount = 0
    runs[0].path.cgPath.applyWithBlock { element in
      if element.pointee.type == .moveToPoint {
        moveCount += 1
      }
    }
    XCTAssertEqual(moveCount, layout.connectors.count)

    let spine = try XCTUnwrap(
      layout.connectors.first(where: {
        $0.angular && abs($0.start.x - $0.end.x) < 0.001
          && abs($0.end.y - $0.start.y) > 1_000
      })
    )
    let sample = CGPoint(x: spine.start.x, y: (spine.start.y + spine.end.y) / 2)
    let screen = MindMapViewportConnectorSnapshot.mapToScreen(
      sample, mapSize: layout.size, viewportSize: viewport,
      offset: .zero, zoom: zoom
    )
    let snapshot = MindMapViewportConnectorSnapshot(
      size: viewport, connectors: visible, style: .classic,
      mapSize: layout.size, viewportOffset: .zero, zoom: zoom, layoutVersion: 1
    )
    let renderer = ImageRenderer(
      content: snapshot.background(Color.white).environment(\.colorScheme, .light)
    )
    renderer.scale = 1
    renderer.isOpaque = true
    renderer.proposedSize = ProposedViewSize(width: viewport.width, height: viewport.height)
    let cgImage = try XCTUnwrap(renderer.cgImage)
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    let pixel = try XCTUnwrap(
      bitmap.colorAt(x: Int(screen.x.rounded()), y: Int(screen.y.rounded()))?
        .usingColorSpace(.deviceRGB)
    )
    XCTAssertLessThan(
      pixel.redComponent, 0.98,
      "The full-map shared spine disappeared at overview zoom."
    )
  }
}
