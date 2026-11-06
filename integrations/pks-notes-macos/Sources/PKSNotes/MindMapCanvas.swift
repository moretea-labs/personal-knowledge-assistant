import SwiftUI

/// An editable Markdown-backed mind-map outline. No separate document storage.
struct MindMapCanvas: View {
    @Binding var source: String
    @State private var selectedID: Int?
    @State private var renameTitle = ""
    @State private var renaming = false
    @State private var collapsed: Set<Int> = []

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
                            Text(node.title).font(.system(size: node.depth == 0 ? 17 : 14, weight: .medium))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(selectedID == node.id ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.leading, CGFloat(node.depth) * 40)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = node.id }
                        .onTapGesture(count: 2) { selectedID = node.id; beginRename() }
                    }
                }.padding(32).frame(minWidth: 500, maxWidth: .infinity, alignment: .leading)
            }
        }
        .alert("Rename Node", isPresented: $renaming) {
            TextField("Title", text: $renameTitle)
            Button("Save") {
                if let id = selectedID, let updated = MindMapOutline.rename(in: source, nodeID: id, to: renameTitle) { source = updated }
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityIdentifier("pks-mind-map-canvas")
    }

    private func beginRename() {
        guard let node = nodes.first(where: { $0.id == selectedID }) else { return }
        renameTitle = node.title
        renaming = true
    }
}
