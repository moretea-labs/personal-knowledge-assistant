import SwiftUI

/// Draw only the currently visible connector set into a viewport-sized Canvas.
///
/// The node layout can be tens of thousands of points tall. A single Canvas
/// spanning that complete map can exceed Core Animation's texture dimensions
/// even though only a small part of it is visible. This renderer keeps its
/// backing surface bounded to the viewport and maps layout points directly
/// into viewport coordinates.
struct MindMapViewportConnectorSnapshot: View, Equatable {
    let size: CGSize
    let connectors: [MindMapConnector]
    let style: MindMapVisualStyle
    let mapSize: CGSize
    let viewportOffset: CGSize
    let zoom: CGFloat
    let layoutVersion: Int

    static func == (
        lhs: MindMapViewportConnectorSnapshot,
        rhs: MindMapViewportConnectorSnapshot
    ) -> Bool {
        lhs.size == rhs.size
            && lhs.connectors == rhs.connectors
            && lhs.style == rhs.style
            && lhs.mapSize == rhs.mapSize
            && lhs.viewportOffset == rhs.viewportOffset
            && lhs.zoom == rhs.zoom
            && lhs.layoutVersion == rhs.layoutVersion
    }

    /// Match the transform applied to the full-size node-card canvas.
    static func mapToScreen(
        _ point: CGPoint,
        mapSize: CGSize,
        viewportSize: CGSize,
        offset: CGSize,
        zoom: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: viewportSize.width / 2 + offset.width
                + (point.x - mapSize.width / 2) * zoom,
            y: viewportSize.height / 2 + offset.height
                + (point.y - mapSize.height / 2) * zoom
        )
    }

    /// Keep strokes legible when the map is zoomed far out, without allowing
    /// them to become excessively heavy when the user zooms in.
    static func screenLineWidth(for connector: MindMapConnector, zoom: CGFloat) -> CGFloat {
        min(2, max(1, connector.lineWidth * max(0.0001, zoom)))
    }

    var body: some View {
        Canvas { context, _ in
            guard zoom.isFinite, zoom > 0,
                  mapSize.width.isFinite, mapSize.height.isFinite else { return }

            for connector in connectors {
                let start = Self.mapToScreen(
                    connector.start, mapSize: mapSize, viewportSize: size,
                    offset: viewportOffset, zoom: zoom
                )
                let end = Self.mapToScreen(
                    connector.end, mapSize: mapSize, viewportSize: size,
                    offset: viewportOffset, zoom: zoom
                )
                let control1 = Self.mapToScreen(
                    connector.control1, mapSize: mapSize, viewportSize: size,
                    offset: viewportOffset, zoom: zoom
                )
                let control2 = Self.mapToScreen(
                    connector.control2, mapSize: mapSize, viewportSize: size,
                    offset: viewportOffset, zoom: zoom
                )
                let points = [start, end, control1, control2]
                guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }

                var path = Path()
                path.move(to: start)
                if connector.angular {
                    path.addLine(to: control1)
                    path.addLine(to: control2)
                    path.addLine(to: end)
                } else {
                    path.addCurve(to: end, control1: control1, control2: control2)
                }

                let color = style.usesBranchColors
                    ? style.branchColor(connector.branch).opacity(style.connectorOpacity)
                    : Color.secondary.opacity(style.connectorOpacity)
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(
                        lineWidth: Self.screenLineWidth(for: connector, zoom: zoom),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
