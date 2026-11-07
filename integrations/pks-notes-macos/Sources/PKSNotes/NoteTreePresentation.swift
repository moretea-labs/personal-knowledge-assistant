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

        fileprivate init(item: NoteItem, foldedName: String, foldedFolder: String, insertionOrder: Int) {
            self.item = item
            self.foldedName = foldedName
            self.foldedFolder = foldedFolder
            self.insertionOrder = insertionOrder
        }
    }

    /// Normalize and alphabetize once when the filesystem tree changes instead of
    /// folding and sorting the full match set on every Quick Open keystroke.
    /// Build one buffer directly so a large flat vault does not allocate an
    /// openable-files copy, a tuple map, and a second mapped result array.
    static func quickOpenEntries(_ items: [NoteItem]) -> [QuickOpenEntry] {
        var entries: [QuickOpenEntry] = []
        entries.reserveCapacity(items.count)

        func visit(_ item: NoteItem) {
            if let children = item.children {
                children.forEach(visit)
                return
            }
            entries.append(
                QuickOpenEntry(
                    item: item,
                    foldedName: fold(item.name),
                    foldedFolder: fold(item.url.deletingLastPathComponent().path),
                    insertionOrder: entries.count
                )
            )
        }

        items.forEach(visit)
        entries.sort { lhs, rhs in
            let comparison = lhs.item.name.localizedStandardCompare(rhs.item.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.insertionOrder < rhs.insertionOrder
        }
        return entries
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

        // Entries are already alphabetized. Keep at most the requested number
        // of candidates per rank while scanning once, then concatenate ranks.
        var ranked = Array(repeating: [NoteItem](), count: 4)
        for entry in entries {
            let rank: Int?
            if entry.foldedName == search { rank = 0 }
            else if entry.foldedName.hasPrefix(search) { rank = 1 }
            else if entry.foldedName.contains(search) { rank = 2 }
            else if entry.foldedFolder.contains(search) { rank = 3 }
            else { rank = nil }

            if let rank, ranked[rank].count < limit {
                ranked[rank].append(entry.item)
            }
        }

        var result: [NoteItem] = []
        result.reserveCapacity(limit)
        for bucket in ranked {
            for item in bucket {
                result.append(item)
                if result.count == limit { return result }
            }
        }
        return result
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
