import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Commands are resolved once from a focused canvas. Inline TextField editing
// bypasses this dispatcher so native text editing retains its own shortcuts.
enum MindMapKeyboard {
    enum Command: Equatable {
        case previous, next, parentOrCollapse, childOrExpand
        case addChild, addSibling, promote, rename, toggleBranch
        case deleteLeaf, deleteBranch, fit, zoomIn, zoomOut, clearSelection
    }

    static func command(for key: KeyEquivalent, modifiers: EventModifiers) -> Command? {
        guard !modifiers.contains(.control), !modifiers.contains(.option) else { return nil }
        if modifiers.contains(.command) {
            if key == .delete, !modifiers.contains(.shift) { return .deleteBranch }
            if key == "0", !modifiers.contains(.shift) { return .fit }
            if key == "-", !modifiers.contains(.shift) { return .zoomOut }
            if key == "=" || key == "+" { return .zoomIn }
            return nil
        }
        if key == .tab { return modifiers.contains(.shift) ? .promote : .addChild }
        guard !modifiers.contains(.shift) else { return nil }
        switch key {
        case .upArrow: return .previous
        case .downArrow: return .next
        case .leftArrow: return .parentOrCollapse
        case .rightArrow: return .childOrExpand
        case .return: return .addSibling
        case .delete: return .deleteLeaf
        case .space: return .toggleBranch
        case .escape: return .clearSelection
        case "e": return .rename
        default: return nil
        }
    }

    // Visible outline is already the current keyboard traversal order.
    // Parent/child resolution uses Markdown depth, not a second tree authority.
    static func selection(
        from selectedID: Int?,
        in visible: [MindMapNode],
        moving direction: Command
    ) -> Int? {
        guard !visible.isEmpty else { return nil }
        guard let selectedID, let index = visible.firstIndex(where: { $0.id == selectedID }) else {
            return direction == .previous ? visible.last?.id : visible.first?.id
        }
        switch direction {
        case .previous: return visible[max(0, index - 1)].id
        case .next: return visible[min(visible.count - 1, index + 1)].id
        case .parentOrCollapse:
            return visible[..<index].last(where: { $0.depth < visible[index].depth })?.id
        case .childOrExpand:
            let following = visible.index(after: index)
            guard following < visible.endIndex,
                  visible[following].depth > visible[index].depth else { return nil }
            return visible[following].id
        default: return nil
        }
    }
}

/// An editable Markdown-backed mind-map canvas. Markdown remains the only document authority.
struct MindMapCanvas: View {
    @Environment(\.notesLanguage) private var language
    @Binding var source: String
    @Binding var selectedID: Int?
    let revision: UInt64
    let openLink: (String) -> Void
    let connectNote: (Int) -> Void
    let connectSection: (Int) -> Void
    let createLinkedNote: (Int) -> Void
    let revealSource: (Int) -> Void
    let importOutline: (String, String) -> Bool
    @State private var renameTitle = ""
    @State private var editingNodeID: Int?
    @State private var editingCreatedNodeID: Int?
    @State private var interchangeError: String?
    @State private var showingShortcuts = false
    @State private var branchDeleteCandidateID: Int?
    @State private var collapsed: Set<Int> = []
    @State private var zoom: CGFloat = 1.0
    @State private var dropTargetID: Int?
    @State private var gestureBaseZoom: CGFloat?
    @State private var nodes: [MindMapNode] = []
    @State private var visible: [MindMapNode] = []
    @State private var mapLayout = MindMapSpatialLayout.layout([])
    @State private var projectionReady = false
    @State private var canPromote = false
    @State private var canDemote = false
    @State private var canDeleteLeaf = false
    @FocusState private var canvasFocused: Bool
    @FocusState private var titleEditorFocused: Bool

    private struct ActionAvailabilityKey: Hashable {
        let revision: UInt64
        let selectedID: Int?
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { viewport in
                ScrollViewReader { scroller in
                    ScrollView([.horizontal, .vertical]) {
                    if !projectionReady {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(language.text("Preparing mind map…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minWidth: max(560, viewport.size.width),
                               minHeight: max(320, viewport.size.height))
                    } else if nodes.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 36, weight: .ultraLight))
                                .foregroundStyle(.secondary)
                            Text(language.text("Start with a central topic"))
                                .font(.headline)
                            Text(language.text("The mind map is saved in the same Markdown note."))
                                .foregroundStyle(.secondary)
                            Button(language.text("Create Mind Map")) {
                                source = MindMapOutline.createMap()
                                startEditingNode(0, title: "New Mind Map")
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
                .accessibilityIdentifier("pks-mind-map-canvas")
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
                    .onChange(of: selectedID) { _, selected in
                        guard let selected,
                              visible.contains(where: { $0.id == selected }) else { return }
                        withAnimation(.easeOut(duration: 0.14)) {
                            scroller.scrollTo(selected, anchor: .center)
                        }
                    }
                    .onChange(of: visible) { _, rows in
                        // New child/sibling nodes are parsed asynchronously after
                        // the ID changes. Reveal them once their placement exists.
                        guard let selected = editingNodeID ?? selectedID,
                              rows.contains(where: { $0.id == selected }) else { return }
                        scroller.scrollTo(selected, anchor: .center)
                    }
                }
            }
        }
        .confirmationDialog(
            language.text("Delete selected branch?"),
            isPresented: Binding(
                get: { branchDeleteCandidateID != nil },
                set: { if !$0 { branchDeleteCandidateID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(language.text("Delete Branch"), role: .destructive) {
                if let id = branchDeleteCandidateID,
                   let updated = MindMapOutline.deleteListSubtree(in: source, nodeID: id) {
                    source = updated
                    selectedID = nil
                    collapsed.removeAll()
                }
                branchDeleteCandidateID = nil
            }
            Button(language.text("Cancel"), role: .cancel) { branchDeleteCandidateID = nil }
        } message: {
            Text(language.text("The selected list branch and its child nodes will be removed from this note."))
        }
        .alert(language.text("Mind Map Import/Export"), isPresented: Binding(
            get: { interchangeError != nil },
            set: { if !$0 { interchangeError = nil } }
        )) {
            Button(language.text("OK"), role: .cancel) { interchangeError = nil }
        } message: {
            Text(interchangeError ?? "")
        }
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .task(id: revision) {
            let input = source
            let sourceRevision = revision
            if nodes.isEmpty { projectionReady = false }

            let parser = Task.detached(priority: .userInitiated) {
                MindMapOutline.nodes(in: input)
            }
            defer { parser.cancel() }
            let parsed = await parser.value
            guard !Task.isCancelled, revision == sourceRevision else { return }

            nodes = parsed
            projectionReady = true
            rebuildVisibleLayout()
            if let selectedID, !parsed.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        }
        .onChange(of: collapsed) { _, _ in
            rebuildVisibleLayout()
        }
        .task(id: ActionAvailabilityKey(revision: revision, selectedID: selectedID)) {
            guard let selectedID else {
                canPromote = false
                canDemote = false
                canDeleteLeaf = false
                return
            }
            let input = source
            let sourceRevision = revision
            let availability = await Task.detached(priority: .utility) {
                MindMapOutline.actionAvailability(in: input, nodeID: selectedID)
            }.value
            guard !Task.isCancelled, revision == sourceRevision, self.selectedID == selectedID else { return }
            canPromote = availability.canPromote
            canDemote = availability.canDemote
            canDeleteLeaf = availability.canDeleteLeaf
        }
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                if editingNodeID == nil {
                    canvasFocused = true
                }
            }
        }
        .onKeyPress { press in
            guard editingNodeID == nil,
                  let command = MindMapKeyboard.command(for: press.key, modifiers: press.modifiers)
            else { return .ignored }
            return performShortcut(command) ? .handled : .ignored
        }
        .onChange(of: showingShortcuts) { _, visible in
            if !visible { requestCanvasFocus() }
        }
        .onChange(of: branchDeleteCandidateID) { _, candidate in
            if candidate == nil { requestCanvasFocus() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(language.text("Mind Map"))
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                addChild()
            } label: {
                Image(systemName: "plus")
                .frame(width: 30, height: 30)
            }
            .disabled(nodes.isEmpty)
            .help("\(language.text("Add Child")) · Tab")
            .accessibilityLabel(language.text("Add Child"))
            .accessibilityIdentifier("pks-mind-map-add-child")

            Button {
                addSibling()
            } label: {
                Image(systemName: "plus.square.on.square")
                .frame(width: 30, height: 30)
            }
            .disabled(nodes.isEmpty)
            .help("\(language.text("Add Sibling")) · Return")
            .accessibilityLabel(language.text("Add Sibling"))
            .accessibilityIdentifier("pks-mind-map-add-sibling")

            Button {
                beginRename()
            } label: {
                Image(systemName: "pencil")
                .frame(width: 30, height: 30)
            }
            .disabled(selectedID == nil)
            .help("\(language.text("Rename node")) · E")
            .accessibilityLabel(language.text("Rename node"))
            .accessibilityIdentifier("pks-mind-map-rename")

            Menu {
                Button(language.text("Link Note"), systemImage: "doc.text") {
                    if let selectedID { connectNote(selectedID) }
                }
                Button(language.text("Link Section"), systemImage: "text.badge.plus") {
                    if let selectedID { connectSection(selectedID) }
                }
                Divider()
                Button(language.text("Create Linked Note"), systemImage: "doc.badge.plus") {
                    if let selectedID { createLinkedNote(selectedID) }
                }
            } label: {
                Image(systemName: "link.badge.plus")
                .frame(width: 30, height: 30)
            }
            .disabled(selectedID == nil)
            .help(language.text("Link selected node to note"))
            .accessibilityLabel(language.text("Link"))
            .accessibilityIdentifier("pks-mind-map-link")

            Button {
                if let selectedID { revealSource(selectedID) }
            } label: {
                Image(systemName: "text.cursor")
                .frame(width: 30, height: 30)
            }
            .disabled(selectedID == nil)
            .help(language.text("Reveal selected node in Markdown"))
            .accessibilityLabel(language.text("Show in Markdown"))
            .accessibilityIdentifier("pks-mind-map-reveal-markdown")

            Menu {
                Button(language.text("Promote node"), systemImage: "arrow.left") {
                    _ = performShortcut(.promote)
                }
                .disabled(selectedID == nil || !canPromote)
                Button(language.text("Make child of previous sibling"), systemImage: "arrow.right") {
                    shiftSelected(deeper: true)
                    requestCanvasFocus()
                }
                .disabled(selectedID == nil || !canDemote)
                Divider()
                Button(language.text("Delete Leaf"), systemImage: "trash") {
                    _ = performShortcut(.deleteLeaf)
                }
                .disabled(selectedID == nil || !canDeleteLeaf)
                Button(language.text("Delete Branch"), systemImage: "trash.slash", role: .destructive) {
                    _ = performShortcut(.deleteBranch)
                }
                .disabled(selectedID == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
                .frame(width: 30, height: 30)
            }
            .disabled(selectedID == nil)
            .help(language.text("Node Actions"))
            .accessibilityLabel(language.text("Node Actions"))
            .accessibilityIdentifier("pks-mind-map-node-actions")

            Divider().frame(height: 18)

            Button {
                _ = performShortcut(.zoomOut)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                .frame(width: 30, height: 30)
            }
            .help("\(language.text("Zoom out")) · ⌘−")
            .accessibilityLabel(language.text("Zoom out"))
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 42)
            Button {
                _ = performShortcut(.zoomIn)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                .frame(width: 30, height: 30)
            }
            .help("\(language.text("Zoom in")) · ⌘+")
            .accessibilityLabel(language.text("Zoom in"))
            Button {
                _ = performShortcut(.fit)
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                .frame(width: 30, height: 30)
            }
            .help("\(language.text("Fit map to window")) · ⌘0")
            .accessibilityLabel(language.text("Fit map to window"))
            .accessibilityIdentifier("pks-mind-map-fit")

            Menu {
                Button(language.text("Import MindNode Package…")) { importMindNode() }
                Button(language.text("Export MindNode Using Template…")) { exportMindNode() }
                    .disabled(nodes.isEmpty)
                Button(language.text("Import OPML from MindNode…")) { importOPML() }
                Button(language.text("Export OPML for MindNode…")) { exportOPML() }
                    .disabled(nodes.isEmpty)
                Divider()
                Button(language.text("Export PNG Image…")) { exportPNG() }
                    .disabled(nodes.isEmpty)
                Button(language.text("Export PDF…")) { exportPDF() }
                    .disabled(nodes.isEmpty)
            } label: {
                Image(systemName: "square.and.arrow.up.on.square")
                .frame(width: 30, height: 30)
            }
            .help(language.text("MindNode package interchange, OPML, PNG and PDF export"))
            .accessibilityLabel(language.text("Import/Export"))
            .accessibilityIdentifier("pks-mind-map-interchange")

            Button {
                showingShortcuts.toggle()
            } label: {
                Image(systemName: "keyboard")
                .frame(width: 30, height: 30)
            }
            .help(language.text("Mind Map Shortcuts"))
            .accessibilityLabel(language.text("Mind Map Shortcuts"))
            .accessibilityIdentifier("pks-mind-map-shortcuts")
            .popover(isPresented: $showingShortcuts, arrowEdge: .bottom) {
                shortcutHelp
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var shortcutHelp: some View {
        let rows: [(String, String)] = [
            ("↑ / ↓", "Select previous / next node"),
            ("← / →", "Parent / child; collapse / expand"),
            ("Tab", "Add Child"),
            ("Return", "Add Sibling"),
            ("⇧ Tab", "Promote node"),
            ("E", "Rename node"),
            ("Space", "Collapse / expand branch"),
            ("Delete", "Delete Leaf"),
            ("⌘ Delete", "Delete Branch"),
            ("⌘ + / ⌘ −", "Zoom in / out"),
            ("⌘ 0", "Fit map to window"),
            ("Esc", "Clear selection")
        ]
        return VStack(alignment: .leading, spacing: 11) {
            Text(language.text("Mind Map Shortcuts"))
                .font(.headline)
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 14) {
                    Text(rows[index].0)
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                        .frame(width: 112, alignment: .leading)
                    Text(language.text(rows[index].1))
                        .font(.subheadline)
                    Spacer(minLength: 0)
                }
            }
            Text(language.text("Shortcuts work when the map is focused, not while editing a node title."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 410, alignment: .leading)
    }

    private func requestCanvasFocus() {
        Task { @MainActor in
            await Task.yield()
            if editingNodeID == nil { canvasFocused = true }
        }
    }

    @discardableResult
    private func performShortcut(_ command: MindMapKeyboard.Command) -> Bool {
        switch command {
        case .previous, .next:
            guard !visible.isEmpty else { return false }
            selectedID = MindMapKeyboard.selection(from: selectedID, in: visible, moving: command)
        case .parentOrCollapse:
            guard let selectedID,
                  let index = visible.firstIndex(where: { $0.id == selectedID }) else {
                self.selectedID = visible.first?.id
                return !visible.isEmpty
            }
            if index + 1 < visible.count, visible[index + 1].depth > visible[index].depth {
                collapsed.insert(selectedID)
            } else if let parent = MindMapKeyboard.selection(
                from: selectedID, in: visible, moving: .parentOrCollapse
            ) {
                self.selectedID = parent
            } else { return false }
        case .childOrExpand:
            guard let selectedID else {
                self.selectedID = visible.first?.id
                return !visible.isEmpty
            }
            if collapsed.remove(selectedID) != nil {
                // The layout refresh makes the child available on the next press.
            } else if let child = MindMapKeyboard.selection(
                from: selectedID, in: visible, moving: .childOrExpand
            ) {
                self.selectedID = child
            } else { return false }
        case .addChild:
            guard !nodes.isEmpty else { return false }
            addChild()
        case .addSibling:
            guard !nodes.isEmpty else { return false }
            addSibling()
        case .promote:
            guard let updated = shiftedSource(deeper: false) else { return false }
            source = updated
            collapsed.removeAll()
        case .rename:
            guard selectedID != nil else { return false }
            beginRename()
        case .toggleBranch:
            guard let selectedID,
                  let index = nodes.firstIndex(where: { $0.id == selectedID }),
                  index + 1 < nodes.count,
                  nodes[index + 1].depth > nodes[index].depth else { return false }
            if !collapsed.insert(selectedID).inserted { collapsed.remove(selectedID) }
        case .deleteLeaf:
            guard let selectedID, let updated = MindMapOutline.deleteLeaf(in: source, nodeID: selectedID)
            else { return false }
            source = updated
            self.selectedID = nil
        case .deleteBranch:
            guard let selectedID, MindMapOutline.deleteListSubtree(in: source, nodeID: selectedID) != nil
            else { return false }
            branchDeleteCandidateID = selectedID
        case .fit:
            NotificationCenter.default.post(name: .pksMindMapFit, object: nil)
        case .zoomIn: zoom = clampedZoom(zoom + 0.15)
        case .zoomOut: zoom = clampedZoom(zoom - 0.15)
        case .clearSelection: selectedID = nil
        }
        if editingNodeID == nil, command != .deleteBranch { requestCanvasFocus() }
        return true
    }

    @ViewBuilder
    private func spatialCanvas(_ layout: MindMapLayoutSnapshot, exporting: Bool = false) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })
        // Build once per rendered map. Never reparse the full Markdown for each card.
        let allNodes = nodes
        let parentIDs = Set(allNodes.indices.dropLast().compactMap { index -> Int? in
            allNodes[index + 1].depth > allNodes[index].depth ? allNodes[index].id : nil
        })
        ZStack(alignment: .topLeading) {
            ForEach(layout.placements) { placement in
                if let parentID = placement.parentID, let parent = byID[parentID] {
                    connector(from: parent, to: placement)
                }
            }

            ForEach(layout.placements) { placement in
                nodeCard(placement.node, hasChildren: parentIDs.contains(placement.id), exporting: exporting)
                    .frame(width: placement.size.width, height: placement.size.height)
                    .position(placement.center)
                    .id(placement.id)
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
    private func nodeCard(_ node: MindMapNode, hasChildren: Bool, exporting: Bool = false) -> some View {
        let presentation = MindMapOutline.presentation(for: node.title)
        HStack(spacing: 9) {
            if hasChildren {
                if exporting {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Button {
                        selectedID = node.id
                        if !collapsed.insert(node.id).inserted { collapsed.remove(node.id) }
                        requestCanvasFocus()
                    } label: {
                        Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pks-mind-map-disclosure-\(node.id)")
                    .accessibilityLabel(language.text(
                        collapsed.contains(node.id) ? "Expand Branch" : "Collapse Branch"
                    ))
                }
            } else {
                Color.clear.frame(width: 10, height: 10)
            }

            if !exporting && editingNodeID == node.id {
                TextField(language.text("Node title"), text: $renameTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: node.depth == 0 ? 16 : 14, weight: .medium))
                    .focused($titleEditorFocused)
                    .onSubmit { finishRename(save: true) }
                    .onExitCommand { finishRename(save: false) }
                    .onKeyPress(.escape) {
                        finishRename(save: false)
                        return .handled
                    }
                    .accessibilityIdentifier("pks-mind-map-inline-title")
                    .onAppear {
                        Task { @MainActor in
                            await Task.yield()
                            titleEditorFocused = true
                        }
                    }
                Button {
                    finishRename(save: true)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .help(language.text("Save"))
                .accessibilityIdentifier("pks-mind-map-inline-save")
                Button {
                    finishRename(save: false)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(language.text("Cancel"))
                .accessibilityIdentifier("pks-mind-map-inline-cancel")
            } else {
                Text(presentation.title)
                    .font(.system(size: node.depth == 0 ? 16 : 14,
                                  weight: node.depth == 0 ? .semibold : .medium))
                    .lineLimit(2)
                    .accessibilityIdentifier("pks-mind-map-node-\(node.id)")
                    .accessibilityValue(!exporting && selectedID == node.id
                                        ? language.text("Selected") : "")
            }
            Spacer(minLength: 0)

            if !exporting, presentation.links.count == 1, let link = presentation.links.first {
                Button {
                    openLink(link.target)
                } label: {
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("\(language.text("Open linked note")) · \(link.label)")
                .accessibilityLabel("\(language.text("Open linked note")) \(link.label)")
            } else if !exporting, presentation.links.count > 1 {
                Menu {
                    ForEach(Array(presentation.links.enumerated()), id: \.offset) { _, link in
                        Button {
                            openLink(link.target)
                        } label: {
                            Label(link.label, systemImage: "link")
                        }
                        .help(link.target)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "link")
                        Text("\(presentation.links.count)")
                            .font(.caption2.monospacedDigit())
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(Color.primary.opacity(0.055), in: Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(language.text("Open linked note"))
                .accessibilityLabel("\(language.text("Open linked note")) \(presentation.links.count)")
            }
        }
        .padding(.horizontal, 13)
        .background(
            !exporting && selectedID == node.id
                ? Color.accentColor.opacity(0.16)
                : (node.depth == 0 ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)),
            in: RoundedRectangle(cornerRadius: node.depth == 0 ? 14 : 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: node.depth == 0 ? 14 : 11)
                .strokeBorder(
                    !exporting && dropTargetID == node.id
                        ? Color.accentColor
                        : (!exporting && selectedID == node.id ? Color.accentColor.opacity(0.60) : Color.primary.opacity(0.08)),
                    style: StrokeStyle(
                        lineWidth: !exporting && dropTargetID == node.id ? 2 : 1,
                        dash: !exporting && dropTargetID == node.id ? [5, 3] : []
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
                  let outcome = MindMapOutline.moveListSubtreeWithOutcome(
                    in: source, nodeID: draggedID, asChildOf: node.id
                  ) else { return false }
            source = outcome.source
            selectedID = outcome.movedNodeID
            collapsed.removeAll()
            dropTargetID = nil
            return true
        } isTargeted: { targeted in
            dropTargetID = targeted ? node.id : nil
        }
        .contextMenu {
            Button(language.text("Rename node"), systemImage: "pencil") {
                if editingNodeID != nil { finishRename(save: true) }
                selectedID = node.id
                beginRename()
            }
            Button(language.text("Link Note"), systemImage: "doc.text") {
                selectedID = node.id
                connectNote(node.id)
            }
            Button(language.text("Link Section"), systemImage: "text.badge.plus") {
                selectedID = node.id
                connectSection(node.id)
            }
            Button(language.text("Create Linked Note"), systemImage: "doc.badge.plus") {
                selectedID = node.id
                createLinkedNote(node.id)
            }
            Button(language.text("Show in Markdown"), systemImage: "text.cursor") {
                selectedID = node.id
                revealSource(node.id)
            }
            Button(language.text("Delete Branch"), systemImage: "trash", role: .destructive) {
                branchDeleteCandidateID = node.id
            }
            .disabled(MindMapOutline.deleteListSubtree(in: source, nodeID: node.id) == nil)
        }
        .onTapGesture {
            guard editingNodeID != node.id else { return }
            if editingNodeID != nil {
                finishRename(save: true)
                guard editingNodeID == nil else { return }
            }
            selectedID = node.id
            canvasFocused = true
        }
        .onTapGesture(count: 2) {
            guard editingNodeID != node.id else { return }
            if editingNodeID != nil {
                finishRename(save: true)
                guard editingNodeID == nil else { return }
            }
            selectedID = node.id
            beginRename()
        }
    }

    private func addChild() {
        guard let id = selectedID ?? nodes.first?.id,
              let updated = MindMapOutline.addChild(in: source, parentID: id) else { return }
        source = updated
        collapsed.removeAll()
        startEditingNode(id + 1, title: "New idea", created: true)
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
        collapsed.removeAll()
        startEditingNode(isList ? siblingLine : id + 1, title: "New idea", created: true)
    }

    private func deleteSelectedLeaf() {
        guard let id = selectedID,
              let updated = MindMapOutline.deleteLeaf(in: source, nodeID: id) else { return }
        source = updated
        selectedID = nil
    }

    private func exportMindNode() {
        let sourcePanel = NSOpenPanel()
        sourcePanel.title = language.text("Choose a MindNode Template")
        sourcePanel.message = language.text("A real MindNode document is needed to preserve native package structure. Verified package versions 7 and 9 are supported; the template remains unchanged.")
        sourcePanel.canChooseDirectories = true
        sourcePanel.canChooseFiles = true
        sourcePanel.allowsMultipleSelection = false
        guard sourcePanel.runModal() == .OK, let template = sourcePanel.url else { return }

        let savePanel = NSSavePanel()
        savePanel.title = language.text("Export Native MindNode")
        savePanel.directoryURL = template.deletingLastPathComponent()
        savePanel.nameFieldStringValue = "Mind Map.mindnode"
        savePanel.allowedContentTypes = [UTType(filenameExtension: "mindnode", conformingTo: .package) ?? .package]
        guard savePanel.runModal() == .OK, let destination = savePanel.url else { return }
        do {
            try MindNodePackage.exportOutline(source, usingTemplate: template, to: destination)
            interchangeError = language.text("New MindNode package exported. The original template and Markdown were not changed.")
        } catch {
            interchangeError = error.localizedDescription
        }
    }

    private func importMindNode() {
        let panel = NSOpenPanel()
        panel.title = language.text("Import MindNode Package")
        panel.message = language.text("Select a .mindnode package. Only the node hierarchy is imported; original files are not modified.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let markdown = try MindNodePackage.importOutline(from: url)
            if importOutline(markdown, url.deletingPathExtension().lastPathComponent) {
                interchangeError = language.text("MindNode hierarchy imported into a new Markdown note. Themes, images, notes, tasks and cross-connections are not imported.")
            }
        } catch {
            interchangeError = error.localizedDescription
        }
    }

    private func importOPML() {
        let panel = NSOpenPanel()
        panel.title = language.text("Import Mind Map from OPML")
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try MindMapInterchange.importOPML(Data(contentsOf: url))
            _ = importOutline(text, url.deletingPathExtension().lastPathComponent)
        } catch {
            interchangeError = error.localizedDescription
        }
    }

    private func exportOPML() {
        do {
            let data = try MindMapInterchange.exportOPML(source)
            let panel = NSSavePanel()
            panel.title = language.text("Export for MindNode (OPML)")
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
        // Export the complete Markdown outline, independent of the user's collapsed viewport.
        let layout = MindMapSpatialLayout.layout(nodes)
        let size = layout.size
        guard size.width * size.height <= 20_000_000 else {
            interchangeError = language.text("This map is too large for a single PNG. Try PDF.")
            return
        }
        let content = spatialCanvas(layout, exporting: true)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            interchangeError = language.text("Cannot render this mind map as an image.")
            return
        }
        saveExport(data, type: .png, extensionName: "png")
    }

    private func exportPDF() {
        guard !nodes.isEmpty else { return }
        let layout = MindMapSpatialLayout.layout(nodes)
        let size = layout.size
        let content = spatialCanvas(layout, exporting: true)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height)
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let data = view.dataWithPDF(inside: view.bounds)
        guard !data.isEmpty else {
            interchangeError = language.text("Cannot render this mind map as a PDF.")
            return
        }
        saveExport(data, type: .pdf, extensionName: "pdf")
    }

    private func saveExport(_ data: Data, type: UTType, extensionName: String) {
        let panel = NSSavePanel()
        panel.title = language.text("Export Mind Map")
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "Mind Map.\(extensionName)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) }
        catch { interchangeError = error.localizedDescription }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(1.80, max(0.45, value))
    }

    private func rebuildVisibleLayout() {
        var hiddenBelow: Int?
        let filtered = nodes.filter { node in
            if let depth = hiddenBelow {
                if node.depth > depth { return false }
                hiddenBelow = nil
            }
            if collapsed.contains(node.id) { hiddenBelow = node.depth }
            return true
        }
        visible = filtered
        mapLayout = MindMapSpatialLayout.layout(filtered)
    }

    private func fitToContent(viewport: CGSize) {
        guard !mapLayout.placements.isEmpty else { return }
        let horizontal = max(0.1, (viewport.width - 36) / mapLayout.size.width)
        let vertical = max(0.1, (viewport.height - 36) / mapLayout.size.height)
        zoom = clampedZoom(min(horizontal, vertical, 1.25))
    }

    private func beginRename() {
        guard let node = nodes.first(where: { $0.id == selectedID }) else { return }
        startEditingNode(node.id, title: node.title)
    }

    private func startEditingNode(_ id: Int, title: String, created: Bool = false) {
        selectedID = id
        renameTitle = title
        editingNodeID = id
        editingCreatedNodeID = created ? id : nil
        canvasFocused = false
        titleEditorFocused = false
    }

    private func finishRename(save: Bool) {
        guard let id = editingNodeID else { return }
        if save {
            // Invalid titles stay in the inline editor instead of silently
            // committing the placeholder/original text.
            guard let updated = MindMapOutline.rename(in: source, nodeID: id, to: renameTitle) else {
                return
            }
            source = updated
        } else if editingCreatedNodeID == id,
                  let updated = MindMapOutline.deleteLeaf(in: source, nodeID: id) {
            // Add Child/Sibling inserts a safe leaf before inline naming. Cancel
            // must restore the original Markdown rather than keep "New idea".
            source = updated
            selectedID = nodes.first?.id
        }
        editingNodeID = nil
        editingCreatedNodeID = nil
        titleEditorFocused = false
        canvasFocused = false
        Task { @MainActor in
            await Task.yield()
            canvasFocused = true
        }
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
