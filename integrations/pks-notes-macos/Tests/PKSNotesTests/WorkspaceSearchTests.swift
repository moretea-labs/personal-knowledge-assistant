import Foundation
import XCTest
@testable import PKSNotes

final class WorkspaceSearchTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func entries(_ root: URL) -> [WorkspaceSearch.Entry] {
        NoteTreePresentation.quickOpenEntries(WorkspaceFiles.flatFiles(in: root))
            .map { WorkspaceSearch.Entry($0) }
    }

    func testStandaloneContentSearchUsesAllTermsAndShowsMatchingExcerpt() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("种植记录.md")
        let body = String(repeating: "前言内容。", count: 100) + "龟背竹换盆以后需要减少浇水，避免根部缺氧。"
        try body.write(to: file, atomically: true, encoding: .utf8)
        try "浇水时机".write(to: root.appendingPathComponent("其他.md"), atomically: true, encoding: .utf8)
        let result = WorkspaceSearch.search(entries: entries(root), root: root, query: "龟背竹 浇水")
        XCTAssertEqual(result.hits.map(\.uri), [file.path])
        XCTAssertTrue(result.hits[0].snippet?.contains("龟背竹") == true)
        XCTAssertEqual(result.hits[0].localFileURL, file)
        XCTAssertFalse(result.coverage.limited)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), body)
    }

    func testFilenamePDFAndAccentMatchingWithoutBinaryReads() throws {
        let root = try fixture()
        let pdf = root.appendingPathComponent("Café 资料.pdf")
        try Data([0, 255, 0]).write(to: pdf)
        let result = WorkspaceSearch.search(entries: entries(root), root: root, query: "CAFE")
        XCTAssertEqual(result.hits.map(\.uri), [pdf.path])
        XCTAssertNil(result.hits[0].snippet)
        XCTAssertEqual(result.coverage.readFiles, 0)
    }

    func testCurrentDraftSearchDoesNotWriteDraftToDisk() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("Draft.md")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let result = WorkspaceSearch.search(entries: entries(root), root: root, query: "unsaved",
                                            draftURL: file, draft: "unsaved changes")
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }

    func testCoverageDisclosesBudgetAndOversizedBodiesWhileKeepingFilenameMatches() throws {
        let root = try fixture()
        for name in ["A.md", "B.md", "C.md"] {
            try "needle".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let capped = WorkspaceSearch.search(entries: entries(root), root: root, query: "needle",
            limits: .init(files: 1, bytesPerFile: 32, totalBytes: 32, results: 50))
        XCTAssertEqual(capped.hits.count, 1)
        XCTAssertTrue(capped.coverage.limited)
        XCTAssertEqual(capped.coverage.skippedFiles, 2)
        let oversized = WorkspaceSearch.search(entries: entries(root), root: root, query: "A",
            limits: .init(files: 10, bytesPerFile: 2, totalBytes: 32, results: 50))
        XCTAssertEqual(oversized.hits.map(\.title), ["A"])
        XCTAssertEqual(oversized.coverage.skippedFiles, 3)
        XCTAssertEqual(oversized.coverage.readFiles, 0)
    }

    func testSymlinksAndOutsideEntriesCannotExposeExternalContents() throws {
        let root = try fixture()
        let outside = try fixture().appendingPathComponent("secret.md")
        try "private needle".write(to: outside, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let candidates = [link, outside].enumerated().map {
            WorkspaceSearch.Entry(
                NoteTreePresentation.QuickOpenEntry(item: NoteItem(url: $0.element, children: nil),
                                                     insertionOrder: $0.offset)
            )
        }
        XCTAssertTrue(WorkspaceSearch.search(entries: candidates, root: root, query: "needle").hits.isEmpty)
    }

    func testMergeKeepsRemoteSectionsAndDeduplicatesLocalDocument() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("Research.md")
        try "needle".write(to: file, atomically: true, encoding: .utf8)
        let local = WorkspaceSearch.search(entries: entries(root), root: root, query: "needle").hits
        let remote = ["section-1", "section-2"].map {
            SearchHit(documentId: "remote-doc", chunkId: $0, title: "Research", uri: file.path,
                      sourceType: "local", snippet: "needle", score: 1, headingPath: $0)
        }
        let merged = WorkspaceSearch.merging(local: local, remote: remote)
        XCTAssertEqual(merged.map(\.id), ["section-1", "section-2"])
        XCTAssertEqual(SearchResultGroup.group(merged).count, 1)
    }

    func testDirectLocalMatchRemainsFirstWhenUnrelatedRemoteResultsArrive() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("Plant.md")
        try "龟背竹换盆后减少浇水".write(to: file, atomically: true, encoding: .utf8)
        let local = WorkspaceSearch.search(entries: entries(root), root: root, query: "龟背竹").hits
        let remote = SearchHit(documentId: "unrelated", chunkId: nil, title: "Database",
                               uri: "notion://database", sourceType: "notion", snippet: "hash tables",
                               score: 0.2, headingPath: nil)
        XCTAssertEqual(WorkspaceSearch.merging(local: local, remote: [remote]).map(\.title), ["Plant", "Database"])
    }
}
