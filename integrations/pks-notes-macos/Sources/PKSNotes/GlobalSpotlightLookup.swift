import Foundation

/// Finder-style metadata search using the system's existing Spotlight index.
/// The search is read-only; PKS remains the document-content index authority.
@MainActor
final class GlobalSpotlightLookup {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var searchToken = UUID()

    func start(_ text: String, completion: @escaping ([GlobalSearchItem]) -> Void) {
        cancel()
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GlobalSearchRanker.shouldStartDocumentSearch(for: term) else { return }

        let metadata = NSMetadataQuery()
        // IndexedLocalComputer omits some iCloud Drive files even when Finder
        // and Spotlight CLI can locate them. LocalComputer includes the home directory.
        metadata.searchScopes = [NSMetadataQueryLocalComputerScope]
        metadata.predicate = Self.searchPredicate(for: term)
        metadata.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]
        query = metadata
        let token = UUID()
        searchToken = token
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: metadata, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.searchToken == token,
                      let metadata = self.query else { return }
                metadata.disableUpdates()
                // A broad content query can return many matches. Inspect a
                // bounded projection, then prefer filename hits over body hits.
                // The old 250-row prefix truncated useful matches prematurely.
                var metadataByPath: [String: NSMetadataItem] = [:]
                let hits: [GlobalSearchItem] = metadata.results.prefix(5000).compactMap { value in
                    guard let result = value as? NSMetadataItem,
                          let url = Self.fileURL(
                              metadataURL: result.value(forAttribute: NSMetadataItemURLKey) as? URL,
                              metadataPath: result.value(forAttribute: NSMetadataItemPathKey) as? String
                          ),
                          url.pathExtension.lowercased() != "app" else { return nil }
                    metadataByPath[url.path] = result
                    let name = result.value(forAttribute: NSMetadataItemFSNameKey) as? String
                        ?? url.lastPathComponent
                    let type = result.value(forAttribute: NSMetadataItemContentTypeKey) as? String
                    let relevance = (result.value(
                        forAttribute: NSMetadataQueryResultContentRelevanceAttribute
                    ) as? NSNumber)?.doubleValue ?? 0
                    return GlobalSearchItem.spotlight(url, title: name,
                                                      isFolder: type == "public.folder",
                                                      relevance: relevance)
                }
                let ranked = GlobalSpotlightLookup.rank(hits, for: term)
                let enriched = ranked.map { item in
                    guard let result = metadataByPath[item.url.path],
                          let content = result.value(forAttribute: "kMDItemTextContent") as? String,
                          let snippet = Self.contentSnippet(content, matching: term) else { return item }
                    return item.withSnippet(snippet)
                }
                self.cancel()
                completion(enriched)
            }
        }
        if !metadata.start() { cancel() }
    }

    // Reuse macOS Spotlight's existing content index; no new disk crawl or
    // document ingestion. Very short queries stay filename-only to avoid
    // broad, low-signal full-text searches.
    nonisolated static func searchPredicate(for term: String) -> NSPredicate {
        if term.count < 3 {
            return NSPredicate(
                format: "(%K CONTAINS[cd] %@) OR (%K CONTAINS[cd] %@)",
                NSMetadataItemFSNameKey, term, NSMetadataItemPathKey, term
            )
        }
        return NSPredicate(
            format: "(%K CONTAINS[cd] %@) OR (%K CONTAINS[cd] %@) OR (%K CONTAINS[cd] %@)",
            NSMetadataItemFSNameKey, term,
            "kMDItemTextContent", term,
            NSMetadataItemPathKey, term
        )
    }

    /// Extract a short excerpt from Spotlight's existing indexed content. This reads
    /// metadata only; it never opens or hydrates the matched document.
    nonisolated static func contentSnippet(
        _ content: String?, matching term: String, limit: Int = 120
    ) -> String? {
        let maximum = max(1, limit)
        guard let content, !content.isEmpty, !term.isEmpty, term.count <= maximum,
              let match = content.range(
                  of: term, options: [.caseInsensitive, .diacriticInsensitive]
              ) else { return nil }

        let context = max(8, (maximum - term.count) / 2)
        let start = content.index(
            match.lowerBound, offsetBy: -context, limitedBy: content.startIndex
        ) ?? content.startIndex
        let end = content.index(
            match.upperBound, offsetBy: context, limitedBy: content.endIndex
        ) ?? content.endIndex
        let excerpt = content[start..<end]
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let clipped = String(excerpt.prefix(maximum))
        guard !clipped.isEmpty else { return nil }
        return (start > content.startIndex ? "…" : "") + clipped
            + (end < content.endIndex ? "…" : "")
    }

    // NSMetadataItemURLKey can be absent for iCloud Drive and local results;
    // NSMetadataItemPathKey still identifies the document. Returning a URL
    // does not grant sandbox access to the file's contents.
    nonisolated static func fileURL(metadataURL: URL?, metadataPath: String?) -> URL? {
        if let metadataURL, metadataURL.isFileURL { return metadataURL }
        guard let metadataPath, metadataPath.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: metadataPath)
    }

    func cancel() {
        searchToken = UUID()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        query?.stop()
        query = nil
    }

    /// Deterministic top-N projection; no local catalog or alternate index.
    nonisolated static func rank(_ entries: [GlobalSearchItem], for term: String, limit: Int = 35) -> [GlobalSearchItem] {
        // Derive all query-specific matching once. The same cached result
        // drives Spotlight top-N, the content-match badge and unified merge.
        let ranked = entries.map { item in
            let ranking = GlobalSearchRanker.ranking(for: item, query: term)
            return (item: item.withRanking(ranking), ranking: ranking)
        }
        return ranked.sorted { left, right in
            let leftName = left.ranking.spotlightNameRank
            let rightName = right.ranking.spotlightNameRank
            if leftName != rightName { return leftName < rightName }
            let leftPath = left.ranking.spotlightPathRank
            let rightPath = right.ranking.spotlightPathRank
            if leftPath != rightPath { return leftPath < rightPath }

            if leftName == 5, leftPath == 5,
               left.item.spotlightRelevance != right.item.spotlightRelevance {
                return left.item.spotlightRelevance > right.item.spotlightRelevance
            }
            if left.item.title.count != right.item.title.count {
                return left.item.title.count < right.item.title.count
            }
            return left.item.title.localizedStandardCompare(right.item.title) == .orderedAscending
        }.prefix(max(0, limit)).map(\.item)
    }
}
