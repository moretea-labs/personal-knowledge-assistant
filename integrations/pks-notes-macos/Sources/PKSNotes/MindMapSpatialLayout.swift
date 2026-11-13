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
    let placementsByID: [Int: MindMapPlacement]
    let placementOrderByID: [Int: Int]
    let parentIDs: Set<Int>
    let branchByID: [Int: Int]

    init(placements: [MindMapPlacement], size: CGSize) {
        self.placements = placements
        self.size = size
        placementsByID = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
        placementOrderByID = Dictionary(
            uniqueKeysWithValues: placements.enumerated().map { ($0.element.id, $0.offset) }
        )
        parentIDs = Set(placements.compactMap(\.parentID))
        branchByID = MindMapVisualStyle.branchIndices(placements.map(\.node))
    }

    /// Resolve the viewport's small visible set without filtering the full
    /// placement array on every pan/zoom update. Preserve Markdown source order.
    func visiblePlacements(for visibleIDs: Set<Int>?) -> [MindMapPlacement] {
        guard let visibleIDs else { return placements }
        return visibleIDs.compactMap { placementsByID[$0] }.sorted {
            placementOrderByID[$0.id, default: .max] < placementOrderByID[$1.id, default: .max]
        }
    }
}

enum MindMapSpatialLayout {
    static func layout(
        _ nodes: [MindMapNode],
        density: MindMapLayoutDensity = .standard,
        style: MindMapVisualStyle = .classic
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
        // traversal or SwiftUI redraw. Card width remains column-safe and the
        // full Markdown node title remains readable instead of being clipped
        // to an arbitrary line count.
        var nodeSizes: [Int: CGSize] = [:]
        nodeSizes.reserveCapacity(nodes.count)
        for node in nodes {
            let isRoot = node.depth == 0
            let width: CGFloat = (isRoot ? 230 : 210) * density.scale
            let baseHeight: CGFloat = (isRoot ? 58 : 50) * density.scale
            var height = baseHeight
            if node.title.count > 8 {
                let label = MindMapOutline.presentation(for: node.title).title
                let font = style.measurementFont(
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
                height = max(baseHeight, ceil(bounds.height + 20))
            }
            nodeSizes[node.id] = CGSize(width: width, height: height)
        }

        func nodeSize(_ node: MindMapNode) -> CGSize {
            nodeSizes[node.id] ?? .zero
        }

        // Nodes are in Markdown source order, so every child appears after
        // its parent. A reverse pass computes subtree heights without recursive
        // calls; deeply nested notes must not be able to exhaust the call stack.
        var subtreeHeights: [Int: CGFloat] = [:]
        subtreeHeights.reserveCapacity(nodes.count)
        for node in nodes.reversed() {
            let children = childrenByID[node.id] ?? []
            let childrenHeight = children.reduce(CGFloat.zero) {
                $0 + (subtreeHeights[$1] ?? 0)
            } + siblingGap * CGFloat(max(0, children.count - 1))
            subtreeHeights[node.id] = max(nodeSize(node).height, childrenHeight)
        }

        let roots = nodes.filter { (parentByID[$0.id] ?? nil) == nil }
        var placements: [MindMapPlacement] = []
        var pending: [(id: Int, top: CGFloat)] = []
        var top = margin
        for root in roots {
            pending.append((id: root.id, top: top))
            top += (subtreeHeights[root.id] ?? nodeSize(root).height) + rootGap
        }

        // Every subtree is vertically centered inside its reserved height, so
        // each node center is exactly top + subtreeHeight / 2. Carry child tops
        // explicitly and walk the tree iteratively instead of recursing.
        while let frame = pending.popLast() {
            guard let node = nodeByID[frame.id] else { continue }
            let children = childrenByID[node.id] ?? []
            let ownSize = nodeSizes[node.id] ?? .zero
            let height = subtreeHeights[node.id] ?? ownSize.height
            let childrenHeight = children.reduce(CGFloat.zero) {
                $0 + (subtreeHeights[$1] ?? 0)
            } + siblingGap * CGFloat(max(0, children.count - 1))
            var childTop = frame.top + max(0, (height - childrenHeight) / 2)
            var childFrames: [(id: Int, top: CGFloat)] = []
            childFrames.reserveCapacity(children.count)
            for child in children {
                childFrames.append((id: child, top: childTop))
                childTop += (subtreeHeights[child] ?? 0) + siblingGap
            }
            for childFrame in childFrames.reversed() {
                pending.append(childFrame)
            }

            let centerX = margin + CGFloat(node.depth) * columnStride + ownSize.width / 2
            placements.append(.init(
                node: node,
                parentID: parentByID[node.id] ?? nil,
                center: CGPoint(x: centerX, y: frame.top + height / 2),
                size: ownSize
            ))
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
