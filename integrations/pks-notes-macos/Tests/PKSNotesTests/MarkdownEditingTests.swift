import AppKit
import XCTest
@testable import PKSNotes

final class MarkdownEditingTests: XCTestCase {
    func testEmphasisCommandsToggleLiveSelectionAndKeepCombinedStyles() {
        let source = "😀 重要"
        let selection = (source as NSString).range(of: "重要")
        let bold = MarkdownEditing.apply(.bold, to: source, selection: selection)
        let unbold = MarkdownEditing.apply(.bold, to: bold.text, selection: bold.selection)
        XCTAssertEqual(bold.text, "😀 **重要**")
        XCTAssertEqual(unbold.text, source)
        XCTAssertEqual((unbold.text as NSString).substring(with: unbold.selection), "重要")

        let italic = MarkdownEditing.apply(.italic, to: "emphasis", selection: NSRange(location: 0, length: 8))
        let unitalic = MarkdownEditing.apply(.italic, to: italic.text, selection: italic.selection)
        XCTAssertEqual(italic.text, "*emphasis*")
        XCTAssertEqual(unitalic.text, "emphasis")

        let boldText = MarkdownEditing.apply(.bold, to: "text", selection: NSRange(location: 0, length: 4))
        let italicText = MarkdownEditing.apply(.italic, to: boldText.text, selection: boldText.selection)
        let removeItalic = MarkdownEditing.apply(.italic, to: italicText.text, selection: italicText.selection)
        let removeBold = MarkdownEditing.apply(.bold, to: removeItalic.text, selection: removeItalic.selection)
        XCTAssertEqual(italicText.text, "***text***")
        XCTAssertEqual(removeItalic.text, "**text**")
        XCTAssertEqual(removeBold.text, "text")
    }

    func testBoldAndItalicCommandsKeepCaretInsideEmptyMarkers() {
        let bold = MarkdownEditing.apply(.bold, to: "", selection: NSRange(location: 0, length: 0))
        let italic = MarkdownEditing.apply(.italic, to: "", selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(bold.text, "****")
        XCTAssertEqual(bold.selection, NSRange(location: 2, length: 0))
        XCTAssertEqual(italic.text, "**")
        XCTAssertEqual(italic.selection, NSRange(location: 1, length: 0))
    }

    func testEmptyEmphasisCommandsToggleOffAndPreserveCombinedStyles() {
        let prefix = "😀"
        let caret = NSRange(location: (prefix as NSString).length, length: 0)

        let bold = MarkdownEditing.apply(.bold, to: prefix, selection: caret)
        let italicOnBold = MarkdownEditing.apply(.italic, to: bold.text, selection: bold.selection)
        let italicOff = MarkdownEditing.apply(.italic, to: italicOnBold.text, selection: italicOnBold.selection)
        let boldOff = MarkdownEditing.apply(.bold, to: italicOff.text, selection: italicOff.selection)
        XCTAssertEqual([italicOnBold.text, italicOff.text, boldOff.text], [prefix + "******", prefix + "****", prefix])
        XCTAssertEqual(boldOff.selection, caret)

        let italic = MarkdownEditing.apply(.italic, to: prefix, selection: caret)
        let boldOnItalic = MarkdownEditing.apply(.bold, to: italic.text, selection: italic.selection)
        let boldOffItalic = MarkdownEditing.apply(.bold, to: boldOnItalic.text, selection: boldOnItalic.selection)
        let italicOffAfterBold = MarkdownEditing.apply(.italic, to: boldOffItalic.text, selection: boldOffItalic.selection)
        XCTAssertEqual([boldOnItalic.text, boldOffItalic.text, italicOffAfterBold.text], [prefix + "******", prefix + "**", prefix])
        XCTAssertEqual(italicOffAfterBold.selection, caret)
    }

    func testInlineCodeCommandTogglesOffLiveSelectionAndPreservesPadding() {
        let selectedCases = [
            "ordinary",
            "  value  ",
            "   ",
            "\nvalue\n",
            "😀 `single` and ``double``",
            "`literal boundary`"
        ]

        for selected in selectedCases {
            let source = "before\(selected)after"
            let selection = (source as NSString).range(of: selected)
            let wrapped = MarkdownEditing.apply(.inlineCode, to: source, selection: selection)
            let unwrapped = MarkdownEditing.apply(.inlineCode, to: wrapped.text, selection: wrapped.selection)

            XCTAssertEqual(unwrapped.text, source, "Failed to toggle inline code for: \(selected)")
            XCTAssertEqual(
                (unwrapped.text as NSString).substring(with: unwrapped.selection),
                selected
            )
        }
    }

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

    func testInlineCodeUsesDelimiterLongerThanBacktickRunsInUnicodeSelection() throws {
        let selected = "😀 `single` and ``double``"
        let source = "before \(selected) after"
        let selection = (source as NSString).range(of: selected)
        let delimiter = "```"

        let result = MarkdownEditing.apply(.inlineCode, to: source, selection: selection)

        XCTAssertEqual(result.text, "before \(delimiter) \(selected) \(delimiter) after")
        XCTAssertEqual(
            result.selection,
            NSRange(location: selection.location + 4, length: selection.length)
        )
        XCTAssertEqual((result.text as NSString).substring(with: result.selection), selected)
        let rendered = try AttributedString(markdown: result.text)
        XCTAssertEqual(String(rendered.characters), "before \(selected) after")
    }

    func testInlineCodeKeepsCaretInsideEmptyCodeSpan() {
        let result = MarkdownEditing.apply(.inlineCode, to: "", selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(result.text, "``")
        XCTAssertEqual(result.selection, NSRange(location: 1, length: 0))

        let removed = MarkdownEditing.apply(.inlineCode, to: result.text, selection: result.selection)
        XCTAssertEqual(removed.text, "")
        XCTAssertEqual(removed.selection, NSRange(location: 0, length: 0))
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
        XCTAssertEqual(result.text, "## Title\n  \n## Child\n## plain\n## \n    code\n")
    }

    func testHeadingCommandPreservesFencedCodeWhileFormattingSurroundingLines() {
        let source = "Title\n```swift\nlet answer = 42\n```\nSummary"
        let result = MarkdownEditing.apply(
            .heading(2), to: source, selection: NSRange(location: 0, length: (source as NSString).length)
        )

        XCTAssertEqual(result.text, "## Title\n```swift\nlet answer = 42\n```\n## Summary")
    }

    func testBulletCommandPreservesFencedAndIndentedCodeAndCanToggleListOff() {
        let source = "first\n```swift\nprint(1)\n```\n    print(2)\nlast\n"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        XCTAssertEqual(
            MindMapOutline.blockCodeLineFlags(in: source),
            [false, true, true, true, true, false, false]
        )
        let formatted = MarkdownEditing.apply(.bullet, to: source, selection: selection)
        XCTAssertEqual(formatted.text, "- first\n  ```swift\n  print(1)\n  ```\n      print(2)\n- last\n")

        let unformatted = MarkdownEditing.apply(.bullet, to: formatted.text, selection: formatted.selection)
        XCTAssertEqual(unformatted.text, source)
    }

    func testHeadingAndListCommandsPreserveVariableLengthFencedCode() {
        let source = "Title\n````swift\n```\n# still code\n~~~\n````\nSummary\n~~~text\n- still code\n~~~~\nEnd"
        let selection = NSRange(location: 0, length: (source as NSString).length)

        let heading = MarkdownEditing.apply(.heading(2), to: source, selection: selection)
        XCTAssertEqual(
            heading.text,
            "## Title\n````swift\n```\n# still code\n~~~\n````\n## Summary\n~~~text\n- still code\n~~~~\n## End"
        )

        let listed = MarkdownEditing.apply(.bullet, to: source, selection: selection)
        XCTAssertEqual(
            listed.text,
            "- Title\n  ````swift\n  ```\n  # still code\n  ~~~\n  ````\n- Summary\n  ~~~text\n  - still code\n  ~~~~\n- End"
        )
        XCTAssertEqual(
            MarkdownEditing.apply(.bullet, to: listed.text, selection: listed.selection).text,
            source
        )
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

extension MarkdownEditingTests {
    func testOrderedListCommandNumbersSiblingsAndNestedItemsAndTogglesOff() {
        let source = "first\n  nested\nsecond\n"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        let numbered = MarkdownEditing.apply(.ordered, to: source, selection: selection)
        XCTAssertEqual(numbered.text, "1. first\n  1. nested\n2. second\n")
        XCTAssertEqual(
            MarkdownEditing.apply(.ordered, to: numbered.text, selection: numbered.selection).text,
            source
        )
    }

    func testListCommandsPreserveIndentationForUnmarkedNestedLines() {
        let source = "parent\n  child\n"
        let selection = NSRange(location: 0, length: (source as NSString).length)
        XCTAssertEqual(MarkdownEditing.apply(.bullet, to: source, selection: selection).text,
                       "- parent\n  - child\n")
        XCTAssertEqual(MarkdownEditing.apply(.task, to: source, selection: selection).text,
                       "- [ ] parent\n  - [ ] child\n")
    }

    func testOrderedListPreservesFencedCodeAndCreatesAnEmptyItem() {
        let source = "first\n```swift\nprint(1)\n```\nlast\n"
        let numbered = MarkdownEditing.apply(
            .ordered, to: source, selection: NSRange(location: 0, length: (source as NSString).length)
        )
        XCTAssertEqual(numbered.text, "1. first\n  ```swift\n  print(1)\n  ```\n2. last\n")

        let empty = MarkdownEditing.apply(.ordered, to: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(empty.text, "1. ")
        XCTAssertEqual(empty.selection, NSRange(location: 0, length: 3))
    }

    @MainActor
    func testOrderedListNativeCommandUsesOneStepAppKitUndo() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        textView.allowsUndo = true
        window.contentView = textView
        window.makeFirstResponder(textView)
        let source = "first\nsecond"
        textView.string = source
        textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        textView.undoManager?.removeAllActions()

        XCTAssertTrue(MarkdownNativeCommand.perform("ordered", in: textView))
        XCTAssertEqual(textView.string, "1. first\n2. second")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: (textView.string as NSString).length))
        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.string, source)
    }
}


extension MarkdownEditingTests {
    func testCodeBlockInsertsAnEmptyFenceAndLeavesCaretInside() {
        let source = "Heading\n"
        let result = MarkdownEditing.apply(
            .codeBlock, to: source, selection: NSRange(location: (source as NSString).length, length: 0)
        )
        let fence = "```"

        XCTAssertEqual(result.text, "Heading\n\n\(fence)\n\n\(fence)")
        XCTAssertEqual(result.selection, NSRange(location: 13, length: 0))
    }

    func testCodeBlockWrapsUnicodeSelectionAndChoosesFenceLongerThanEmbeddedBackticks() {
        let embeddedFence = "```"
        let selected = "let marker = \"\(embeddedFence)\"\nprint(\"你好 😀\")"
        let source = "Before \(selected) after"
        let range = (source as NSString).range(of: selected)
        let fence = "````"

        let result = MarkdownEditing.apply(.codeBlock, to: source, selection: range)
        let expected = "Before \n\n\(fence)\n\(selected)\n\(fence)\n\n after"
        XCTAssertEqual(result.text, expected)
        XCTAssertEqual(
            (result.text as NSString).substring(with: result.selection),
            selected
        )
        XCTAssertEqual(result.selection.location, range.location + 2 + fence.utf16.count + 1)
        XCTAssertEqual(result.selection.length, (selected as NSString).length)
    }

    @MainActor
    func testCodeBlockNativeCommandUsesOneStepAppKitUndo() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        textView.allowsUndo = true
        window.contentView = textView
        window.makeFirstResponder(textView)
        let source = "let value = 1"
        textView.string = source
        textView.setSelectedRange(NSRange(location: 0, length: (source as NSString).length))
        textView.undoManager?.removeAllActions()
        let fence = "```"

        XCTAssertTrue(MarkdownNativeCommand.perform("codeBlock", in: textView))
        XCTAssertEqual(textView.string, "\(fence)\nlet value = 1\n\(fence)")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: (source as NSString).length))
        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.string, source)
    }
}
