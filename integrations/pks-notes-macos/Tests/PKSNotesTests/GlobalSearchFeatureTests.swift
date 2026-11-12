import Carbon.HIToolbox
import XCTest
@testable import PKSNotes

final class GlobalSearchFeatureTests: XCTestCase {
    func testApplicationRankingIsExactPrefixThenSubstring() {
        let apps = [
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Visual Studio Code.app"), title: "Visual Studio Code"),
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Code.app"), title: "Code"),
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Xcode.app"), title: "Xcode"),
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Numbers.app"), title: "Numbers")
        ]
        let results = GlobalApplicationCatalog.matches(apps, query: "code")
        XCTAssertEqual(results.map(\.title), ["Code", "Xcode", "Visual Studio Code"])
    }

    func testSearchFoldIsCaseAndDiacriticInsensitive() {
        let apps = [
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Cafe.app"), title: "Café"),
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/Notes.app"), title: "Notes")
        ]
        XCTAssertEqual(GlobalApplicationCatalog.matches(apps, query: "CAFE").map(\.title), ["Café"])
        XCTAssertTrue(GlobalApplicationCatalog.matches(apps, query: " ").isEmpty)
    }

    func testSearchLimitAndShortcutChoices() {
        let apps = (0..<20).map { index in
            GlobalSearchItem.application(URL(fileURLWithPath: "/Applications/App\(index).app"), title: "App \(index)")
        }
        XCTAssertEqual(GlobalApplicationCatalog.matches(apps, query: "App", limit: 3).count, 3)
        XCTAssertEqual(GlobalSearchShortcut.optionSpace.keyCode, UInt32(kVK_Space))
        XCTAssertNotEqual(GlobalSearchShortcut.optionSpace.modifiers,
                          GlobalSearchShortcut.controlOptionP.modifiers)
    }

    func testUnifiedResultsDeduplicateAndPreferFilenames() {
        let path = URL(fileURLWithPath: "/Users/test/Documents/Budget Plan.pdf")
        let application = GlobalSearchItem.application(
            URL(fileURLWithPath: "/Applications/Budget.app"), title: "Budget")
        let document = GlobalSearchItem.spotlight(path, title: "Budget Plan.pdf", isFolder: false)
        let content = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/Diary.md"),
            title: "Diary.md", isFolder: false)
        let items = GlobalSearchRanker.merge(
            apps: [application], documents: [content, document],
            spotlight: [document], query: "budget"
        )
        XCTAssertEqual(items.map(\.title), ["Budget", "Budget Plan.pdf", "Diary.md"])
        XCTAssertEqual(items.count, 3)
    }

    func testSystemSpotlightCoversFilenamesAndIndexedDocumentContent() {
        let full = GlobalSpotlightLookup.searchPredicate(for: "OpenClaw")
        XCTAssertTrue(full.evaluate(with: [
            NSMetadataItemFSNameKey: "OpenClaw-guide.pdf",
            "kMDItemTextContent": ""
        ]))
        XCTAssertTrue(full.evaluate(with: [
            NSMetadataItemFSNameKey: "learning.md",
            "kMDItemTextContent": "Notes on OpenClaw commands"
        ]))
        XCTAssertFalse(full.evaluate(with: [
            NSMetadataItemFSNameKey: "budget.pdf",
            "kMDItemTextContent": "unrelated project"
        ]))
        let short = GlobalSpotlightLookup.searchPredicate(for: "OA")
        XCTAssertFalse(short.evaluate(with: [
            NSMetadataItemFSNameKey: "learning.md",
            "kMDItemTextContent": "OA only in body"
        ]))
    }

    func testDirectNameMatchesOutrankGlobalSpotlightBodyMatches() {
        let direct = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/OpenClaw-guide.md"),
            title: "OpenClaw-guide.md", isFolder: false
        )
        let body = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/commands.md"),
            title: "commands.md", isFolder: false,
            contentMatch: true, relevance: 0.85
        )
        let weakerBody = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/misc.md"),
            title: "misc.md", isFolder: false,
            contentMatch: true, relevance: 0.3
        )
        let found = GlobalSearchRanker.merge(
            apps: [], documents: [], spotlight: [weakerBody, direct, body],
            query: "OpenClaw"
        )
        XCTAssertEqual(found.map(\.title),
                       ["OpenClaw-guide.md", "commands.md", "misc.md"])
        XCTAssertFalse(found[0].spotlightContentMatch)
        XCTAssertTrue(found[1].spotlightContentMatch)
        XCTAssertEqual(found[1].spotlightRelevance, 0.85)
    }

    func testSpotlightRecoversICloudFilePathWithoutMetadataURL() {
        // A Spotlight result may have kMDItemPath but no kMDItemURL.
        let path = "/Users/example/Library/Mobile Documents/com~apple~CloudDocs/吉他谱/夜的钢琴曲五.pdf"
        let recovered = GlobalSpotlightLookup.fileURL(metadataURL: nil, metadataPath: path)
        XCTAssertEqual(recovered?.path, path)
        XCTAssertEqual(recovered?.lastPathComponent, "夜的钢琴曲五.pdf")
        XCTAssertTrue(recovered?.isFileURL == true)
        if let recovered {
            let entry = GlobalSearchItem.spotlight(recovered, title: "夜的钢琴曲五.pdf", isFolder: false)
            XCTAssertEqual(GlobalSpotlightLookup.rank([entry], for: "夜的钢琴曲").first?.url, recovered)
        }
        XCTAssertNil(GlobalSpotlightLookup.fileURL(metadataURL: nil, metadataPath: nil))
        XCTAssertNil(GlobalSpotlightLookup.fileURL(metadataURL: nil, metadataPath: "relative/path.pdf"))
        XCTAssertNil(GlobalSpotlightLookup.fileURL(
            metadataURL: URL(string: "https://example.com/unavailable.pdf"), metadataPath: nil
        ))
    }

    func testSpotlightRankingAndFolderClassification() {
        let folder = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/Study", isDirectory: true),
            title: "Study", isFolder: true)
        let file = GlobalSearchItem.spotlight(
            URL(fileURLWithPath: "/Users/test/Documents/Study-list.pdf"),
            title: "Study-list.pdf", isFolder: false)
        let match = GlobalSpotlightLookup.rank([file, folder], for: "study")
        XCTAssertEqual(match.first?.title, "Study")
        XCTAssertEqual(match.first?.kind, .folder)
    }

    func testPKSFileRetainsHitForLeafspanNavigation() {
        let url = URL(fileURLWithPath: "/Users/test/Documents/Study.md")
        let hit = SearchHit(
            documentId: "doc-123", chunkId: "chunk-456", title: "Study.md",
            uri: url.path, sourceType: "local",
            snippet: "matching paragraph", score: 0.98, headingPath: "Section One"
        )
        let item = GlobalSearchItem.file(hit, url: url)
        XCTAssertEqual(item.sourceHit?.documentId, "doc-123")
        XCTAssertEqual(item.sourceHit?.chunkId, "chunk-456")
        XCTAssertNil(GlobalSearchItem.spotlight(url, title: "Study.md", isFolder: false).sourceHit)
    }

    func testRelatedSuggestionsRankAfterDirectMatches() {
        XCTAssertFalse(GlobalSearchRanker.shouldFindRelated("kafka"))
        XCTAssertFalse(GlobalSearchRanker.shouldFindRelated("my file"))
        XCTAssertTrue(GlobalSearchRanker.shouldFindRelated("Kafka consumer event"))
        XCTAssertTrue(GlobalSearchRanker.shouldFindRelated("腹膜透析治疗"))
        XCTAssertFalse(GlobalSearchRanker.shouldFindRelated("腹膜"))
        func item(_ name: String, score: Double, related: Bool) -> GlobalSearchItem {
            let url = URL(fileURLWithPath: "/Users/test/Documents/" + name)
            let hit = SearchHit(documentId: name, chunkId: nil, title: name,
                uri: url.path, sourceType: "local", snippet: "matching consumer event",
                score: score, headingPath: nil)
            return GlobalSearchItem.file(hit, url: url, isRelated: related)
        }
        let merged = GlobalSearchRanker.merge(
            apps: [], documents: [item("Kafka.md", score: 0.6, related: false)],
            spotlight: [], related: [
                item("Offset.md", score: 0.4, related: true),
                item("Kafka.md", score: 0.99, related: true),
                item("Consumer.md", score: 0.9, related: true)
            ], query: "Kafka consumer event")
        XCTAssertEqual(merged.map(\.title), ["Kafka.md", "Consumer.md", "Offset.md"])
        XCTAssertFalse(merged[0].isRelated)
        XCTAssertTrue(merged[1].isRelated)
        XCTAssertEqual(merged[1].sourceHit?.score, 0.9)
    }

    func testRelatedSuggestionsRemainVisibleWhenDirectResultsFillTheLimit() {
        func item(_ index: Int, related: Bool) -> GlobalSearchItem {
            let url = URL(fileURLWithPath: "/Users/test/Documents/Study-\(index).md")
            let hit = SearchHit(documentId: "\(index)", chunkId: nil,
                                title: url.lastPathComponent, uri: url.path,
                                sourceType: "local", snippet: "notes about study",
                                score: Double(index) / 100, headingPath: nil)
            return GlobalSearchItem.file(hit, url: url, isRelated: related)
        }
        let direct = (0..<45).map { item($0, related: false) }
        let related = (45..<57).map { item($0, related: true) }
        let results = GlobalSearchRanker.merge(
            apps: [], documents: direct, spotlight: [],
            related: related, query: "学习阅读技巧", limit: 45)
        XCTAssertEqual(results.count, 53)
        XCTAssertTrue(results.prefix(45).allSatisfy { !$0.isRelated })
        XCTAssertTrue(results.suffix(8).allSatisfy(\.isRelated))
        XCTAssertEqual(Set(results.map(\.url)).count, 53)
    }

    func testLocalFileSourceDoesNotInterpretOpaqueURI() {
        let hit = SearchHit(
            documentId: "opaque", chunkId: nil, title: "Notion page",
            uri: "notion://page-1", sourceType: "notion", snippet: nil,
            score: nil, headingPath: nil
        )
        XCTAssertNil(hit.localFileURL)
    }
}

extension GlobalSearchFeatureTests {
    func testGlobalShortcutAndPKSIndexedFolderSearchAreIndependentOptIns() {
        XCTAssertNotEqual(GlobalSearchPreferences.enabledKey,
                          GlobalSearchPreferences.indexedFoldersEnabledKey)
        XCTAssertEqual(GlobalSearchShortcut.defaultChoice, .controlOptionP)
        XCTAssertEqual(GlobalSearchShortcut.defaultChoice.keyCode, UInt32(kVK_ANSI_P))
        XCTAssertEqual(GlobalSearchShortcut.defaultChoice.modifiers, UInt32(controlKey | optionKey))
        XCTAssertNotEqual(GlobalSearchShortcut.optionSpace.modifiers,
                          GlobalSearchShortcut.defaultChoice.modifiers)
    }
}
