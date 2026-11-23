import XCTest
@testable import PKSNotes

final class EmbeddedPKSCoreTests: XCTestCase {
    func testAvailabilityMatchesLinkedNativeModule() {
#if canImport(PKSCore)
        XCTAssertTrue(EmbeddedPKSCore.isAvailable)
#else
        XCTAssertFalse(EmbeddedPKSCore.isAvailable)
#endif
    }

#if canImport(PKSCore)
    func testIndexSearchAndFinalizeUseTheEmbeddedDatabase() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-EmbeddedPKS-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = try EmbeddedPKSCore(databaseURL: root.appendingPathComponent("knowledge.db"))
        let alpha = root.appendingPathComponent("Alpha.md").path
        let beta = root.appendingPathComponent("Beta.md").path

        let changed = try await core.index(EmbeddedPKSDocument(
            sourceId: "library",
            sourceName: "Library",
            rootURI: root.path,
            uri: alpha,
            title: "Alpha",
            text: "# Alpha\nNative Leafspan library search",
            documentType: "note"
        ))
        XCTAssertTrue(changed)
        _ = try await core.index(EmbeddedPKSDocument(
            sourceId: "library",
            sourceName: "Library",
            rootURI: root.path,
            uri: beta,
            title: "Beta",
            text: "# Beta\nOther library material",
            documentType: "note"
        ))

        let hits = try await core.search("Leafspan library", source: "library")
        XCTAssertEqual(hits.first?.title, "Alpha")
        XCTAssertTrue(hits.contains { $0.uri == alpha })

        let deleted = try await core.finalize(sourceId: "library", seenURIs: [alpha])
        XCTAssertEqual(deleted, 1)
        let betaHits = try await core.search("Beta", mode: "metadata", source: "library")
        XCTAssertTrue(betaHits.isEmpty)
    }
#endif
}
