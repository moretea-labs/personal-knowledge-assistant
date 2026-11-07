import AppKit
import PDFKit
import SwiftUI

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

    static func markdown(for url: URL, page: Int, root: URL) -> String? {
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
        return "[\(label) · p. \(page)](/\(encoded)#page=\(page))"
    }

    static func noteSnippet(
        for url: URL,
        page: Int,
        root: URL,
        commentary: String? = nil,
        selectedText: String? = nil
    ) -> String? {
        guard let reference = markdown(for: url, page: page, root: root) else { return nil }

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
        var values = defaults.dictionary(forKey: defaultsKey) ?? [:]
        values[url.standardizedFileURL.path] = max(0, pageIndex)
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

    private weak var pdfView: PDFView?
    private var document: PDFDocument?
    private var documentURL: URL?
    private var requestedPage: Int?
    private var viewObservers: [NSObjectProtocol] = []
    private var findObservers: [NSObjectProtocol] = []
    private var searchMatches: [PDFSelection] = []

    func attach(view: PDFView, document: PDFDocument, url: URL, requestedPage: Int?) {
        if pdfView !== view {
            removeViewObservers()
            pdfView = view
            installViewObservers(for: view)
        }

        let documentChanged = self.document !== document || documentURL != url
        let pageRequestChanged = self.requestedPage != requestedPage
        self.document = document
        documentURL = url
        self.requestedPage = requestedPage

        if view.document !== document {
            view.document = document
        }
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .textBackgroundColor

        if !documentChanged {
            if pageRequestChanged {
                applyRequestedPage(requestedPage)
            } else {
                syncFromView()
            }
            return
        }

        cancelSearch()
        pageCount = document.pageCount
        outline = Self.flattenOutline(document.outlineRoot, in: document)
        installFindObservers(for: document)

        if let requestedPage {
            applyRequestedPage(requestedPage)
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

    func goPrevious() {
        pdfView?.goToPreviousPage(nil)
        syncFromView()
    }

    func goNext() {
        pdfView?.goToNextPage(nil)
        syncFromView()
    }

    func goToPage(_ oneBasedPage: Int) {
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
        document.cancelFindString()
        searchMatches.removeAll()
        searchMatchCount = 0
        searchMatchIndex = 0

        guard !text.isEmpty else {
            isSearching = false
            pdfView?.currentSelection = nil
            return
        }
        isSearching = true
        document.beginFindString(text, withOptions: .caseInsensitive)
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

    private func syncFromView() {
        guard let view = pdfView else { return }
        if let document, let page = view.currentPage {
            currentPageIndex = max(0, document.index(for: page))
            if let url = documentURL {
                PDFReadingPositionStore.save(pageIndex: currentPageIndex, for: url)
            }
        }
        scalePercent = max(10, Int((view.scaleFactor * 100).rounded()))
    }

    private func installViewObservers(for view: PDFView) {
        let center = NotificationCenter.default
        viewObservers = [
            center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.syncFromView() }
            },
            center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.syncFromView() }
            }
        ]
    }

    private func installFindObservers(for document: PDFDocument) {
        removeFindObservers()
        let center = NotificationCenter.default
        findObservers = [
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] note in
                Task { @MainActor in
                    guard let self,
                          let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection
                    else { return }
                    self.searchMatches.append(selection)
                    self.searchMatchCount = self.searchMatches.count
                    if self.searchMatches.count == 1 {
                        self.searchMatchIndex = 0
                        self.revealSearchMatch()
                    }
                }
            },
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isSearching = false }
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
        document?.cancelFindString()
        searchMatches.removeAll()
        searchMatchCount = 0
        searchMatchIndex = 0
        isSearching = false
        removeFindObservers()
    }

    private func removeViewObservers() {
        let center = NotificationCenter.default
        for observer in viewObservers { center.removeObserver(observer) }
        viewObservers.removeAll()
    }

    private func removeFindObservers() {
        let center = NotificationCenter.default
        for observer in findObservers { center.removeObserver(observer) }
        findObservers.removeAll()
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
    let requestedPage: Int?
    let onAddPageToNote: (Int, String?) -> Void

    @State private var document: PDFDocument?
    @State private var attemptedURL: URL?
    @State private var pageText = "1"
    @State private var searchText = ""
    @State private var copiedPage: Int?
    @StateObject private var controller = PDFReaderController()

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
                    }
                    Divider()
                    PDFCanvas(
                        document: document,
                        url: url,
                        requestedPage: requestedPage,
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
        .task(id: url) {
            document = PDFDocument(url: url)
            attemptedURL = url
        }
        .onChange(of: controller.currentPageIndex) { _, page in
            pageText = String(page + 1)
            if copiedPage != page { copiedPage = nil }
        }
    }

    private var readerToolbar: some View {
        HStack(spacing: 8) {
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

            Divider().frame(height: 18)

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

            Button {
                onAddPageToNote(
                    controller.currentPageIndex + 1,
                    controller.selectedText()
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

            Spacer(minLength: 12)

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

            Divider().frame(height: 18)

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
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func copyCurrentPageReference() {
        guard let root,
              let markdown = PDFPageReference.markdown(
                for: url,
                page: controller.currentPageIndex + 1,
                root: root
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
        controller.attach(view: view, document: document, url: url, requestedPage: requestedPage)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        controller.attach(view: view, document: document, url: url, requestedPage: requestedPage)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.controller.detach(view: view)
        view.document = nil
    }
}
