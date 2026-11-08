import AppKit
import CoreGraphics

/// Visual spacing is an app preference, not a second node/document authority.
enum MindMapLayoutDensity: String, CaseIterable, Identifiable {
    case compact, standard, spacious

    static let defaultsKey = "PKSNotesMindMapDensity"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .spacious: "Spacious"
        }
    }

    var symbol: String {
        switch self {
        case .compact: "rectangle.compress.vertical"
        case .standard: "rectangle"
        case .spacious: "rectangle.expand.vertical"
        }
    }

    var scale: CGFloat {
        switch self {
        case .compact: 0.86
        case .standard: 1
        case .spacious: 1.18
        }
    }
}

struct MindMapPlacement: Identifiable, Equatable {
    let node: MindMapNode
    let parentID: Int?
    let center: CGPoint
    let size: CGSize

    var id: Int { node.id }
}

struct MindMapLayoutSnapshot: Equatable {
    let placements: [MindMapPlacement]
    let size: CGSize
}

enum MindMapSpatialLayout {
    static func layout(
        _ nodes: [MindMapNode],
        density: MindMapLayoutDensity = .standard
    ) -> MindMapLayoutSnapshot {
        // Keep node dimensions and connector spacing from a single layout
        // scale so compact maps never overlap and exports match the canvas.
        let margin: CGFloat = 42 * density.scale
        let columnStride: CGFloat = 270 * density.scale
        let siblingGap: CGFloat = 24 * density.scale
        let rootGap: CGFloat = 40 * density.scale
        guard !nodes.isEmpty else {
            return .init(placements: [], size: CGSize(width: 560, height: 320))
        }

        var parentByID: [Int: Int?] = [:]
        var stack: [MindMapNode] = []
        for node in nodes {
            while let last = stack.last, last.depth >= node.depth {
                stack.removeLast()
            }
            parentByID[node.id] = stack.last?.id
            stack.append(node)
        }

        var childrenByID: [Int: [Int]] = [:]
        var nodeByID: [Int: MindMapNode] = [:]
        for node in nodes {
            nodeByID[node.id] = node
            if let parent = parentByID[node.id] ?? nil {
                childrenByID[parent, default: []].append(node.id)
            }
        }

        // Compute visible text height once per layout, not once per subtree
        // traversal or SwiftUI redraw. Card width remains column-safe.
        // The canvas shows up to five lines; longer titles expose their full
        // text on hover instead of silently overlapping adjacent nodes.
        var nodeSizes: [Int: CGSize] = [:]
        nodeSizes.reserveCapacity(nodes.count)
        for node in nodes {
            let isRoot = node.depth == 0
            let width: CGFloat = (isRoot ? 230 : 210) * density.scale
            let baseHeight: CGFloat = (isRoot ? 58 : 50) * density.scale
            var height = baseHeight
            if node.title.count > 8 {
                let label = String(MindMapOutline.presentation(for: node.title).title.prefix(240))
                let font = NSFont.systemFont(
                    ofSize: isRoot ? 16 : 14,
                    weight: isRoot ? .semibold : .medium
                )
                // Reserve space for padding, disclosure, branch accent and
                // link affordances. Readable font size is not shrunk by density.
                let textWidth = max(72, width - 78)
                let bounds = (label as NSString).boundingRect(
                    with: CGSize(width: textWidth, height: 10_000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]
                )
                let lineHeight = font.ascender - font.descender + font.leading
                height = max(baseHeight, ceil(min(bounds.height, lineHeight * 5) + 20))
            }
            nodeSizes[node.id] = CGSize(width: width, height: height)
        }

        func nodeSize(_ node: MindMapNode) -> CGSize {
            nodeSizes[node.id] ?? .zero
        }

        var heightCache: [Int: CGFloat] = [:]
        func subtreeHeight(_ id: Int) -> CGFloat {
            if let cached = heightCache[id] { return cached }
            guard let node = nodeByID[id] else { return 0 }
            let own = nodeSize(node).height
            let children = childrenByID[id] ?? []
            guard !children.isEmpty else {
                heightCache[id] = own
                return own
            }
            let childrenHeight = children.reduce(CGFloat.zero) { $0 + subtreeHeight($1) }
                + siblingGap * CGFloat(max(0, children.count - 1))
            let value = max(own, childrenHeight)
            heightCache[id] = value
            return value
        }

        let roots = nodes.filter { (parentByID[$0.id] ?? nil) == nil }
        var placements: [MindMapPlacement] = []

        @discardableResult
        func place(_ id: Int, top: CGFloat) -> CGFloat? {
            guard let node = nodeByID[id] else { return nil }
            let children = childrenByID[id] ?? []
            let ownSize = nodeSize(node)
            let height = subtreeHeight(id)
            var childCenters: [CGFloat] = []

            if !children.isEmpty {
                let childrenHeight = children.reduce(CGFloat.zero) { $0 + subtreeHeight($1) }
                    + siblingGap * CGFloat(max(0, children.count - 1))
                var childTop = top + max(0, (height - childrenHeight) / 2)
                for child in children {
                    let childHeight = subtreeHeight(child)
                    if let childCenterY = place(child, top: childTop) {
                        childCenters.append(childCenterY)
                    }
                    childTop += childHeight + siblingGap
                }
            }

            let centerY: CGFloat
            if let first = childCenters.first, let last = childCenters.last {
                centerY = (first + last) / 2
            } else {
                centerY = top + height / 2
            }
            let centerX = margin + CGFloat(node.depth) * columnStride + ownSize.width / 2
            placements.append(.init(
                node: node,
                parentID: parentByID[node.id] ?? nil,
                center: CGPoint(x: centerX, y: centerY),
                size: ownSize
            ))
            return centerY
        }

        var top = margin
        for root in roots {
            place(root.id, top: top)
            top += subtreeHeight(root.id) + rootGap
        }

        let order = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        placements.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }

        let maxX = placements.map { $0.center.x + $0.size.width / 2 }.max() ?? 480
        let maxY = placements.map { $0.center.y + $0.size.height / 2 }.max() ?? 280
        return .init(
            placements: placements,
            size: CGSize(width: max(560, maxX + margin), height: max(320, maxY + margin))
        )
    }
}
