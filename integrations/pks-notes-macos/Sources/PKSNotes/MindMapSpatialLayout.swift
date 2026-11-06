import CoreGraphics

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
    private static let margin: CGFloat = 42
    private static let columnStride: CGFloat = 270
    private static let siblingGap: CGFloat = 24
    private static let rootGap: CGFloat = 40

    static func layout(_ nodes: [MindMapNode]) -> MindMapLayoutSnapshot {
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

        func nodeSize(_ node: MindMapNode) -> CGSize {
            node.depth == 0
                ? CGSize(width: 230, height: 58)
                : CGSize(width: 210, height: 50)
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

        func place(_ id: Int, top: CGFloat) {
            guard let node = nodeByID[id] else { return }
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
                    place(child, top: childTop)
                    if let childPlacement = placements.first(where: { $0.id == child }) {
                        childCenters.append(childPlacement.center.y)
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
