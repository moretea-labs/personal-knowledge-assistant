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

    func testPinyinAndChineseQueriesFindEachOtherInFilenamesWithoutReadingBinary() throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("吉他谱", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let chinese = folder.appendingPathComponent("夜的钢琴曲五.pdf")
        let romanized = root.appendingPathComponent("ye-de-gang-qin-qu-five.pdf")
        try Data([0, 255, 0]).write(to: chinese)
        try Data([1, 254, 1]).write(to: romanized)

        let pinyinQuery = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "ye de gang qin qu"
        )
        XCTAssertEqual(Set(pinyinQuery.hits.map(\.uri)), Set([chinese.path, romanized.path]))
        XCTAssertEqual(pinyinQuery.coverage.readFiles, 0)

        let chineseQuery = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "夜的钢琴曲"
        )
        XCTAssertEqual(Set(chineseQuery.hits.map(\.uri)), Set([chinese.path, romanized.path]))
        XCTAssertEqual(chineseQuery.coverage.readFiles, 0)
    }

    func testPinyinPathSearchDoesNotMatchTheWorkspaceRootName() throws {
        let parent = try fixture()
        let root = parent.appendingPathComponent("夜的钢琴曲", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unrelated = root.appendingPathComponent("Unrelated.md")
        try "".write(to: unrelated, atomically: true, encoding: .utf8)

        let result = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "ye de gang qin qu",
            searchBodies: false
        )

        XCTAssertTrue(result.hits.isEmpty)
    }

    func testPinyinPathSearchCanSpanFolderAndFilename() throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("夜的", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("钢琴曲.md")
        try "".write(to: file, atomically: true, encoding: .utf8)

        let result = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "ye de gang qin qu",
            searchBodies: false
        )

        XCTAssertEqual(result.hits.map(\.uri), [file.path])
    }

    func testPinyinFilenameMatchRanksAheadOfPinyinFolderMatch() throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("夜的钢琴曲", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let nested = folder.appendingPathComponent("notes.md")
        let filename = root.appendingPathComponent("夜的钢琴曲.md")
        try "# Nested note".write(to: nested, atomically: true, encoding: .utf8)
        try "# Filename match".write(to: filename, atomically: true, encoding: .utf8)

        let result = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "ye de gang qin qu",
            searchBodies: false
        )
        let paths = result.hits.map(\.uri)
        XCTAssertLessThan(
            try XCTUnwrap(paths.firstIndex(of: filename.path)),
            try XCTUnwrap(paths.firstIndex(of: nested.path))
        )
    }

    func testPinyinFilenameSearchSkipsBodyReadWhenBodySearchIsEnabled() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("夜的钢琴曲五.md")
        try "The body does not contain any query terms".write(
            to: file, atomically: true, encoding: .utf8
        )

        let result = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "ye de gang qin qu"
        )

        XCTAssertEqual(result.hits.map(\.uri), [file.path])
        XCTAssertEqual(result.coverage.readFiles, 0)
        XCTAssertEqual(result.coverage.skippedFiles, 0)
        XCTAssertNil(result.hits[0].snippet)
    }

    func testPinyinBodySearchMatchesWordStartsAndShowsTheChineseExcerpt() throws {
        let root = try fixture()
        let piano = root.appendingPathComponent("Study.md")
        let world = root.appendingPathComponent("World.md")
        let middleMatch = root.appendingPathComponent("History.md")
        let prefix = String(repeating: "前言内容。", count: 80)
        try (prefix + "今天练习夜的钢琴曲五。").write(
            to: piano, atomically: true, encoding: .utf8
        )
        try (prefix + "今天阅读世界地图。").write(
            to: world, atomically: true, encoding: .utf8
        )
        try (prefix + "今天研究历史结构。").write(
            to: middleMatch, atomically: true, encoding: .utf8
        )

        let pianoResult = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "ye de gang qin qu"
        )
        XCTAssertEqual(pianoResult.hits.map(\.uri), [piano.path])
        XCTAssertTrue(pianoResult.hits[0].snippet?.contains("夜的钢琴曲五") == true)

        let wordStartResult = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "shi jie"
        )
        XCTAssertEqual(wordStartResult.hits.map(\.uri), [world.path])
        XCTAssertTrue(wordStartResult.hits[0].snippet?.contains("世界地图") == true)
        XCTAssertFalse(wordStartResult.hits.contains { $0.uri == middleMatch.path })
    }

    func testFilenameSearchAllowsOneTypoButDoesNotBroadenShortOrTwoEditTerms() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("night-piano.md")
        try "A piano practice note".write(to: file, atomically: true, encoding: .utf8)

        let oneEdit = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "nigjt piano"
        )
        XCTAssertEqual(oneEdit.hits.map(\.uri), [file.path])

        let twoEdits = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "nigjjtt piano"
        )
        XCTAssertTrue(twoEdits.hits.isEmpty)

        let short = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "nigt"
        )
        XCTAssertTrue(short.hits.isEmpty)
    }

    func testMultiTermFuzzySearchMatchesSeparatePathTokens() throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("night", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("piano.md")
        try "# Practice".write(to: file, atomically: true, encoding: .utf8)

        let matched = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "nigjt piana", searchBodies: false
        )
        XCTAssertEqual(matched.hits.map(\.uri), [file.path])
        XCTAssertEqual(matched.coverage.readFiles, 0)

        let missingTerm = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "nigjt piana cello", searchBodies: false
        )
        XCTAssertTrue(missingTerm.hits.isEmpty)
    }

    func testFilenameMatchesDoNotReadMarkdownBodies() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("Research.md")
        try "This body should not be read for a filename match".write(
            to: file, atomically: true, encoding: .utf8
        )

        let result = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "Research"
        )

        XCTAssertEqual(result.hits.map(\.uri), [file.path])
        XCTAssertEqual(result.coverage.readFiles, 0)
        XCTAssertEqual(result.coverage.skippedFiles, 0)
        XCTAssertNil(result.hits[0].snippet)
    }

    func testFolderAndFilenameTermsDoNotReadMarkdownBodies() throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("Research Plans", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notes.md")
        try "This body is unrelated to the path query".write(
            to: file, atomically: true, encoding: .utf8
        )

        let result = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "Research notes"
        )

        XCTAssertEqual(result.hits.map(\.uri), [file.path])
        XCTAssertEqual(result.coverage.readFiles, 0)
        XCTAssertEqual(result.coverage.skippedFiles, 0)
        XCTAssertNil(result.hits[0].snippet)
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
        XCTAssertEqual(oversized.coverage.skippedFiles, 2)
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


extension WorkspaceSearchTests {
    func testPinyinSearchRespectsChineseWordStartBoundaries() throws {
        let root = try fixture()
        let expected = root.appendingPathComponent("世界.md")
        let falsePositive = root.appendingPathComponent("历史结构.md")
        try "".write(to: expected, atomically: true, encoding: .utf8)
        try "".write(to: falsePositive, atomically: true, encoding: .utf8)
        let result = WorkspaceSearch.search(
            entries: entries(root), root: root, query: "shi jie", searchBodies: false
        )
        XCTAssertEqual(result.hits.map(\.uri), [expected.path])
        XCTAssertEqual(result.coverage.readFiles, 0)
    }
}
