import SwiftUI

struct MindMapViewportNodeSnapshot: View, Equatable {
    let size: CGSize
    let placements: [MindMapPlacement]
    let branchByID: [Int: Int]
    let style: MindMapVisualStyle
    let colorScheme: ColorScheme
    let mapSize: CGSize
    let viewportOffset: CGSize
    let zoom: CGFloat
    let selectedID: Int?
    let totalNodeCount: Int
    let accessibilityLabel: String
    let accessibilityValue: String
    let accessibilityHint: String
    let onActivate: () -> Void
    let layoutVersion: Int

    static func == (
        lhs: MindMapViewportNodeSnapshot,
        rhs: MindMapViewportNodeSnapshot
    ) -> Bool {
        lhs.size == rhs.size
            && lhs.style == rhs.style
            && lhs.colorScheme == rhs.colorScheme
            && lhs.mapSize == rhs.mapSize
            && lhs.viewportOffset == rhs.viewportOffset
            && lhs.zoom == rhs.zoom
            && lhs.selectedID == rhs.selectedID
            && lhs.totalNodeCount == rhs.totalNodeCount
            && lhs.accessibilityLabel == rhs.accessibilityLabel
            && lhs.accessibilityValue == rhs.accessibilityValue
            && lhs.accessibilityHint == rhs.accessibilityHint
            && lhs.layoutVersion == rhs.layoutVersion
    }

    var body: some View {
        Canvas { context, _ in
            let viewportBounds = CGRect(origin: .zero, size: size)
            for placement in placements {
                let center = MindMapViewportConnectorSnapshot.mapToScreen(
                    placement.center,
                    mapSize: mapSize,
                    viewportSize: size,
                    offset: viewportOffset,
                    zoom: zoom
                )
                let width = max(2, placement.size.width * zoom)
                let height = max(2, placement.size.height * zoom)
                let bounds = CGRect(
                    x: center.x - width / 2,
                    y: center.y - height / 2,
                    width: width,
                    height: height
                )
                guard bounds.intersects(viewportBounds) else { continue }

                let branch = branchByID[placement.id] ?? 0
                let selected = selectedID == placement.id
                let radius = min(style.cardRadius * zoom, min(width, height) / 2)
                let path = RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .path(in: bounds)
                let markerColor = style.usesBranchColors || placement.node.depth == 0
                    ? style.branchColor(branch)
                    : Color.secondary
                let fill = markerColor.opacity(selected ? 0.82 : 0.20)
                let outline = markerColor.opacity(selected ? 1 : 0.68)
                context.fill(path, with: .color(fill))
                context.stroke(
                    path,
                    with: .color(outline),
                    style: StrokeStyle(
                        lineWidth: selected
                            ? max(0.9, style.unselectedOutlineWidth * zoom)
                            : max(0.6, style.unselectedOutlineWidth * zoom),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) {
            onActivate()
        }
    }
}
