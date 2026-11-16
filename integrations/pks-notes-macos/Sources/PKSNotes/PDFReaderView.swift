import AppKit
import Darwin
import PDFKit
import SwiftUI

enum PDFDocumentLoadFailure: Error, Equatable {
    case missing
    case permissionDenied
    case cloudUnavailable
    case invalidPDF
    case passwordProtected
    case unreadable
    case cancelled

    var message: String {
        switch self {
        case .missing:
            "The PDF file could not be found. It may have been moved or deleted."
        case .permissionDenied:
            "Leafspan cannot read this PDF. Check the file's permissions or choose the workspace folder again."
        case .cloudUnavailable:
            "This PDF is not available from its cloud provider yet. Check your connection and cloud-drive status, then reload."
        case .invalidPDF:
            "This file could not be opened as a PDF. It may be damaged or use an unsupported format."
        case .passwordProtected:
            "This PDF is password-protected. Open it in Preview and save an unlocked copy to read it here."
        case .unreadable:
            "Leafspan could not read this PDF. Check that the file is available, then reload."
        case .cancelled:
            "Opening this PDF was cancelled."
        }
    }
}

enum PDFDocumentLoading {
    static func load(_ url: URL) async -> Result<PDFDocument, PDFDocumentLoadFailure> {
        let loader = Task.detached(priority: .userInitiated) {
            () -> Result<PDFDocument, PDFDocumentLoadFailure> in
            do {
                try await WorkspaceFiles.hydrateUbiquitousItemIfNeeded(url)
                try Task.checkCancellation()
                let handle = try FileHandle(forReadingFrom: url)
                try handle.close()
                guard let document = PDFDocument(url: url) else {
                    return .failure(.invalidPDF)
                }
                guard !document.isLocked else {
                    return .failure(.passwordProtected)
                }
                guard document.pageCount > 0 else {
                    return .failure(.invalidPDF)
                }
                return .success(document)
            } catch {
                return .failure(failure(for: error, url: url))
            }
        }
        // Detached workers do not inherit cancellation. When SwiftUI replaces
        // the active PDF task, propagate cancellation to an in-flight iCloud
        // hydration rather than leaving it running after a rapid file switch.
        let loaded = await withTaskCancellationHandler {
            await loader.value
        } onCancel: {
            loader.cancel()
        }
        return Task.isCancelled ? .failure(.cancelled) : loaded
    }

    static func failure(for error: Error, url: URL) -> PDFDocumentLoadFailure {
        if error is CancellationError { return .cancelled }
        var value = error as NSError
        // FileHandle wraps common POSIX failures in NSCocoaErrorDomain while
        // retaining the actionable errno as NSUnderlyingError.
        for _ in 0..<4 {
            if value.domain == NSCocoaErrorDomain {
                if value.code == CocoaError(.fileNoSuchFile).code.rawValue
                    || value.code == CocoaError(.fileReadNoSuchFile).code.rawValue {
                    return .missing
                }
                if value.code == CocoaError(.fileReadNoPermission).code.rawValue {
                    return .permissionDenied
                }
            }
            if value.domain == NSPOSIXErrorDomain {
                switch value.code {
                case Int(ENOENT):
                    return .missing
                case Int(EACCES), Int(EPERM):
                    return .permissionDenied
                default:
                    break
                }
            }
            guard let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError,
                  underlying !== value else { break }
            value = underlying
        }
        if WorkspaceFiles.isDataless(url) { return .cloudUnavailable }
        return .unreadable
    }
}

enum PDFCitationPasteboard {
    /// Internal type distinguishes a PDF citation from ordinary text dragged
    /// inside the editor; the same payload is also exported as plain text.
    static let type = NSPasteboard.PasteboardType("com.leafspan.pdf-citation")

    static func markdown(from item: Any?) -> String? {
        let value: String?
        if let data = item as? Data {
            value = String(data: data, encoding: .utf8)
        } else if let string = item as? String {
            value = string
        } else if let string = item as? NSString {
            value = string as String
        } else {
            value = nil
        }
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

struct PDFSourceAnchor: Equatable {
    static let maxRects = 32
    static let maxFragmentBytes = 4_096

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

        guard normalizedRects.allSatisfy({ rect in
            rect.origin.x.isFinite && rect.origin.y.isFinite
                && rect.size.width.isFinite && rect.size.height.isFinite
                && rect.size.width > 0 && rect.size.height > 0
                && rect.origin.x >= 0 && rect.origin.y >= 0
                && (rect.origin.x + rect.size.width).isFinite
                && (rect.origin.y + rect.size.height).isFinite
                && rect.origin.x + rect.size.width <= 1.000_01
                && rect.origin.y + rect.size.height <= 1.000_01
        }) else { return nil }
        let rects = normalizedRects

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
        guard fragment.utf8.count <= maxFragmentBytes else { return nil }

        var page: Int?
        var rectString: String?
        var fingerprint: String?

        for part in fragment.split(separator: "&", omittingEmptySubsequences: false) {
            guard !part.isEmpty else { return nil }
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[0].isEmpty else { return nil }

            switch pair[0].lowercased() {
            case "page":
                guard page == nil, let value = Int(pair[1]), value > 0 else { return nil }
                page = value
            case "rects":
                guard rectString == nil, !pair[1].isEmpty else { return nil }
                rectString = String(pair[1])
            case "fp":
                guard fingerprint == nil, !pair[1].isEmpty else { return nil }
                fingerprint = String(pair[1])
            default:
                continue
            }
        }

        guard let page, let rectString, let fingerprint else { return nil }
        let encodedRects = rectString.split(separator: "~", omittingEmptySubsequences: false)
        guard !encodedRects.isEmpty,
              encodedRects.count <= maxRects,
              encodedRects.allSatisfy({ !$0.isEmpty }) else { return nil }

        let rects = encodedRects.compactMap { encoded -> CGRect? in
            let values = encoded.split(separator: ",", omittingEmptySubsequences: false)
            guard values.count == 4,
                  let x = Double(values[0]), let y = Double(values[1]),
                  let width = Double(values[2]), let height = Double(values[3]),
                  x.isFinite, y.isFinite, width.isFinite, height.isFinite,
                  x >= 0, y >= 0, width > 0, height > 0,
                  x + width <= 1.000_01, y + height <= 1.000_01
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        guard rects.count == encodedRects.count else { return nil }
        return PDFSourceAnchor(page: page, normalizedRects: rects, fingerprint: fingerprint)
    }
}

enum PDFPageReference {
    static func page(from url: URL) -> Int? {
        guard let fragment = url.fragment else { return nil }
        var requestedPage: Int?
        for part in fragment.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].lowercased() == "page" else { continue }
            guard requestedPage == nil, let page = Int(pair[1]), page > 0 else { return nil }
            requestedPage = page
        }
        return requestedPage
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
        // Parentheses are legal in a URL but terminate Markdown destinations.
        // Encode them here, as with spaces and '#', so copied references and
        // PDF-to-note captures resolve to filenames such as "Plan (v2).pdf".
        allowed.remove(charactersIn: "#?()%")
        guard let encoded = relative.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }

        // The display label and canonical URL path have separate escaping rules.
        let label = MindMapOutline.escapeMarkdownLinkLabel(canonicalURL.lastPathComponent)
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
        let trimmedSelection = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let validAnchor: PDFSourceAnchor?
        if let trimmedSelection, !trimmedSelection.isEmpty,
           let anchor, anchor.page == page, anchor.matches(text: trimmedSelection) {
            validAnchor = anchor
        } else {
            // An unanchorable selection may still be useful context, but it must
            // never be stored as a quote that cannot be returned to precisely.
            validAnchor = nil
        }
        guard let reference = markdown(
            for: url, page: page, root: root, anchor: validAnchor
        ) else { return nil }

        var sections: [String] = []
        if let commentary {
            let trimmed = commentary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sections.append(trimmed) }
        }
        sections.append(reference)

        if let trimmedSelection, !trimmedSelection.isEmpty, validAnchor != nil {
            let quote = trimmedSelection
                .components(separatedBy: .newlines)
                .map { "> \(MindMapOutline.escapeInlineText($0))" }
                .joined(separator: "\n")
            sections.append(quote)
        }

        return sections.joined(separator: "\n\n")
    }
}

enum PDFStudyNoteTarget {
    static func resolve(note: URL?, pdf: URL, root: URL?, externalBody: String?) -> URL? {
        guard externalBody == nil,
              let note,
              let root,
              ["md", "markdown"].contains(note.pathExtension.lowercased()),
              WorkspaceFiles.contains(note, in: root),
              WorkspaceFiles.contains(pdf, in: root) else { return nil }
        return note
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

    private static let storedPageIndexKey = "pageIndex"
    private static let lastReadAtKey = "lastReadAt"

    static func pageIndex(
        for url: URL,
        pageCount: Int,
        defaults: UserDefaults = .standard
    ) -> Int? {
        guard pageCount > 0,
              let stored = defaults.dictionary(forKey: defaultsKey)?[url.standardizedFileURL.path],
              let pageIndex = storedPageIndex(in: stored)
        else { return nil }
        return min(max(0, pageIndex), pageCount - 1)
    }

    static func save(
        pageIndex: Int,
        for url: URL,
        defaults: UserDefaults = .standard
    ) {
        let key = url.standardizedFileURL.path
        let normalized = max(0, pageIndex)
        var values = defaults.dictionary(forKey: defaultsKey) ?? [:]
        if normalized == 0 {
            if values.removeValue(forKey: key) != nil {
                defaults.set(values, forKey: defaultsKey)
            }
            return
        }

        let now = Date().timeIntervalSince1970
        if let existing = values[key],
           storedPageIndex(in: existing) == normalized {
            let lastReadAt = lastReadAt(in: existing)
            if now >= lastReadAt, now - lastReadAt < 60 {
                return
            }
        }
        values[key] = [
            storedPageIndexKey: normalized,
            lastReadAtKey: now
        ]
        if values.count > maxEntries {
            let previousValues = values
            let keep = previousValues.keys.sorted {
                let lhs = lastReadAt(in: previousValues[$0])
                let rhs = lastReadAt(in: previousValues[$1])
                return lhs == rhs ? $0 > $1 : lhs > rhs
            }.prefix(maxEntries)
            values = Dictionary(uniqueKeysWithValues: keep.compactMap { existingKey in
                previousValues[existingKey].map { (existingKey, $0) }
            })
        }
        defaults.set(values, forKey: defaultsKey)
    }

    /// A successful workspace rename/move changes PDF identity, not reading progress.
    /// Rebase the one existing preferences dictionary, including PDFs inside moved folders.
    static func replacePath(
        _ from: URL, with to: URL, defaults: UserDefaults = .standard
    ) {
        let oldPath = from.standardizedFileURL.path
        let newPath = to.standardizedFileURL.path
        guard oldPath != newPath,
              var values = defaults.dictionary(forKey: defaultsKey) else { return }

        let moved = values.compactMap { path, value -> (String, Any)? in
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { return nil }
            return (newPath + path.dropFirst(oldPath.count), value)
        }
        // The target may have belonged to a previously deleted PDF. Its stale
        // path history must not supersede the newly moved file's position.
        for path in values.keys where path == newPath || path.hasPrefix(newPath + "/") {
            values.removeValue(forKey: path)
        }
        for path in values.keys where path == oldPath || path.hasPrefix(oldPath + "/") {
            values.removeValue(forKey: path)
        }
        for (path, value) in moved {
            values[path] = value
        }
        defaults.set(values, forKey: defaultsKey)
    }

    private static func storedPageIndex(in value: Any) -> Int? {
        if let legacyValue = value as? Int {
            return legacyValue
        }
        return (value as? [String: Any])?[storedPageIndexKey] as? Int
    }

    private static func lastReadAt(in value: Any?) -> TimeInterval {
        (value as? [String: Any])?[lastReadAtKey] as? TimeInterval ?? 0
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
    @Published private(set) var completedSearchQuery = ""
    @Published private(set) var isSearching = false
    @Published private(set) var invalidRequestedPage: Int?
    @Published private(set) var invalidRequestedSelection = false
    @Published private(set) var selectionNeedsPageOnlyReference = false

    private weak var pdfView: PDFView?
    private var document: PDFDocument?
    private var documentURL: URL?
    private var requestedPage: Int?
    private var requestedAnchor: PDFSourceAnchor?
    private var navigationSequence: UInt64 = 0
    private var viewObservers: [NSObjectProtocol] = []
    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var searchMatches: [PDFSelection] = []
    // PDFView has one current selection for both search hits and user source text.
    // Retain only the active search selection so invalidation cannot clear newer user intent.
    private var activeSearchSelection: PDFSelection?

    func attach(
        view: PDFView,
        document: PDFDocument,
        url: URL,
        requestedPage: Int?,
        requestedAnchor: PDFSourceAnchor?,
        navigationSequence: UInt64 = 0
    ) {
        let viewChanged = pdfView !== view
        let documentChanged = self.document !== document || documentURL != url
        if viewChanged || documentChanged {
            // Persist the outgoing document before replacing its PDFView or identity.
            syncPageFromView()
        }
        if viewChanged {
            removeViewObservers()
            pdfView = view
            installViewObservers(for: view)
        }

        let pageRequestChanged = self.requestedPage != requestedPage
        let anchorRequestChanged = self.requestedAnchor != requestedAnchor
        let navigationRequested = self.navigationSequence != navigationSequence
        let presentationChanged = viewChanged || documentChanged
        self.document = document
        documentURL = url
        self.requestedPage = requestedPage
        self.requestedAnchor = requestedAnchor
        self.navigationSequence = navigationSequence

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
            if pageRequestChanged || anchorRequestChanged || navigationRequested {
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
        Task { @MainActor [weak self, weak view, weak document] in
            await Task.yield()
            // A prior document's deferred layout must not resize the newly
            // opened PDF after the user switches A → B in the same window.
            guard let self, let view, let document,
                  self.pdfView === view, self.document === document,
                  self.documentURL == url else { return }
            self.fitWidth()
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
        syncPageFromView()
        removeViewObservers()
        pdfView = nil
        selectionNeedsPageOnlyReference = false
    }

    func selectedText() -> String? {
        guard let text = pdfView?.currentSelection?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    func selectedSourcePage() -> Int? {
        guard let document,
              let pages = pdfView?.currentSelection?.pages,
              !pages.isEmpty else { return nil }
        let pageIndex = pages
            .map { document.index(for: $0) }
            .filter { $0 >= 0 && $0 < document.pageCount }
            .min()
        return pageIndex.map { $0 + 1 }
    }

    /// A selected passage is the source of truth for its reference page.
    /// PDFView.currentPage can lag in continuous mode near page boundaries.
    func referencePageForCurrentSelection() -> Int {
        selectedSourcePage() ?? currentPageIndex + 1
    }

    /// The dragged payload is the same portable Markdown citation as Add to Note.
    /// NSTextView can insert this plain text at its native drop position, preserving
    /// the existing draft binding, undo stack and autosave writer.
    func selectedCitationForDrag(pdf: URL, root: URL) -> String? {
        guard let text = selectedText() else { return nil }
        let anchor = selectedSourceAnchor()
        let page = anchor?.page ?? referencePageForCurrentSelection()
        guard let snippet = PDFPageReference.noteSnippet(
            for: pdf, page: page, root: root, selectedText: text, anchor: anchor
        ) else { return nil }
        // The entire dropped citation remains a block even when the caret is
        // in the middle of an existing Markdown paragraph.
        return "\n\n\(snippet)\n\n"
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
        clearInvalidRequestedSourceWarning()
        pdfView?.goToPreviousPage(nil)
        syncFromView()
    }

    func goNext() {
        clearInvalidRequestedSourceWarning()
        pdfView?.goToNextPage(nil)
        syncFromView()
    }

    func goToPage(_ oneBasedPage: Int) {
        guard let document, pageCount > 0 else { return }
        guard (1...pageCount).contains(oneBasedPage) else {
            // The old clamping behavior silently opened a different page.
            // Keep the current position and expose the invalid requested page
            // through the same warning used by anchored PDF references.
            invalidRequestedPage = oneBasedPage
            return
        }
        guard let page = document.page(at: oneBasedPage - 1) else { return }
        clearInvalidRequestedSourceWarning()
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

    func invalidateSearchIfQueryChanged(_ query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != completedSearchQuery,
              isSearching || !completedSearchQuery.isEmpty || searchMatchCount > 0
        else { return }
        cancelSearch()
    }

    func search(_ query: String) {
        guard let document else { return }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelSearch()

        guard !text.isEmpty else { return }

        searchGeneration &+= 1
        let generation = searchGeneration
        isSearching = true
        searchTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                document.findString(text, withOptions: .caseInsensitive)
            }
            // Detached tasks do not inherit cancellation. Signal the worker
            // when the query/document changes; PDFKit's synchronous findString
            // is not forcibly preemptible, so the generation guard below
            // remains authoritative for discarding late results.
            let matches = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  let self,
                  self.searchGeneration == generation,
                  self.document === document else { return }

            self.searchMatches = matches
            self.completedSearchQuery = text
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

    private func syncPageFromView(preferredPage: PDFPage? = nil) {
        guard let view = pdfView,
              let document,
              let page = preferredPage ?? view.currentPage else { return }
        let pageIndex = document.index(for: page)
        // A page from a view that was just rebound belongs to another PDF.
        // PDFKit returns NSNotFound, which must never become a stored page index.
        guard pageIndex >= 0, pageIndex < document.pageCount else { return }
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
        syncSelectionStatus()
    }

    private func syncSelectionStatus() {
        if let activeSearchSelection,
           pdfView?.currentSelection !== activeSearchSelection {
            self.activeSearchSelection = nil
        }
        let hasSelectedText = selectedText() != nil
        if hasSelectedText {
            clearInvalidRequestedSourceWarning()
        }
        selectionNeedsPageOnlyReference = hasSelectedText && selectedSourceAnchor() == nil
    }

    private func installViewObservers(for view: PDFView) {
        let center = NotificationCenter.default
        viewObservers = [
            center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.syncPageFromView() }
            },
            center.addObserver(forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.syncScaleFromView() }
            },
            center.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.syncSelectionStatus() }
            }
        ]
    }

    private func clearInvalidRequestedSourceWarning() {
        invalidRequestedPage = nil
        invalidRequestedSelection = false
    }

    private func revealSearchMatch() {
        guard searchMatches.indices.contains(searchMatchIndex),
              let view = pdfView else { return }
        clearInvalidRequestedSourceWarning()
        let selection = searchMatches[searchMatchIndex]
        selection.color = NSColor.systemYellow.withAlphaComponent(0.45)
        view.currentSelection = selection
        view.go(to: selection)
        activeSearchSelection = view.currentSelection
        // In continuous mode PDFView.currentPage may remain the mostly-visible
        // previous page even after the search match is revealed. The match's
        // own page is the canonical navigation destination for toolbar state
        // and persisted reading position.
        syncPageFromView(preferredPage: selection.pages.first)
        syncScaleFromView()
    }

    private func cancelSearch() {
        searchGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
        searchMatches.removeAll()
        // Clear only the exact selection owned by search. The user may have
        // replaced it with a source passage that must survive query edits.
        if let activeSearchSelection,
           pdfView?.currentSelection === activeSearchSelection {
            pdfView?.currentSelection = nil
        }
        activeSearchSelection = nil
        syncSelectionStatus()
        completedSearchQuery = ""
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
                var descendantDepth = depth
                if let destination = child.destination,
                   let page = destination.page {
                    let pageIndex = document.index(for: page)
                    let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // PDFKit can return an out-of-range sentinel for a
                    // destination owned by another document; never expose it.
                    if !title.isEmpty, (0..<document.pageCount).contains(pageIndex) {
                        entries.append(.init(
                            id: childPath,
                            title: title,
                            depth: depth,
                            pageIndex: pageIndex
                        ))
                        // Skipped grouping/stale bookmarks must not leave visible
                        // descendants at an indentation with no visible parent.
                        descendantDepth += 1
                    }
                }
                visit(child, depth: descendantDepth, path: childPath)
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
    let loadFailure: PDFDocumentLoadFailure?
    @ObservedObject var controller: PDFReaderController
    let requestedPage: Int?
    let requestedAnchor: PDFSourceAnchor?
    let navigationSequence: UInt64
    let onAddPageToNote: (Int, String?, PDFSourceAnchor?) -> Void
    let onQuoteToCurrentNote: ((Int, String?, PDFSourceAnchor?) -> Void)?
    let onReload: () -> Void

    @State private var pageText = "1"
    @State private var searchText = ""
    @FocusState private var pdfSearchFocused: Bool
    @State private var copiedPage: Int?

    var body: some View {
        Group {
            if let document, attemptedURL == url {
                VStack(spacing: 0) {
                    readerToolbar
                    if let invalid = controller.invalidRequestedPage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(language.text("PDF page is unavailable.")
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
                            Text(language.text("Referenced PDF selection changed. The page is open, but the exact highlight is no longer available."))
                            Spacer()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .background(Color(nsColor: .controlBackgroundColor))
                    } else if root != nil && controller.selectionNeedsPageOnlyReference {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(language.text("This PDF selection cannot be linked precisely. Only a page link will be saved; the selected text will be omitted. Select a smaller passage on one page to save the quote with precise highlighting."))
                            Spacer()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .accessibilityIdentifier("pks-pdf-selection-anchor-warning")
                    }
                    Divider()
                    PDFCanvas(
                        document: document,
                        url: url,
                        root: root,
                        requestedPage: requestedPage,
                        requestedAnchor: requestedAnchor,
                        navigationSequence: navigationSequence,
                        controller: controller,
                        quoteTitle: language.text("Add to Study Note"),
                        copyCitationTitle: language.text("Copy Quote with Source"),
                        onQuoteToCurrentNote: onQuoteToCurrentNote.map { quote in
                            {
                                let anchor = controller.selectedSourceAnchor()
                                quote(anchor?.page ?? controller.referencePageForCurrentSelection(),
                                      controller.selectedText(), anchor)
                            }
                        },
                        onCopySelectedCitation: root.map { root in
                            {
                                guard let citation = controller.selectedCitationForDrag(
                                    pdf: url, root: root
                                ) else { return }
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(citation, forType: .string)
                            }
                        }
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
        .onReceive(NotificationCenter.default.publisher(for: NotesMenuEvent.findCurrentFile)) { _ in
            pdfSearchFocused = true
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
                pdfReloadControl
                Divider().frame(height: 18)
                pdfNavigationControls
                pdfCaptureControls(compact: false)
                Spacer(minLength: 12)
                pdfSearchControls
                Divider().frame(height: 18)
                pdfZoomControls
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 860, minHeight: 38)

            // Preserve direct zoom controls when they fit beside search.
            VStack(spacing: 0) {
                compactPDFPrimaryRow
                HStack(spacing: 8) {
                    pdfSearchControls
                    Spacer(minLength: 0)
                    pdfZoomControls
                }
                .frame(height: 36)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 560)

            // In a split PDF pane, the 420pt minimum width must still expose
            // page navigation, quote capture, search and zoom without clipping.
            VStack(spacing: 0) {
                compactPDFPrimaryRow
                HStack(spacing: 8) {
                    pdfSearchControls
                    Spacer(minLength: 0)
                    compactPDFZoomMenu
                }
                .frame(height: 36)
            }
            .padding(.horizontal, 12)
        }
        .controlSize(.small)
        .symbolRenderingMode(.hierarchical)
        .font(.system(size: NotesGeometry.symbolSize, weight: .medium))
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var compactPDFPrimaryRow: some View {
        HStack(spacing: 8) {
            pdfOutlineControls
            pdfReloadControl
            pdfNavigationControls
            Spacer(minLength: 0)
            pdfCaptureControls(compact: true)
        }
        .frame(height: 36)
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
            .accessibilityLabel(language.text("Document Outline"))
            .accessibilityIdentifier("pks-pdf-outline")
            // AppKit menus otherwise claim leftover toolbar width and
            // squeeze page/search controls at the split-pane threshold.
            .frame(width: 24, height: 26)
    }

    private var pdfReloadControl: some View {
        Button(action: onReload) {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .help(language.text("Reload PDF"))
        .accessibilityLabel(language.text("Reload PDF"))
        .accessibilityIdentifier("pks-pdf-reload")
    }

    private var pdfNavigationControls: some View {
        HStack(spacing: 8) {
            Button { controller.goPrevious() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(controller.currentPageIndex <= 0)
            .help(language.text("Previous Page"))
            .accessibilityLabel(language.text("Previous Page"))
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
                .accessibilityLabel(language.text("Total Pages"))
                .accessibilityValue("\(max(1, controller.pageCount))")
                .accessibilityIdentifier("pks-pdf-page-count")

            Button { controller.goNext() } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(controller.pageCount == 0 || controller.currentPageIndex >= controller.pageCount - 1)
            .help(language.text("Next Page"))
            .accessibilityLabel(language.text("Next Page"))
            .accessibilityIdentifier("pks-pdf-next-page")
        }
    }

    private func pdfCaptureControls(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                let selectedText = controller.selectedText()
                let anchor = controller.selectedSourceAnchor()
                onAddPageToNote(
                    anchor?.page ?? controller.referencePageForCurrentSelection(),
                    selectedText,
                    anchor
                )
            } label: {
                if compact {
                    Image(systemName: "note.text.badge.plus")
                } else {
                    Label(language.text("Add to Note"), systemImage: "note.text.badge.plus")
                        .font(.caption.weight(.medium))
                }
            }
            .buttonStyle(.plain)
            .disabled(root == nil || controller.pageCount == 0)
            .help(language.text("Add selected PDF text or current page to note"))
            .accessibilityLabel(language.text("Add to Note"))
            .accessibilityIdentifier("pks-pdf-add-page-to-note")

            Button {
                copyCurrentPageReference()
            } label: {
                Image(systemName: copiedPage == controller.referencePageForCurrentSelection() - 1 ? "checkmark" : "link.badge.plus")
            }
            .buttonStyle(.plain)
            .disabled(root == nil || controller.pageCount == 0)
            .help(language.text(copiedPage == controller.referencePageForCurrentSelection() - 1
                                ? "PDF page link copied"
                                : "Copy PDF page link"))
            .accessibilityLabel(language.text(copiedPage == controller.referencePageForCurrentSelection() - 1
                                ? "PDF page link copied"
                                : "Copy PDF page link"))
            .accessibilityIdentifier("pks-pdf-copy-page-link")
        }
    }

    private var pdfSearchControls: some View {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(language.text("Find in PDF"), text: $searchText)
                    .focused($pdfSearchFocused)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 120, idealWidth: 180, maxWidth: 220)
                    .onSubmit { controller.search(searchText) }
                    .onExitCommand { searchText = "" }
                    .onChange(of: searchText) { _, value in
                        controller.invalidateSearchIfQueryChanged(value)
                    }
                    .accessibilityLabel(language.text("Find in PDF"))
                    .accessibilityIdentifier("pks-pdf-search-field")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        pdfSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help(language.text("Clear Search"))
                    .accessibilityLabel(language.text("Clear Search"))
                    .accessibilityIdentifier("pks-pdf-search-clear")
                }
                Button {
                    controller.search(searchText)
                } label: {
                    Image(systemName: "arrow.right")
                }
                .buttonStyle(.plain)
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(language.text("Search PDF"))
                .accessibilityLabel(language.text("Search PDF"))
                .accessibilityIdentifier("pks-pdf-search-submit")
                if controller.isSearching {
                    ProgressView().controlSize(.small)
                } else if controller.searchMatchCount > 0 {
                    Text("\(controller.searchMatchIndex + 1)/\(controller.searchMatchCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(language.text("Search Result Position"))
                        .accessibilityValue("\(controller.searchMatchIndex + 1) / \(controller.searchMatchCount)")
                        .accessibilityIdentifier("pks-pdf-search-count")
                } else if !controller.completedSearchQuery.isEmpty,
                          controller.completedSearchQuery ==
                            searchText.trimmingCharacters(in: .whitespacesAndNewlines) {
                    Text(language.text("No matches"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pks-pdf-search-empty")
                }
                Button { controller.previousSearchMatch() } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(controller.searchMatchCount == 0)
                .accessibilityLabel(language.text("Previous Search Match"))
                .accessibilityIdentifier("pks-pdf-search-previous")
                Button { controller.nextSearchMatch() } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(controller.searchMatchCount == 0)
                .accessibilityLabel(language.text("Next Search Match"))
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
            .accessibilityLabel(language.text("Zoom Out"))
            .accessibilityIdentifier("pks-pdf-zoom-out")

            Button { controller.actualSize() } label: {
                Text("\(controller.scalePercent)%")
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 42)
            }
            .buttonStyle(.plain)
            .help(language.text("Actual Size"))
            .accessibilityLabel(language.text("Actual Size"))
            .accessibilityIdentifier("pks-pdf-actual-size")
            .accessibilityValue("\(controller.scalePercent)")

            Button { controller.zoomIn() } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help(language.text("Zoom In"))
            .accessibilityLabel(language.text("Zoom In"))
            .accessibilityIdentifier("pks-pdf-zoom-in")

            Button { controller.fitWidth() } label: {
                Image(systemName: "arrow.left.and.right.square")
            }
            .buttonStyle(.plain)
            .help(language.text("Fit Width"))
            .accessibilityLabel(language.text("Fit Width"))
            .accessibilityIdentifier("pks-pdf-fit-width")
        }
    }

    private var compactPDFZoomMenu: some View {
        Menu {
            Button {
                controller.zoomOut()
            } label: {
                Label(language.text("Zoom Out"), systemImage: "minus.magnifyingglass")
            }
            Button {
                controller.zoomIn()
            } label: {
                Label(language.text("Zoom In"), systemImage: "plus.magnifyingglass")
            }
            Button {
                controller.actualSize()
            } label: {
                Label(language.text("Actual Size"), systemImage: "1.circle")
            }
            Button {
                controller.fitWidth()
            } label: {
                Label(language.text("Fit Width"), systemImage: "arrow.left.and.right.square")
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(controller.scalePercent)%")
                    .font(.caption.monospacedDigit())
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
            }
            .frame(minWidth: 58, minHeight: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(language.text("Zoom level"))
        .accessibilityLabel(language.text("Zoom level"))
        .accessibilityValue("\(controller.scalePercent)%")
        .accessibilityIdentifier("pks-pdf-zoom-menu")
    }

    private func copyCurrentPageReference() {
        let anchor = controller.selectedSourceAnchor()
        let page = anchor?.page ?? controller.referencePageForCurrentSelection()
        guard let root,
              let markdown = PDFPageReference.markdown(
                for: url,
                page: page,
                root: root,
                anchor: anchor
              ) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        copiedPage = page - 1
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 27, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(language.text("Cannot preview this PDF"))
                .font(.title3.weight(.medium))
            Text(language.text(loadFailure?.message ?? "The original file may be unavailable or damaged."))
                .accessibilityIdentifier("pks-pdf-load-failure")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(language.text("Reload PDF"), action: onReload)
                .padding(.top, 6)
            Button(language.text("Open with Default App")) {
                NSWorkspace.shared.open(url)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Preserve PDFKit's native copy/search menu and add a direct path to the
/// active Markdown note only when the current PDF contains a text selection.
final class StudyPDFView: PDFView {
    var quoteTitle = "Add to Study Note"
    var copyCitationTitle = "Copy Quote with Source"
    var onQuoteToCurrentNote: (() -> Void)?
    var onCopySelectedCitation: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let standard = super.menu(for: event)
        guard onQuoteToCurrentNote != nil || onCopySelectedCitation != nil,
              let selectedText = currentSelection?.string,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return standard
        }
        let menu = (standard?.copy() as? NSMenu) ?? NSMenu()
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        if onQuoteToCurrentNote != nil {
            let item = NSMenuItem(title: quoteTitle,
                                  action: #selector(quoteSelection(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if onCopySelectedCitation != nil {
            let item = NSMenuItem(title: copyCitationTitle,
                                  action: #selector(copySelectedCitation(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func quoteSelection(_ sender: NSMenuItem) {
        onQuoteToCurrentNote?()
    }

    @objc private func copySelectedCitation(_ sender: NSMenuItem) {
        onCopySelectedCitation?()
    }
}

/// Hit-test individual text-line bounds instead of the union rectangle for a
/// multi-line selection. The union includes whitespace that should remain usable
/// for native PDFView scrolling rather than starting a citation drag.
enum PDFSelectionHitTesting {
    private static let hitSlop: CGFloat = 3

    static func contains(_ point: CGPoint, in selection: PDFSelection, on page: PDFPage) -> Bool {
        let lineSelections = selection.selectionsByLine()
        let candidates = lineSelections.isEmpty ? [selection] : lineSelections
        return candidates.contains { line in
            let bounds = line.bounds(for: page).standardized
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return false }
            return bounds.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point)
        }
    }
}

@MainActor
final class PDFSelectionDragGestureRecognizer: NSPanGestureRecognizer {
    private(set) var initialMouseDownEvent: NSEvent?

    override func mouseDown(with event: NSEvent) {
        initialMouseDownEvent = event
        super.mouseDown(with: event)
    }

    override func reset() {
        super.reset()
        initialMouseDownEvent = nil
    }
}

private struct PDFCanvas: NSViewRepresentable {
    let document: PDFDocument
    let url: URL
    let root: URL?
    let requestedPage: Int?
    let requestedAnchor: PDFSourceAnchor?
    let navigationSequence: UInt64
    let controller: PDFReaderController
    let quoteTitle: String
    let copyCitationTitle: String
    let onQuoteToCurrentNote: (() -> Void)?
    let onCopySelectedCitation: (() -> Void)?

    @MainActor
    final class Coordinator: NSObject, NSGestureRecognizerDelegate, NSDraggingSource {
        let controller: PDFReaderController
        weak var view: PDFView?
        var pdf: URL?
        var root: URL?

        init(controller: PDFReaderController) {
            self.controller = controller
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? NSPanGestureRecognizer,
                  let view, let selection = view.currentSelection,
                  controller.selectedText() != nil else { return false }
            let location = pan.location(in: view)
            let translation = pan.translation(in: view)
            let origin = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            guard let page = view.page(for: origin, nearest: false),
                  selection.pages.contains(where: { $0 === page }) else { return false }
            return PDFSelectionHitTesting.contains(
                view.convert(origin, to: page),
                in: selection,
                on: page
            )
        }

        @objc func dragSelectedText(_ recognizer: PDFSelectionDragGestureRecognizer) {
            guard recognizer.state == .began,
                  let view, let pdf, let root,
                  let citation = controller.selectedCitationForDrag(pdf: pdf, root: root),
                  let event = recognizer.initialMouseDownEvent,
                  event.type == .leftMouseDown else { return }

            let item = NSPasteboardItem()
            item.setString(citation, forType: .string)
            item.setString(citation, forType: PDFCitationPasteboard.type)
            let drag = NSDraggingItem(pasteboardWriter: item)
            let label = String(citation.prefix(64)).replacingOccurrences(of: "\n", with: " ")
            let image = NSImage(size: NSSize(width: 250, height: 34))
            image.lockFocus()
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 250, height: 34),
                         xRadius: 6, yRadius: 6).fill()
            (label as NSString).draw(in: NSRect(x: 10, y: 9, width: 230, height: 20),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 12),
                                                      .foregroundColor: NSColor.labelColor])
            image.unlockFocus()
            let initialLocation = view.convert(event.locationInWindow, from: nil)
            drag.setDraggingFrame(NSRect(origin: initialLocation,
                                         size: image.size), contents: image)
            view.beginDraggingSession(with: [drag], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = StudyPDFView()
        view.quoteTitle = quoteTitle
        view.copyCitationTitle = copyCitationTitle
        view.onQuoteToCurrentNote = onQuoteToCurrentNote
        view.onCopySelectedCitation = onCopySelectedCitation
        context.coordinator.view = view
        context.coordinator.pdf = url
        context.coordinator.root = root
        let recognizer = PDFSelectionDragGestureRecognizer(target: context.coordinator,
                                                              action: #selector(Coordinator.dragSelectedText(_:)))
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        controller.attach(
            view: view,
            document: document,
            url: url,
            requestedPage: requestedPage,
            requestedAnchor: requestedAnchor,
            navigationSequence: navigationSequence
        )
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if let view = view as? StudyPDFView {
            view.quoteTitle = quoteTitle
            view.copyCitationTitle = copyCitationTitle
            view.onQuoteToCurrentNote = onQuoteToCurrentNote
            view.onCopySelectedCitation = onCopySelectedCitation
        }
        context.coordinator.pdf = url
        context.coordinator.root = root
        controller.attach(
            view: view,
            document: document,
            url: url,
            requestedPage: requestedPage,
            requestedAnchor: requestedAnchor,
            navigationSequence: navigationSequence
        )
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.controller.detach(view: view)
        view.document = nil
    }
}
