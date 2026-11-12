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
