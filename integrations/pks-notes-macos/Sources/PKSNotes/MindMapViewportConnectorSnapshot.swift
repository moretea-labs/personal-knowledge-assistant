import SwiftUI

struct MindMapConnectorStrokeRun {
  let branch: Int
  let lineWidth: CGFloat
  let path: Path
}

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

  static func strokeRuns(
    connectors: [MindMapConnector], style: MindMapVisualStyle,
    mapSize: CGSize, viewportSize: CGSize, offset: CGSize, zoom: CGFloat
  ) -> [MindMapConnectorStrokeRun] {
    guard zoom.isFinite, zoom > 0,
      mapSize.width.isFinite, mapSize.height.isFinite,
      viewportSize.width.isFinite, viewportSize.height.isFinite,
      offset.width.isFinite, offset.height.isFinite
    else { return [] }

    var runs: [MindMapConnectorStrokeRun] = []
    var activeBranch: Int?
    var activeLineWidth: CGFloat?
    var activePath = Path()
    for connector in connectors {
      let start = mapToScreen(
        connector.start, mapSize: mapSize, viewportSize: viewportSize,
        offset: offset, zoom: zoom
      )
      let end = mapToScreen(
        connector.end, mapSize: mapSize, viewportSize: viewportSize,
        offset: offset, zoom: zoom
      )
      let control1 = mapToScreen(
        connector.control1, mapSize: mapSize, viewportSize: viewportSize,
        offset: offset, zoom: zoom
      )
      let control2 = mapToScreen(
        connector.control2, mapSize: mapSize, viewportSize: viewportSize,
        offset: offset, zoom: zoom
      )
      guard start.x.isFinite, start.y.isFinite,
        end.x.isFinite, end.y.isFinite,
        control1.x.isFinite, control1.y.isFinite,
        control2.x.isFinite, control2.y.isFinite
      else { continue }

      // Merge only adjacent strokes with identical paint attributes.
      // Run order preserves the existing deterministic connector paint order.
      let branch = style.usesBranchColors ? connector.branch : 0
      let lineWidth = screenLineWidth(for: connector, zoom: zoom)
      if activeBranch != branch || activeLineWidth != lineWidth {
        if let activeBranch, let activeLineWidth {
          runs.append(
            .init(
              branch: activeBranch, lineWidth: activeLineWidth, path: activePath
            ))
        }
        activePath = Path()
        activeBranch = branch
        activeLineWidth = lineWidth
      }
      activePath.move(to: start)
      if connector.angular {
        activePath.addLine(to: control1)
        activePath.addLine(to: control2)
        activePath.addLine(to: end)
      } else {
        activePath.addCurve(to: end, control1: control1, control2: control2)
      }
    }
    if let activeBranch, let activeLineWidth {
      runs.append(
        .init(
          branch: activeBranch, lineWidth: activeLineWidth, path: activePath
        ))
    }
    return runs
  }

  var body: some View {
    let runs = Self.strokeRuns(
      connectors: connectors, style: style, mapSize: mapSize,
      viewportSize: size, offset: viewportOffset, zoom: zoom
    )
    Canvas { context, _ in
      for run in runs {
        let color =
          style.usesBranchColors
          ? style.branchColor(run.branch).opacity(style.connectorOpacity)
          : Color.secondary.opacity(style.connectorOpacity)
        context.stroke(
          run.path, with: .color(color),
          style: StrokeStyle(
            lineWidth: run.lineWidth, lineCap: .round, lineJoin: .round
          )
        )
      }
    }
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
