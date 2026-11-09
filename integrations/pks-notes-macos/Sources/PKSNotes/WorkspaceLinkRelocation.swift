import Foundation

/// Preserve a moved Markdown note's own outgoing links without touching any
/// other file. Markdown is the sole source of truth; no alias database or index.
enum WorkspaceLinkRelocation {
    struct Prepared {
        let original: String
        let updated: String
        let sourceStamp: WorkspaceFileStamp
    }

    struct RelatedEdit: Sendable {
        let source: URL
        let destination: URL
        let original: String
        let updated: String
        let sourceStamp: WorkspaceFileStamp
    }

    struct RelatedPlan: Sendable {
        let edits: [RelatedEdit]
        let skippedCloudFiles: Int
        let skippedUnavailableFiles: Int
    }

    /// Capture the canonical Markdown before a path change. The shared opening
    /// reader owns File Provider hydration and stable-stamp validation, so a
    /// dataless iCloud note is never moved with link repair silently skipped.
    static func prepare(
        from source: URL,
        to destination: URL,
        root: URL,
        markdownFiles: [URL] = [],
        candidateBasenames: [String: [URL]] = [:]
    ) async throws -> Prepared? {
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
        let rawTargets = Set(MindMapOutline.linkOccurrences(in: original, includeImages: true).map(\.link.target))
        for raw in rawTargets.sorted() {
            let path = String(raw.split(separator: "#", maxSplits: 1,
                                        omittingEmptySubsequences: false).first ?? "")
            guard !path.isEmpty, URL(string: path)?.scheme == nil,
                  let target = WorkspaceFiles.resolveLinkedTarget(
                    raw,
                    from: source,
                    in: root,
                    candidates: markdownFiles,
                    candidateBasenames: candidateBasenames
                  ) else { continue }
            let pointsToSelf = target.standardizedFileURL == source.standardizedFileURL
            // Root-relative links to other files survive a source move intact.
            guard pointsToSelf || (movedBetweenFolders && !path.hasPrefix("/")) else {
                continue
            }
            let after = pointsToSelf ? destination : target
            guard let canonical = WorkspaceFiles.canonicalLinkTarget(for: after, in: root) else { continue }
            let fragment = raw.firstIndex(of: "#").map { String(raw[$0...]) } ?? ""
            guard let changed = MindMapOutline.retargetLinks(
                in: updated, from: raw, to: canonical + fragment, includeImages: true
            ) else { continue }
            updated = changed
        }
        return .init(original: original, updated: updated, sourceStamp: snapshot.stamp)
    }

    /// Prepare Markdown sources whose link semantics change when a file or
    /// folder moves or is renamed. Hydrate only Markdown descendants inside
    /// that folder; unrelated cloud placeholders remain untouched and are reported.
    static func prepareRelatedSources(
        from movingSource: URL,
        to movingDestination: URL,
        movingIsDirectory: Bool,
        root: URL,
        markdownFiles: [URL],
        candidateBasenames: [String: [URL]]
    ) async throws -> RelatedPlan {
        let movingSource = movingSource.standardizedFileURL
        let movingDestination = movingDestination.standardizedFileURL
        let root = root.standardizedFileURL
        return try await Task.detached(priority: .userInitiated) {
            func isInsideMove(_ url: URL) -> Bool {
                let path = url.standardizedFileURL.path
                return path == movingSource.path || path.hasPrefix(movingSource.path + "/")
            }

            func relocated(_ url: URL) -> URL {
                let url = url.standardizedFileURL
                guard isInsideMove(url) else { return url }
                if url == movingSource { return movingDestination }
                let suffix = String(url.path.dropFirst(movingSource.path.count + 1))
                return movingDestination.appendingPathComponent(suffix).standardizedFileURL
            }

            var edits: [RelatedEdit] = []
            var skippedCloud = 0
            var skippedUnavailable = 0

            for rawSource in markdownFiles {
                try Task.checkCancellation()
                let source = rawSource.standardizedFileURL

                // The directly moved Markdown file has its own hydration-aware
                // preparation above. Avoid a second writer for the same source.
                if !movingIsDirectory && source == movingSource { continue }

                let sourceMoves = isInsideMove(source)
                let original: String
                let stamp: WorkspaceFileStamp
                if movingIsDirectory && sourceMoves {
                    if let currentStamp = WorkspaceFiles.fileStamp(source),
                       currentStamp.size > 4_000_000 {
                        throw CocoaError(.fileReadUnknown)
                    }
                    let snapshot = try await WorkspaceFiles.readUTF8ForOpening(source)
                    guard snapshot.stamp.size <= 4_000_000 else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    original = snapshot.content
                    stamp = snapshot.stamp
                } else {
                    if WorkspaceFiles.isDataless(source) {
                        skippedCloud += 1
                        continue
                    }
                    guard let currentStamp = WorkspaceFiles.fileStamp(source),
                          currentStamp.size <= 4_000_000,
                          let contents = try? String(contentsOf: source, encoding: .utf8),
                          WorkspaceFiles.fileStamp(source) == currentStamp else {
                        skippedUnavailable += 1
                        continue
                    }
                    original = contents
                    stamp = currentStamp
                }
                guard stamp.size <= 4_000_000 else {
                    skippedUnavailable += 1
                    continue
                }

                var updated = original
                let rawTargets = Set(MindMapOutline.linkOccurrences(in: original, includeImages: true).map(\.link.target))
                for raw in rawTargets.sorted() {
                    let pathPart = String(raw.split(
                        separator: "#",
                        maxSplits: 1,
                        omittingEmptySubsequences: false
                    ).first ?? "")
                    let decodedPath = pathPart.removingPercentEncoding ?? pathPart
                    guard !decodedPath.isEmpty,
                          URL(string: decodedPath)?.scheme == nil,
                          let linked = WorkspaceFiles.resolveLinkedTarget(
                            raw,
                            from: source,
                            in: root,
                            candidates: markdownFiles,
                            candidateBasenames: candidateBasenames
                          ) else { continue }

                    let targetMoves = isInsideMove(linked)
                    guard sourceMoves || targetMoves else { continue }

                    // Relative links entirely inside a moved folder preserve the
                    // same relationship. Root-relative links do not, because the
                    // folder's workspace path changes.
                    let rootRelative = decodedPath.hasPrefix("/")
                    let needsRewrite: Bool
                    if movingIsDirectory && sourceMoves && targetMoves {
                        needsRewrite = rootRelative
                    } else if sourceMoves && !targetMoves {
                        needsRewrite = !rootRelative
                    } else {
                        needsRewrite = true
                    }
                    guard needsRewrite,
                          let canonical = WorkspaceFiles.canonicalLinkTarget(for: relocated(linked), in: root)
                    else { continue }

                    let fragment = raw.firstIndex(of: "#").map { String(raw[$0...]) } ?? ""
                    guard let changed = MindMapOutline.retargetLinks(
                        in: updated,
                        from: raw,
                        to: canonical + fragment,
                        includeImages: true
                    ) else { continue }
                    updated = changed
                }

                if updated != original {
                    edits.append(.init(
                        source: source,
                        destination: relocated(source),
                        original: original,
                        updated: updated,
                        sourceStamp: stamp
                    ))
                }
            }

            return RelatedPlan(
                edits: edits,
                skippedCloudFiles: skippedCloud,
                skippedUnavailableFiles: skippedUnavailable
            )
        }.value
    }

    /// Prepare Markdown files inside a copied folder. Original sources are read
    /// through the hydration-aware reader so cloud-only descendants participate
    /// in link rewriting; only the copied destination is ever mutated.
    static func prepareCopiedSources(
        from copyingSource: URL,
        to copyingDestination: URL,
        root: URL,
        markdownFiles: [URL],
        candidateBasenames: [String: [URL]]
    ) async throws -> RelatedPlan {
        let copyingSource = copyingSource.standardizedFileURL
        let copyingDestination = copyingDestination.standardizedFileURL
        let root = root.standardizedFileURL
        return try await Task.detached(priority: .userInitiated) {
            func isInsideCopy(_ url: URL) -> Bool {
                let path = url.standardizedFileURL.path
                return path == copyingSource.path || path.hasPrefix(copyingSource.path + "/")
            }

            func copied(_ url: URL) -> URL {
                let url = url.standardizedFileURL
                guard isInsideCopy(url) else { return url }
                if url == copyingSource { return copyingDestination }
                let suffix = String(url.path.dropFirst(copyingSource.path.count + 1))
                return copyingDestination.appendingPathComponent(suffix).standardizedFileURL
            }

            var edits: [RelatedEdit] = []
            let skippedCloud = 0
            let skippedUnavailable = 0

            for rawSource in markdownFiles {
                try Task.checkCancellation()
                let source = rawSource.standardizedFileURL
                guard isInsideCopy(source) else { continue }

                if let currentStamp = WorkspaceFiles.fileStamp(source),
                   currentStamp.size > 4_000_000 {
                    throw CocoaError(.fileReadUnknown)
                }
                let snapshot = try await WorkspaceFiles.readUTF8ForOpening(source)
                guard snapshot.stamp.size <= 4_000_000 else {
                    throw CocoaError(.fileReadUnknown)
                }
                let original = snapshot.content
                let stamp = snapshot.stamp
                var updated = original
                let rawTargets = Set(MindMapOutline.linkOccurrences(
                    in: original,
                    includeImages: true
                ).map(\.link.target))
                for raw in rawTargets.sorted() {
                    let pathPart = String(raw.split(
                        separator: "#",
                        maxSplits: 1,
                        omittingEmptySubsequences: false
                    ).first ?? "")
                    let decodedPath = pathPart.removingPercentEncoding ?? pathPart
                    guard !decodedPath.isEmpty,
                          URL(string: decodedPath)?.scheme == nil,
                          let linked = WorkspaceFiles.resolveLinkedTarget(
                            raw,
                            from: source,
                            in: root,
                            candidates: markdownFiles,
                            candidateBasenames: candidateBasenames
                          ) else { continue }

                    let targetInsideCopy = isInsideCopy(linked)
                    let rootRelative = decodedPath.hasPrefix("/")
                    let needsRewrite: Bool
                    let rewrittenTarget: URL
                    if targetInsideCopy {
                        // Relative links preserve the copied folder topology.
                        // Root-relative links would otherwise keep pointing to
                        // the original subtree, so redirect those to the copy.
                        needsRewrite = rootRelative
                        rewrittenTarget = copied(linked)
                    } else {
                        // Root-relative links to external targets already remain
                        // valid. Relative links need rebasing because the copied
                        // source now lives under a different parent.
                        needsRewrite = !rootRelative
                        rewrittenTarget = linked
                    }
                    guard needsRewrite,
                          let canonical = WorkspaceFiles.canonicalLinkTarget(
                            for: rewrittenTarget,
                            in: root
                          ) else { continue }

                    let fragment = raw.firstIndex(of: "#").map { String(raw[$0...]) } ?? ""
                    guard let changed = MindMapOutline.retargetLinks(
                        in: updated,
                        from: raw,
                        to: canonical + fragment,
                        includeImages: true
                    ) else { continue }
                    updated = changed
                }

                if updated != original {
                    edits.append(.init(
                        source: source,
                        destination: copied(source),
                        original: original,
                        updated: updated,
                        sourceStamp: stamp
                    ))
                }
            }

            return RelatedPlan(
                edits: edits,
                skippedCloudFiles: skippedCloud,
                skippedUnavailableFiles: skippedUnavailable
            )
        }.value
    }

    static func relatedSourcesAreCurrent(_ plan: RelatedPlan) -> Bool {
        plan.edits.allSatisfy {
            WorkspaceFiles.fileStamp($0.source) == $0.sourceStamp
        }
    }

    /// Preflight every destination before writing any repair. The filesystem
    /// move remains authoritative; if another editor changed one source during
    /// the operation, fail closed instead of overwriting it.
    static func apply(_ plan: RelatedPlan) -> Bool {
        for edit in plan.edits {
            guard !WorkspaceFiles.isDataless(edit.destination),
                  let current = try? String(contentsOf: edit.destination, encoding: .utf8),
                  current == edit.original else { return false }
        }
        do {
            for edit in plan.edits {
                try edit.updated.write(to: edit.destination, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            return false
        }
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


}
