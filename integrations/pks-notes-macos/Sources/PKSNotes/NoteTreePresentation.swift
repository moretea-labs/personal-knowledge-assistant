import Foundation

/// Window-local disclosure state for the visible tree, not a second file index.
enum NoteTreePresentation {
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

    struct QuickOpenEntry: Identifiable {
        let item: NoteItem
        let foldedName: String
        let foldedFolder: String
        let insertionOrder: Int
        var id: String { item.id }

        init(item: NoteItem, insertionOrder: Int) {
            self.item = item
            self.foldedName = NoteTreePresentation.fold(item.name)
            self.foldedFolder = NoteTreePresentation.fold(item.url.deletingLastPathComponent().path)
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

        func appendFile(_ item: NoteItem) {
            let path = item.url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return }
            entries.append(QuickOpenEntry(item: item, insertionOrder: entries.count))
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
            // Keep the index order consistent with the literal hasPrefix checks
            // below. Natural numeric collation can interleave prefix matches
            // (for example "Note 10") with non-prefix names ("Note 2").
            if lhs.foldedName != rhs.foldedName {
                return lhs.foldedName < rhs.foldedName
            }
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

    /// Case/diacritic-insensitive native file matching, without another search index.
    /// Name prefix matches precede name substring, then parent-folder path matches.
    static func quickOpen(_ entries: [QuickOpenEntry], query: String, limit: Int = 24) -> [NoteItem] {
        let search = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !search.isEmpty, limit > 0 else { return [] }

        var result: [NoteItem] = []
        result.reserveCapacity(limit)

        // Entries are sorted by foldedName, so the common exact/prefix path can
        // jump straight to the first possible match instead of scanning the vault.
        var index = quickOpenLowerBound(entries, search: search)

        // Exact names always outrank longer prefix matches.
        while index < entries.count, entries[index].foldedName == search {
            result.append(entries[index].item)
            if result.count == limit { return result }
            index += 1
        }

        while index < entries.count, entries[index].foldedName.hasPrefix(search) {
            result.append(entries[index].item)
            if result.count == limit { return result }
            index += 1
        }

        // Only uncommon substring/path queries pay the complete-index scan.
        // Gather both lower-priority ranks in one pass so a path fallback does
        // not traverse a large vault a second time.
        let remaining = limit - result.count
        var nameSubstringMatches: [NoteItem] = []
        var folderMatches: [NoteItem] = []
        nameSubstringMatches.reserveCapacity(remaining)
        folderMatches.reserveCapacity(remaining)

        for entry in entries {
            if entry.foldedName.hasPrefix(search) { continue }

            if entry.foldedName.contains(search) {
                nameSubstringMatches.append(entry.item)
                if nameSubstringMatches.count == remaining {
                    result.append(contentsOf: nameSubstringMatches)
                    return result
                }
            } else if entry.foldedFolder.contains(search), folderMatches.count < remaining {
                folderMatches.append(entry.item)
            }
        }

        result.append(contentsOf: nameSubstringMatches)
        if result.count == limit { return result }

        for item in folderMatches {
            result.append(item)
            if result.count == limit { break }
        }
        return result
    }

    private static func quickOpenLowerBound(_ entries: [QuickOpenEntry], search: String) -> Int {
        var lower = 0
        var upper = entries.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            // Use the same lexicographic order as sortQuickOpenEntries so
            // every literal prefix match remains in one searchable range.
            if entries[middle].foldedName < search {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    static func quickOpen(_ files: [NoteItem], query: String, limit: Int = 24) -> [NoteItem] {
        quickOpen(quickOpenEntries(files), query: query, limit: limit)
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
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
