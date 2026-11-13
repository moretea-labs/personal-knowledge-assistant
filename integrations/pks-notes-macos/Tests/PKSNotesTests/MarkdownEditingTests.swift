import XCTest
@testable import PKSNotes

final class MarkdownEditingTests: XCTestCase {
    func testInlineCodeUsesSingleBackticksForOrdinaryText() {
        let source = "before ordinary after"
        let selection = (source as NSString).range(of: "ordinary")

        let result = MarkdownEditing.apply(.inlineCode, to: source, selection: selection)

        XCTAssertEqual(result.text, "before `ordinary` after")
        XCTAssertEqual(
            result.selection,
            NSRange(location: selection.location + 1, length: selection.length)
        )
    }

    func testInlineCodeUsesDelimiterLongerThanBacktickRunsInUnicodeSelection() {
        let selected = "😀 `single` and ``double``"
        let source = "before \(selected) after"
        let selection = (source as NSString).range(of: selected)
        let delimiter = "```"

        let result = MarkdownEditing.apply(.inlineCode, to: source, selection: selection)

        XCTAssertEqual(result.text, "before \(delimiter)\(selected)\(delimiter) after")
        XCTAssertEqual(
            result.selection,
            NSRange(location: selection.location + 3, length: selection.length)
        )
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), selected)
    }

    func testInlineCodeKeepsCaretInsideEmptyCodeSpan() {
        let result = MarkdownEditing.apply(.inlineCode, to: "", selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(result.text, "``")
        XCTAssertEqual(result.selection, NSRange(location: 1, length: 0))
    }
}
