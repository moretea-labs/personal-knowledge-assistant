import Foundation

/// Preserve a moved Markdown note's own outgoing links without touching any
/// other file. Markdown is the sole source of truth; no alias database or index.
enum WorkspaceLinkRelocation {
    struct Prepared {
        let original: String
        let updated: String
        let sourceStamp: WorkspaceFileStamp
    }

    /// Capture the canonical Markdown before a path change. The shared opening
    /// reader owns File Provider hydration and stable-stamp validation, so a
    /// dataless iCloud note is never moved with link repair silently skipped.
    static func prepare(from source: URL, to destination: URL, root: URL) async throws -> Prepared? {
        guard ["md", "markdown"].contains(source.pathExtension.lowercased()) else { return nil }
        guard WorkspaceFiles.contains(source, in: root),
              WorkspaceFiles.contains(destination, in: root) else {
            throw CocoaError(.fileReadNoPermission)
        }

        let snapshot = try await WorkspaceFiles.readUTF8ForOpening(source)
        let original = snapshot.content

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
        return .init(original: original, updated: updated, sourceStamp: snapshot.stamp)
    }

    /// A hydration/read can yield while File Provider or the user changes the
    /// source. Never move a different revision than the one link repair parsed.
    static func sourceIsCurrent(_ prepared: Prepared, at source: URL) -> Bool {
        WorkspaceFiles.fileStamp(source) == prepared.sourceStamp
    }

    /// Verify the moved file still contains the source we planned against.
    /// Fail closed on concurrent edits/iCloud changes; never overwrite blindly.
    static func apply(_ prepared: Prepared, to destination: URL) -> Bool {
        guard let stamp = WorkspaceFiles.fileStamp(destination),
              !WorkspaceFiles.isDataless(destination),
              let current = try? String(contentsOf: destination, encoding: .utf8),
              current == prepared.original,
              WorkspaceFiles.fileStamp(destination) == stamp else { return false }
        if prepared.updated == prepared.original { return true }
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
