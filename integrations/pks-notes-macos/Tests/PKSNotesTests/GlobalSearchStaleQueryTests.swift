import Foundation
import XCTest
@testable import PKSNotes

final class GlobalSearchStaleQueryTests: XCTestCase {
    @MainActor
    func testLateLibraryResultsCannotReplaceNewerQueryOrClearItsLoadingState() async throws {
        let key = GlobalSearchPreferences.indexedFoldersEnabledKey
        let previousSetting = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)

        let provider = DeferredGlobalLibrarySearchProvider()
        let results = GlobalSearchResults(libraryProvider: provider)
        defer {
            results.cancel()
            if let previousSetting {
                UserDefaults.standard.set(previousSetting, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let staleQuery = "zzalpha01"
        let currentQuery = "zzbeta01"
        let staleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-stale-search-result.md")
        let currentFirstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-current-search-first.md")
        let currentSecondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-current-search-second.md")

        func hit(_ id: String, title: String, url: URL, snippet: String) -> SearchHit {
            SearchHit(
                documentId: id,
                chunkId: id,
                title: title,
                uri: url.path,
                sourceType: "local",
                snippet: snippet,
                score: 1,
                headingPath: nil
            )
        }

        results.start()
        results.query = staleQuery
        try await Task.sleep(for: .milliseconds(300))
        let staleRequestStarted = await provider.hasPendingRequest(for: staleQuery)
        XCTAssertTrue(staleRequestStarted, "The delayed first query must reach the library provider.")

        results.query = currentQuery
        try await Task.sleep(for: .milliseconds(300))
        let currentRequestStarted = await provider.hasPendingRequest(for: currentQuery)
        XCTAssertTrue(currentRequestStarted, "The replacement query must start while the first provider call is still pending.")

        // Let the replacement query's independent Spotlight timeout expire. Its library
        // request must still own the loading state while the stale first request is pending.
        try await Task.sleep(for: .milliseconds(3_100))
        XCTAssertTrue(results.loading, "The current query must remain loading while its library response is pending.")

        await provider.complete(
            staleQuery,
            with: [hit("stale", title: "zzalpha01 stale", url: staleURL, snippet: "stale-only")]
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(results.loading, "A late stale completion must not clear the replacement query's loading state.")
        XCTAssertFalse(results.items.contains(where: { $0.url == staleURL }), "A stale result must never be published into the replacement query.")

        await provider.complete(
            currentQuery,
            with: [
                hit("current-1", title: "zzbeta01 first", url: currentFirstURL, snippet: "current-first"),
                hit("current-2", title: "zzbeta01 second", url: currentSecondURL, snippet: "current-second")
            ]
        )
        for _ in 0..<100 {
            let hasBothCurrentResults = results.items.contains(where: { $0.url == currentFirstURL })
                && results.items.contains(where: { $0.url == currentSecondURL })
            if hasBothCurrentResults { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let currentURLs = Set(results.items.map(\.url))
        XCTAssertEqual(currentURLs, Set([currentFirstURL, currentSecondURL]))
        XCTAssertFalse(results.items.contains(where: { $0.url == staleURL }))
        if let selected = results.items.first(where: { $0.url == currentSecondURL }) {
            results.select(selected)
            XCTAssertEqual(results.selected?.url, currentSecondURL)
        } else {
            XCTFail("The replacement query's second result should remain selectable.")
        }
        XCTAssertFalse(results.loading, "The replacement query should stop loading after its own response completes.")
        await provider.completeAll()
    }
}

private actor DeferredGlobalLibrarySearchProvider: GlobalLibrarySearchProviding {
    private var pending: [String: CheckedContinuation<[SearchHit], Error>] = [:]

    func search(_ query: String, mode _: String, limit _: Int) async throws -> [SearchHit] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[SearchHit], Error>) in
            pending[query] = continuation
        }
    }

    func hasPendingRequest(for query: String) -> Bool {
        pending[query] != nil
    }

    func complete(_ query: String, with hits: [SearchHit]) {
        pending.removeValue(forKey: query)?.resume(returning: hits)
    }

    func completeAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(returning: [])
        }
    }
}
