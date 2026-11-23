import Foundation
import XCTest
@testable import PKSNotes

private actor DelayedLibraryProvider: LibrarySearchProviding {
    func search(
        _ query: String,
        mode: String,
        limit: Int,
        excludeURI: String?
    ) async throws -> [SearchHit] {
        if query == "offline-needle" {
            throw URLError(.cannotConnectToHost)
        }
        try await Task.sleep(for: query == "slow" ? .milliseconds(300) : .milliseconds(20))
        try Task.checkCancellation()
        return [SearchHit(
            documentId: query,
            chunkId: nil,
            title: query,
            uri: "/tmp/\(query).md",
            sourceType: "local",
            snippet: nil,
            score: 1,
            headingPath: nil
        )]
    }
}

final class SearchConcurrencyTests: XCTestCase {
    @MainActor
    private func workspace(
        provider: any LibrarySearchProviding = DelayedLibraryProvider()
    ) throws -> (NotesModel, URL) {
        let defaults = UserDefaults.standard
        let keys = ["PKSNotesWorkspace", "PKSNotesWorkspaceBookmark", "PKSNotesLastOpenedMarkdown"]
        let original = keys.map { defaults.object(forKey: $0) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            for (key, value) in zip(keys, original) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        let model = NotesModel(libraryProvider: provider)
        XCTAssertTrue(model.openWorkspace(root))
        return (model, root)
    }

    @MainActor
    func testMissingProviderRetainsStandaloneBodySearchAndCanOpenResult() async throws {
        let (model, root) = try workspace()
        let note = root.appendingPathComponent("Field notes.md")
        try "# Field notes\nAn offline-needle is in the body.".write(to: note, atomically: true, encoding: .utf8)
        model.query = "offline-needle"
        model.search()
        for _ in 0..<200 where model.searching {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.searching)
        XCTAssertFalse(model.searchFailed)
        XCTAssertEqual(model.hits.map(\.uri), [note.path])
        XCTAssertNil(model.message)
        if let hit = model.hits.first { model.openResult(hit) }
        for _ in 0..<200 where model.loadingNote {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.selected, note)
        XCTAssertTrue(model.draft.contains("offline-needle"))
    }

    @MainActor
    func testLocalResultsPublishBeforeSlowProviderAndWorkspaceChangeCancelsSearch() async throws {
        let (model, root) = try workspace()
        try "slow keyword".write(to: root.appendingPathComponent("Local.md"), atomically: true, encoding: .utf8)
        model.query = "slow"
        model.search()
        for _ in 0..<100 where model.hits.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(model.hits.first?.title, "Local")
        XCTAssertTrue(model.searching, "Local results appear while the provider is still pending")
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertTrue(model.openWorkspace(other))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertFalse(model.searching)
        XCTAssertEqual(model.query, "")
    }

    @MainActor
    func testSupersededSearchCannotOverwriteLatestResults() async throws {
        let model = NotesModel(libraryProvider: DelayedLibraryProvider())

        model.query = "slow"
        model.search()
        try await Task.sleep(for: .milliseconds(40))
        model.query = "fast"
        model.search()

        for _ in 0..<150 where model.searching {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.searching)
        XCTAssertEqual(model.hits.map(\.title), ["fast"])
        XCTAssertFalse(model.searchFailed)

        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.hits.map(\.title), ["fast"])
        XCTAssertFalse(model.searchFailed)
    }

    @MainActor
    func testQueryEditAndClearCancelPendingSearchWithoutStaleError() async throws {
        let model = NotesModel(libraryProvider: DelayedLibraryProvider())

        model.query = "slow"
        model.search()
        XCTAssertTrue(model.searching)
        model.query = ""
        model.search()
        XCTAssertFalse(model.searching)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertFalse(model.searchFailed)

        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(model.searching)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertFalse(model.searchFailed)
    }
}

extension SearchConcurrencyTests {
    @MainActor
    func testGlobalSearchPublishesLoadedWorkspaceMatchesBeforeColdIndexCompletes() async throws {
        let (model, root) = try workspace()
        let note = root.appendingPathComponent("Immediate study.md")
        try "# Immediate study\nA local result should appear before the complete vault scan.".write(
            to: note, atomically: true, encoding: .utf8
        )
        model.refresh()
        for _ in 0..<200 where model.loadingFiles {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(model.loadingFiles)
        XCTAssertFalse(model.globalFileIndexReady)
        var partialPaths: [String] = []
        var deliveredBeforeFullIndex = false
        let complete = await model.searchWorkspace("Immediate") { partial in
            partialPaths = partial.hits.map(\.uri)
            deliveredBeforeFullIndex = !model.globalFileIndexReady
        }

        XCTAssertTrue(deliveredBeforeFullIndex)
        XCTAssertEqual(partialPaths, [note.path])
        XCTAssertEqual(complete.hits.map(\.uri), [note.path])
        XCTAssertTrue(model.globalFileIndexReady)
    }
}
