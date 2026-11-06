import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// An editable Markdown-backed mind-map canvas. Markdown remains the only document authority.
struct MindMapCanvas: View {
    @Binding var source: String
    let openLink: (String) -> Void
    let importOutline: (String, String) -> Void
    @State private var selectedID: Int?
    @State private var renameTitle = ""
    @State private var renaming = false
    @State private var interchangeError: String?
    @State private var collapsed: Set<Int> = []
    @State private var zoom: CGFloat = 1.0
    @State private var dropTargetID: Int?
    @State private var gestureBaseZoom: CGFloat?
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
            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    if nodes.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 36, weight: .ultraLight))
                                .foregroundStyle(.secondary)
                            Text("Start with a central topic")
                                .font(.headline)
                            Text("The mind map is saved in the same Markdown note.")
                                .foregroundStyle(.secondary)
                            Button("Create Mind Map") {
                                source = MindMapOutline.createMap()
                                selectedID = 0
                                canvasFocused = true
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("pks-mind-map-create")
                        }
                        .frame(minWidth: max(560, viewport.size.width),
                               minHeight: max(320, viewport.size.height))
                    } else {
                        spatialCanvas(mapLayout)
                            .scaleEffect(zoom, anchor: .topLeading)
                            .frame(
                                width: max(viewport.size.width, mapLayout.size.width * zoom),
                                height: max(viewport.size.height, mapLayout.size.height * zoom),
                                alignment: .topLeading
                            )
                    }
                }
                .background(Color.primary.opacity(0.012))
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if gestureBaseZoom == nil { gestureBaseZoom = zoom }
                            zoom = clampedZoom((gestureBaseZoom ?? zoom) * value.magnification)
                        }
                        .onEnded { _ in gestureBaseZoom = nil }
                )
                .onReceive(NotificationCenter.default.publisher(for: .pksMindMapFit)) { _ in
                    fitToContent(viewport: viewport.size)
                }
            }
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
        .alert("Mind Map Import/Export", isPresented: Binding(
            get: { interchangeError != nil },
            set: { if !$0 { interchangeError = nil } }
        )) {
            Button("OK", role: .cancel) { interchangeError = nil }
        } message: {
            Text(interchangeError ?? "")
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
        .onKeyPress(.tab) {
            addChild()
            return .handled
        }
        .onKeyPress(.return) {
            addSibling()
            return .handled
        }
        .onKeyPress(.delete) {
            deleteSelectedLeaf()
            return .handled
        }
        .accessibilityIdentifier("pks-mind-map-canvas")
    }

    private var toolbar: some View {
        HStack {
            Text("Mind Map").font(.headline)
            Spacer()
            Button("Add Child", systemImage: "plus") { addChild() }
                .disabled(nodes.isEmpty)
                .help("Add child (Tab)")
                .accessibilityIdentifier("pks-mind-map-add-child")

            Button("Add Sibling", systemImage: "plus.square.on.square") { addSibling() }
                .disabled(nodes.isEmpty)
                .help("Add sibling (Return)")
                .accessibilityIdentifier("pks-mind-map-add-sibling")

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

            Button("Delete Leaf", systemImage: "trash") { deleteSelectedLeaf() }
            .disabled(selectedID == nil || MindMapOutline.deleteLeaf(in: source, nodeID: selectedID ?? -1) == nil)

            Divider().frame(height: 18)

            Button {
                NotificationCenter.default.post(name: .pksMindMapFit, object: nil)
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .help("Fit map to window")

            Button { zoom = clampedZoom(zoom - 0.15) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")
            Text("(Int(zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 45)
            Button { zoom = clampedZoom(zoom + 0.15) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")

            Menu {
                Button("Import OPML from MindNode…") { importOPML() }
                Button("Export OPML for MindNode…") { exportOPML() }
                    .disabled(nodes.isEmpty)
                Divider()
                Button("Export PNG Image…") { exportPNG() }
                    .disabled(nodes.isEmpty)
                Button("Export PDF…") { exportPDF() }
                    .disabled(nodes.isEmpty)
            } label: {
                Image(systemName: "square.and.arrow.up.on.square")
            }
            .help("MindNode-compatible OPML import/export")
            .accessibilityIdentifier("pks-mind-map-interchange")
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

    private func addChild() {
        guard let id = selectedID ?? nodes.first?.id,
              let updated = MindMapOutline.addChild(in: source, parentID: id) else { return }
        source = updated
        selectedID = id + 1
        collapsed.removeAll()
        canvasFocused = true
    }

    private func addSibling() {
        guard let id = selectedID ?? nodes.first?.id,
              let updated = MindMapOutline.addSibling(in: source, nodeID: id) else { return }
        let original = nodes
        let position = original.firstIndex(where: { $0.id == id })!
        let siblingLine = original.dropFirst(position + 1)
            .first(where: { $0.depth <= original[position].depth })?.id
            ?? source.components(separatedBy: "\n").count
        let trimmedLine = source.components(separatedBy: "\n")[id]
            .trimmingCharacters(in: .whitespaces)
        let isList = ["- ", "* ", "+ "].contains(where: { trimmedLine.hasPrefix($0) })
        source = updated
        selectedID = isList ? siblingLine : id + 1
        collapsed.removeAll()
        canvasFocused = true
    }

    private func deleteSelectedLeaf() {
        guard let id = selectedID,
              let updated = MindMapOutline.deleteLeaf(in: source, nodeID: id) else { return }
        source = updated
        selectedID = nil
    }

    private func importOPML() {
        let panel = NSOpenPanel()
        panel.title = "Import Mind Map from OPML"
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try MindMapInterchange.importOPML(Data(contentsOf: url))
            importOutline(text, url.deletingPathExtension().lastPathComponent)
        } catch {
            interchangeError = error.localizedDescription
        }
    }

    private func exportOPML() {
        do {
            let data = try MindMapInterchange.exportOPML(source)
            let panel = NSSavePanel()
            panel.title = "Export for MindNode (OPML)"
            panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
            panel.nameFieldStringValue = "Mind Map.opml"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            interchangeError = error.localizedDescription
        }
    }

    /// Export a whole map, not a cropped screenshot of the current scroll viewport.
    /// Rendering uses the existing spatial layout and never modifies the source.
    private func exportPNG() {
        guard !nodes.isEmpty else { return }
        let size = mapLayout.size
        guard size.width * size.height <= 20_000_000 else {
            interchangeError = "This map is too large for a single PNG. Try PDF."
            return
        }
        let content = spatialCanvas(mapLayout)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            interchangeError = "Cannot render this mind map as an image."
            return
        }
        saveExport(data, type: .png, extensionName: "png")
    }

    private func exportPDF() {
        guard !nodes.isEmpty else { return }
        let size = mapLayout.size
        let content = spatialCanvas(mapLayout)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height)
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let data = view.dataWithPDF(inside: view.bounds)
        guard !data.isEmpty else {
            interchangeError = "Cannot render this mind map as a PDF."
            return
        }
        saveExport(data, type: .pdf, extensionName: "pdf")
    }

    private func saveExport(_ data: Data, type: UTType, extensionName: String) {
        let panel = NSSavePanel()
        panel.title = "Export Mind Map"
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "Mind Map.\(extensionName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) }
        catch { interchangeError = error.localizedDescription }
    }

    private func hasChildren(_ node: MindMapNode) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }),
              index + 1 < nodes.count else { return false }
        return nodes[index + 1].depth > node.depth
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(1.80, max(0.45, value))
    }

    private func fitToContent(viewport: CGSize) {
        guard !mapLayout.placements.isEmpty else { return }
        let horizontal = max(0.1, (viewport.width - 36) / mapLayout.size.width)
        let vertical = max(0.1, (viewport.height - 36) / mapLayout.size.height)
        zoom = clampedZoom(min(horizontal, vertical, 1.25))
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

extension Notification.Name {
    static let pksMindMapFit = Notification.Name("PKSNotesMindMapFit")
}
