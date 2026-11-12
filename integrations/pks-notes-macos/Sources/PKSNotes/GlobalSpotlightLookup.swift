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
        guard term.count >= 2 else { return }

        let metadata = NSMetadataQuery()
        metadata.searchScopes = [NSMetadataQueryIndexedLocalComputerScope]
        metadata.predicate = NSPredicate(format: "%K CONTAINS[cd] %@",
                                         NSMetadataItemFSNameKey, term)
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
                let hits: [GlobalSearchItem] = metadata.results.prefix(250).compactMap { value in
                    guard let result = value as? NSMetadataItem,
                          let url = result.value(forAttribute: NSMetadataItemURLKey) as? URL,
                          url.isFileURL,
                          url.pathExtension.lowercased() != "app" else { return nil }
                    let name = result.value(forAttribute: NSMetadataItemFSNameKey) as? String
                        ?? url.lastPathComponent
                    let type = result.value(forAttribute: NSMetadataItemContentTypeKey) as? String
                    return GlobalSearchItem.spotlight(url, title: name,
                                                      isFolder: type == "public.folder")
                }
                self.cancel()
                completion(GlobalSpotlightLookup.rank(hits, for: term))
            }
        }
        if !metadata.start() { cancel() }
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
        let q = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return entries.sorted {
            func rank(_ item: GlobalSearchItem) -> Int {
                let name = item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if name == q { return 0 }
                if name.hasPrefix(q) { return 1 }
                return 2
            }
            let left = rank($0)
            let right = rank($1)
            if left != right { return left < right }
            if $0.title.count != $1.title.count { return $0.title.count < $1.title.count }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }.prefix(max(0, limit)).map { $0 }
    }
}
