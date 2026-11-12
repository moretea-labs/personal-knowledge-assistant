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

    func testLocalFileSourceDoesNotInterpretOpaqueURI() {
        let hit = SearchHit(
            documentId: "opaque", chunkId: nil, title: "Notion page",
            uri: "notion://page-1", sourceType: "notion", snippet: nil,
            score: nil, headingPath: nil
        )
        XCTAssertNil(hit.localFileURL)
    }
}
