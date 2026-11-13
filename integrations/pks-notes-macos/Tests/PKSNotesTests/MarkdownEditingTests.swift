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

    func testInlineCodePreservesBoundarySpacesAndDoesNotPadWhitespaceOnlySelection() {
        let cases = [
            ("  value  ", "before`   value   `after", 2),
            ("   ", "before`   `after", 1),
            ("\nvalue\n", "before` \nvalue\n `after", 2)
        ]

        for (selected, expected, selectionOffset) in cases {
            let source = "before\(selected)after"
            let selection = (source as NSString).range(of: selected)
            let result = MarkdownEditing.apply(.inlineCode, to: source, selection: selection)

            XCTAssertEqual(result.text, expected)
            XCTAssertEqual(
                result.selection,
                NSRange(location: selection.location + selectionOffset, length: selection.length)
            )
            XCTAssertEqual((result.text as NSString).substring(with: result.selection), selected)
        }
    }

    func testBulletListCommandTogglesOffExistingNestedBullets() {
        let source = "- first\n  * nested\n"
        let result = MarkdownEditing.apply(
            .bullet, to: source, selection: NSRange(location: 0, length: (source as NSString).length)
        )
        XCTAssertEqual(result.text, "first\n  nested\n")
    }

    func testTaskCommandConvertsMixedLinesAndPreservesCheckedStateAndBlankLines() {
        let source = "first\n* [X] done\n- bullet\n  \nlast\n"
        let result = MarkdownEditing.apply(
            .task, to: source, selection: NSRange(location: 0, length: (source as NSString).length)
        )
        XCTAssertEqual(result.text, "- [ ] first\n- [X] done\n- [ ] bullet\n  \n- [ ] last\n")
    }

    func testTaskListCommandTogglesOffCheckedAndUncheckedItems() {
        let source = "- [ ] todo\n  + [x] done\n"
        let result = MarkdownEditing.apply(
            .task, to: source, selection: NSRange(location: 0, length: (source as NSString).length)
        )
        XCTAssertEqual(result.text, "todo\n  done\n")
    }

    func testBulletCommandConvertsOrderedAndTaskItemsWithoutNestingMarkers() {
        let source = "1. first\n- [ ] done\n"
        let result = MarkdownEditing.apply(
            .bullet, to: source, selection: NSRange(location: 0, length: (source as NSString).length)
        )
        XCTAssertEqual(result.text, "- first\n- done\n")
    }

    func testMixedBulletSelectionDoesNotDoublePrefixExistingItems() {
        let source = "- already\nplain\n"
        let result = MarkdownEditing.apply(
            .bullet, to: source, selection: NSRange(location: 0, length: (source as NSString).length)
        )
        XCTAssertEqual(result.text, "- already\n- plain\n")
    }

    func testTaskCommandCreatesAnEmptyItemInAnEmptyDocument() {
        let result = MarkdownEditing.apply(.task, to: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(result.text, "- [ ] ")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 6))
    }

    func testHeadingCommandReplacesExistingLevelsAndPreservesBlankLines() {
        let source = "# Title\n  \n### Child\nplain\n###\n    code\n"
        let result = MarkdownEditing.apply(
            .heading(2), to: source, selection: NSRange(location: 0, length: (source as NSString).length)
        )
        XCTAssertEqual(result.text, "## Title\n  \n## Child\n## plain\n## \n##     code\n")
    }

    func testQuoteCommandTogglesOffOneLevelIncludingNestedQuotes() {
        let source = "> first\n  > > nested\n"
        let result = MarkdownEditing.apply(
            .quote, to: source, selection: NSRange(location: 0, length: (source as NSString).length)
        )
        XCTAssertEqual(result.text, "first\n  > nested\n")
    }

    func testQuoteCommandAddsOnlyMissingMarkersAndPreservesBlankSeparators() {
        let source = "> existing\nplain\n    code\n  \nlast\n"
        let result = MarkdownEditing.apply(
            .quote, to: source, selection: NSRange(location: 0, length: (source as NSString).length)
        )
        XCTAssertEqual(result.text, "> existing\n> plain\n>     code\n  \n> last\n")
    }

    func testQuoteCommandCreatesAnEmptyBlockQuoteInAnEmptyDocument() {
        let result = MarkdownEditing.apply(.quote, to: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(result.text, "> ")
    }

}
