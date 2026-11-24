import Darwin
import XCTest
@testable import PKSNotes

final class EmbeddedPKSLibraryTests: XCTestCase {
    func testReselectingExistingFolderRenewsBookmarkWithoutDuplicateSource() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Regrant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "EmbeddedPKSRegrant-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let prior = EmbeddedPKSLibrarySource(
            id: "stable-library-id",
            name: folder.lastPathComponent,
            bookmark: Data([0x00, 0x01, 0x02]),
            lastKnownPath: folder.standardizedFileURL.resolvingSymlinksInPath().path,
            createdAt: createdAt
        )
        defaults.set(try PropertyListEncoder().encode([prior]),
                     forKey: EmbeddedPKSLibrarySourceRegistry.defaultsKey)

        let registry = EmbeddedPKSLibrarySourceRegistry(suiteName: suite)
        XCTAssertThrowsError(try EmbeddedPKSLibrarySourceRegistry.resolve(prior))
        let renewed = try await registry.add(folder: folder, excludingWorkspace: nil)
        XCTAssertEqual(renewed.id, prior.id)
        XCTAssertEqual(renewed.createdAt, createdAt)
        XCTAssertNotEqual(renewed.bookmark, prior.bookmark)
        XCTAssertEqual(try EmbeddedPKSLibrarySourceRegistry.resolve(renewed).path,
                       folder.standardizedFileURL.resolvingSymlinksInPath().path)

        let selectedAgain = try await registry.add(folder: folder, excludingWorkspace: nil)
        XCTAssertEqual(selectedAgain.id, prior.id)
        let saved = await registry.sources()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.bookmark, selectedAgain.bookmark)
    }

    func testOverlapRejectsWorkspaceAndNestedDirectories() {
        let workspace = URL(fileURLWithPath: "/Users/test/Documents/Workspace")
        XCTAssertTrue(EmbeddedPKSLibrarySourceRegistry.overlaps(workspace, workspace))
        XCTAssertTrue(EmbeddedPKSLibrarySourceRegistry.overlaps(
            URL(fileURLWithPath: "/Users/test/Documents"),
            workspace
        ))
        XCTAssertTrue(EmbeddedPKSLibrarySourceRegistry.overlaps(
            workspace.appendingPathComponent("Notes"),
            workspace
        ))
        XCTAssertFalse(EmbeddedPKSLibrarySourceRegistry.overlaps(
            URL(fileURLWithPath: "/Users/test/Library"),
            workspace
        ))
    }

#if canImport(PKSCore)
    func testIndexDoesNotFollowSymlinkOutOfGrantedFolder() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Link-Safety-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Granted", isDirectory: true)
        let outside = base.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let privateNote = outside.appendingPathComponent("Private.md")
        try "# Confidential\nDo not index outside a folder grant.".write(
            to: privateNote, atomically: true, encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Escape.md"), withDestinationURL: privateNote
        )
        let suite = "EmbeddedPKSLinks-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let registry = EmbeddedPKSLibrarySourceRegistry(suiteName: suite)
        let source = try await registry.add(folder: root, excludingWorkspace: nil)
        let core = try EmbeddedPKSCore(
            databaseURL: base.appendingPathComponent("Index/knowledge.db")
        )
        let summary = try await EmbeddedPKSLibraryIndexer(core: core).refresh(source)
        XCTAssertEqual(summary.scannedFiles, 0)
        let hits = try await core.search("Confidential", source: source.id)
        XCTAssertTrue(hits.isEmpty)
    }

    func testIncompleteEnumerationDoesNotPurgePreviouslyIndexedDocuments() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires a non-root user") }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Scan-Safety-\(UUID().uuidString)", isDirectory: true)
        let restricted = base.appendingPathComponent("Restricted", isDirectory: true)
        try FileManager.default.createDirectory(
            at: restricted, withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: restricted.path
            )
            try? FileManager.default.removeItem(at: base)
        }
        try "# Secret\nPreviously indexed content.".write(
            to: restricted.appendingPathComponent("Secret.md"),
            atomically: true, encoding: .utf8
        )
        let suite = "EmbeddedPKSScan-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let registry = EmbeddedPKSLibrarySourceRegistry(suiteName: suite)
        let source = try await registry.add(folder: base, excludingWorkspace: nil)
        let core = try EmbeddedPKSCore(
            databaseURL: base.appendingPathComponent("Index/knowledge.db")
        )
        let indexer = EmbeddedPKSLibraryIndexer(core: core)
        let initial = try await indexer.refresh(source)
        XCTAssertEqual(initial.indexedContentFiles, 1)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: restricted.path
        )
        do {
            _ = try await indexer.refresh(source)
            XCTFail("Incomplete enumeration must not finalize missing entries")
        } catch EmbeddedPKSLibraryError.enumerationFailed {
            // Expected: previous indexed files must remain searchable.
        }
        let preserved = try await core.search("Secret", mode: "metadata", source: source.id)
        XCTAssertEqual(preserved.first?.title, "Secret.md")
    }

    func testUnreadableTextPreservesPreviouslyIndexedBodyAndAllowsRecovery() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Decode-Safety-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let note = root.appendingPathComponent("Note.md")
        try "# Notes\nReliable indexed passage.".write(to: note, atomically: true, encoding: .utf8)
        let suite = "EmbeddedPKSDecode-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let registry = EmbeddedPKSLibrarySourceRegistry(suiteName: suite)
        let source = try await registry.add(folder: root, excludingWorkspace: nil)
        let core = try EmbeddedPKSCore(
            databaseURL: base.appendingPathComponent("Index/knowledge.db")
        )
        let indexer = EmbeddedPKSLibraryIndexer(core: core)
        let firstScan = try await indexer.refresh(source)
        XCTAssertEqual(firstScan.indexedContentFiles, 1)

        // A failed content read must not replace indexed chunks with metadata-only.
        try Data([0xFF, 0xFE, 0xFD]).write(to: note, options: .atomic)
        do {
            _ = try await indexer.refresh(source)
            XCTFail("A failed text read must not finalize a partial source scan")
        } catch EmbeddedPKSLibraryError.enumerationFailed {
            // Previously indexed content stays searchable.
        }
        let preserved = try await core.search("Reliable", mode: "fts", source: source.id)
        XCTAssertEqual(preserved.first?.title, "Note.md")

        try "# Notes\nUpdated indexed passage.".write(
            to: note, atomically: true, encoding: .utf8
        )
        let recoveryScan = try await indexer.refresh(source)
        XCTAssertEqual(recoveryScan.indexedContentFiles, 1)
        let refreshed = try await core.search("Updated", mode: "fts", source: source.id)
        XCTAssertEqual(refreshed.first?.title, "Note.md")
    }

    func testDatalessPlaceholdersAreDeferredWithoutReadingOrPurgingExistingIndex() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Dataless-Index-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let note = root.appendingPathComponent("Note.md")
        let cloudOnly = root.appendingPathComponent("CloudOnly.md")
        try "# Notes\nPreviously searchable passage.".write(
            to: note, atomically: true, encoding: .utf8
        )

        let suite = "EmbeddedPKSDataless-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let registry = EmbeddedPKSLibrarySourceRegistry(suiteName: suite)
        let source = try await registry.add(folder: root, excludingWorkspace: nil)
        let core = try EmbeddedPKSCore(
            databaseURL: base.appendingPathComponent("Index/knowledge.db")
        )
        let initial = try await EmbeddedPKSLibraryIndexer(core: core).refresh(source)
        XCTAssertEqual(initial.indexedContentFiles, 1)

        // Simulate File Provider replacing local bytes with a cloud-only placeholder.
        try "# Notes\nReplacement passage must stay deferred.".write(
            to: note, atomically: true, encoding: .utf8
        )
        try "# Cloud\nNew cloud-only document.".write(
            to: cloudOnly, atomically: true, encoding: .utf8
        )
        let deferredPaths = Set([note.path, cloudOnly.path])
        let indexer = EmbeddedPKSLibraryIndexer(core: core, isDataless: { url in
            deferredPaths.contains(url.standardizedFileURL.path)
        })
        let summary = try await indexer.refresh(source)

        XCTAssertEqual(summary.scannedFiles, 2)
        XCTAssertEqual(summary.deferredFiles, 2)
        XCTAssertEqual(summary.indexedContentFiles, 0)
        XCTAssertEqual(summary.metadataOnlyFiles, 0)
        XCTAssertEqual(summary.deletedDocuments, 0)

        let preserved = try await core.search("Previously searchable", mode: "fts", source: source.id)
        XCTAssertEqual(preserved.first?.uri, note.path)
        let replacement = try await core.search("Replacement passage", mode: "fts", source: source.id)
        XCTAssertTrue(replacement.isEmpty)
        let newDocument = try await core.search("New cloud-only", mode: "fts", source: source.id)
        XCTAssertTrue(newDocument.isEmpty)
    }

    func testDatalessRootDoesNotEnumerateOrFinalizeExistingIndex() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Dataless-Root-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let note = root.appendingPathComponent("Note.md")
        try "# Notes\nRoot placeholder safety.".write(to: note, atomically: true, encoding: .utf8)

        let suite = "EmbeddedPKSDatalessRoot-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let registry = EmbeddedPKSLibrarySourceRegistry(suiteName: suite)
        let source = try await registry.add(folder: root, excludingWorkspace: nil)
        let core = try EmbeddedPKSCore(
            databaseURL: base.appendingPathComponent("Index/knowledge.db")
        )
        _ = try await EmbeddedPKSLibraryIndexer(core: core).refresh(source)

        let indexer = EmbeddedPKSLibraryIndexer(core: core, isDataless: { url in
            url.standardizedFileURL == root.standardizedFileURL
        })
        do {
            _ = try await indexer.refresh(source)
            XCTFail("A dataless library root must not be enumerated or finalized")
        } catch EmbeddedPKSLibraryError.datalessPlaceholder {
            // Expected: prior rows remain searchable until the user downloads the root.
        }
        let preserved = try await core.search("Root placeholder", mode: "fts", source: source.id)
        XCTAssertEqual(preserved.first?.uri, note.path)
    }

    func testDatalessSubdirectoryAbortsRefreshWithoutPurgingIndexedChildren() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Dataless-Subdirectory-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Library", isDirectory: true)
        let cloudFolder = root.appendingPathComponent("CloudFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let note = cloudFolder.appendingPathComponent("Note.md")
        try "# Notes\nPreviously searchable nested content.".write(
            to: note, atomically: true, encoding: .utf8
        )

        let suite = "EmbeddedPKSDatalessSubdirectory-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let registry = EmbeddedPKSLibrarySourceRegistry(suiteName: suite)
        let source = try await registry.add(folder: root, excludingWorkspace: nil)
        let core = try EmbeddedPKSCore(
            databaseURL: base.appendingPathComponent("Index/knowledge.db")
        )
        _ = try await EmbeddedPKSLibraryIndexer(core: core).refresh(source)

        try "# Notes\nReplacement must remain deferred.".write(
            to: note, atomically: true, encoding: .utf8
        )
        let indexer = EmbeddedPKSLibraryIndexer(core: core, isDataless: { url in
            url.standardizedFileURL == cloudFolder.standardizedFileURL
        })
        do {
            _ = try await indexer.refresh(source)
            XCTFail("A dataless subdirectory must stop traversal and source finalization")
        } catch EmbeddedPKSLibraryError.datalessPlaceholder {
            // Expected: do not enumerate the folder or delete its old indexed children.
        }

        let preserved = try await core.search("Previously searchable nested", mode: "fts", source: source.id)
        XCTAssertEqual(preserved.first?.uri, note.path)
        let replacement = try await core.search("Replacement must remain", mode: "fts", source: source.id)
        XCTAssertTrue(replacement.isEmpty)
    }

    func testRegistryAndIndexerPersistGrantAndBuildOfflineIndex() async throws {
        let suite = "EmbeddedPKSLibraryTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Alpha\nOffline library phrase".write(
            to: root.appendingPathComponent("Alpha.md"),
            atomically: true,
            encoding: .utf8
        )
        try Data("%PDF-1.4 test".utf8).write(to: root.appendingPathComponent("Manual.pdf"))

        let registry = EmbeddedPKSLibrarySourceRegistry(suiteName: suite)
        let source = try await registry.add(folder: root, excludingWorkspace: nil)
        let persistedSources = await registry.sources()
        XCTAssertEqual(persistedSources.count, 1)
        XCTAssertEqual(try EmbeddedPKSLibrarySourceRegistry.resolve(source).path, root.path)

        let database = root.appendingPathComponent("Index/knowledge.db")
        let core = try EmbeddedPKSCore(databaseURL: database)
        let indexer = EmbeddedPKSLibraryIndexer(core: core)
        let summary = try await indexer.refresh(source)
        XCTAssertEqual(summary.scannedFiles, 2)
        XCTAssertEqual(summary.indexedContentFiles, 1)
        XCTAssertEqual(summary.metadataOnlyFiles, 1)

        let contentHits = try await core.search("Offline library", source: source.id)
        XCTAssertTrue(contentHits.contains { $0.title == "Alpha.md" })
        let pdfHits = try await core.search("Manual PDF", mode: "metadata", source: source.id)
        XCTAssertEqual(pdfHits.first?.title, "Manual.pdf")

        try FileManager.default.removeItem(at: root.appendingPathComponent("Alpha.md"))
        let refreshed = try await indexer.refresh(source)
        XCTAssertEqual(refreshed.deletedDocuments, 1)
        let deletedHits = try await core.search("Alpha", mode: "metadata", source: source.id)
        XCTAssertTrue(deletedHits.isEmpty)
    }
#endif
}
