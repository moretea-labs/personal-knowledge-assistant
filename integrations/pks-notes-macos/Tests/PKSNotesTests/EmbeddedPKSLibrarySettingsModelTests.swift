import XCTest
@testable import PKSNotes

final class EmbeddedPKSLibrarySettingsModelTests: XCTestCase {
    @MainActor
    func testOverlappingFolderDoesNotRegisterOrEnableIndexedLibrary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Library-Overlap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suite = "Leafspan-Library-Settings-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let registry = EmbeddedPKSLibrarySourceRegistry(suiteName: suite)
        let model = EmbeddedPKSLibrarySettingsModel(registry: registry)

        let registered = await model.add(folder: root, excludingWorkspace: root)
        XCTAssertFalse(registered)
        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertTrue(model.statusIsError)
        XCTAssertNotNil(model.statusMessage)
        let saved = await registry.sources()
        XCTAssertTrue(saved.isEmpty)
    }

    #if canImport(PKSCore)
    @MainActor
    func testRegisteredButUnreadableFolderShowsRetryInsteadOfAddFailure() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Library-Index-Failure-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data([0xFF, 0xFE, 0xFD]).write(
            to: root.appendingPathComponent("Invalid.md"), options: .atomic
        )

        let suite = "Leafspan-Library-Settings-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let registry = EmbeddedPKSLibrarySourceRegistry(suiteName: suite)
        let core = try EmbeddedPKSCore(
            databaseURL: base.appendingPathComponent("Index/knowledge.db")
        )
        let model = EmbeddedPKSLibrarySettingsModel(registry: registry, core: core)

        let registered = await model.add(folder: root, excludingWorkspace: nil)
        XCTAssertTrue(registered, "Folder grant succeeded even when parsing failed.")
        XCTAssertEqual(model.sources.count, 1)
        XCTAssertTrue(model.statusIsError)
        let message = try XCTUnwrap(model.statusMessage)
        XCTAssertTrue(message.contains("索引失败") || message.contains("indexing failed"))
        XCTAssertFalse(message.contains("无法添加") || message.contains("Unable to add"))
        let saved = await registry.sources()
        XCTAssertEqual(saved.count, 1)

        try "# Notes\nRecovered searchable paragraph.".write(
            to: root.appendingPathComponent("Invalid.md"),
            atomically: true, encoding: .utf8
        )
        let refreshed = try await model.refresh(try XCTUnwrap(saved.first))
        XCTAssertEqual(refreshed.indexedContentFiles, 1)
        XCTAssertFalse(model.statusIsError)
        XCTAssertNil(model.workingSourceID)
    }

    @MainActor
    func testSuccessfullyAddedFolderShowsIndexSummaryWithoutError() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Library-Added-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "# Notes\nSearch settings regression.".write(
            to: root.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8
        )

        let suite = "Leafspan-Library-Settings-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let registry = EmbeddedPKSLibrarySourceRegistry(suiteName: suite)
        let core = try EmbeddedPKSCore(
            databaseURL: base.appendingPathComponent("Index/knowledge.db")
        )
        let model = EmbeddedPKSLibrarySettingsModel(registry: registry, core: core)

        let registered = await model.add(folder: root, excludingWorkspace: nil)
        XCTAssertTrue(registered)
        XCTAssertEqual(model.sources.count, 1)
        XCTAssertFalse(model.statusIsError)
        let message = try XCTUnwrap(model.statusMessage)
        XCTAssertTrue(message.contains("已扫描") || message.contains("Scanned"))
    }
    #endif
}
