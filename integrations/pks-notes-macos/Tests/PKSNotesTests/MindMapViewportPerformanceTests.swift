import Foundation
import XCTest
@testable import PKSNotes

final class MindMapViewportPerformanceTests: XCTestCase {
    func test607NodeEightLevelViewportCullingMatchesLinearOracleAndReportsLatency() {
        var nodes = [MindMapNode(id: 0, depth: 0, title: "Root")]
        nodes += (1...7).map {
            MindMapNode(id: $0, depth: $0, title: "Deep level \($0)")
        }
        nodes += (8..<607).map {
            MindMapNode(id: $0, depth: 1, title: "Branch \($0)")
        }

        let buildStart = ProcessInfo.processInfo.systemUptime
        let layout = MindMapSpatialLayout.layout(nodes, style: .classic)
        let layoutMilliseconds = (ProcessInfo.processInfo.systemUptime - buildStart) * 1_000
        XCTAssertEqual(nodes.count, 607)
        XCTAssertEqual(nodes.map(\.depth).max(), 7)
        XCTAssertEqual(layout.placements.count, 607)

        let viewport = CGSize(width: 1_024, height: 768)
        let zooms: [CGFloat] = [0.75, 1, 1.25]
        var queryMilliseconds: [Double] = []
        var maximumVisibleNodes = 0
        var maximumVisibleConnectors = 0

        for frame in 0..<120 {
            let target = layout.placements[(frame * 37) % layout.placements.count]
            let zoom = zooms[frame % zooms.count]
            let offset = MindMapViewportGeometry.centeredOffset(
                for: target.center, mapSize: layout.size, zoom: zoom
            )
            guard let rect = MindMapViewportGeometry.visibleRect(
                mapSize: layout.size, viewport: viewport, offset: offset,
                zoom: zoom, overscan: 320
            ) else {
                XCTFail("A valid pan/zoom transform must produce a viewport.")
                return
            }

            let queryStart = ProcessInfo.processInfo.systemUptime
            let visibleIDs = MindMapViewportGeometry.visibleNodeIDs(
                in: layout, viewport: viewport, offset: offset, zoom: zoom, overscan: 320
            )
            let visibleConnectors = layout.visibleConnectors(in: rect)
            queryMilliseconds.append(
                (ProcessInfo.processInfo.systemUptime - queryStart) * 1_000
            )
            maximumVisibleNodes = max(maximumVisibleNodes, visibleIDs.count)
            maximumVisibleConnectors = max(maximumVisibleConnectors, visibleConnectors.count)

            let linearNodeIDs = Set(layout.placements.compactMap { placement -> Int? in
                let bounds = CGRect(
                    x: placement.center.x - placement.size.width / 2,
                    y: placement.center.y - placement.size.height / 2,
                    width: placement.size.width,
                    height: placement.size.height
                )
                return bounds.intersects(rect) ? placement.id : nil
            })
            XCTAssertEqual(visibleIDs, linearNodeIDs, "Node culling diverged at frame \(frame).")
            XCTAssertEqual(
                visibleConnectors, layout.connectors.filter { $0.bounds.intersects(rect) },
                "Connector culling diverged at frame \(frame)."
            )
        }

        let sorted = queryMilliseconds.sorted()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[Int((Double(sorted.count - 1) * 0.95).rounded(.up))]
        print(String(
            format: "[MindMapPerf] 607 nodes / 8 levels; layout %.2f ms; viewport culling P50 %.3f ms / P95 %.3f ms; max visible nodes %d / connectors %d across 120 pan-zoom positions",
            layoutMilliseconds, p50, p95, maximumVisibleNodes, maximumVisibleConnectors
        ))
        XCTAssertLessThan(maximumVisibleNodes, 50)
        XCTAssertLessThan(maximumVisibleConnectors, 100)
    }
}
