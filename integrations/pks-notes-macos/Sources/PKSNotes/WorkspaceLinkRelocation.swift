import Foundation

/// Preserve a moved Markdown note's own outgoing links without touching any
/// other file. Markdown is the sole source of truth; no alias database or index.
enum WorkspaceLinkRelocation {
    struct Prepared {
        let original: String
        let updated: String
    }

    static func prepare(from source: URL, to destination: URL, root: URL) -> Prepared? {
        guard ["md", "markdown"].contains(source.pathExtension.lowercased()),
              WorkspaceFiles.contains(source, in: root),
              WorkspaceFiles.contains(destination, in: root),
              !WorkspaceFiles.isDataless(source),
              let stamp = WorkspaceFiles.fileStamp(source),
              stamp.size <= 4_000_000,
              let original = try? String(contentsOf: source, encoding: .utf8),
              WorkspaceFiles.fileStamp(source) == stamp else { return nil }

        let movedBetweenFolders =
            source.deletingLastPathComponent().standardizedFileURL
                != destination.deletingLastPathComponent().standardizedFileURL
        var updated = original
        let rawTargets = Set(MindMapOutline.linkOccurrences(in: original).map(\.link.target))
        for raw in rawTargets.sorted() {
            let path = String(raw.split(separator: "#", maxSplits: 1,
                                        omittingEmptySubsequences: false).first ?? "")
            guard !path.isEmpty, URL(string: path)?.scheme == nil,
                  let target = WorkspaceFiles.resolveLinkedTarget(
                    raw, from: source, in: root, candidates: []
                  ) else { continue }
            let pointsToSelf = target.standardizedFileURL == source.standardizedFileURL
            // Root-relative links to other files survive a source move intact.
            guard pointsToSelf || (movedBetweenFolders && !path.hasPrefix("/")) else {
                continue
            }
            let after = pointsToSelf ? destination : target
            guard let canonical = canonicalTarget(for: after, in: root) else { continue }
            let fragment = raw.firstIndex(of: "#").map { String(raw[$0...]) } ?? ""
            guard let changed = MindMapOutline.retargetLinks(
                in: updated, from: raw, to: canonical + fragment
            ) else { continue }
            updated = changed
        }
        return updated == original ? nil : .init(original: original, updated: updated)
    }

    /// Verify the moved file still contains the source we planned against.
    /// Fail closed on concurrent edits/iCloud changes; never overwrite blindly.
    static func apply(_ prepared: Prepared, to destination: URL) -> Bool {
        guard let stamp = WorkspaceFiles.fileStamp(destination),
              !WorkspaceFiles.isDataless(destination),
              let current = try? String(contentsOf: destination, encoding: .utf8),
              current == prepared.original,
              WorkspaceFiles.fileStamp(destination) == stamp else { return false }
        do {
            try prepared.updated.write(to: destination, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static func canonicalTarget(for target: URL, in root: URL) -> String? {
        if let note = WorkspaceFiles.canonicalWikiTarget(for: target, in: root) {
            return note
        }
        let rootPath = root.standardizedFileURL.path + "/"
        let targetPath = target.standardizedFileURL.path
        guard WorkspaceFiles.contains(target, in: root),
              targetPath.hasPrefix(rootPath) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?[]|%()")
        guard let encoded = String(targetPath.dropFirst(rootPath.count))
            .addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "/" + encoded
    }
}
