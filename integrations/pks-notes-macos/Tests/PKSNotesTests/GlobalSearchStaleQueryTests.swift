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

        let staleQuery = ["jxalpha", "20261127"].joined()
        let currentQuery = ["jxbravo", "20261127"].joined()
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
            with: [hit("stale", title: "\(staleQuery) stale", url: staleURL, snippet: "stale-only")]
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(results.loading, "A late stale completion must not clear the replacement query's loading state.")
        XCTAssertFalse(results.items.contains(where: { $0.url == staleURL }), "A stale result must never be published into the replacement query.")

        await provider.complete(
            currentQuery,
            with: [
                hit("current-1", title: "\(currentQuery) first", url: currentFirstURL, snippet: "current-first"),
                hit("current-2", title: "\(currentQuery) second", url: currentSecondURL, snippet: "current-second")
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

    @MainActor
    func testClosedPaletteInvalidatesQueriesAAndBBeforeReopenedQueryC() async throws {
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

        let queryA = ["jny07alpha", "20261127"].joined()
        let queryB = ["jny07beta", "20261127"].joined()
        let queryC = ["jny07gamma", "20261127"].joined()
        let urlA = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-closed-search-a.md")
        let urlB = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-closed-search-b.md")
        let urlCFirst = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-reopened-search-c-first.md")
        let urlCSecond = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-reopened-search-c-second.md")

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
        results.query = queryA
        try await Task.sleep(for: .milliseconds(300))
        let requestAStarted = await provider.hasPendingRequest(for: queryA)
        XCTAssertTrue(requestAStarted)

        results.query = queryB
        try await Task.sleep(for: .milliseconds(300))
        let requestBStarted = await provider.hasPendingRequest(for: queryB)
        XCTAssertTrue(requestBStarted)
        XCTAssertTrue(results.loading)

        // Cancel closes the palette while both disjoint provider requests are unresolved.
        results.cancel()
        XCTAssertFalse(results.loading)
        XCTAssertTrue(results.items.isEmpty)
        XCTAssertNil(results.selected)

        // Query A completes while the palette is closed; it must not publish into hidden state.
        await provider.complete(
            queryA,
            with: [hit("a", title: "\(queryA) stale", url: urlA, snippet: "stale-a")]
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(results.items.isEmpty)
        XCTAssertFalse(results.loading)

        // Reopening starts a new presentation generation and discards the previous selection/results.
        results.start()
        XCTAssertEqual(results.query, "")
        XCTAssertTrue(results.items.isEmpty)
        XCTAssertNil(results.selected)
        XCTAssertFalse(results.loading)

        results.query = queryC
        try await Task.sleep(for: .milliseconds(300))
        let requestCStarted = await provider.hasPendingRequest(for: queryC)
        XCTAssertTrue(requestCStarted)
        XCTAssertTrue(results.loading)

        // Query B's delayed completion arrives after C has become the active query.
        await provider.complete(
            queryB,
            with: [hit("b", title: "\(queryB) stale", url: urlB, snippet: "stale-b")]
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(results.items.isEmpty)
        XCTAssertTrue(results.loading)

        await provider.complete(
            queryC,
            with: [
                hit("c-1", title: "\(queryC) first", url: urlCFirst, snippet: "current-c-first"),
                hit("c-2", title: "\(queryC) second", url: urlCSecond, snippet: "current-c-second")
            ]
        )
        for _ in 0..<100 {
            let hasBothCurrentResults = results.items.contains(where: { $0.url == urlCFirst })
                && results.items.contains(where: { $0.url == urlCSecond })
            if hasBothCurrentResults { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(Set(results.items.map(\.url)), Set([urlCFirst, urlCSecond]))
        XCTAssertFalse(results.items.contains(where: { $0.url == urlA || $0.url == urlB }))
        if let secondCurrentResult = results.items.first(where: { $0.url == urlCSecond }) {
            results.select(secondCurrentResult)
            XCTAssertEqual(results.selected?.url, urlCSecond)
        } else {
            XCTFail("The reopened query's second result must remain selectable.")
        }

        // Global Spotlight has an independent three-second timeout; once it settles,
        // the completed C request must leave the palette idle.
        for _ in 0..<400 {
            if !results.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(results.loading)
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
