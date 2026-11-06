import SwiftUI

/// An editable Markdown-backed mind-map canvas. Markdown remains the only document authority.
struct MindMapCanvas: View {
    @Binding var source: String
    let openLink: (String) -> Void
    @State private var selectedID: Int?
    @State private var renameTitle = ""
    @State private var renaming = false
    @State private var collapsed: Set<Int> = []
    @State private var zoom: CGFloat = 1.0
    @State private var dropTargetID: Int?
    @FocusState private var canvasFocused: Bool

    private var nodes: [MindMapNode] { MindMapOutline.nodes(in: source) }

    private var visible: [MindMapNode] {
        var hiddenBelow: Int?
        return nodes.filter { node in
            if let depth = hiddenBelow {
                if node.depth > depth { return false }
                hiddenBelow = nil
            }
            if collapsed.contains(node.id) { hiddenBelow = node.depth }
            return true
        }
    }

    private var mapLayout: MindMapLayoutSnapshot {
        MindMapSpatialLayout.layout(visible)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView([.horizontal, .vertical]) {
                if nodes.isEmpty {
                    Text("Add Markdown headings or lists to begin.")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 560, minHeight: 320)
                } else {
                    spatialCanvas(mapLayout)
                        .scaleEffect(zoom, anchor: .topLeading)
                        .frame(
                            width: mapLayout.size.width * zoom,
                            height: mapLayout.size.height * zoom,
                            alignment: .topLeading
                        )
                }
            }
            .background(Color.primary.opacity(0.012))
        }
        .alert("Rename Node", isPresented: $renaming) {
            TextField("Title", text: $renameTitle)
            Button("Save") {
                if let id = selectedID,
                   let updated = MindMapOutline.rename(in: source, nodeID: id, to: renameTitle) {
                    source = updated
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .focusable()
        .focused($canvasFocused)
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.return) {
            guard selectedID != nil else { return .ignored }
            beginRename()
            return .handled
        }
        .accessibilityIdentifier("pks-mind-map-canvas")
    }

    private var toolbar: some View {
        HStack {
            Text("Mind Map").font(.headline)
            Spacer()
            Button("Add Child", systemImage: "plus") {
                guard let id = selectedID,
                      let updated = MindMapOutline.addChild(in: source, parentID: id) else { return }
                source = updated
                selectedID = id + 1
                collapsed.removeAll()
            }
            .disabled(selectedID == nil)

            Button("Rename", systemImage: "pencil") { beginRename() }
                .disabled(selectedID == nil)

            Button {
                shiftSelected(deeper: false)
            } label: {
                Image(systemName: "arrow.left")
            }
            .help("Promote node")
            .disabled(selectedID == nil || shiftedSource(deeper: false) == nil)

            Button {
                shiftSelected(deeper: true)
            } label: {
                Image(systemName: "arrow.right")
            }
            .help("Make child of previous sibling")
            .disabled(selectedID == nil || shiftedSource(deeper: true) == nil)

            Button("Delete Leaf", systemImage: "trash") {
                guard let id = selectedID,
                      let updated = MindMapOutline.deleteLeaf(in: source, nodeID: id) else { return }
                source = updated
                selectedID = nil
            }
            .disabled(selectedID == nil || MindMapOutline.deleteLeaf(in: source, nodeID: selectedID ?? -1) == nil)

            Divider().frame(height: 18)

            Button { zoom = max(0.65, zoom - 0.15) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            Text("(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 45)
            Button { zoom = min(1.75, zoom + 0.15) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")
        }
        .padding(16)
    }

    @ViewBuilder
    private func spatialCanvas(_ layout: MindMapLayoutSnapshot) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })
        ZStack(alignment: .topLeading) {
            ForEach(layout.placements) { placement in
                if let parentID = placement.parentID, let parent = byID[parentID] {
                    connector(from: parent, to: placement)
                }
            }

            ForEach(layout.placements) { placement in
                nodeCard(placement.node)
                    .frame(width: placement.size.width, height: placement.size.height)
                    .position(placement.center)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private func connector(from parent: MindMapPlacement, to child: MindMapPlacement) -> some View {
        Path { path in
            let start = CGPoint(
                x: parent.center.x + parent.size.width / 2,
                y: parent.center.y
            )
            let end = CGPoint(
                x: child.center.x - child.size.width / 2,
                y: child.center.y
            )
            let bend = max(34, (end.x - start.x) * 0.48)
            path.move(to: start)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + bend, y: start.y),
                control2: CGPoint(x: end.x - bend, y: end.y)
            )
        }
        .stroke(Color.secondary.opacity(0.30), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func nodeCard(_ node: MindMapNode) -> some View {
        HStack(spacing: 9) {
            if hasChildren(node) {
                Button {
                    if !collapsed.insert(node.id).inserted { collapsed.remove(node.id) }
                } label: {
                    Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 10, height: 10)
            }

            Text(node.title)
                .font(.system(size: node.depth == 0 ? 16 : 14, weight: node.depth == 0 ? .semibold : .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let link = MindMapOutline.links(in: node.title).first {
                Button {
                    openLink(link.target)
                } label: {
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open (link.label)")
                .accessibilityLabel("Open linked note (link.label)")
            }
        }
        .padding(.horizontal, 13)
        .background(
            selectedID == node.id
                ? Color.accentColor.opacity(0.16)
                : (node.depth == 0 ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)),
            in: RoundedRectangle(cornerRadius: node.depth == 0 ? 14 : 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: node.depth == 0 ? 14 : 11)
                .strokeBorder(
                    dropTargetID == node.id
                        ? Color.accentColor
                        : (selectedID == node.id ? Color.accentColor.opacity(0.60) : Color.primary.opacity(0.08)),
                    style: StrokeStyle(
                        lineWidth: dropTargetID == node.id ? 2 : 1,
                        dash: dropTargetID == node.id ? [5, 3] : []
                    )
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(node.depth == 0 ? 0.08 : 0.04), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .draggable(String(node.id))
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first,
                  let draggedID = Int(raw),
                  let updated = MindMapOutline.moveListSubtree(
                    in: source, nodeID: draggedID, asChildOf: node.id
                  ) else { return false }
            source = updated
            selectedID = nil
            collapsed.removeAll()
            dropTargetID = nil
            return true
        } isTargeted: { targeted in
            dropTargetID = targeted ? node.id : nil
        }
        .onTapGesture {
            selectedID = node.id
            canvasFocused = true
        }
        .onTapGesture(count: 2) {
            selectedID = node.id
            canvasFocused = true
            beginRename()
        }
    }

    private func hasChildren(_ node: MindMapNode) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }),
              index + 1 < nodes.count else { return false }
        return nodes[index + 1].depth > node.depth
    }

    private func moveSelection(by offset: Int) {
        let rows = visible
        guard !rows.isEmpty else {
            selectedID = nil
            return
        }
        guard let selectedID,
              let index = rows.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = offset < 0 ? rows.last?.id : rows.first?.id
            return
        }
        let next = min(max(index + offset, 0), rows.count - 1)
        self.selectedID = rows[next].id
    }

    private func beginRename() {
        guard let node = nodes.first(where: { $0.id == selectedID }) else { return }
        renameTitle = node.title
        renaming = true
    }

    private func shiftedSource(deeper: Bool) -> String? {
        guard let selectedID else { return nil }
        return MindMapOutline.shiftListSubtree(in: source, nodeID: selectedID, deeper: deeper)
    }

    private func shiftSelected(deeper: Bool) {
        guard let updated = shiftedSource(deeper: deeper) else { return }
        source = updated
        collapsed.removeAll()
    }
}
