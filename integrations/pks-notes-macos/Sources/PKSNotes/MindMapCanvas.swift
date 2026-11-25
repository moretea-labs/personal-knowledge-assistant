import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Commands are resolved once from a focused canvas. Inline TextField editing
// bypasses this dispatcher so native text editing retains its own shortcuts.
enum MindMapKeyboard {
    enum Command: Equatable {
        case previous, next, parentOrCollapse, childOrExpand
        case moveUp, moveDown, addChild, addSibling, promote, demote, rename, toggleBranch
        case deleteLeaf, deleteBranch, boldTitle, italicTitle, toggleTask
        case fit, zoomIn, zoomOut, clearSelection
    }

    static func command(for key: KeyEquivalent, modifiers: EventModifiers) -> Command? {
        if modifiers.contains(.option) {
            guard !modifiers.contains(.control),
                  !modifiers.contains(.command),
                  !modifiers.contains(.shift) else { return nil }
            switch key {
            case .upArrow: return .moveUp
            case .downArrow: return .moveDown
            case .leftArrow: return .promote
            case .rightArrow: return .demote
            default: return nil
            }
        }
        guard !modifiers.contains(.control) else { return nil }
        if modifiers.contains(.command) {
            // Cmd+B / Cmd+I / Cmd+Return are owned by the app menu so they
            // work without relying on canvas first-responder focus. The menu
            // routes them back here only while a Mind Map is actually mounted.
            if key == .delete, !modifiers.contains(.shift) { return .deleteBranch }
            if key == "0", !modifiers.contains(.shift) { return .fit }
            if key == "-", !modifiers.contains(.shift) { return .zoomOut }
            if key == "=" || key == "+" { return .zoomIn }
            return nil
        }
        // macOS consumes Shift+Tab as backward focus traversal before a
        // SwiftUI canvas onKeyPress, so do not advertise an unreachable shortcut.
        if key == .tab, !modifiers.contains(.shift) { return .addChild }
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

/// Undo an uncommitted list-node insertion only in the exact draft where
/// the temporary placeholder was created. Also used on canvas disappearance.
enum MindMapPendingCreation {
    static func rollback(in source: String, expected: String, nodeID: Int) -> String? {
        guard source == expected,
              MindMapOutline.nodes(in: source).contains(where: {
                  $0.id == nodeID && $0.title == "New idea"
              }) else { return nil }
        return MindMapOutline.deleteLeaf(in: source, nodeID: nodeID)
    }
}

/// Visual-only preference: node hierarchy/links still come from Markdown.
enum MindMapVisualStyle: String, CaseIterable, Identifiable, Equatable, Sendable {
    case classic, colorful, minimal
    static let defaultsKey = "PKSNotesMindMapStyle"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .classic: "Classic"
        case .colorful: "Colorful"
        case .minimal: "Minimal"
        }
    }
    var symbol: String {
        switch self {
        case .classic: "square.on.square"
        case .colorful: "paintpalette"
        case .minimal: "line.diagonal"
        }
    }
    /// Stable branch accents follow the original Markdown order, even when
    /// a subtree is collapsed; there is no second stored hierarchy.
    static func branchIndices(_ nodes: [MindMapNode]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var currentBranch = 0
        for node in nodes {
            if node.depth == 0 { currentBranch = 0 }
            else if node.depth == 1 { currentBranch += 1 }
            result[node.id] = currentBranch
        }
        return result
    }

    var usesBranchColors: Bool { self == .colorful }
    var angularConnectors: Bool { self == .minimal }
    var connectorWidth: CGFloat {
        switch self {
        case .classic: 1.25
        case .colorful: 2.0
        case .minimal: 1.2
        }
    }
    var connectorOpacity: Double {
        switch self {
        case .classic: 0.30
        case .colorful: 0.50
        case .minimal: 0.34
        }
    }
    var cardRadius: CGFloat { self == .minimal ? 6 : (self == .colorful ? 15 : 18) }
    var nodeShadowRadius: CGFloat { self == .colorful ? 2 : 0 }
    var nodeShadowYOffset: CGFloat { self == .colorful ? 1 : 0 }

    func nodeShadowOpacity(depth: Int) -> Double {
        guard self == .colorful else { return 0 }
        return depth == 0 ? 0.018 : 0.008
    }

    var unselectedOutlineWidth: CGFloat {
        self == .classic ? 0.8 : (self == .minimal ? 0.8 : 0.85)
    }

    /// Keep the work surface distinct from the system control fill used by node cards.
    /// The restrained change is intentionally limited to the Classic default style.
    var canvasBackgroundOpacity: Double {
        switch self {
        case .classic: 0.035
        case .colorful: 0.012
        case .minimal: 0.005
        }
    }

    // Reuse the palette across nodes and connectors; large maps must not
    // allocate six SwiftUI Color values on every node render.
    private static let branchPalette: [Color] = [
        Color(red: 0.25, green: 0.49, blue: 0.91),
        Color(red: 0.12, green: 0.65, blue: 0.54),
        Color(red: 0.64, green: 0.41, blue: 0.87),
        Color(red: 0.89, green: 0.53, blue: 0.22),
        Color(red: 0.88, green: 0.39, blue: 0.57),
        Color(red: 0.26, green: 0.64, blue: 0.80)
    ]

    func branchColor(_ index: Int) -> Color {
        guard usesBranchColors else { return .accentColor }
        return Self.branchPalette[index % Self.branchPalette.count]
    }

    func fill(depth: Int, branch: Int, scheme: ColorScheme) -> Color {
        switch self {
        case .classic:
            return depth == 0
                ? .accentColor.opacity(scheme == .dark ? 0.16 : 0.10)
                : Color(nsColor: .controlBackgroundColor)
        case .colorful:
            return branchColor(branch).opacity(depth == 0
                ? (scheme == .dark ? 0.28 : 0.19)
                : (scheme == .dark ? 0.23 : 0.13))
        case .minimal:
            return depth == 0
                ? Color.primary.opacity(scheme == .dark ? 0.11 : 0.065)
                : (scheme == .dark ? Color(red: 0.14, green: 0.14, blue: 0.15) : .white)
        }
    }

    func outlineOpacity(depth: Int) -> Double {
        switch self {
        case .classic: 0.10
        case .colorful: depth == 0 ? 0.68 : 0.44
        case .minimal: depth == 0 ? 0.14 : 0.09
        }
    }

    func outline(depth: Int, branch: Int) -> Color {
        switch self {
        case .classic, .minimal: Color.primary.opacity(outlineOpacity(depth: depth))
        case .colorful: branchColor(branch).opacity(outlineOpacity(depth: depth))
        }
    }

    var fontDesign: Font.Design {
        switch self {
        case .classic: .default
        case .colorful: .rounded
        case .minimal: .serif
        }
    }

    /// Use the same system font design for AppKit text measurement as SwiftUI
    /// uses when drawing the node title. Otherwise rounded/serif presets can
    /// wrap differently from the geometry that positioned neighboring cards.
    func measurementFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let design: NSFontDescriptor.SystemDesign
        switch self {
        case .classic: return base
        case .colorful: design = .rounded
        case .minimal: design = .serif
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// Node emphasis uses standard Markdown markup, not additional style metadata.
/// The canvas formats titles for display while inline editing still shows source.
enum MindMapTitleEmphasis {
    static func toggle(_ title: String, marker: String) -> String {
        guard marker == "**" || marker == "*", !title.isEmpty else { return title }
        // Task markers must remain at the beginning of the list item. Styling
        // wraps only its label, or the checkbox ceases to be valid Markdown.
        if let task = MindMapTaskNode.parse(title) {
            guard !task.title.isEmpty else { return title }
            return String(title.prefix(3)) + " " + toggle(task.title, marker: marker)
        }
        // Applying italic to an already bold title adds italic; a single
        // asterisk must not strip half of the existing double-asterisk pair.
        if marker == "*", title.hasPrefix("**"), title.hasSuffix("**"),
           !title.hasPrefix("***"), !title.hasSuffix("***") {
            return marker + title + marker
        }
        if title.hasPrefix(marker), title.hasSuffix(marker),
           title.count > marker.count * 2 {
            return String(title.dropFirst(marker.count).dropLast(marker.count))
        }
        return marker + title + marker
    }

    static func display(_ title: String) -> AttributedString {
        guard title.contains("*") || title.contains("_") ||
              title.contains("~") || title.utf8.contains(96) ||
              title.contains("\\") || title.contains("&") else {
            return AttributedString(title)
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: title, options: options))
            ?? AttributedString(title)
    }
}

enum MindMapExportBudget {
    static let pngScale: CGFloat = 2
    static let maxRasterPixels: CGFloat = 20_000_000

    static func allowsPNG(size: CGSize, scale: CGFloat = pngScale) -> Bool {
        guard size.width > 0, size.height > 0, scale > 0,
              size.width.isFinite, size.height.isFinite, scale.isFinite else {
            return false
        }
        return size.width * size.height * scale * scale <= maxRasterPixels
    }
}

struct MindMapBranchDeleteCandidate: Equatable {
    let nodeID: Int
    let source: String
    let revision: UInt64

    func matches(source: String, revision: UInt64, nodeExists: Bool) -> Bool {
        self.source == source && self.revision == revision && nodeExists
    }
}

struct MindMapNodeDragPayload: Codable, Transferable, Equatable, Sendable {
    let canvasSessionID: UUID
    let revision: UInt64
    let nodeID: Int

    func resolve(
        in ids: Set<Int>,
        target: Int,
        canvasSessionID: UUID,
        revision: UInt64
    ) -> Int? {
        guard self.canvasSessionID == canvasSessionID,
              self.revision == revision,
              ids.contains(nodeID),
              ids.contains(target) else { return nil }
        return nodeID
    }
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

enum MindMapSelectionAccessibility {
    static func selectionTraits(isSelected: Bool) -> AccessibilityTraits {
        isSelected ? .isSelected : []
    }
}

enum MindMapDisclosureAccessibility {
    static func accessibilityValue(isExpanded: Bool, language: AppLanguage) -> String {
        language.text(isExpanded ? "Expanded" : "Collapsed")
    }
}

enum MindMapNodeAccessibility {
    static func accessibilityValue(
        level: Int,
        isSelected: Bool,
        language: AppLanguage
    ) -> String {
        let levelDescription = "\(language.text("Level")) \(max(1, level))"
        guard isSelected else { return levelDescription }
        return "\(language.text("Selected")) · \(levelDescription)"
    }
}

enum MindMapTaskAccessibility {
    static func accessibilityValue(isCompleted: Bool, language: AppLanguage) -> String {
        language.text(isCompleted ? "Completed" : "Not completed")
    }
}

enum MindMapDocumentProjectionState {
    static func hasChanged(from previous: URL?, to current: URL?) -> Bool {
        guard let previous, let current else { return previous != current }
        return previous.standardizedFileURL != current.standardizedFileURL
    }

    static func rebasedCollapsedNodeIDs(
        _ collapsed: Set<Int>,
        from previousDocument: URL?,
        to currentDocument: URL?,
        lineIndexMap: [Int: Int]
    ) -> Set<Int> {
        guard !hasChanged(from: previousDocument, to: currentDocument) else { return [] }
        return Set(collapsed.compactMap { lineIndexMap[$0] })
    }
}

/// An editable Markdown-backed mind-map canvas. Markdown remains the only document authority.
struct MindMapCanvas: View {
    @Environment(\.notesLanguage) private var language
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: NotesModel
    @AppStorage(MindMapVisualStyle.defaultsKey) private var mapStyleID = MindMapVisualStyle.classic.rawValue
    @AppStorage(MindMapLayoutDensity.defaultsKey) private var layoutDensityID = MindMapLayoutDensity.standard.rawValue
    @Binding var source: String
    @Binding var selectedID: Int?
    let revision: UInt64
    let validateSource: (UInt64, String) -> Bool
    let hidesNodeDetails: Bool
    let activeMarkdownTextView: () -> NSTextView?
    let openLink: (String) -> Void
    let linkForDroppedFile: (URL) -> String?
    let connectNote: (Int) -> Void
    let connectSection: (Int) -> Void
    let createLinkedNote: (Int) -> Void
    let revealSource: (Int) -> Void
    let importOutline: (String, String, [MindNodePackage.ImportedImage], [MindNodePackage.ImportedPDF]) -> Bool
    @State private var renameTitle = ""
    @State private var editingNodeID: Int?
    @State private var editingCreatedNodeID: Int?
    // Exact transient draft guard: never remove a node from another note if
    // navigation replaces the model's draft while an inline edit is pending.
    @State private var createdNodeDraftSnapshot: String?
    @State private var interchangeError: String?
    @State private var showingShortcuts = false
    @State private var branchDeleteCandidate: MindMapBranchDeleteCandidate?
    @State private var collapsed: Set<Int> = []
    @State private var zoom: CGFloat = 1.0
    @State private var viewportOffset: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var gestureBaseOffset: CGSize?
    @GestureState private var canvasDrag: CGSize = .zero
    @State private var showingNodeDetails = false
    @State private var didInitializeViewport = false
    @State private var mapContentVersion = 0
    @State private var dragSessionID = UUID()
    @State private var dropTargetID: Int?
    @State private var gestureBaseZoom: CGFloat?
    @State private var nodes: [MindMapNode] = []
    @State private var lineStartOffsets: [Int] = [0]
    @State private var nodePresentations: [Int: MindMapNodePresentation] = [:]
    @State private var nodeParentIDs: Set<Int> = []
    @State private var visible: [MindMapNode] = []
    @State private var mapLayout = MindMapSpatialLayout.layout([])
    @State private var layoutGeneration = 0
    @State private var isLayoutRebuilding = false
    @State private var projectionReady = false
    @State private var projectedRevision: UInt64?
    @State private var projectedDocumentURL: URL?
    @State private var suppressNextCollapsedReveal = false
    @State private var canMoveUp = false
    @State private var canMoveDown = false
    @State private var canPromote = false
    @State private var canDemote = false
    @State private var canDeleteLeaf = false
    @FocusState private var canvasFocused: Bool
    @FocusState private var titleEditorFocused: Bool

    private var mapStyle: MindMapVisualStyle {
        MindMapVisualStyle(rawValue: mapStyleID) ?? .classic
    }

    private var branchDeleteCandidateIsCurrent: Bool {
        guard let candidate = branchDeleteCandidate,
              projectionIsCurrent,
              candidate.matches(
                  source: source,
                  revision: revision,
                  nodeExists: nodes.contains(where: { $0.id == candidate.nodeID })
              ) else { return false }
        return validateSource(candidate.revision, candidate.source)
    }

    private var layoutDensity: MindMapLayoutDensity {
        MindMapLayoutDensity(rawValue: layoutDensityID) ?? .standard
    }

    private var projectionBelongsToSelectedDocument: Bool {
        !MindMapDocumentProjectionState.hasChanged(
            from: projectedDocumentURL,
            to: model.selected?.standardizedFileURL
        )
    }

    private var projectionIsCurrent: Bool {
        projectionReady
            && projectedRevision == revision
            && projectionBelongsToSelectedDocument
    }

    /// The expensive node and connector tree does not change when the user pans
    /// or magnifies the viewport. Keep it out of those per-frame view updates.
    private struct ProjectionTaskKey: Hashable {
        let documentURL: URL?
        let revision: UInt64
    }

    private struct MapContentKey: Equatable {
        let revision: UInt64
        let layoutVersion: Int
        let selectedID: Int?
        let editingNodeID: Int?
        let renameTitle: String
        let dropTargetID: Int?
        let styleID: String
        let densityID: String
        let scheme: ColorScheme
        let language: AppLanguage
        let projectionIsCurrent: Bool
        let visibleNodeIDs: Set<Int>
    }

    private struct MapNodeCardsSnapshot: View, Equatable {
        let owner: MindMapCanvas
        let layout: MindMapLayoutSnapshot
        let key: MapContentKey

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }

        var body: some View {
            owner.nodeCards(layout, visibleNodeIDs: key.visibleNodeIDs)
        }
    }

    /// Connector geometry is stable while the canvas is translated. Reuse the
    /// rendered Canvas until the visible edge set or map geometry actually changes.
    private struct MapConnectorSnapshot: View, Equatable {
        let size: CGSize
        let connectors: [MindMapConnector]
        let style: MindMapVisualStyle
        let layoutVersion: Int

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.size == rhs.size
                && lhs.connectors == rhs.connectors
                && lhs.style == rhs.style
                && lhs.layoutVersion == rhs.layoutVersion
        }

        var body: some View {
            Canvas { context, _ in
                for connector in connectors {
                    var path = Path()
                    path.move(to: connector.start)
                    if connector.angular {
                        path.addLine(to: connector.control1)
                        path.addLine(to: connector.control2)
                        path.addLine(to: connector.end)
                    } else {
                        path.addCurve(
                            to: connector.end,
                            control1: connector.control1,
                            control2: connector.control2
                        )
                    }
                    let color = style.usesBranchColors
                        ? style.branchColor(connector.branch).opacity(style.connectorOpacity)
                        : Color.secondary.opacity(style.connectorOpacity)
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(
                            lineWidth: connector.lineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var viewportVisibleNodeIDs: Set<Int> {
        MindMapViewportGeometry.visibleNodeIDs(
            in: mapLayout,
            viewport: viewportSize,
            offset: CGSize(
                width: viewportOffset.width + canvasDrag.width,
                height: viewportOffset.height + canvasDrag.height
            ),
            zoom: zoom,
            overscan: 320
        )
    }

    private var pinnedNodeIDs: Set<Int> {
        Set([selectedID, editingNodeID, dropTargetID].compactMap { $0 })
    }

    private var usesOverviewNodeRendering: Bool {
        MindMapViewportRenderingPolicy.usesOverviewNodeRendering(
            zoom: zoom,
            visibleNodeCount: viewportVisibleNodeIDs.count
        )
    }

    private var visibleNodeIDs: Set<Int> {
        MindMapViewportRenderingPolicy.interactiveNodeIDs(
            visibleNodeIDs: viewportVisibleNodeIDs,
            pinnedIDs: pinnedNodeIDs,
            zoom: zoom
        )
    }

    private var mapContentKey: MapContentKey {
        .init(
            revision: revision,
            layoutVersion: mapContentVersion,
            selectedID: selectedID,
            editingNodeID: editingNodeID,
            renameTitle: renameTitle,
            dropTargetID: dropTargetID,
            styleID: mapStyleID,
            densityID: layoutDensityID,
            scheme: colorScheme,
            language: language,
            projectionIsCurrent: projectionIsCurrent,
            visibleNodeIDs: visibleNodeIDs
        )
    }

    private struct ActionAvailabilityKey: Hashable {
        let revision: UInt64
        let selectedID: Int?
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                GeometryReader { viewport in
                    ZStack {
                        Color.primary.opacity(mapStyle.canvasBackgroundOpacity)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 3)
                                    .updating($canvasDrag) { value, state, _ in
                                        state = value.translation
                                    }
                                    .onEnded { value in
                                        viewportOffset.width += value.translation.width
                                        viewportOffset.height += value.translation.height
                                    }
                            )
                            .onTapGesture { selectedID = nil }

                        if !projectionReady || !projectionBelongsToSelectedDocument {
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text(language.text("Preparing mind map…"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
                        } else {
                            ZStack(alignment: .topLeading) {
                                connectorViewportCanvas(mapLayout, viewport: viewport.size)
                                if usesOverviewNodeRendering {
                                    overviewNodeViewportCanvas(mapLayout, viewport: viewport.size)
                                        .contentShape(Rectangle())
                                        .onTapGesture(coordinateSpace: .local) { location in
                                            focusNodeAtOverviewPoint(
                                                location, layout: mapLayout, viewport: viewport.size
                                            )
                                        }
                                        .allowsHitTesting(projectionIsCurrent)
                                        .accessibilityHidden(!projectionIsCurrent)
                                } else {
                                    interactiveCanvas(mapLayout)
                                        .allowsHitTesting(projectionIsCurrent)
                                        .accessibilityHidden(!projectionIsCurrent)
                                        .scaleEffect(zoom)
                                        .position(
                                            x: viewport.size.width / 2 + viewportOffset.width + canvasDrag.width,
                                            y: viewport.size.height / 2 + viewportOffset.height + canvasDrag.height
                                        )
                                }
                            }
                            .frame(width: viewport.size.width, height: viewport.size.height)
                        }
                    }
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .clipped()
                    .background {
                        MindMapWheelCapture { delta in
                            viewportOffset.width += delta.width
                            viewportOffset.height += delta.height
                        }
                    }
                    .accessibilityIdentifier("pks-mind-map-canvas")
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                if gestureBaseZoom == nil {
                                    gestureBaseZoom = zoom
                                    gestureBaseOffset = viewportOffset
                                }
                                let next = clampedZoom((gestureBaseZoom ?? zoom) * value.magnification)
                                viewportOffset = MindMapViewportGeometry.offsetPreservingAnchor(
                                    gestureBaseOffset ?? viewportOffset,
                                    from: gestureBaseZoom ?? zoom,
                                    to: next,
                                    anchor: CGPoint(
                                        x: value.startAnchor.x * viewport.size.width,
                                        y: value.startAnchor.y * viewport.size.height
                                    ),
                                    viewport: viewport.size
                                )
                                zoom = next
                            }
                            .onEnded { _ in
                                gestureBaseZoom = nil
                                gestureBaseOffset = nil
                            }
                    )
                    .onAppear {
                        viewportSize = viewport.size
                        if projectionReady && !didInitializeViewport {
                            didInitializeViewport = focusOnRoot(viewport: viewport.size)
                        }
                    }
                    .onChange(of: viewport.size) { oldSize, size in
                        // Refit only while the map is still at its untouched opening overview.
                        // A manual pan, zoom or selection keeps its current content position.
                        let shouldRefocus: Bool
                        if let root = mapLayout.placements.first(where: { $0.parentID == nil }) {
                            shouldRefocus = MindMapViewportGeometry.isAtInitialRootViewport(
                                root: root,
                                visiblePlacements: [root],
                                mapSize: mapLayout.size,
                                viewport: oldSize,
                                zoom: zoom,
                                offset: viewportOffset
                            )
                        } else {
                            shouldRefocus = false
                        }
                        viewportSize = size
                        if shouldRefocus, projectionIsCurrent {
                            _ = focusOnRoot(viewport: size)
                        }
                    }
                    .onChange(of: projectionReady) { _, ready in
                        if ready && !didInitializeViewport {
                            didInitializeViewport = focusOnRoot(viewport: viewport.size)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .pksMindMapFit)) { _ in
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            _ = fitToContent(viewport: viewport.size)
                        }
                    }
                    .onChange(of: selectedID) { _, selected in
                        guard let selected,
                              let position = mapLayout.placements.first(where: { $0.id == selected }) else { return }
                        syncMarkdownCaretFromMap(selected)
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            viewportOffset = MindMapViewportGeometry.centeredOffset(
                                for: position.center, mapSize: mapLayout.size, zoom: zoom
                            )
                        }
                    }
                    .onChange(of: visible) { _, rows in
                        guard let selected = editingNodeID ?? selectedID,
                              rows.contains(where: { $0.id == selected }),
                              let position = mapLayout.placements.first(where: { $0.id == selected }) else { return }
                        viewportOffset = MindMapViewportGeometry.centeredOffset(
                            for: position.center, mapSize: mapLayout.size, zoom: zoom
                        )
                    }
                }
                if showingNodeDetails && !hidesNodeDetails,
                   let selectedID,
                   let node = nodes.first(where: { $0.id == selectedID }) {
                    Divider()
                        .transition(reduceMotion ? .identity : .opacity)
                    nodeDetails(node)
                        .frame(width: 270)
                        .allowsHitTesting(projectionIsCurrent)
                        .accessibilityHidden(!projectionIsCurrent)
                        .transition(
                            reduceMotion
                                ? .identity
                                : .move(edge: .trailing).combined(with: .opacity)
                        )
                }
            }
        }
        .confirmationDialog(
            language.text("Delete selected branch?"),
            isPresented: Binding(
                get: { branchDeleteCandidate != nil },
                set: { if !$0 { branchDeleteCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(language.text("Delete Branch"), role: .destructive) {
                if branchDeleteCandidateIsCurrent,
                   let candidate = branchDeleteCandidate,
                   let updated = MindMapOutline.deleteNodeSubtree(
                       in: source, nodeID: candidate.nodeID
                   ) {
                    source = updated
                    selectedID = nil
                } else if branchDeleteCandidate != nil {
                    interchangeError = language.text(
                        "The note changed before the branch was deleted. Select the branch again."
                    )
                }
                branchDeleteCandidate = nil
                restoreCanvasFocusAfterMenu()
            }
            .disabled(!branchDeleteCandidateIsCurrent)
            Button(language.text("Cancel"), role: .cancel) {
                branchDeleteCandidate = nil
                restoreCanvasFocusAfterMenu()
            }
        } message: {
            Text(language.text("The selected section, its child nodes and attached Markdown content will be removed from this note."))
        }
        .alert(language.text("Mind Map"), isPresented: Binding(
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
        .onReceive(NotificationCenter.default.publisher(
            for: NSTextView.didChangeSelectionNotification
        )) { notification in
            syncSelectedNodeFromMarkdownEditor(notification.object as? NSTextView)
        }
        .task(id: ProjectionTaskKey(
            documentURL: model.selected?.standardizedFileURL,
            revision: revision
        )) {
            let documentURL = model.selected?.standardizedFileURL
            let documentChanged = MindMapDocumentProjectionState.hasChanged(
                from: projectedDocumentURL, to: documentURL
            )
            let input = source
            let sourceRevision = revision
            let previousNodes = documentChanged ? [] : nodes
            let createdSourceSnapshot = documentChanged ? nil : createdNodeDraftSnapshot
            if documentChanged || nodes.isEmpty { projectionReady = false }

            let parser = Task.detached(priority: .userInitiated) {
                () -> (nodes: [MindMapNode], lineStartOffsets: [Int],
                       presentations: [Int: MindMapNodePresentation], parentIDs: Set<Int>,
                       lineIndexMap: [Int: Int], createdNodeLineIndexMap: [Int: Int])? in
                let nodes = MindMapOutline.nodes(in: input)
                guard !Task.isCancelled else { return nil }
                let lineStartOffsets = MindMapOutline.lineStartOffsets(in: input)
                guard !Task.isCancelled else { return nil }
                let presentations = MindMapOutline.presentations(in: input, nodes: nodes)
                guard !Task.isCancelled else { return nil }
                let parentIDs = MindMapOutline.parentIDs(in: nodes)
                guard !Task.isCancelled else { return nil }
                let lineIndexMap = MindMapOutline.lineIndexMap(from: previousNodes, to: nodes)
                guard !Task.isCancelled else { return nil }
                let createdNodeLineIndexMap = createdSourceSnapshot.map {
                    MindMapOutline.lineIndexMap(from: MindMapOutline.nodes(in: $0), to: nodes)
                } ?? [:]
                guard !Task.isCancelled else { return nil }
                return (
                    nodes: nodes,
                    lineStartOffsets: lineStartOffsets,
                    presentations: presentations,
                    parentIDs: parentIDs,
                    lineIndexMap: lineIndexMap,
                    createdNodeLineIndexMap: createdNodeLineIndexMap
                )
            }
            let projection = await withTaskCancellationHandler {
                await parser.value
            } onCancel: {
                parser.cancel()
            }
            guard let projection, !Task.isCancelled, revision == sourceRevision,
                  model.selected?.standardizedFileURL == documentURL else { return }

            let oldNodeIDs = Set(previousNodes.map(\.id))
            let newNodeIDs = Set(projection.nodes.map(\.id))
            func rebaseNodeID(_ id: Int?) -> Int? {
                guard !documentChanged, let id else { return nil }
                if oldNodeIDs.contains(id) { return projection.lineIndexMap[id] }
                return newNodeIDs.contains(id) ? id : nil
            }

            let rebasedCollapsed = MindMapDocumentProjectionState.rebasedCollapsedNodeIDs(
                collapsed,
                from: projectedDocumentURL,
                to: documentURL,
                lineIndexMap: projection.lineIndexMap
            )
            let rebasedCreatedNodeID = documentChanged
                ? nil : editingCreatedNodeID.flatMap { projection.createdNodeLineIndexMap[$0] }
            let isEditingCreatedNode = !documentChanged && editingCreatedNodeID != nil
            let rebasedSelectedID = documentChanged ? nil : (
                isEditingCreatedNode && selectedID == editingCreatedNodeID
                    ? rebasedCreatedNodeID : rebaseNodeID(selectedID)
            )
            let rebasedEditingNodeID = documentChanged ? nil : (
                isEditingCreatedNode && editingNodeID == editingCreatedNodeID
                    ? rebasedCreatedNodeID : rebaseNodeID(editingNodeID)
            )
            let currentDeleteCandidate = documentChanged ? nil : branchDeleteCandidate.flatMap { candidate in
                candidate.matches(
                    source: input,
                    revision: sourceRevision,
                    nodeExists: projection.nodes.contains(where: { $0.id == candidate.nodeID })
                ) ? candidate : nil
            }
            let rebasedDropTargetID = rebaseNodeID(dropTargetID)
            let collapsedChanged = rebasedCollapsed != collapsed

            nodes = projection.nodes
            lineStartOffsets = projection.lineStartOffsets
            nodePresentations = projection.presentations
            nodeParentIDs = projection.parentIDs
            projectedRevision = sourceRevision
            projectedDocumentURL = documentURL
            selectedID = rebasedSelectedID
            editingNodeID = rebasedEditingNodeID
            editingCreatedNodeID = rebasedCreatedNodeID
            branchDeleteCandidate = currentDeleteCandidate
            dropTargetID = rebasedDropTargetID
            if editingNodeID == nil && editingCreatedNodeID == nil {
                renameTitle = ""
            }
            if editingCreatedNodeID == nil {
                createdNodeDraftSnapshot = nil
            }

            if documentChanged {
                showingNodeDetails = false
                interchangeError = nil
                zoom = 1
                viewportOffset = .zero
                didInitializeViewport = false
                gestureBaseOffset = nil
                gestureBaseZoom = nil
                dragSessionID = UUID()
                suppressNextCollapsedReveal = collapsedChanged
            }
            if collapsedChanged {
                collapsed = rebasedCollapsed
            }
            if documentChanged || !collapsedChanged {
                await rebuildVisibleLayout()
            }
            if documentChanged {
                didInitializeViewport = focusOnRoot(viewport: viewportSize)
            }
            projectionReady = true
            syncSelectedNodeFromMarkdownEditor(
                NSApp.keyWindow?.firstResponder as? NSTextView
            )
        }
        .onChange(of: collapsed) { oldValue, newValue in
            if suppressNextCollapsedReveal {
                suppressNextCollapsedReveal = false
                return
            }
            let changedIDs = oldValue.symmetricDifference(newValue)
            let focusNodeID: Int?
            if changedIDs.count == 1,
               let changedID = changedIDs.first,
               oldValue.contains(changedID),
               !newValue.contains(changedID) {
                focusNodeID = changedID
            } else {
                focusNodeID = nil
            }

            isLayoutRebuilding = true
            Task { @MainActor in
                await rebuildVisibleLayout(animated: true)
                // Expanding a branch changes the vertical geometry of the whole
                // subtree. Keep the branch that was just opened in view so its
                // newly revealed descendants are reachable immediately.
                guard let focusNodeID,
                      let position = mapLayout.placements.first(where: { $0.id == focusNodeID })
                else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    viewportOffset = MindMapViewportGeometry.centeredOffset(
                        for: position.center,
                        mapSize: mapLayout.size,
                        zoom: zoom
                    )
                }
            }
        }
        .onChange(of: mapStyleID) { _, _ in
            isLayoutRebuilding = true
            Task { @MainActor in await rebuildVisibleLayout() }
        }
        .onChange(of: layoutDensityID) { _, _ in
            isLayoutRebuilding = true
            Task { @MainActor in await rebuildVisibleLayout() }
        }
        .task(id: ActionAvailabilityKey(revision: revision, selectedID: selectedID)) {
            canMoveUp = false
            canMoveDown = false
            canPromote = false
            canDemote = false
            canDeleteLeaf = false
            guard let selectedID else { return }
            let input = source
            let sourceRevision = revision
            let availability = await Task.detached(priority: .utility) {
                MindMapOutline.actionAvailability(in: input, nodeID: selectedID)
            }.value
            guard !Task.isCancelled, revision == sourceRevision, self.selectedID == selectedID else { return }
            canMoveUp = availability.canMoveUp
            canMoveDown = availability.canMoveDown
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
        .onChange(of: hidesNodeDetails) { _, sourceVisible in
            if sourceVisible {
                canvasFocused = false
            } else {
                requestCanvasFocus()
            }
        }
        .onDisappear {
            // A draft placeholder may already have autosaved before the user
            // leaves the canvas. Cancel an unfinished Add Child/Sibling here,
            // but only while the original note draft is still exact.
            discardPendingCreationIfUnchanged()
        }
        .onKeyPress { press in
            guard editingNodeID == nil,
                  let command = MindMapKeyboard.command(for: press.key, modifiers: press.modifiers)
            else { return .ignored }
            return performShortcut(command) ? .handled : .ignored
        }
        .onReceive(NotificationCenter.default.publisher(for: .pksMindMapBold)) { _ in
            guard editingNodeID == nil else { return }
            _ = performShortcut(.boldTitle)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pksMindMapItalic)) { _ in
            guard editingNodeID == nil else { return }
            _ = performShortcut(.italicTitle)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pksMindMapToggleTask)) { _ in
            guard editingNodeID == nil else { return }
            _ = performShortcut(.toggleTask)
        }
        .onChange(of: showingShortcuts) { _, visible in
            if !visible { requestCanvasFocus() }
        }
        .onChange(of: branchDeleteCandidate) { _, candidate in
            if candidate == nil { requestCanvasFocus() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(language.text("Mind Map"))
                .font(.headline)
                .lineLimit(1)
            if !projectionIsCurrent {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(language.text("Preparing mind map…"))
            }
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

            if !hidesNodeDetails {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        showingNodeDetails.toggle()
                    }
                    restoreCanvasFocusAfterMenu()
                } label: {
                    Image(systemName: showingNodeDetails ? "sidebar.right" : "info.circle")
                        .frame(width: 30, height: 30)
                }
                .disabled(selectedID == nil)
                .help(language.text("Node Details"))
                .accessibilityLabel(language.text("Node Details"))
                .accessibilityIdentifier("pks-mind-map-node-details")
            }

            Menu {
                Button(language.text("Link Note"), systemImage: "doc.text") {
                    if let selectedID { connectNote(selectedID) }
                }
                .accessibilityIdentifier("pks-mind-map-toolbar-link-note")
                Button(language.text("Link Section"), systemImage: "text.badge.plus") {
                    if let selectedID { connectSection(selectedID) }
                }
                .accessibilityIdentifier("pks-mind-map-toolbar-link-section")
                Divider()
                Button(language.text("Create Linked Note"), systemImage: "doc.badge.plus") {
                    if let selectedID { createLinkedNote(selectedID) }
                    restoreCanvasFocusAfterMenu()
                }
                .accessibilityIdentifier("pks-mind-map-toolbar-create-linked-note")
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
                Button(language.text("Move Up"), systemImage: "arrow.up") {
                    _ = performShortcut(.moveUp)
                    restoreCanvasFocusAfterMenu()
                }
                .disabled(editingNodeID != nil || selectedID == nil || !canMoveUp)
                .accessibilityIdentifier("pks-mind-map-move-up")
                Button(language.text("Move Down"), systemImage: "arrow.down") {
                    _ = performShortcut(.moveDown)
                    restoreCanvasFocusAfterMenu()
                }
                .disabled(editingNodeID != nil || selectedID == nil || !canMoveDown)
                .accessibilityIdentifier("pks-mind-map-move-down")
                Divider()
                Button(language.text("Promote node"), systemImage: "arrow.left") {
                    _ = performShortcut(.promote)
                    restoreCanvasFocusAfterMenu()
                }
                .disabled(editingNodeID != nil || selectedID == nil || !canPromote)
                Button(language.text("Make child of previous sibling"), systemImage: "arrow.right") {
                    shiftSelected(deeper: true)
                    restoreCanvasFocusAfterMenu()
                }
                .disabled(selectedID == nil || !canDemote)
                Divider()
                Button(language.text("Bold node title"), systemImage: "bold") {
                    if let selectedID { toggleTitleEmphasis(nodeID: selectedID, marker: "**") }
                    restoreCanvasFocusAfterMenu()
                }
                .disabled(selectedID == nil)
                .accessibilityIdentifier("pks-mind-map-node-bold")
                Button(language.text("Italic node title"), systemImage: "italic") {
                    if let selectedID { toggleTitleEmphasis(nodeID: selectedID, marker: "*") }
                    restoreCanvasFocusAfterMenu()
                }
                .disabled(selectedID == nil)
                .accessibilityIdentifier("pks-mind-map-node-italic")
                Divider()
                Button(language.text("Delete Leaf"), systemImage: "trash") {
                    _ = performShortcut(.deleteLeaf)
                    restoreCanvasFocusAfterMenu()
                }
                .disabled(selectedID == nil || !canDeleteLeaf)
                Button(language.text("Delete Branch"), systemImage: "trash.slash", role: .destructive) {
                    _ = performShortcut(.deleteBranch)
                }
                .disabled(selectedID.flatMap { MindMapOutline.deleteNodeSubtree(in: source, nodeID: $0) } == nil)
                Divider()
                Menu {
                    ForEach(MindMapVisualStyle.allCases) { style in
                        Button {
                            mapStyleID = style.rawValue
                            restoreCanvasFocusAfterMenu()
                        } label: {
                            Label(language.text(style.label), systemImage: style.symbol)
                            if mapStyle == style {
                                Image(systemName: "checkmark")
                            }
                        }
                        .accessibilityIdentifier("pks-mind-map-style-\(style.rawValue)")
                        .accessibilityAddTraits(MindMapSelectionAccessibility.selectionTraits(isSelected: mapStyle == style))
                    }
                    Divider()
                    Text(language.text("Layout Density"))
                    ForEach(MindMapLayoutDensity.allCases) { density in
                        Button {
                            layoutDensityID = density.rawValue
                            restoreCanvasFocusAfterMenu()
                        } label: {
                            Label(language.text(density.label), systemImage: density.symbol)
                            if layoutDensity == density {
                                Image(systemName: "checkmark")
                            }
                        }
                        .accessibilityIdentifier("pks-mind-map-density-\(density.rawValue)")
                        .accessibilityAddTraits(MindMapSelectionAccessibility.selectionTraits(isSelected: layoutDensity == density))
                    }
                    Divider()
                    Text(language.text("Appearance applies to all mind maps."))
                } label: {
                    Label(language.text("Appearance"), systemImage: "paintpalette")
                }
                .accessibilityIdentifier("pks-mind-map-style")
            } label: {
                Image(systemName: "ellipsis.circle")
                .frame(width: 30, height: 30)
            }
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
            Menu {
                ForEach([25, 50, 75, 100, 125, 150, 200], id: \.self) { percent in
                    Button("\(percent)%") {
                        zoomAboutCenter(to: CGFloat(percent) / 100)
                    }
                }
            } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 44)
            }
            .menuIndicator(.hidden)
            .help(language.text("Zoom level"))
            .accessibilityLabel(language.text("Zoom level"))
            .accessibilityValue("\(Int((zoom * 100).rounded()))%")
            .accessibilityIdentifier("pks-mind-map-zoom-level")
            Button {
                _ = performShortcut(.zoomIn)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                .frame(width: 30, height: 30)
            }
            .help("\(language.text("Zoom in")) · ⌘+")
            .accessibilityLabel(language.text("Zoom in"))
            Button {
                centerSelectedNode()
            } label: {
                Image(systemName: "scope")
                    .frame(width: 30, height: 30)
            }
            .disabled(selectedID == nil)
            .help(language.text("Center Selected Node"))
            .accessibilityLabel(language.text("Center Selected Node"))
            .accessibilityIdentifier("pks-mind-map-center-selected")

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
                Button(language.text("Import XMind File…")) { importXMind() }
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
        .symbolRenderingMode(.hierarchical)
        .font(.system(size: NotesGeometry.symbolSize, weight: .medium))
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 46)
        .disabled(!projectionIsCurrent)
    }

    private func nodeDetails(_ node: MindMapNode) -> some View {
        let presentation = nodePresentations[node.id]
            ?? MindMapOutline.presentation(for: node.title)
        let notes = presentation.body
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(language.text("Node Details")).font(.headline)
                Spacer()
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        showingNodeDetails = false
                    }
                    requestCanvasFocus()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(language.text("Close"))
                .accessibilityLabel(language.text("Close"))
                .accessibilityIdentifier("pks-mind-map-details-close")
            }
            Text(MindMapTitleEmphasis.display(presentation.title))
                .font(.title3.weight(.medium))
                .textSelection(.enabled)
            Text("\(language.text("Level")) \(node.depth + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if !notes.isEmpty {
                        Text(language.text("Notes"))
                            .font(.subheadline.weight(.semibold))
                        Text(notes)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !presentation.links.isEmpty {
                        Text(language.text("Linked Sources"))
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(presentation.links.enumerated()), id: \.offset) { _, link in
                            Button {
                                openLink(link.target)
                            } label: {
                                Label(link.label, systemImage: "link")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(2)
                            }
                            .buttonStyle(.link)
                            .help(link.target)
                        }
                    }
                    if notes.isEmpty && presentation.links.isEmpty {
                        Text(language.text("No attached notes or links"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                revealSource(node.id)
            } label: {
                Label(language.text("Edit in Markdown"), systemImage: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pks-mind-map-details-edit-source")
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("pks-mind-map-details")
    }

    private var shortcutHelp: some View {
        let rows: [(String, String)] = [
            ("↑ / ↓", "Select previous / next node"),
            ("← / →", "Parent / child; collapse / expand"),
            ("⌥ ↑ / ⌥ ↓", "Move node up / down"),
            ("⌥ ←", "Promote node"),
            ("⌥ →", "Make child of previous sibling"),
            ("Tab", "Add Child"),
            ("Return", "Add Sibling"),
            ("E", "Rename node"),
            ("⌘ B / ⌘ I", "Bold / Italic node title"),
            ("⌘ Return", "Toggle task completion"),
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

    @MainActor
    private func handlePDFCitationDrop(_ providers: [NSItemProvider], onto nodeID: Int) -> Bool {
        guard projectionIsCurrent, editingNodeID == nil,
              let provider = providers.first(where: {
                  $0.hasItemConformingToTypeIdentifier(PDFCitationPasteboard.type.rawValue)
              }) else { return false }

        let expectedSource = source
        let expectedRevision = revision
        let expectedSession = dragSessionID
        provider.loadItem(forTypeIdentifier: PDFCitationPasteboard.type.rawValue, options: nil) { item, _ in
            guard let citation = PDFCitationPasteboard.markdown(from: item) else {
                Task { @MainActor in
                    guard dragSessionID == expectedSession else { return }
                    interchangeError = language.text(
                        "Could not read the PDF citation. Try dragging the selection again."
                    )
                    dropTargetID = nil
                }
                return
            }

            Task { @MainActor in
                guard dragSessionID == expectedSession else { return }
                guard validateSource(expectedRevision, expectedSource),
                      projectionIsCurrent, editingNodeID == nil else {
                    interchangeError = language.text(
                        "The note or editor changed before the citation was inserted. Drag the PDF selection again."
                    )
                    dropTargetID = nil
                    return
                }
                guard let updated = PDFCitationDropTarget.citationForNodeInsertion(
                    citation, in: source, nodeID: nodeID
                ) else {
                    interchangeError = language.text(
                        "Could not read the PDF citation. Try dragging the selection again."
                    )
                    dropTargetID = nil
                    return
                }
                source = updated
                selectedID = nodeID
                dropTargetID = nil
                requestCanvasFocus()
            }
        }
        return true
    }

    @MainActor
    private func handleWorkspaceFileDrop(_ providers: [NSItemProvider], onto nodeID: Int) -> Bool {
        guard projectionIsCurrent, editingNodeID == nil,
              let provider = providers.first(where: {
                  $0.canLoadObject(ofClass: NSURL.self)
              }) else { return false }

        let expectedSource = source
        let expectedRevision = revision
        let expectedSession = dragSessionID
        provider.loadObject(ofClass: NSURL.self) { item, _ in
            guard let file = item as? URL else {
                Task { @MainActor in
                    guard dragSessionID == expectedSession else { return }
                    interchangeError = language.text(
                        "Could not read the dropped file. Try dropping it again."
                    )
                    dropTargetID = nil
                }
                return
            }

            Task { @MainActor in
                guard dragSessionID == expectedSession else { return }
                guard validateSource(expectedRevision, expectedSource),
                      projectionIsCurrent, editingNodeID == nil else {
                    interchangeError = language.text(
                        "The note or editor changed before the file link was inserted. Drop the file again."
                    )
                    dropTargetID = nil
                    return
                }
                guard let link = linkForDroppedFile(file),
                      let updated = MindMapOutline.appendMarkdownLinkToNodeBody(
                        link, in: source, nodeID: nodeID
                      ) else {
                    interchangeError = language.text(
                        "Link target not available in this workspace."
                    )
                    dropTargetID = nil
                    return
                }
                interchangeError = nil
                source = updated
                selectedID = nodeID
                dropTargetID = nil
                requestCanvasFocus()
            }
        }
        return true
    }

    private func selectNode(_ nodeID: Int) {
        guard projectionIsCurrent, editingNodeID != nodeID else { return }
        if editingNodeID != nil {
            finishRename(save: true)
            guard editingNodeID == nil else { return }
        }
        selectedID = nodeID
        canvasFocused = true
    }

    private func requestCanvasFocus() {
        Task { @MainActor in
            await Task.yield()
            if editingNodeID == nil { canvasFocused = true }
        }
    }

    // SwiftUI Menu restores first responder to its label after the action
    // closure returns. Force one focus-state transition after dismissal so
    // the next map shortcut is not silently consumed by toolbar focus.
    private func restoreCanvasFocusAfterMenu() {
        Task { @MainActor in
            canvasFocused = false
            try? await Task.sleep(for: .milliseconds(80))
            if editingNodeID == nil, branchDeleteCandidate == nil {
                canvasFocused = true
            }
        }
    }

    @discardableResult
    private func performShortcut(_ command: MindMapKeyboard.Command) -> Bool {
        guard projectionIsCurrent else { return false }
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
        case .moveUp:
            guard moveSelectedSibling(.up) else { return false }
        case .moveDown:
            guard moveSelectedSibling(.down) else { return false }
        case .addChild:
            guard !nodes.isEmpty else { return false }
            guard addChild() else { return false }
        case .addSibling:
            guard !nodes.isEmpty else { return false }
            guard addSibling() else { return false }
        case .boldTitle, .italicTitle:
            guard let selectedID,
                  toggleTitleEmphasis(
                    nodeID: selectedID,
                    marker: command == .boldTitle ? "**" : "*"
                  ) else { return false }
        case .toggleTask:
            guard let selectedID,
                  let updated = MindMapTaskNode.toggle(in: source, nodeID: selectedID)
            else { return false }
            source = updated
        case .promote:
            guard let updated = shiftedSource(deeper: false) else { return false }
            source = updated
        case .demote:
            guard let updated = shiftedSource(deeper: true) else { return false }
            source = updated
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
            guard let selectedID, MindMapOutline.deleteNodeSubtree(in: source, nodeID: selectedID) != nil
            else { return false }
            branchDeleteCandidate = MindMapBranchDeleteCandidate(
                nodeID: selectedID, source: source, revision: revision
            )
        case .fit:
            NotificationCenter.default.post(name: .pksMindMapFit, object: nil)
        case .zoomIn: zoomAboutCenter(to: clampedZoom(zoom * 1.15))
        case .zoomOut: zoomAboutCenter(to: clampedZoom(zoom / 1.15))
        case .clearSelection: selectedID = nil
        }
        if editingNodeID == nil, command != .deleteBranch { requestCanvasFocus() }
        return true
    }

    /// Node cards retain their map-sized coordinate space and native hit testing.
    /// Live connectors are rendered separately in viewport coordinates below.
    @ViewBuilder
    private func interactiveCanvas(_ layout: MindMapLayoutSnapshot) -> some View {
        ZStack(alignment: .topLeading) {
            MapNodeCardsSnapshot(owner: self, layout: layout, key: mapContentKey)
                .equatable()
            mapCenterAnchor(layout)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .allowsHitTesting(!isLayoutRebuilding)
    }

    /// Draw only the connectors intersecting the current map-space viewport into
    /// a bounded screen-space Canvas. This surface must stay outside the
    /// map-sized scale/position transform applied to node cards.
    private func connectorViewportCanvas(
        _ layout: MindMapLayoutSnapshot,
        viewport: CGSize
    ) -> some View {
        let offset = CGSize(
            width: viewportOffset.width + canvasDrag.width,
            height: viewportOffset.height + canvasDrag.height
        )
        let connectorViewport = MindMapViewportGeometry.visibleRect(
            mapSize: layout.size,
            viewport: viewport,
            offset: offset,
            zoom: zoom,
            overscan: 320
        )
        let visibleConnectors = layout.visibleConnectors(in: connectorViewport)
        return MindMapViewportConnectorSnapshot(
            size: viewport,
            connectors: visibleConnectors,
            style: mapStyle,
            mapSize: layout.size,
            viewportOffset: offset,
            zoom: zoom,
            layoutVersion: mapContentVersion
        )
        .equatable()
    }

    /// Overview node glyphs share the connector Canvas coordinate transform.
    /// They stay viewport-sized and never instantiate one SwiftUI view per node.
    private func overviewNodeViewportCanvas(
        _ layout: MindMapLayoutSnapshot,
        viewport: CGSize
    ) -> some View {
        let offset = CGSize(
            width: viewportOffset.width + canvasDrag.width,
            height: viewportOffset.height + canvasDrag.height
        )
        let overviewRect = MindMapViewportGeometry.visibleRect(
            mapSize: layout.size,
            viewport: viewport,
            offset: offset,
            zoom: zoom,
            overscan: 320
        )
        let visibleIDs = layout.visiblePlacementIDs(
            in: overviewRect,
            pinnedIDs: pinnedNodeIDs
        )
        return MindMapViewportNodeSnapshot(
            size: viewport,
            placements: layout.visiblePlacements(for: visibleIDs),
            branchByID: layout.branchByID,
            style: mapStyle,
            colorScheme: colorScheme,
            mapSize: layout.size,
            viewportOffset: offset,
            zoom: zoom,
            selectedID: selectedID,
            totalNodeCount: layout.placements.count,
            accessibilityLabel: language.text("Mind Map overview"),
            accessibilityValue: language.text("\(layout.placements.count) nodes"),
            accessibilityHint: language.text("Activate to focus the node nearest the map center."),
            onActivate: {
                focusNodeAtOverviewPoint(
                    CGPoint(x: viewport.width / 2, y: viewport.height / 2),
                    layout: layout,
                    viewport: viewport,
                    requireHitRadius: false
                )
            },
            layoutVersion: mapContentVersion
        )
        .equatable()
    }

    @ViewBuilder
    private func spatialCanvas(
        _ layout: MindMapLayoutSnapshot,
        exporting: Bool = false,
        visibleNodeIDs: Set<Int>? = nil
    ) -> some View {
        ZStack(alignment: .topLeading) {
            connectorCanvas(layout, exporting: exporting)
            nodeCards(layout, visibleNodeIDs: visibleNodeIDs, exporting: exporting)
            mapCenterAnchor(layout)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    /// Full-map connector Canvas retained for PNG/PDF export, where the
    /// complete map coordinate surface is intentional. Interactive rendering
    /// uses connectorViewportCanvas above to keep its backing surface bounded.
    private func connectorCanvas(
        _ layout: MindMapLayoutSnapshot,
        exporting: Bool = false
    ) -> some View {
        let connectorViewport = !exporting
            ? MindMapViewportGeometry.visibleRect(
                mapSize: layout.size,
                viewport: viewportSize,
                offset: CGSize(
                    width: viewportOffset.width + canvasDrag.width,
                    height: viewportOffset.height + canvasDrag.height
                ),
                zoom: zoom,
                overscan: 320
            )
            : nil
        let visibleConnectors = layout.visibleConnectors(in: connectorViewport)
        return MapConnectorSnapshot(
            size: layout.size,
            connectors: visibleConnectors,
            style: mapStyle,
            layoutVersion: mapContentVersion
        )
        .equatable()
    }

    @ViewBuilder
    private func nodeCards(
        _ layout: MindMapLayoutSnapshot,
        visibleNodeIDs: Set<Int>? = nil,
        exporting: Bool = false
    ) -> some View {
        let renderedPlacements = layout.visiblePlacements(for: visibleNodeIDs)
        // Branch colors come from the layout snapshot; disclosure ownership comes from the complete
        // Markdown projection so collapsed descendants never erase their own expand affordance.
        let branchByID = layout.branchByID
        let parentIDs = nodeParentIDs
        // Keep node positions in the exact same fixed-size coordinate space
        // as connectorCanvas. A bare ForEach can be measured independently by
        // the equatable card snapshot and shift card origins away from paths.
        ZStack(alignment: .topLeading) {
            ForEach(renderedPlacements) { placement in
                nodeCard(placement.node, hasChildren: parentIDs.contains(placement.id),
                         branch: branchByID[placement.id] ?? 0,
                         dropHeight: placement.size.height, exporting: exporting)
                    .frame(width: placement.size.width, height: placement.size.height)
                    .position(placement.center)
                    .id(placement.id)
                    .transition(
                        reduceMotion || exporting
                            ? .identity
                            : .opacity.combined(with: .scale(scale: 0.985, anchor: .leading))
                    )
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private func mapCenterAnchor(_ layout: MindMapLayoutSnapshot) -> some View {
        Color.clear
            .frame(width: 1, height: 1)
            .position(x: layout.size.width / 2, y: layout.size.height / 2)
            .id("pks-mind-map-center")
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func nodeCard(_ node: MindMapNode, hasChildren: Bool,
                          branch: Int, dropHeight: CGFloat,
                          exporting: Bool = false) -> some View {
        let presentation = nodePresentations[node.id] ?? MindMapOutline.presentation(for: node.title)
        let task = MindMapTaskNode.parse(presentation.title)
        let visibleTitle = task?.title ?? presentation.title
        let accent = mapStyle.branchColor(branch)
        let scheme: ColorScheme = exporting ? .light : colorScheme
        let highlighted = !exporting && selectedID == node.id
        let cardRadius = mapStyle.cardRadius
        HStack(spacing: 9) {
            if mapStyle.usesBranchColors && node.depth > 0 {
                Capsule()
                    .fill(accent)
                    .frame(width: 4, height: 24)
                    .accessibilityHidden(true)
            }
            if let task {
                if exporting {
                    Image(systemName: task.checked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(task.checked ? accent : Color.secondary)
                        .font(.system(size: 14))
                        .accessibilityHidden(true)
                } else {
                    Button {
                        if let updated = MindMapTaskNode.toggle(in: source, nodeID: node.id) {
                            source = updated
                            selectedID = node.id
                            requestCanvasFocus()
                        }
                    } label: {
                        Image(systemName: task.checked ? "checkmark.square.fill" : "square")
                            .foregroundStyle(task.checked ? accent : Color.secondary)
                            .font(.system(size: 14))
                            .frame(minWidth: 20, minHeight: 24)
                    }
                    .buttonStyle(.plain)
                    .help(language.text(task.checked ? "Mark task incomplete" : "Mark task complete"))
                    .accessibilityLabel(language.text(task.checked ? "Mark task incomplete" : "Mark task complete"))
                    .accessibilityValue(MindMapTaskAccessibility.accessibilityValue(isCompleted: task.checked, language: language))
                    .accessibilityIdentifier("pks-mind-map-task-\(node.id)")
                }
            }
            if hasChildren {
                if exporting {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    let disclosureTitle = language.text(
                        collapsed.contains(node.id) ? "Expand Branch" : "Collapse Branch"
                    )
                    Button {
                        selectedID = node.id
                        if !collapsed.insert(node.id).inserted { collapsed.remove(node.id) }
                        requestCanvasFocus()
                    } label: {
                        Image(systemName: collapsed.contains(node.id) ? "chevron.right" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(disclosureTitle)
                    .accessibilityIdentifier("pks-mind-map-disclosure-\(node.id)")
                    .accessibilityLabel(disclosureTitle)
                    .accessibilityValue(
                        MindMapDisclosureAccessibility.accessibilityValue(
                            isExpanded: !collapsed.contains(node.id), language: language
                        )
                    )
                }
            } else {
                Color.clear.frame(width: 24, height: 24)
            }

            if !exporting && editingNodeID == node.id {
                TextField(language.text("Node title"), text: $renameTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: node.depth == 0 ? 16 : 14,
                                  weight: .medium, design: mapStyle.fontDesign))
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
                .accessibilityLabel(language.text("Save"))
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
                .accessibilityLabel(language.text("Cancel"))
                .accessibilityIdentifier("pks-mind-map-inline-cancel")
            } else {
                Text(MindMapTitleEmphasis.display(visibleTitle))
                    .font(.system(size: node.depth == 0 ? 16 : 14,
                                  weight: node.depth == 0 ? .semibold : .medium,
                                  design: mapStyle.fontDesign))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(visibleTitle)
                    .accessibilityIdentifier("pks-mind-map-node-\(node.id)")
                    .accessibilityValue(
                        MindMapNodeAccessibility.accessibilityValue(
                            level: node.depth + 1,
                            isSelected: highlighted,
                            language: language
                        )
                    )
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAddTraits(MindMapSelectionAccessibility.selectionTraits(isSelected: highlighted))
                    .accessibilityAction {
                        selectNode(node.id)
                    }
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
                .help("\(language.text("Open linked source")) · \(link.label)")
                .accessibilityLabel("\(language.text("Open linked source")) \(link.label)")
                .accessibilityIdentifier("pks-mind-map-node-link-\(node.id)")
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
                .help(language.text("Open linked source"))
                .accessibilityLabel("\(language.text("Open linked source")) \(presentation.links.count)")
                .accessibilityIdentifier("pks-mind-map-node-link-\(node.id)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            highlighted ? accent.opacity(scheme == .dark ? 0.32 : 0.22)
                        : mapStyle.fill(depth: node.depth, branch: branch, scheme: scheme),
            in: RoundedRectangle(cornerRadius: cardRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cardRadius)
                .strokeBorder(
                    !exporting && dropTargetID == node.id
                        ? accent
                        : (highlighted ? accent.opacity(0.85)
                                       : mapStyle.outline(depth: node.depth, branch: branch)),
                    style: StrokeStyle(
                        lineWidth: !exporting && dropTargetID == node.id ? 2.2
                                   : (highlighted ? 1.8 : mapStyle.unselectedOutlineWidth),
                        dash: !exporting && dropTargetID == node.id ? [5, 3] : []
                    )
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(mapStyle.nodeShadowOpacity(depth: node.depth)),
                radius: mapStyle.nodeShadowRadius, y: mapStyle.nodeShadowYOffset)
        .contentShape(RoundedRectangle(cornerRadius: cardRadius))
        .draggable(MindMapNodeDragPayload(
            canvasSessionID: dragSessionID,
            revision: projectedRevision ?? revision,
            nodeID: node.id
        ))
        .dropDestination(for: MindMapNodeDragPayload.self) { items, location in
            // The canvas only accepts drops for its current projection; reuse it instead of reparsing Markdown on the main-thread drop path.
            let ids = Set(nodes.map(\.id))
            guard let payload = items.first,
                  let draggedID = payload.resolve(
                    in: ids, target: node.id,
                    canvasSessionID: dragSessionID,
                    revision: revision
                  ) else {
                dropTargetID = nil
                return false
            }
            guard draggedID != node.id else {
                dropTargetID = nil
                return true
            }

            let placement: MindMapDropPlacement
            let sourceIsList = MindMapOutline.isListNode(in: source, nodeID: draggedID)
            let targetIsList = MindMapOutline.isListNode(in: source, nodeID: node.id)
            if sourceIsList == targetIsList {
                let edgeZone = min(16, dropHeight * 0.25)
                if location.y < edgeZone {
                    placement = .before
                } else if location.y > dropHeight - edgeZone {
                    placement = .after
                } else {
                    placement = .child
                }
            } else {
                placement = .child
            }

            guard let outcome = MindMapOutline.moveNodeSubtreeWithOutcome(
                in: source, nodeID: draggedID, relativeTo: node.id, placement: placement
            ) else {
                interchangeError = language.text(
                    "Cannot move this branch without changing attached Markdown. Use the editor."
                )
                dropTargetID = nil
                return false
            }
            // A child drop must reveal the newly attached node, but unrelated
            // collapsed branches (including descendants) keep their state.
            if placement == .child { collapsed.remove(node.id) }
            source = outcome.source
            // Selection still belongs to the previous projection here. The
            // revision task maps this original ID to the moved node's new line
            // index; assigning outcome.movedNodeID would map it a second time
            // when that index collides with another old node.
            selectedID = draggedID
            dropTargetID = nil
            requestCanvasFocus()
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTargetID = node.id
            } else if dropTargetID == node.id {
                // A late exit from another card must not erase the current drop cue.
                dropTargetID = nil
            }
        }
        .onDrop(
            of: [
                UTType(exportedAs: PDFCitationPasteboard.type.rawValue, conformingTo: .plainText),
                .url,
                .fileURL
            ],
            isTargeted: Binding(
                get: { !exporting && dropTargetID == node.id },
                set: { targeted in
                    guard !exporting else { return }
                    if targeted {
                        dropTargetID = node.id
                    } else if dropTargetID == node.id {
                        dropTargetID = nil
                    }
                }
            )
        ) { providers in
            guard !exporting else { return false }
            if handlePDFCitationDrop(providers, onto: node.id) { return true }
            return handleWorkspaceFileDrop(providers, onto: node.id)
        }
        .contextMenu {
            let availability = MindMapOutline.actionAvailability(in: source, nodeID: node.id)
            Button(language.text("Add Child"), systemImage: "plus") {
                selectedID = node.id
                _ = addChild()
            }
            .disabled(editingNodeID != nil)
            .accessibilityIdentifier("pks-mind-map-context-add-child")
            Button(language.text("Add Sibling"), systemImage: "plus.square.on.square") {
                selectedID = node.id
                _ = addSibling()
            }
            .disabled(editingNodeID != nil)
            .accessibilityIdentifier("pks-mind-map-context-add-sibling")
            Divider()
            Button(language.text("Rename node"), systemImage: "pencil") {
                if editingNodeID != nil { finishRename(save: true) }
                selectedID = node.id
                beginRename()
            }
            Button(language.text("Move Up"), systemImage: "arrow.up") {
                selectedID = node.id
                _ = performShortcut(.moveUp)
                restoreCanvasFocusAfterMenu()
            }
            .disabled(editingNodeID != nil || !availability.canMoveUp)
            .accessibilityIdentifier("pks-mind-map-context-move-up")
            Button(language.text("Move Down"), systemImage: "arrow.down") {
                selectedID = node.id
                _ = performShortcut(.moveDown)
                restoreCanvasFocusAfterMenu()
            }
            .disabled(editingNodeID != nil || !availability.canMoveDown)
            .accessibilityIdentifier("pks-mind-map-context-move-down")
            Divider()
            Button(language.text("Promote node"), systemImage: "arrow.left") {
                selectedID = node.id
                _ = performShortcut(.promote)
                restoreCanvasFocusAfterMenu()
            }
            .disabled(editingNodeID != nil || !availability.canPromote)
            .accessibilityIdentifier("pks-mind-map-context-promote")
            Button(language.text("Make child of previous sibling"), systemImage: "arrow.right") {
                selectedID = node.id
                shiftSelected(deeper: true)
                restoreCanvasFocusAfterMenu()
            }
            .disabled(editingNodeID != nil || !availability.canDemote)
            .accessibilityIdentifier("pks-mind-map-context-demote")
            Button(language.text("Toggle branch"),
                   systemImage: collapsed.contains(node.id) ? "chevron.right" : "chevron.down") {
                selectedID = node.id
                _ = performShortcut(.toggleBranch)
                restoreCanvasFocusAfterMenu()
            }
            .disabled(editingNodeID != nil || !hasChildren)
            .accessibilityIdentifier("pks-mind-map-context-toggle-branch")
            Divider()
            if let task = MindMapTaskNode.parse(node.title) {
                Button(language.text("Toggle task completion"),
                       systemImage: task.checked ? "checkmark.circle.fill" : "circle") {
                    selectedID = node.id
                    _ = performShortcut(.toggleTask)
                    restoreCanvasFocusAfterMenu()
                }
                .disabled(editingNodeID != nil)
                .accessibilityIdentifier("pks-mind-map-context-toggle-task")
            }
            Divider()
            Button(language.text("Bold node title"), systemImage: "bold") {
                toggleTitleEmphasis(nodeID: node.id, marker: "**")
            }
            Button(language.text("Italic node title"), systemImage: "italic") {
                toggleTitleEmphasis(nodeID: node.id, marker: "*")
            }
            Divider()
            Button(language.text("Link Note"), systemImage: "doc.text") {
                selectedID = node.id
                connectNote(node.id)
            }
            .accessibilityIdentifier("pks-mind-map-context-link-note")
            Button(language.text("Link Section"), systemImage: "text.badge.plus") {
                selectedID = node.id
                connectSection(node.id)
            }
            .accessibilityIdentifier("pks-mind-map-context-link-section")
            Button(language.text("Create Linked Note"), systemImage: "doc.badge.plus") {
                selectedID = node.id
                createLinkedNote(node.id)
                restoreCanvasFocusAfterMenu()
            }
            .accessibilityIdentifier("pks-mind-map-context-create-linked-note")
            Button(language.text("Show in Markdown"), systemImage: "text.cursor") {
                selectedID = node.id
                revealSource(node.id)
            }
            .disabled(editingNodeID != nil)
            Divider()
            Button(language.text("Delete Leaf"), systemImage: "trash") {
                selectedID = node.id
                _ = performShortcut(.deleteLeaf)
                restoreCanvasFocusAfterMenu()
            }
            .disabled(editingNodeID != nil || !availability.canDeleteLeaf)
            .accessibilityIdentifier("pks-mind-map-context-delete-leaf")
            Button(language.text("Delete Branch"), systemImage: "trash.slash", role: .destructive) {
                selectedID = node.id
                branchDeleteCandidate = MindMapBranchDeleteCandidate(
                    nodeID: node.id, source: source, revision: revision
                )
            }
            .disabled(editingNodeID != nil ||
                      MindMapOutline.deleteNodeSubtree(in: source, nodeID: node.id) == nil)
            .accessibilityIdentifier("pks-mind-map-context-delete-branch")
        }
        .onTapGesture {
            selectNode(node.id)
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

    @discardableResult
    private func toggleTitleEmphasis(nodeID: Int, marker: String) -> Bool {
        guard projectionIsCurrent,
              editingNodeID == nil,
              let node = MindMapOutline.nodes(in: source).first(where: { $0.id == nodeID }),
              let updated = MindMapOutline.rename(
                in: source, nodeID: nodeID,
                to: MindMapTitleEmphasis.toggle(node.title, marker: marker)
              ) else { return false }
        source = updated
        selectedID = nodeID
        requestCanvasFocus()
        return true
    }

    @discardableResult
    private func addChild() -> Bool {
        guard projectionIsCurrent,
              let id = selectedID ?? nodes.first?.id else { return false }
        guard let outcome = MindMapOutline.addChildWithOutcome(in: source, parentID: id) else {
            interchangeError = language.text(
                "Cannot add a node here without changing attached Markdown. Use the editor."
            )
            return false
        }
        collapsed.remove(id)
        startEditingNode(
            outcome.nodeID, title: "New idea", pendingCreationSource: outcome.source
        )
        source = outcome.source
        return true
    }

    @discardableResult
    private func addSibling() -> Bool {
        guard projectionIsCurrent,
              let id = selectedID ?? nodes.first?.id else { return false }
        guard let outcome = MindMapOutline.addSiblingWithOutcome(in: source, nodeID: id) else {
            interchangeError = language.text(
                "Cannot add a node here without changing attached Markdown. Use the editor."
            )
            return false
        }
        startEditingNode(
            outcome.nodeID, title: "New idea", pendingCreationSource: outcome.source
        )
        source = outcome.source
        return true
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

        do {
            try withSecurityScopedAccess(to: template) {
                let savePanel = NSSavePanel()
                savePanel.title = language.text("Export Native MindNode")
                savePanel.directoryURL = template.deletingLastPathComponent()
                savePanel.nameFieldStringValue = "Mind Map.mindnode"
                savePanel.allowedContentTypes = [UTType(filenameExtension: "mindnode", conformingTo: .package) ?? .package]
                guard savePanel.runModal() == .OK, let destination = savePanel.url else { return }
                try withSecurityScopedAccess(to: destination) {
                    try MindNodePackage.exportOutline(source, usingTemplate: template, to: destination)
                }
                interchangeError = language.text("New MindNode package exported. The original template and Markdown were not changed.")
            }
        } catch {
            interchangeError = error.localizedDescription
        }
    }

    private func importXMind() {
        let panel = NSOpenPanel()
        panel.title = language.text("Import XMind File")
        panel.message = language.text("Import XMind topics, notes, labels, marker IDs, web links, relationship descriptions and embedded PNG, JPEG and TIFF images into an editable Markdown map. Images are copied into the new note; styles, task behavior and connection geometry are not converted. The original .xmind file remains unchanged.")
        panel.allowedContentTypes = [UTType(filenameExtension: "xmind") ?? .zip]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try withSecurityScopedAccess(to: url) {
                try XMindPackage.importDocument(from: url)
            }
            if importOutline(imported.markdown, url.deletingPathExtension().lastPathComponent, imported.images, []) {
                interchangeError = language.text("XMind topics, notes, labels, marker IDs, web links, relationship descriptions and embedded PNG, JPEG and TIFF images imported. Styles, task behavior and connection geometry remain in the original file.")
            }
        } catch {
            interchangeError = error.localizedDescription
        }
    }

    private func importMindNode() {
        let panel = NSOpenPanel()
        panel.title = language.text("Import MindNode Document")
        panel.message = language.text("Select a MindNode Next package or a MindNode Classic package or single-file document. Node titles, notes and supported PNG images or PDF attachments become editable Markdown; the source stays unchanged.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Keep the open-panel grant only for the read; the source package is never written.
            let imported = try withSecurityScopedAccess(to: url) {
                try MindNodePackage.importDocument(from: url)
            }
            if importOutline(
                imported.markdown, url.deletingPathExtension().lastPathComponent,
                imported.images, imported.pdfs
            ) {
                interchangeError = language.text("MindNode topics, notes and supported PDF attachments imported. Images and PDFs are copied into the new note; original layout, styling, tasks and cross-connections remain in the source.")
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
            let data = try withSecurityScopedAccess(to: url) {
                try Data(contentsOf: url)
            }
            let text = try MindMapInterchange.importOPML(data)
            _ = importOutline(text, url.deletingPathExtension().lastPathComponent, [], [])
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
            try withSecurityScopedAccess(to: url) {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            interchangeError = error.localizedDescription
        }
    }

    /// Export a whole map, not a cropped screenshot of the current scroll viewport.
    /// Rendering uses the existing spatial layout and never modifies the source.
    private func exportPNG() {
        guard !nodes.isEmpty else { return }
        // Export the complete Markdown outline, independent of the user's collapsed viewport.
        let layout = MindMapSpatialLayout.layout(nodes, density: layoutDensity, style: mapStyle)
        let size = layout.size
        guard MindMapExportBudget.allowsPNG(size: size) else {
            interchangeError = language.text("This map is too large for a single PNG. Try PDF.")
            return
        }
        let content = spatialCanvas(layout, exporting: true)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = MindMapExportBudget.pngScale
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
        let layout = MindMapSpatialLayout.layout(nodes, density: layoutDensity, style: mapStyle)
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
        do {
            try withSecurityScopedAccess(to: url) {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            interchangeError = error.localizedDescription
        }
    }

    private func withSecurityScopedAccess<T>(
        to url: URL,
        perform operation: () throws -> T
    ) rethrows -> T {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(2.50, max(0.0001, value))
    }

    private func zoomAboutCenter(to nextZoom: CGFloat) {
        viewportOffset = MindMapViewportGeometry.offsetPreservingAnchor(
            viewportOffset,
            from: zoom,
            to: nextZoom,
            anchor: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2),
            viewport: viewportSize
        )
        zoom = nextZoom
    }

    private func centerSelectedNode() {
        guard let selectedID,
              let position = mapLayout.placements.first(where: { $0.id == selectedID }) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            viewportOffset = MindMapViewportGeometry.centeredOffset(
                for: position.center, mapSize: mapLayout.size, zoom: zoom
            )
        }
    }

    @MainActor
    private func rebuildVisibleLayout(animated: Bool = false) async {
        let inputNodes = nodes
        let collapsedIDs = collapsed
        let density = layoutDensity
        let style = mapStyle
        layoutGeneration &+= 1
        let generation = layoutGeneration
        isLayoutRebuilding = true

        let worker = Task.detached(priority: .userInitiated) {
            var hiddenBelow: Int?
            let filtered = inputNodes.filter { node in
                if let depth = hiddenBelow {
                    if node.depth > depth { return false }
                    hiddenBelow = nil
                }
                if collapsedIDs.contains(node.id) { hiddenBelow = node.depth }
                return true
            }
            let layout = MindMapSpatialLayout.layout(filtered, density: density, style: style)
            return (filtered, layout)
        }
        let (filtered, layout) = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, generation == layoutGeneration else { return }

        if animated {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                visible = filtered
                mapLayout = layout
                mapContentVersion &+= 1
                isLayoutRebuilding = false
            }
        } else {
            visible = filtered
            mapLayout = layout
            mapContentVersion &+= 1
            isLayoutRebuilding = false
        }
    }

    /// Keep every node expanded on open and anchor the initial viewport on the root.
    /// Off-screen descendants remain in the full Markdown-backed layout and are reachable by pan/zoom.
    private func focusOnRoot(viewport: CGSize) -> Bool {
        guard let visibleRoot = mapLayout.placements.first(where: { $0.parentID == nil }),
              viewport.width > 0, viewport.height > 0 else { return false }
        let initial = MindMapViewportGeometry.initialRootViewport(
            root: visibleRoot, visiblePlacements: [visibleRoot],
            mapSize: mapLayout.size, viewport: viewport
        )
        zoom = initial.zoom
        viewportOffset = initial.offset
        return true
    }

    private func fitToContent(viewport: CGSize) -> Bool {
        guard let fitted = MindMapViewportGeometry.fittingViewport(
            placements: mapLayout.placements,
            mapSize: mapLayout.size,
            viewport: viewport
        ) else { return false }
        zoom = fitted.zoom
        viewportOffset = fitted.offset
        return true
    }

    private func focusNodeAtOverviewPoint(
        _ screenPoint: CGPoint,
        layout: MindMapLayoutSnapshot,
        viewport: CGSize,
        requireHitRadius: Bool = true
    ) {
        let offset = CGSize(
            width: viewportOffset.width + canvasDrag.width,
            height: viewportOffset.height + canvasDrag.height
        )
        guard let mapPoint = MindMapViewportGeometry.mapPoint(
            fromScreenPoint: screenPoint,
            mapSize: layout.size,
            viewport: viewport,
            offset: offset,
            zoom: zoom
        ) else { return }

        let nearest = layout.placements.min { lhs, rhs in
            let leftX = lhs.center.x - mapPoint.x
            let leftY = lhs.center.y - mapPoint.y
            let rightX = rhs.center.x - mapPoint.x
            let rightY = rhs.center.y - mapPoint.y
            return leftX * leftX + leftY * leftY < rightX * rightX + rightY * rightY
        }
        guard let nearest else { return }

        if requireHitRadius {
            let deltaX = nearest.center.x - mapPoint.x
            let deltaY = nearest.center.y - mapPoint.y
            let hitRadius = max(nearest.size.width, nearest.size.height) * 0.9
            guard deltaX * deltaX + deltaY * deltaY <= hitRadius * hitRadius else { return }
        }

        let nextZoom = min(1.25, max(0.72, zoom * 1.8))
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            selectedID = nearest.id
            zoom = nextZoom
            viewportOffset = MindMapViewportGeometry.centeredOffset(
                for: nearest.center, mapSize: layout.size, zoom: nextZoom
            )
        }
        requestCanvasFocus()
    }

    private func beginRename() {
        guard projectionIsCurrent,
              let node = nodes.first(where: { $0.id == selectedID }) else { return }
        startEditingNode(node.id, title: MindMapTaskNode.titleForEditing(
            MindMapOutline.titleForInlineEditing(node.title)
        ))
    }

    private func startEditingNode(
        _ id: Int, title: String, pendingCreationSource: String? = nil
    ) {
        selectedID = id
        renameTitle = title
        editingNodeID = id
        editingCreatedNodeID = pendingCreationSource == nil ? nil : id
        createdNodeDraftSnapshot = pendingCreationSource
        canvasFocused = false
        titleEditorFocused = false
    }

    private func syncMarkdownCaretFromMap(_ nodeID: Int) {
        guard hidesNodeDetails, projectionIsCurrent,
              let textView = activeMarkdownTextView(),
              textView.isEditable, !textView.isFieldEditor,
              textView.string == source else { return }
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound,
              MindMapOutline.nodeID(
                atUTF16Offset: selection.location,
                lineStartOffsets: lineStartOffsets,
                nodes: nodes
              ) != nodeID,
              let caret = MindMapOutline.caretRange(
                atNodeID: nodeID, lineStartOffsets: lineStartOffsets
              ) else { return }
        // Keep keyboard focus on the map; update only the editor's insertion point.
        textView.setSelectedRange(caret)
        textView.scrollRangeToVisible(caret)
    }

    private func syncSelectedNodeFromMarkdownEditor(_ textView: NSTextView?) {
        guard hidesNodeDetails, projectionIsCurrent,
              let textView, textView.isEditable, !textView.isFieldEditor,
              let window = textView.window,
              window === NSApp.keyWindow,
              window.firstResponder === textView,
              textView.string == source else { return }
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound,
              let nodeID = MindMapOutline.nodeID(
                atUTF16Offset: selection.location,
                lineStartOffsets: lineStartOffsets,
                nodes: nodes
              ),
              selectedID != nodeID else { return }
        selectedID = nodeID
    }

    private func finishRename(save: Bool) {
        guard let id = editingNodeID, !save || projectionIsCurrent else { return }
        if save {
            // Invalid titles stay in the inline editor instead of silently
            // committing the placeholder/original text.
            guard let node = nodes.first(where: { $0.id == id }),
                  let markdownTitle = MindMapTaskNode.replacingTitle(
                    renameTitle, in: MindMapOutline.titleForInlineEditing(node.title)
                  ),
                  let updated = MindMapOutline.renameInlineTitle(
                    in: source, nodeID: id, to: markdownTitle
                  ) else {
                interchangeError = language.text("Enter a nonempty, single-line node title.")
                return
            }
            source = updated
        } else {
            discardPendingCreationIfUnchanged()
        }
        editingNodeID = nil
        editingCreatedNodeID = nil
        createdNodeDraftSnapshot = nil
        titleEditorFocused = false
        canvasFocused = false
        Task { @MainActor in
            await Task.yield()
            canvasFocused = true
        }
    }

    private func discardPendingCreationIfUnchanged() {
        guard let id = editingCreatedNodeID,
              let snapshot = createdNodeDraftSnapshot,
              let restored = MindMapPendingCreation.rollback(
                in: source, expected: snapshot, nodeID: id
              ) else { return }
        source = restored
        selectedID = nodes.first?.id
        editingCreatedNodeID = nil
        createdNodeDraftSnapshot = nil
    }

    private func moveSelectedSibling(_ direction: MindMapSiblingMoveDirection) -> Bool {
        guard projectionIsCurrent, editingNodeID == nil, let selectedID,
              let outcome = MindMapOutline.moveNodeToAdjacentSibling(
                in: source, nodeID: selectedID, direction: direction
              ) else { return false }
        // Keep the old projection's ID until the revision task maps it to the moved line.
        source = outcome.source
        return true
    }

    private func shiftedSource(deeper: Bool) -> String? {
        guard let selectedID else { return nil }
        return MindMapOutline.shiftNodeSubtree(in: source, nodeID: selectedID, deeper: deeper)
    }

    private func shiftSelected(deeper: Bool) {
        guard projectionIsCurrent,
              let updated = shiftedSource(deeper: deeper) else { return }
        source = updated
    }
}

extension Notification.Name {
    static let pksMindMapFit = Notification.Name("PKSNotesMindMapFit")
    static let pksMindMapBold = Notification.Name("PKSNotesMindMapBold")
    static let pksMindMapItalic = Notification.Name("PKSNotesMindMapItalic")
    static let pksMindMapToggleTask = Notification.Name("PKSNotesMindMapToggleTask")
}
