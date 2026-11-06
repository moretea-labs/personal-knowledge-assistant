import SwiftUI

/// An editable Markdown-backed mind-map outline. No separate document storage.
struct MindMapCanvas: View {
    @Binding var source: String
    let openLink: (String) -> Void
    @State private var selectedID: Int?
    @State private var renameTitle = ""
    @State private var renaming = false
    @State private var collapsed: Set<Int> = []
    @State private var zoom: CGFloat = 1.0
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mind Map").font(.headline)
                Spacer()
                Button("Add Child", systemImage: "plus") {
                    guard let id = selectedID, let updated = MindMapOutline.addChild(in: source, parentID: id) else { return }
                    source = updated
                    selectedID = id + 1
                    collapsed.removeAll()
                }.disabled(selectedID == nil)
                Button("Rename", systemImage: "pencil") { beginRename() }.disabled(selectedID == nil)
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
                    guard let id = selectedID, let updated = MindMapOutline.deleteLeaf(in: source, nodeID: id) else { return }
                    source = updated
                    selectedID = nil
                }
                .disabled(selectedID == nil || MindMapOutline.deleteLeaf(in: source, nodeID: selectedID ?? -1) == nil)
                Divider().frame(height: 18)
                Button { zoom = max(0.65, zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                Text("\(Int(zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 45)
                Button { zoom = min(1.75, zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")
            }
            .padding(16)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 14) {
                    if nodes.isEmpty {
                        Text("Add Markdown headings or lists to begin.").foregroundStyle(.secondary)
                    }
                    ForEach(visible) { node in
                        HStack(spacing: 10) {
                            Button {
                                if !collapsed.insert(node.id).inserted { collapsed.remove(node.id) }
                            } label: {
                                Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                            }.buttonStyle(.plain)
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundStyle(.tertiary)
                            Text(node.title).font(.system(size: node.depth == 0 ? 17 : 14, weight: .medium))
                            if let link = MindMapOutline.links(in: node.title).first {
                                Button {
                                    openLink(link.target)
                                } label: {
                                    Image(systemName: "link")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Open \(link.label)")
                                .accessibilityLabel("Open linked note \(link.label)")
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(selectedID == node.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.leading, CGFloat(node.depth) * 40)
                        .overlay(alignment: .leading) {
                            if node.depth > 0 {
                                Path { path in
                                    let x = CGFloat(node.depth) * 40 - 18
                                    path.move(to: CGPoint(x: x, y: -7))
                                    path.addLine(to: CGPoint(x: x, y: 22))
                                    path.addQuadCurve(to: CGPoint(x: x + 13, y: 35), control: CGPoint(x: x, y: 35))
                                }
                                .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                                .allowsHitTesting(false)
                            }
                        }
                        .contentShape(Rectangle())
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
                }
                .scaleEffect(zoom, anchor: .topLeading)
                .padding(32)
                .frame(minWidth: 500 * zoom, maxWidth: .infinity, alignment: .leading)
            }
        }
        .alert("Rename Node", isPresented: $renaming) {
            TextField("Title", text: $renameTitle)
            Button("Save") {
                if let id = selectedID, let updated = MindMapOutline.rename(in: source, nodeID: id, to: renameTitle) { source = updated }
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
