import Foundation

struct EmbeddedPKSLibrarySource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let bookmark: Data
    let lastKnownPath: String
    let createdAt: Date
}

enum EmbeddedPKSLibraryError: Error {
    case overlapsWorkspace
    case bookmarkCreationFailed
    case bookmarkResolutionFailed
    case folderUnavailable
    case enumerationFailed
}

actor EmbeddedPKSLibrarySourceRegistry {
    static let defaultsKey = "LeafspanEmbeddedPKSLibrarySourcesV1"

    private let suiteName: String?
    private let defaultsKey: String
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init(
        suiteName: String? = nil,
        defaultsKey: String = EmbeddedPKSLibrarySourceRegistry.defaultsKey
    ) {
        self.suiteName = suiteName
        self.defaultsKey = defaultsKey
    }

    func sources() -> [EmbeddedPKSLibrarySource] {
        guard let data = defaults().data(forKey: defaultsKey),
              let decoded = try? decoder.decode([EmbeddedPKSLibrarySource].self, from: data)
        else { return [] }
        return decoded
    }

    @discardableResult
    func add(folder: URL, excludingWorkspace workspace: URL?) throws -> EmbeddedPKSLibrarySource {
        let resolved = Self.canonical(folder)
        if let workspace, Self.overlaps(resolved, Self.canonical(workspace)) {
            throw EmbeddedPKSLibraryError.overlapsWorkspace
        }

        var current = sources()
        let existingIndex = current.firstIndex(where: {
            Self.canonical(URL(fileURLWithPath: $0.lastKnownPath)) == resolved
        })

        // An explicit folder selection is also a permission renewal. Do not
        // return an old or revoked bookmark for the same path.
        let bookmark: Data
        do {
            bookmark = try folder.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw EmbeddedPKSLibraryError.bookmarkCreationFailed
        }

        let previous = existingIndex.map { current[$0] }
        let source = EmbeddedPKSLibrarySource(
            id: previous?.id ?? "leafspan-library-\(UUID().uuidString.lowercased())",
            name: resolved.lastPathComponent.isEmpty ? resolved.path : resolved.lastPathComponent,
            bookmark: bookmark,
            lastKnownPath: resolved.path,
            createdAt: previous?.createdAt ?? Date()
        )
        if let existingIndex {
            current[existingIndex] = source
        } else {
            current.append(source)
        }
        try persist(current)
        return source
    }

    func remove(id: String) throws {
        try persist(sources().filter { $0.id != id })
    }

    func removeAll() {
        defaults().removeObject(forKey: defaultsKey)
    }

    static func resolve(_ source: EmbeddedPKSLibrarySource) throws -> URL {
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: source.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard !stale else { throw EmbeddedPKSLibraryError.bookmarkResolutionFailed }
            return canonical(url)
        } catch {
            throw EmbeddedPKSLibraryError.bookmarkResolutionFailed
        }
    }

    static func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = canonical(lhs).path
        let right = canonical(rhs).path
        if left == right { return true }
        let leftPrefix = left.hasSuffix("/") ? left : left + "/"
        let rightPrefix = right.hasSuffix("/") ? right : right + "/"
        return left.hasPrefix(rightPrefix) || right.hasPrefix(leftPrefix)
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func persist(_ sources: [EmbeddedPKSLibrarySource]) throws {
        defaults().set(try encoder.encode(sources), forKey: defaultsKey)
    }

    private func defaults() -> UserDefaults {
        if let suiteName, let scoped = UserDefaults(suiteName: suiteName) {
            return scoped
        }
        return .standard
    }
}

struct EmbeddedPKSLibraryIndexSummary: Equatable, Sendable {
    let scannedFiles: Int
    let indexedContentFiles: Int
    let metadataOnlyFiles: Int
    let deletedDocuments: Int
}

actor EmbeddedPKSLibraryIndexer {
    static let maximumTextBytes = 8 * 1024 * 1024
    static let contentExtensions: Set<String> = ["md", "markdown", "txt"]
    static let metadataOnlyExtensions: Set<String> = ["pdf"]

    private let core: EmbeddedPKSCore
    private let fileManager: FileManager

    init(core: EmbeddedPKSCore, fileManager: FileManager = .default) {
        self.core = core
        self.fileManager = fileManager
    }

    func refresh(_ source: EmbeddedPKSLibrarySource) async throws -> EmbeddedPKSLibraryIndexSummary {
        try Task.checkCancellation()
        let root = try EmbeddedPKSLibrarySourceRegistry.resolve(source)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw EmbeddedPKSLibraryError.folderUnavailable
        }

        let accessed = root.startAccessingSecurityScopedResource()
        defer {
            if accessed { root.stopAccessingSecurityScopedResource() }
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        let fileURLs = try Self.enumeratedFiles(
            at: root,
            keys: keys,
            fileManager: fileManager
        )

        // Constrain all indexed files to the granted root, including symlink targets.
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var seen: [String] = []
        var scanned = 0
        var contentIndexed = 0
        var metadataOnly = 0
        let formatter = ISO8601DateFormatter()

        for fileURL in fileURLs {
            try Task.checkCancellation()
            let ext = fileURL.pathExtension.lowercased()
            guard Self.contentExtensions.contains(ext) || Self.metadataOnlyExtensions.contains(ext)
            else { continue }

            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }

            let canonical = fileURL.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical.path.hasPrefix(rootPrefix) else { continue }
            let byteCount = values.fileSize ?? 0
            var text: String?
            if Self.contentExtensions.contains(ext),
               byteCount <= Self.maximumTextBytes {
                do {
                    text = try String(contentsOf: canonical, encoding: .utf8)
                } catch {
                    // Transient file errors must not replace indexed chunks
                    // with metadata-only and silently lose searchable content.
                    throw EmbeddedPKSLibraryError.enumerationFailed
                }
            }

            let contentAvailable = text != nil
            let documentType: String
            if ext == "pdf" {
                documentType = "pdf"
            } else if ext == "txt" {
                documentType = "text"
            } else {
                documentType = "note"
            }

            _ = try await core.index(EmbeddedPKSDocument(
                sourceId: source.id,
                sourceName: source.name,
                rootURI: root.path,
                uri: canonical.path,
                title: canonical.lastPathComponent,
                text: text,
                createdAt: values.creationDate.map { formatter.string(from: $0) },
                modifiedAt: values.contentModificationDate.map { formatter.string(from: $0) },
                documentType: documentType,
                indexStatus: contentAvailable ? "indexed" : "metadata_only"
            ))
            seen.append(canonical.path)
            scanned += 1
            if contentAvailable { contentIndexed += 1 } else { metadataOnly += 1 }
        }

        try Task.checkCancellation()
        let deleted = try await core.finalize(sourceId: source.id, seenURIs: seen)
        return EmbeddedPKSLibraryIndexSummary(
            scannedFiles: scanned,
            indexedContentFiles: contentIndexed,
            metadataOnlyFiles: metadataOnly,
            deletedDocuments: deleted
        )
    }

    private static func enumeratedFiles(
        at root: URL,
        keys: [URLResourceKey],
        fileManager: FileManager
    ) throws -> [URL] {
        // A partial scan must not mark unseen indexed documents as deleted.
        // Inaccessible File Provider/iCloud subdirectories are not deletions.
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw EmbeddedPKSLibraryError.enumerationFailed
        }
        var files: [URL] = []
        while let next = enumerator.nextObject() as? URL {
            files.append(next)
        }
        guard enumerationError == nil else {
            throw EmbeddedPKSLibraryError.enumerationFailed
        }
        return files
    }
}
