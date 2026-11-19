import Foundation
import NaturalLanguage

/// Window-local disclosure state for the visible tree, not a second file index.
enum NoteTreePresentation {
    struct TransliterationKey: Sendable {
        let value: String
        let tokenStarts: Set<Int>
    }

    /// Reuses pure token-to-Latin conversions for one transient index build.
    final class TransliterationTokenCache {
        private var values: [String: String] = [:]

        init(reservingCapacity: Int = 0) {
            values.reserveCapacity(reservingCapacity)
        }

        func resolve(_ token: String) -> String? {
            if let cached = values[token] { return cached }
            guard let normalized = NoteTreePresentation.transliterationToken(token) else { return nil }
            values[token] = normalized
            return normalized
        }
    }

    struct Row: Identifiable {
        let item: NoteItem
        let depth: Int
        var id: String { item.id }
    }
    static func visibleRows(_ items: [NoteItem], expandedPaths: Set<String>) -> [Row] {
        var rows: [Row] = []
        func visit(_ item: NoteItem, depth: Int) {
            rows.append(Row(item: item, depth: depth))
            if expandedPaths.contains(item.id), let children = item.children {
                children.forEach { visit($0, depth: depth + 1) }
            }
        }
        items.forEach { visit($0, depth: 0) }
        return rows
    }

    /// A derived list for Quick Open. Built once per vault scan, never persisted.
    static func openableFiles(_ items: [NoteItem]) -> [NoteItem] {
        var result: [NoteItem] = []
        func visit(_ item: NoteItem) {
            if let children = item.children {
                children.forEach(visit)
            } else {
                result.append(item)
            }
        }
        items.forEach(visit)
        return result
    }

    /// Search keys are built with the Quick Open projection and reused across queries.
    struct QuickOpenEntry: Identifiable, Sendable {
        let item: NoteItem
        let foldedName: String
        let foldedFolder: String
        let pathTransliterationKey: TransliterationKey
        let nameTransliterationKey: TransliterationKey
        let insertionOrder: Int
        var id: String { item.id }

        init(item: NoteItem, insertionOrder: Int) {
            self.init(
                item: item,
                insertionOrder: insertionOrder,
                transliteration: NoteTreePresentation.transliterationKeys(
                    path: item.url.standardizedFileURL.path,
                    filename: item.name,
                    useASCIIIndexFastPath: true
                )
            )
        }

        init(item: NoteItem, insertionOrder: Int, tokenCache: TransliterationTokenCache) {
            self.init(
                item: item,
                insertionOrder: insertionOrder,
                transliteration: NoteTreePresentation.transliterationKeys(
                    path: item.url.standardizedFileURL.path,
                    filename: item.name,
                    useASCIIIndexFastPath: true,
                    tokenCache: tokenCache
                )
            )
        }

        private init(
            item: NoteItem, insertionOrder: Int,
            transliteration: (path: TransliterationKey, name: TransliterationKey)
        ) {
            self.item = item
            self.foldedName = NoteTreePresentation.fold(item.name)
            self.foldedFolder = NoteTreePresentation.fold(item.url.deletingLastPathComponent().path)
            self.pathTransliterationKey = transliteration.path
            self.nameTransliterationKey = transliteration.name
            self.insertionOrder = insertionOrder
        }
    }

    /// Normalize and alphabetize once when the filesystem tree changes instead of
    /// folding and sorting the full match set on every Quick Open keystroke.
    /// Build one buffer directly so a large flat vault does not allocate an
    /// openable-files copy, a tuple map, and a second mapped result array.
    static func quickOpenEntries(
        _ items: [NoteItem],
        prioritizedFiles: [URL] = []
    ) -> [QuickOpenEntry] {
        var entries: [QuickOpenEntry] = []
        entries.reserveCapacity(items.count + prioritizedFiles.count)
        var seenPaths: Set<String> = []
        seenPaths.reserveCapacity(items.count + prioritizedFiles.count)
        let tokenCache = TransliterationTokenCache(reservingCapacity: 512)

        func appendFile(_ item: NoteItem) {
            let path = item.url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return }
            entries.append(QuickOpenEntry(
                item: item, insertionOrder: entries.count, tokenCache: tokenCache
            ))
        }

        // Current/recent/favorite notes are already-known navigation targets.
        // Seeding them adds no recursive filesystem I/O and makes deep notes
        // searchable while the complete-vault utility scan is still running.
        prioritizedFiles.forEach {
            appendFile(NoteItem(url: $0.standardizedFileURL, children: nil))
        }

        func visit(_ item: NoteItem) {
            if let children = item.children {
                children.forEach(visit)
                return
            }
            appendFile(item)
        }

        items.forEach(visit)
        sortQuickOpenEntries(&entries)
        return entries
    }

    static func sortQuickOpenEntries(_ entries: inout [QuickOpenEntry]) {
        entries.sort { lhs, rhs in
            let foldedComparison = lhs.foldedName.localizedStandardCompare(rhs.foldedName)
            if foldedComparison != .orderedSame { return foldedComparison == .orderedAscending }
            let nameComparison = lhs.item.name.localizedStandardCompare(rhs.item.name)
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
            return lhs.insertionOrder < rhs.insertionOrder
        }
    }

    /// Show a note's folder path relative to its selected workspace.
    /// This makes identically named notes in import/backup folders distinguishable.
    static func quickOpenFolder(for url: URL, in root: URL?) -> String {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard let root else { return parent.lastPathComponent }
        let base = root.standardizedFileURL.path
        let parentPath = parent.path
        guard parentPath == base || parentPath.hasPrefix(base + "/") else {
            return parent.lastPathComponent
        }
        let relative = String(parentPath.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? "Workspace Root" : relative
    }

    /// Case/diacritic-insensitive matching without another search index.
    /// One bounded in-memory pass preserves natural ordering within each rank.
    static func quickOpen(_ entries: [QuickOpenEntry], query: String, limit: Int = 24) -> [NoteItem] {
        let search = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !search.isEmpty, limit > 0 else { return [] }

        var exactMatches: [NoteItem] = []
        var prefixMatches: [NoteItem] = []
        var nameSubstringMatches: [NoteItem] = []
        var folderMatches: [NoteItem] = []
        exactMatches.reserveCapacity(limit)
        prefixMatches.reserveCapacity(limit)
        nameSubstringMatches.reserveCapacity(limit)
        folderMatches.reserveCapacity(limit)

        for entry in entries {
            if entry.foldedName == search {
                exactMatches.append(entry.item)
                if exactMatches.count == limit { return exactMatches }
            } else if entry.foldedName.hasPrefix(search) {
                if prefixMatches.count < limit { prefixMatches.append(entry.item) }
            } else if entry.foldedName.contains(search) {
                if nameSubstringMatches.count < limit { nameSubstringMatches.append(entry.item) }
            } else if entry.foldedFolder.contains(search), folderMatches.count < limit {
                folderMatches.append(entry.item)
            }
        }

        var result = exactMatches
        for matches in [prefixMatches, nameSubstringMatches, folderMatches] {
            let remaining = limit - result.count
            if remaining <= 0 { break }
            result.append(contentsOf: matches.prefix(remaining))
        }
        return result
    }

    static func quickOpen(_ files: [NoteItem], query: String, limit: Int = 24) -> [NoteItem] {
        quickOpen(quickOpenEntries(files), query: query, limit: limit)
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func transliterationToken(_ token: String) -> String? {
        let latin = token.applyingTransform(.toLatin, reverse: false) ?? token
        let folded = latin.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let normalized = String(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedToken(
        _ token: String, cache: TransliterationTokenCache?
    ) -> String? {
        guard let cache else { return transliterationToken(token) }
        return cache.resolve(token)
    }

    static func transliterationKey(
        _ value: String,
        useASCIIIndexFastPath: Bool = false,
        tokenCache: TransliterationTokenCache? = nil
    ) -> TransliterationKey {
        if useASCIIIndexFastPath {
            // Most workspace paths are Latin. Keep index construction cheap;
            // content-body transliteration stays on NaturalLanguage below.
            let folded = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            if folded.utf8.allSatisfy({ $0 < 0x80 }) {
                var keyBytes = [UInt8]()
                var tokenStarts = Set<Int>()
                var insideToken = false
                for byte in folded.utf8 {
                    let isAlphanumeric =
                        (byte >= 0x30 && byte <= 0x39)
                        || (byte >= 0x41 && byte <= 0x5A)
                        || (byte >= 0x61 && byte <= 0x7A)
                    if isAlphanumeric {
                        if !insideToken { tokenStarts.insert(keyBytes.count) }
                        keyBytes.append(byte)
                        insideToken = true
                    } else if byte == 0x27 && insideToken {
                        continue
                    } else {
                        insideToken = false
                    }
                }
                return TransliterationKey(
                    value: String(decoding: keyBytes, as: UTF8.self),
                    tokenStarts: tokenStarts
                )
            }
        }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = value
        var key = ""
        var tokenStarts = Set<Int>()
        for range in tokenizer.tokens(for: value.startIndex..<value.endIndex) {
            let token = String(value[range])
            guard let normalized = normalizedToken(token, cache: tokenCache) else { continue }
            tokenStarts.insert(key.count)
            key.append(normalized)
        }
        return TransliterationKey(value: key, tokenStarts: tokenStarts)
    }

    /// Build path and filename pinyin keys in one NaturalLanguage pass. The
    /// filename is the path suffix, so its tokens can be collected while the
    /// full path key is built instead of tokenizing the same CJK name twice.
    static func transliterationKeys(
        path: String, filename: String, useASCIIIndexFastPath: Bool = false,
        tokenCache: TransliterationTokenCache? = nil
    ) -> (path: TransliterationKey, name: TransliterationKey) {
        guard path.hasSuffix(filename),
              let filenameStart = path.index(
                path.endIndex, offsetBy: -filename.count, limitedBy: path.startIndex
              ) else {
            return (
                transliterationKey(path, useASCIIIndexFastPath: useASCIIIndexFastPath, tokenCache: tokenCache),
                transliterationKey(filename, useASCIIIndexFastPath: useASCIIIndexFastPath, tokenCache: tokenCache)
            )
        }
        if useASCIIIndexFastPath,
           path.utf8.allSatisfy({ $0 < 0x80 })
               || path.folding(
                   options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current
               ).utf8.allSatisfy({ $0 < 0x80 }) {
            return (
                transliterationKey(path, useASCIIIndexFastPath: true, tokenCache: tokenCache),
                transliterationKey(filename, useASCIIIndexFastPath: true, tokenCache: tokenCache)
            )
        }

        let filenameIsASCII = useASCIIIndexFastPath
            && (filename.utf8.allSatisfy({ $0 < 0x80 })
                || filename.folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current
                ).utf8.allSatisfy({ $0 < 0x80 }))
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = path
        var pathValue = ""
        var pathStarts: Set<Int> = []
        var nameValue = ""
        var nameStarts: Set<Int> = []
        for range in tokenizer.tokens(for: path.startIndex..<path.endIndex) {
            guard let normalized = normalizedToken(String(path[range]), cache: tokenCache) else { continue }
            pathStarts.insert(pathValue.count)
            pathValue.append(normalized)
            if !filenameIsASCII, range.lowerBound >= filenameStart {
                nameStarts.insert(nameValue.count)
                nameValue.append(normalized)
            }
        }
        let pathKey = TransliterationKey(value: pathValue, tokenStarts: pathStarts)
        let nameKey = filenameIsASCII
            ? transliterationKey(filename, useASCIIIndexFastPath: true, tokenCache: tokenCache)
            : TransliterationKey(value: nameValue, tokenStarts: nameStarts)
        return (pathKey, nameKey)
    }

    enum Direction {
        case up, down, left, right
    }

    /// Finder-style movement through the currently visible rows only.
    /// This is window presentation state; the filesystem tree remains authoritative.
    static func navigate(_ direction: Direction, rows: [Row],
                         focusedPath: String?, expandedPaths: Set<String>)
        -> (path: String, expanded: Set<String>)? {
        guard !rows.isEmpty else { return nil }
        guard let index = rows.firstIndex(where: { $0.id == focusedPath }) else {
            return (direction == .up ? rows[rows.count - 1].id : rows[0].id, expandedPaths)
        }
        let row = rows[index]
        var expanded = expandedPaths
        switch direction {
        case .up:
            return (rows[max(0, index - 1)].id, expanded)
        case .down:
            return (rows[min(rows.count - 1, index + 1)].id, expanded)
        case .right:
            guard row.item.isFolder else { return (row.id, expanded) }
            if !expanded.contains(row.id) {
                expanded.insert(row.id)
                return (row.id, expanded)
            }
            if index + 1 < rows.count, rows[index + 1].depth == row.depth + 1 {
                return (rows[index + 1].id, expanded)
            }
            return (row.id, expanded)
        case .left:
            if row.item.isFolder, expanded.remove(row.id) != nil {
                return (row.id, expanded)
            }
            guard row.depth > 0 else { return (row.id, expanded) }
            let parent = row.item.url.deletingLastPathComponent().path
            return (rows.contains(where: { $0.id == parent }) ? parent : row.id, expanded)
        }
    }

    static func ancestorPaths(for note: URL, in root: URL) -> Set<String> {
        let rootPath = root.standardizedFileURL.path
        var parent = note.deletingLastPathComponent().standardizedFileURL
        var result: Set<String> = []
        while parent.path != rootPath, parent.path.hasPrefix(rootPath + "/") {
            result.insert(parent.path)
            let next = parent.deletingLastPathComponent()
            guard next != parent else { break }
            parent = next
        }
        return result
    }
}
