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
