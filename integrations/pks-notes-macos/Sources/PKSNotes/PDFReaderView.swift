import AppKit
import PDFKit
import SwiftUI

enum PDFDocumentLoading {
    static func load(_ url: URL) async -> PDFDocument? {
        let loader = Task.detached(priority: .userInitiated) {
            do {
                try await WorkspaceFiles.hydrateUbiquitousItemIfNeeded(url)
                try Task.checkCancellation()
                return PDFDocument(url: url)
            } catch {
                return nil
            }
        }
        let loaded = await loader.value
        guard !Task.isCancelled else {
            loader.cancel()
            return nil
        }
        return loaded
    }
}

struct PDFSourceAnchor: Equatable {
    static let maxRects = 32

    let page: Int
    let normalizedRects: [CGRect]
    let fingerprint: String

    init?(page: Int, normalizedRects: [CGRect], fingerprint: String) {
        let cleanFingerprint = fingerprint.lowercased()
        guard page > 0,
              !normalizedRects.isEmpty,
              normalizedRects.count <= Self.maxRects,
              cleanFingerprint.count == 16,
              cleanFingerprint.allSatisfy({ $0.isHexDigit })
        else { return nil }

        let rects = normalizedRects.map(\.standardized)
        guard rects.allSatisfy({ rect in
            rect.minX.isFinite && rect.minY.isFinite
                && rect.width.isFinite && rect.height.isFinite
                && rect.width > 0 && rect.height > 0
                && rect.minX >= 0 && rect.minY >= 0
                && rect.maxX <= 1.000_01 && rect.maxY <= 1.000_01
        }) else { return nil }

        self.page = page
        self.normalizedRects = rects
        self.fingerprint = cleanFingerprint
    }

    static func fingerprint(for text: String) -> String? {
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return nil }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    func matches(text: String) -> Bool {
        Self.fingerprint(for: text) == fingerprint
    }

    var fragment: String {
        let locale = Locale(identifier: "en_US_POSIX")
        let rects = normalizedRects.map { rect in
            String(
                format: "%.5f,%.5f,%.5f,%.5f",
                locale: locale,
                rect.minX, rect.minY, rect.width, rect.height
            )
        }.joined(separator: "~")
        return "page=\(page)&rects=\(rects)&fp=\(fingerprint)"
    }

    func rects(in pageBounds: CGRect) -> [CGRect] {
        normalizedRects.map { rect in
            CGRect(
                x: pageBounds.minX + rect.minX * pageBounds.width,
                y: pageBounds.minY + rect.minY * pageBounds.height,
                width: rect.width * pageBounds.width,
                height: rect.height * pageBounds.height
            )
        }
    }

    static func parse(fragment: String) -> PDFSourceAnchor? {
        var page: Int?
        var rectString: String?
        var fingerprint: String?

        for part in fragment.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            switch pair[0].lowercased() {
            case "page": page = Int(pair[1])
            case "rects": rectString = String(pair[1])
            case "fp": fingerprint = String(pair[1])
            default: continue
            }
        }

        guard let page, let rectString, let fingerprint else { return nil }
        let rects = rectString.split(separator: "~").compactMap { encoded -> CGRect? in
            let values = encoded.split(separator: ",", omittingEmptySubsequences: false)
            guard values.count == 4,
                  let x = Double(values[0]), let y = Double(values[1]),
                  let width = Double(values[2]), let height = Double(values[3])
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        guard rects.count == rectString.split(separator: "~").count else { return nil }
        return PDFSourceAnchor(page: page, normalizedRects: rects, fingerprint: fingerprint)
    }
}

enum PDFPageReference {
    static func page(from url: URL) -> Int? {
        guard let fragment = url.fragment else { return nil }
        for part in fragment.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].lowercased() == "page",
                  let page = Int(pair[1]), page > 0 else { continue }
            return page
        }
        return nil
    }

    static func anchor(from url: URL) -> PDFSourceAnchor? {
        guard let fragment = url.fragment else { return nil }
        return PDFSourceAnchor.parse(fragment: fragment)
    }

    static func markdown(
        for url: URL,
        page: Int,
        root: URL,
        anchor: PDFSourceAnchor? = nil
    ) -> String? {
        guard page > 0 else { return nil }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        guard WorkspaceFiles.contains(canonicalURL, in: canonicalRoot) else { return nil }

        let rootPath = canonicalRoot.path
        guard canonicalURL.path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(canonicalURL.path.dropFirst(rootPath.count + 1))
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?")
        guard let encoded = relative.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }

        let label = canonicalURL.lastPathComponent
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let fragment = anchor?.page == page ? anchor!.fragment : "page=\(page)"
        return "[\(label) · p. \(page)](/\(encoded)#\(fragment))"
    }

    static func noteSnippet(
        for url: URL,
        page: Int,
        root: URL,
        commentary: String? = nil,
        selectedText: String? = nil,
        anchor: PDFSourceAnchor? = nil
    ) -> String? {
        guard let reference = markdown(for: url, page: page, root: root, anchor: anchor) else { return nil }

        var sections: [String] = []
        if let commentary {
            let trimmed = commentary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sections.append(trimmed) }
        }
        sections.append(reference)

        if let selectedText {
            let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let quote = trimmed
                    .components(separatedBy: .newlines)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
                sections.append(quote)
            }
        }

        return sections.joined(separator: "\n\n")
    }
}

struct PDFOutlineEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let depth: Int
    let pageIndex: Int
}

enum PDFReadingPositionStore {
    static let defaultsKey = "PKSNotesPDFReadingPositionsV1"
    static let maxEntries = 200

    static func pageIndex(
        for url: URL,
        pageCount: Int,
        defaults: UserDefaults = .standard
    ) -> Int? {
        guard pageCount > 0,
              let stored = defaults.dictionary(forKey: defaultsKey)?[url.standardizedFileURL.path] as? Int
        else { return nil }
        return min(max(0, stored), pageCount - 1)
    }

    static func save(
        pageIndex: Int,
        for url: URL,
        defaults: UserDefaults = .standard
    ) {
        let key = url.standardizedFileURL.path
        let normalized = max(0, pageIndex)
        var values = defaults.dictionary(forKey: defaultsKey) ?? [:]
        if values[key] as? Int == normalized { return }
        values[key] = normalized
        if values.count > maxEntries {
            let keep = values.keys.sorted().suffix(maxEntries)
            values = Dictionary(uniqueKeysWithValues: keep.compactMap { key in
                values[key].map { (key, $0) }
            })
        }
        defaults.set(values, forKey: defaultsKey)
    }
}

@MainActor
final class PDFReaderController: ObservableObject {
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var scalePercent = 100
    @Published private(set) var outline: [PDFOutlineEntry] = []
    @Published private(set) var searchMatchIndex = 0
    @Published private(set) var searchMatchCount = 0
    @Published private(set) var isSearching = false
    @Published private(set) var invalidRequestedPage: Int?
    @Published private(set) var invalidRequestedSelection = false

    private weak var pdfView: PDFView?
    private var document: PDFDocument?
    private var documentURL: URL?
    private var requestedPage: Int?
    private var requestedAnchor: PDFSourceAnchor?
    private var viewObservers: [NSObjectProtocol] = []
    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var searchMatches: [PDFSelection] = []

    func attach(
        view: PDFView,
        document: PDFDocument,
        url: URL,
        requestedPage: Int?,
        requestedAnchor: PDFSourceAnchor?
    ) {
        let viewChanged = pdfView !== view
        if viewChanged {
            removeViewObservers()
            pdfView = view
            installViewObservers(for: view)
        }

        let documentChanged = self.document !== document || documentURL != url
        let pageRequestChanged = self.requestedPage != requestedPage
        let anchorRequestChanged = self.requestedAnchor != requestedAnchor
        let presentationChanged = viewChanged || documentChanged
        self.document = document
        documentURL = url
        self.requestedPage = requestedPage
        self.requestedAnchor = requestedAnchor

        // PDFView presentation properties can trigger PDFKit layout/redraw work even when
        // assigned the same value. SwiftUI calls updateNSView for unrelated toolbar and
        // controller publications, so only configure the native view when its actual
        // view/document identity changes.
        if presentationChanged {
            if view.document !== document {
                view.document = document
            }
            view.displayMode = .singlePageContinuous
            view.displaysPageBreaks = true
            view.backgroundColor = .textBackgroundColor
        }

        if !presentationChanged {
            if pageRequestChanged || anchorRequestChanged {
                applyRequestedSource(page: requestedPage, anchor: requestedAnchor)
            } else {
                syncFromView()
            }
            return
        }

        cancelSearch()
        pageCount = document.pageCount
        outline = Self.flattenOutline(document.outlineRoot, in: document)

        if requestedPage != nil || requestedAnchor != nil {
            applyRequestedSource(page: requestedPage, anchor: requestedAnchor)
        } else if let restored = PDFReadingPositionStore.pageIndex(
            for: url,
            pageCount: document.pageCount
        ), let page = document.page(at: restored) {
            invalidRequestedPage = nil
            view.go(to: page)
        } else if let first = document.page(at: 0) {
            invalidRequestedPage = nil
            view.go(to: first)
        }
        syncFromView()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.fitWidth()
        }
    }

    private func applyRequestedSource(page: Int?, anchor: PDFSourceAnchor?) {
        if let anchor {
            applyRequestedAnchor(anchor)
        } else {
            invalidRequestedSelection = false
            pdfView?.currentSelection = nil
            applyRequestedPage(page)
        }
    }

    private func applyRequestedAnchor(_ anchor: PDFSourceAnchor) {
        guard anchor.page >= 1, anchor.page <= pageCount,
              let document,
              let page = document.page(at: anchor.page - 1),
              let view = pdfView
        else {
            invalidRequestedSelection = false
            applyRequestedPage(anchor.page)
            return
        }

        invalidRequestedPage = nil
        view.go(to: page)

        let pageBounds = page.bounds(for: .cropBox)
        let selections = anchor.rects(in: pageBounds).compactMap { page.selection(for: $0) }
        guard selections.count == anchor.normalizedRects.count,
              let combined = selections.first
        else {
            invalidRequestedSelection = true
            view.currentSelection = nil
            syncFromView()
            return
        }

        for selection in selections.dropFirst() {
            combined.add(selection)
        }
        guard let text = combined.string,
              anchor.matches(text: text)
        else {
            invalidRequestedSelection = true
            view.currentSelection = nil
            syncFromView()
            return
        }

        invalidRequestedSelection = false
        combined.color = NSColor.systemYellow.withAlphaComponent(0.45)
        view.currentSelection = combined
        view.go(to: combined)
        syncFromView()
    }

    private func applyRequestedPage(_ oneBasedPage: Int?) {
        guard let oneBasedPage else {
            invalidRequestedPage = nil
            return
        }
        guard oneBasedPage >= 1, oneBasedPage <= pageCount else {
            invalidRequestedPage = oneBasedPage
            return
        }
        invalidRequestedPage = nil
        goToPage(oneBasedPage)
    }

    func detach(view: PDFView) {
        guard pdfView === view else { return }
        removeViewObservers()
        pdfView = nil
    }

    func selectedText() -> String? {
        guard let text = pdfView?.currentSelection?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    func selectedSourceAnchor() -> PDFSourceAnchor? {
        guard let document,
              let selection = pdfView?.currentSelection,
              let text = selectedText(),
              let fingerprint = PDFSourceAnchor.fingerprint(for: text)
        else { return nil }

        let pages = selection.pages
        guard pages.count == 1, let page = pages.first else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex >= 0, pageIndex < document.pageCount else { return nil }

        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }

        let lines = selection.selectionsByLine()
        let selections = lines.isEmpty ? [selection] : lines
        guard selections.count <= PDFSourceAnchor.maxRects else { return nil }

        let normalizedRects = selections.compactMap { line -> CGRect? in
            let clipped = line.bounds(for: page).standardized.intersection(pageBounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            return CGRect(
                x: (clipped.minX - pageBounds.minX) / pageBounds.width,
                y: (clipped.minY - pageBounds.minY) / pageBounds.height,
                width: clipped.width / pageBounds.width,
                height: clipped.height / pageBounds.height
            )
        }
        guard normalizedRects.count == selections.count else { return nil }

        return PDFSourceAnchor(
            page: pageIndex + 1,
            normalizedRects: normalizedRects,
            fingerprint: fingerprint
        )
    }

    func goPrevious() {
        pdfView?.goToPreviousPage(nil)
        syncFromView()
    }

    func goNext() {
        pdfView?.goToNextPage(nil)
        syncFromView()
    }

    func goToPage(_ oneBasedPage: Int) {
        invalidRequestedSelection = false
        guard let document,
              let page = document.page(at: min(max(0, oneBasedPage - 1), max(0, pageCount - 1)))
        else { return }
        pdfView?.go(to: page)
        syncFromView()
    }

    func goToOutline(_ entry: PDFOutlineEntry) {
        goToPage(entry.pageIndex + 1)
    }

    func zoomIn() {
        adjustScale(multiplier: 1.15)
    }

    func zoomOut() {
        adjustScale(multiplier: 1 / 1.15)
    }

    func actualSize() {
        guard let view = pdfView else { return }
        view.autoScales = false
        view.scaleFactor = 1
        syncFromView()
    }

    func fitWidth() {
        guard let view = pdfView,
              let page = view.currentPage ?? document?.page(at: currentPageIndex)
        else { return }
        let pageBounds = page.bounds(for: view.displayBox)
        guard pageBounds.width > 0, view.bounds.width > 40 else { return }
        view.autoScales = false
        let target = (view.bounds.width - 28) / pageBounds.width
        view.scaleFactor = min(max(0.1, target), 8)
        syncFromView()
    }

    func search(_ query: String) {
        guard let document else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelSearch()

        guard !text.isEmpty else {
            pdfView?.currentSelection = nil
            return
        }

        searchGeneration &+= 1
        let generation = searchGeneration
        isSearching = true
        searchTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                document.findString(text, withOptions: .caseInsensitive)
            }
            let matches = await worker.value
            guard !Task.isCancelled,
                  let self,
                  self.searchGeneration == generation,
                  self.document === document else { return }

            self.searchMatches = matches
            self.searchMatchCount = matches.count
            self.searchMatchIndex = 0
            self.isSearching = false
            self.searchTask = nil
            if !matches.isEmpty {
                self.revealSearchMatch()
            }
        }
    }

    func previousSearchMatch() {
        guard !searchMatches.isEmpty else { return }
        searchMatchIndex = (searchMatchIndex - 1 + searchMatches.count) % searchMatches.count
        revealSearchMatch()
    }

    func nextSearchMatch() {
        guard !searchMatches.isEmpty else { return }
        searchMatchIndex = (searchMatchIndex + 1) % searchMatches.count
        revealSearchMatch()
    }

    private func adjustScale(multiplier: CGFloat) {
        guard let view = pdfView else { return }
        view.autoScales = false
        view.scaleFactor = min(max(0.1, view.scaleFactor * multiplier), 8)
        syncFromView()
    }

    private func syncPageFromView() {
        guard let view = pdfView, let document, let page = view.currentPage else { return }
        let pageIndex = max(0, document.index(for: page))
        if currentPageIndex != pageIndex {
            currentPageIndex = pageIndex
        }
        if let url = documentURL {
            PDFReadingPositionStore.save(pageIndex: pageIndex, for: url)
        }
    }

    private func syncScaleFromView() {
        guard let view = pdfView else { return }
        let percent = max(10, Int((view.scaleFactor * 100).rounded()))
        if scalePercent != percent {
            scalePercent = percent
        }
    }

    private func syncFromView() {
        syncPageFromView()
        syncScaleFromView()
    }

    private func installViewObservers(for view: PDFView) {
        let center = NotificationCenter.default
        viewObservers = [
            center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.syncPageFromView() }
            },
            center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.syncScaleFromView() }
            }
        ]
    }

    private func revealSearchMatch() {
        guard searchMatches.indices.contains(searchMatchIndex),
              let view = pdfView else { return }
        let selection = searchMatches[searchMatchIndex]
        selection.color = NSColor.systemYellow.withAlphaComponent(0.45)
        view.currentSelection = selection
        view.go(to: selection)
        syncFromView()
    }

    private func cancelSearch() {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        searchMatches.removeAll()
        searchMatchCount = 0
        searchMatchIndex = 0
        isSearching = false
    }

    private func removeViewObservers() {
        let center = NotificationCenter.default
        for observer in viewObservers { center.removeObserver(observer) }
        viewObservers.removeAll()
    }


    private static func flattenOutline(
        _ root: PDFOutline?,
        in document: PDFDocument
    ) -> [PDFOutlineEntry] {
        guard let root else { return [] }
        var entries: [PDFOutlineEntry] = []

        func visit(_ parent: PDFOutline, depth: Int, path: String) {
            for index in 0..<parent.numberOfChildren {
                guard let child = parent.child(at: index) else { continue }
                let childPath = path + ".\(index)"
                if let destination = child.destination,
                   let page = destination.page {
                    let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !title.isEmpty {
                        entries.append(.init(
                            id: childPath,
                            title: title,
                            depth: depth,
                            pageIndex: max(0, document.index(for: page))
                        ))
                    }
                }
                visit(child, depth: depth + 1, path: childPath)
            }
        }

        visit(root, depth: 0, path: "outline")
        return entries
    }
}

/// Native PDFKit reader. The PDF stays immutable source material; this view owns only reading UI state.
struct NativePDFPreview: View {
    @Environment(\.notesLanguage) private var language
    let url: URL
    let root: URL?
    let document: PDFDocument?
    let attemptedURL: URL?
    @ObservedObject var controller: PDFReaderController
    let requestedPage: Int?
    let requestedAnchor: PDFSourceAnchor?
    let onAddPageToNote: (Int, String?, PDFSourceAnchor?) -> Void

    @State private var pageText = "1"
    @State private var searchText = ""
    @State private var copiedPage: Int?

    var body: some View {
        Group {
            if let document, attemptedURL == url {
                VStack(spacing: 0) {
                    readerToolbar
                    if let invalid = controller.invalidRequestedPage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(language.text("Referenced PDF page is unavailable.")
                                 + " \(invalid) / \(max(1, controller.pageCount))")
                            Spacer()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .background(Color(nsColor: .controlBackgroundColor))
                    } else if controller.invalidRequestedSelection {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(language.text("Referenced PDF selection has changed."))
                            Spacer()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                    Divider()
                    PDFCanvas(
                        document: document,
                        url: url,
                        requestedPage: requestedPage,
                        requestedAnchor: requestedAnchor,
                        controller: controller
                    )
                    .accessibilityIdentifier("pks-pdf-canvas")
                }
            } else if attemptedURL == url {
                unavailableView
            } else {
                ProgressView(language.text("Opening PDF…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            pageText = String(controller.currentPageIndex + 1)
        }
        .onChange(of: url) { _, _ in
            // Loading belongs to NotesWindow. Reset only this reader's
            // transient controls when SwiftUI reuses it for another PDF.
            searchText = ""
            pageText = "1"
            copiedPage = nil
        }
        .onChange(of: controller.currentPageIndex) { _, page in
            pageText = String(page + 1)
            if copiedPage != page { copiedPage = nil }
        }
    }

    private var readerToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                pdfOutlineControls
                Divider().frame(height: 18)
                pdfNavigationControls
                pdfCaptureControls
                Spacer(minLength: 12)
                pdfSearchControls
                Divider().frame(height: 18)
                pdfZoomControls
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 860, minHeight: 38)

            // A narrow PDF column gets two readable tool rows, never an
            // overflowing single row of invisible / compressed controls.
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    pdfOutlineControls
                    pdfNavigationControls
                    Spacer(minLength: 0)
                    pdfCaptureControls
                }
                .frame(height: 36)
                HStack(spacing: 8) {
                    pdfSearchControls
                    Spacer(minLength: 0)
                    pdfZoomControls
                }
                .frame(height: 36)
            }
            .padding(.horizontal, 12)
        }
        .controlSize(.small)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pdfOutlineControls: some View {
            Menu {
                if controller.outline.isEmpty {
                    Text(language.text("No document outline"))
                } else {
                    ForEach(controller.outline) { entry in
                        Button {
                            controller.goToOutline(entry)
                        } label: {
                            Text(String(repeating: "  ", count: entry.depth) + entry.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "list.bullet.indent")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(controller.outline.isEmpty)
            .help(language.text("Document Outline"))
            .accessibilityIdentifier("pks-pdf-outline")
            // AppKit menus otherwise claim leftover toolbar width and
            // squeeze page/search controls at the split-pane threshold.
            .frame(width: 24, height: 26)
    }

    private var pdfNavigationControls: some View {
        HStack(spacing: 8) {
            Button { controller.goPrevious() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(controller.currentPageIndex <= 0)
            .help(language.text("Previous Page"))
            .accessibilityIdentifier("pks-pdf-previous-page")

            TextField("", text: $pageText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 46)
                .onSubmit {
                    if let page = Int(pageText) {
                        controller.goToPage(page)
                    }
                    pageText = String(controller.currentPageIndex + 1)
                }
                .accessibilityLabel(language.text("Page"))
                .accessibilityIdentifier("pks-pdf-page-field")

            Text("/ \(max(1, controller.pageCount))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("pks-pdf-page-count")

            Button { controller.goNext() } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(controller.pageCount == 0 || controller.currentPageIndex >= controller.pageCount - 1)
            .help(language.text("Next Page"))
            .accessibilityIdentifier("pks-pdf-next-page")
        }
    }

    private var pdfCaptureControls: some View {
        HStack(spacing: 8) {
            Button {
                let selectedText = controller.selectedText()
                let anchor = controller.selectedSourceAnchor()
                onAddPageToNote(
                    anchor?.page ?? controller.currentPageIndex + 1,
                    selectedText,
                    anchor
                )
            } label: {
                Label(language.text("Add to Note"), systemImage: "note.text.badge.plus")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .disabled(root == nil || controller.pageCount == 0)
            .help(language.text("Add current PDF page to note"))
            .accessibilityIdentifier("pks-pdf-add-page-to-note")

            Button {
                copyCurrentPageReference()
            } label: {
                Image(systemName: copiedPage == controller.currentPageIndex ? "checkmark" : "link.badge.plus")
            }
            .buttonStyle(.plain)
            .disabled(root == nil || controller.pageCount == 0)
            .help(language.text(copiedPage == controller.currentPageIndex
                                ? "PDF page link copied"
                                : "Copy PDF page link"))
            .accessibilityIdentifier("pks-pdf-copy-page-link")
        }
    }

    private var pdfSearchControls: some View {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(language.text("Find in PDF"), text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 120, idealWidth: 180, maxWidth: 220)
                    .onSubmit { controller.search(searchText) }
                    .onChange(of: searchText) { _, value in
                        if value.isEmpty { controller.search("") }
                    }
                    .accessibilityIdentifier("pks-pdf-search-field")
                Button {
                    controller.search(searchText)
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.plain)
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(language.text("Search PDF"))
                .accessibilityIdentifier("pks-pdf-search-submit")
                if controller.isSearching {
                    ProgressView().controlSize(.small)
                } else if controller.searchMatchCount > 0 {
                    Text("\(controller.searchMatchIndex + 1)/\(controller.searchMatchCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pks-pdf-search-count")
                }
                Button { controller.previousSearchMatch() } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(controller.searchMatchCount == 0)
                .accessibilityIdentifier("pks-pdf-search-previous")
                Button { controller.nextSearchMatch() } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(controller.searchMatchCount == 0)
                .accessibilityIdentifier("pks-pdf-search-next")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }

    private var pdfZoomControls: some View {
        HStack(spacing: 8) {
            Button { controller.zoomOut() } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help(language.text("Zoom Out"))
            .accessibilityIdentifier("pks-pdf-zoom-out")

            Button { controller.actualSize() } label: {
                Text("\(controller.scalePercent)%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 42)
            }
            .buttonStyle(.plain)
            .help(language.text("Actual Size"))
            .accessibilityIdentifier("pks-pdf-actual-size")
            .accessibilityValue("\(controller.scalePercent)")

            Button { controller.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help(language.text("Zoom In"))
            .accessibilityIdentifier("pks-pdf-zoom-in")

            Button { controller.fitWidth() } label: {
                Image(systemName: "arrow.left.and.right.square")
            }
            .buttonStyle(.plain)
            .help(language.text("Fit Width"))
            .accessibilityIdentifier("pks-pdf-fit-width")
        }
    }

    private func copyCurrentPageReference() {
        let anchor = controller.selectedSourceAnchor()
        let page = anchor?.page ?? controller.currentPageIndex + 1
        guard let root,
              let markdown = PDFPageReference.markdown(
                for: url,
                page: page,
                root: root,
                anchor: anchor
              ) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        copiedPage = controller.currentPageIndex
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 27, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(language.text("Cannot preview this PDF"))
                .font(.title3.weight(.medium))
            Text(language.text("The original file may be unavailable or damaged."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(language.text("Open with Default App")) {
                NSWorkspace.shared.open(url)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let url: URL
    let requestedPage: Int?
    let requestedAnchor: PDFSourceAnchor?
    let controller: PDFReaderController

    final class Coordinator {
        let controller: PDFReaderController
        init(controller: PDFReaderController) {
            self.controller = controller
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        controller.attach(
            view: view,
            document: document,
            url: url,
            requestedPage: requestedPage,
            requestedAnchor: requestedAnchor
        )
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        controller.attach(
            view: view,
            document: document,
            url: url,
            requestedPage: requestedPage,
            requestedAnchor: requestedAnchor
        )
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.controller.detach(view: view)
        view.document = nil
    }
}
