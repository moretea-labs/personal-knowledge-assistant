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

    /// Case/diacritic-insensitive native file matching, without another search index.
    /// Name prefix matches precede name substring, then parent-folder path matches.
    static func quickOpen(_ files: [NoteItem], query: String, limit: Int = 24) -> [NoteItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !search.isEmpty, limit > 0 else { return [] }
        func score(_ item: NoteItem) -> Int? {
            let name = item.name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                         locale: .current)
            if name == search { return 0 }
            if name.hasPrefix(search) { return 1 }
            if name.contains(search) { return 2 }
            let folder = item.url.deletingLastPathComponent().path
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return folder.contains(search) ? 3 : nil
        }
        return files.compactMap { item -> (item: NoteItem, rank: Int)? in
            guard let rank = score(item) else { return nil }
            return (item, rank)
        }
        .sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending
        }
        .prefix(limit)
        .map(\.item)
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
