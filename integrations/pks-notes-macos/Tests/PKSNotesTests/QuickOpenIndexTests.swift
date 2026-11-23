import Foundation
import XCTest
@testable import PKSNotes

final class QuickOpenIndexTests: XCTestCase {
    func testSharedTokenCachePreservesExactSearchKeys() {
        let paths = [
            "/Users/test/学习笔记管理/学习资料/冒险与偏好.md",
            "/Users/test/学习笔记管理/学习资料/Unit 3A - 冒险与偏好.md",
            "/Users/test/学习笔记管理/学习资料/Notion/Untitled 68df-b2b7/acquireSharedInterruptibly f8a4de26cc2a48e5baa469b8120a7b00.md",
            "/Users/test/学习笔记管理/学习资料/Notion/MVC-in-Wikipedia.jpg",
            "/Users/test/学习笔记管理/课程/Redis.md"
        ]
        let items = paths.map { NoteItem(url: URL(fileURLWithPath: $0), children: nil) }
        let expected = items.enumerated().map {
            NoteTreePresentation.QuickOpenEntry(item: $0.element, insertionOrder: $0.offset)
        }
        let tokenCache = NoteTreePresentation.TransliterationTokenCache()
        let actual = items.enumerated().map {
            NoteTreePresentation.QuickOpenEntry(item: $0.element, insertionOrder: $0.offset, tokenCache: tokenCache)
        }
        XCTAssertEqual(actual.count, expected.count)
        for index in expected.indices {
            XCTAssertEqual(actual[index].foldedName, expected[index].foldedName)
            XCTAssertEqual(actual[index].foldedFolder, expected[index].foldedFolder)
            XCTAssertEqual(actual[index].pathTransliterationKey.value, expected[index].pathTransliterationKey.value)
            XCTAssertEqual(actual[index].pathTransliterationKey.tokenStarts, expected[index].pathTransliterationKey.tokenStarts)
            XCTAssertEqual(actual[index].nameTransliterationKey.value, expected[index].nameTransliterationKey.value)
            XCTAssertEqual(actual[index].nameTransliterationKey.tokenStarts, expected[index].nameTransliterationKey.tokenStarts)
        }
    }
}
