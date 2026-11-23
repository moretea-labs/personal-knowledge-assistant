import AppKit
import XCTest
@testable import PKSNotes

final class EmbeddedPKSSearchProviderTests: XCTestCase {
#if canImport(PKSCore)
    func testProviderSearchesEmbeddedDatabaseWithoutHTTP() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Provider-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let core = try EmbeddedPKSCore(databaseURL: root.appendingPathComponent("knowledge.db"))
        let uri = root.appendingPathComponent("Provider.md").path
        _ = try await core.index(EmbeddedPKSDocument(
            sourceId: "library",
            sourceName: "Library",
            rootURI: root.path,
            uri: uri,
            title: "Provider.md",
            text: "# Provider\nEmbedded provider needle",
            documentType: "note"
        ))

        let provider = EmbeddedPKSSearchProvider(core: core)
        let hits = try await provider.search("provider needle", mode: "auto", limit: 10)

        XCTAssertTrue(hits.contains { $0.uri == uri })
    }
#endif

    @MainActor
    func testGlobalSearchUsesInjectedLibraryProvider() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let key = GlobalSearchPreferences.indexedFoldersEnabledKey
        let original = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("Injected Provider.md").path
        let provider = StubGlobalLibraryProvider(hit: SearchHit(
            documentId: "provider-doc",
            chunkId: "provider-chunk",
            title: "Injected Provider.md",
            uri: file,
            sourceType: "local",
            snippet: "injected library needle",
            score: 0.9,
            headingPath: nil
        ))
        let results = GlobalSearchResults(libraryProvider: provider)
        results.start()
        results.query = "injected library"

        for _ in 0..<200 where !results.items.contains(where: { $0.url.path == file }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(results.items.contains { $0.url.path == file })
        XCTAssertFalse(results.statusMessage?.contains("Library search unavailable") ?? false)
        results.cancel()
    }
}

private actor StubGlobalLibraryProvider: GlobalLibrarySearchProviding {
    let hit: SearchHit

    init(hit: SearchHit) {
        self.hit = hit
    }

    func search(_ query: String, mode: String, limit: Int) async throws -> [SearchHit] {
        mode == "auto" ? [hit] : []
    }
}
