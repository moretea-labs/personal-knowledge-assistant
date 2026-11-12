import Foundation
import XCTest
@testable import PKSNotes

/// Local-only deterministic transport fixture; no real PKS service is contacted.
private final class DelayedSearchURLProtocol: URLProtocol {
    private var delivery: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/api/search"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else { return }
        let term = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
        if term == "offline-needle" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let payload = try! JSONSerialization.data(withJSONObject: [[
            "documentId": term, "title": term,
            "uri": "/tmp/\(term).md", "sourceType": "local"
        ]])
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.delivery?.isCancelled == false else { return }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: payload)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        delivery = job
        DispatchQueue.global().asyncAfter(
            deadline: .now() + (term == "slow" ? 0.30 : 0.02), execute: job
        )
    }

    override func stopLoading() {
        delivery?.cancel()
        delivery = nil
    }
}

final class SearchConcurrencyTests: XCTestCase {
    @MainActor
    private func workspace() throws -> (NotesModel, URL) {
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
        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        return (model, root)
    }

    @MainActor
    func testMissingProviderRetainsStandaloneBodySearchAndCanOpenResult() async throws {
        let (model, root) = try workspace()
        let note = root.appendingPathComponent("Field notes.md")
        try "# Field notes\nAn offline-needle is in the body.".write(to: note, atomically: true, encoding: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedSearchURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        model.query = "offline-needle"
        model.search(using: session)
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedSearchURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        model.query = "slow"
        model.search(using: session)
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedSearchURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = NotesModel()

        model.query = "slow"
        model.search(using: session)
        try await Task.sleep(for: .milliseconds(40))
        model.query = "fast"
        model.search(using: session)

        for _ in 0..<150 where model.searching {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.searching)
        XCTAssertEqual(model.hits.map(\.title), ["fast"])
        XCTAssertFalse(model.searchFailed)

        // The slower previous request must not repaint or clear newer results.
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.hits.map(\.title), ["fast"])
        XCTAssertFalse(model.searchFailed)
    }

    @MainActor
    func testQueryEditAndClearCancelPendingSearchWithoutStaleError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedSearchURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = NotesModel()

        model.query = "slow"
        model.search(using: session)
        XCTAssertTrue(model.searching)
        model.query = ""
        model.search(using: session)
        XCTAssertFalse(model.searching)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertFalse(model.searchFailed)

        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(model.searching)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertFalse(model.searchFailed)
    }
}
