import Foundation
import Darwin

/// Persists only lightweight navigation metadata. Markdown files remain the content authority.
enum NoteNavigationStore {
    static let recentLimit = 12
    private static let recentKey = "PKSNotesRecentByWorkspace"
    private static let favoritesKey = "PKSNotesFavoritesByWorkspace"

    static func recent(in root: URL, defaults: UserDefaults = .standard) -> [URL] {
        load(key: recentKey, root: root, defaults: defaults)
    }

    static func favorites(in root: URL, defaults: UserDefaults = .standard) -> [URL] {
        load(key: favoritesKey, root: root, defaults: defaults)
    }

    @discardableResult
    static func recordRecent(_ note: URL, in root: URL,
                             defaults: UserDefaults = .standard) -> [URL] {
        guard let relative = relativePath(note, in: root) else {
            return recent(in: root, defaults: defaults)
        }
        var paths = storedPaths(key: recentKey, root: root, defaults: defaults)
        paths.removeAll { $0 == relative }
        paths.insert(relative, at: 0)
        if paths.count > recentLimit { paths.removeLast(paths.count - recentLimit) }
        write(paths, key: recentKey, root: root, defaults: defaults)
        return load(key: recentKey, root: root, defaults: defaults)
    }

    @discardableResult
    static func toggleFavorite(_ note: URL, in root: URL,
                               defaults: UserDefaults = .standard) -> [URL] {
        guard let relative = relativePath(note, in: root) else {
            return favorites(in: root, defaults: defaults)
        }
        var paths = storedPaths(key: favoritesKey, root: root, defaults: defaults)
        if let index = paths.firstIndex(of: relative) {
            paths.remove(at: index)
        } else {
            paths.insert(relative, at: 0)
        }
        write(paths, key: favoritesKey, root: root, defaults: defaults)
        return load(key: favoritesKey, root: root, defaults: defaults)
    }

    static func replacePath(_ old: URL, with new: URL, in root: URL,
                            defaults: UserDefaults = .standard) {
        guard let oldRelative = relativePath(old, in: root),
              let newRelative = relativePath(new, in: root) else { return }
        for key in [recentKey, favoritesKey] {
            let changed = storedPaths(key: key, root: root, defaults: defaults).map { path -> String in
                if path == oldRelative { return newRelative }
                let prefix = oldRelative + "/"
                guard path.hasPrefix(prefix) else { return path }
                return newRelative + String(path.dropFirst(oldRelative.count))
            }
            write(deduplicated(changed), key: key, root: root, defaults: defaults)
        }
    }

    static func removePath(_ item: URL, in root: URL,
                           defaults: UserDefaults = .standard) {
        guard let relative = relativePath(item, in: root) else { return }
        let prefix = relative + "/"
        for key in [recentKey, favoritesKey] {
            let kept = storedPaths(key: key, root: root, defaults: defaults)
                .filter { $0 != relative && !$0.hasPrefix(prefix) }
            write(kept, key: key, root: root, defaults: defaults)
        }
    }

    static func relativePath(_ url: URL, in root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        let relative = String(path.dropFirst(base.count + 1))
        return relative.isEmpty ? nil : relative
    }

    private static func load(key: String, root: URL, defaults: UserDefaults) -> [URL] {
        storedPaths(key: key, root: root, defaults: defaults).compactMap { relative in
            let url = root.appendingPathComponent(relative).standardizedFileURL
            guard WorkspaceFiles.contains(url, in: root),
                  ["md", "markdown"].contains(url.pathExtension.lowercased()) else { return nil }
            var info = Darwin.stat()
            guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
            return url
        }
    }

    private static func storedPaths(key: String, root: URL, defaults: UserDefaults) -> [String] {
        guard let dictionary = defaults.dictionary(forKey: key),
              let paths = dictionary[root.standardizedFileURL.path] as? [String] else { return [] }
        return paths
    }

    private static func write(_ paths: [String], key: String, root: URL, defaults: UserDefaults) {
        var dictionary = defaults.dictionary(forKey: key) ?? [:]
        dictionary[root.standardizedFileURL.path] = paths
        defaults.set(dictionary, forKey: key)
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
