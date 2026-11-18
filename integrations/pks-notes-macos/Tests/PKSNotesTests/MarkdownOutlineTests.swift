import XCTest
@testable import PKSNotes

final class MarkdownOutlineTests: XCTestCase {
    func testHeadingsShareSectionRecognitionAndIgnoreFencedCode() {
        let source = """
        Intro

        # Overview
        Text

        ~~~markdown
        ## Not a heading
        ~~~

        ## Details
        ### 深入
        """

        let headings = MarkdownOutline.headings(in: source)
        XCTAssertEqual(headings.map(\.title), ["Overview", "Details", "深入"])
        XCTAssertEqual(headings.map(\.level), [1, 2, 3])

        let sections = MarkdownSection.sections(in: source)
        for heading in headings {
            XCTAssertLessThan(heading.sectionID, sections.count)
            XCTAssertEqual(sections[heading.sectionID].heading, heading.title)
        }
    }

    func testVariableLengthFencesAreSharedByOutlinePreviewAndMindMap() {
        let source = "Intro\n````swift\n```\n# Hidden tick heading\n~~~\n````\n# Visible\n~~~text\n## Hidden tilde heading\n~~~~\n## Next"

        XCTAssertEqual(MarkdownOutline.headings(in: source).map(\.title), ["Visible", "Next"])
        XCTAssertEqual(MarkdownSection.sections(in: source).compactMap(\.heading), ["Visible", "Next"])
        XCTAssertEqual(MindMapOutline.nodes(in: source).map(\.title), ["Visible", "Next"])

        let indentedSource = "first\n```\nprint(1)\n```\n    print(2)\nlast"
        XCTAssertEqual(
            MindMapOutline.blockCodeLineFlags(in: indentedSource),
            [false, true, true, true, true, false]
        )
    }

    func testHeadingOffsetsUseUTF16ForNativeTextViewSelection() {
        let source = "😀 preface\n# 标题\nBody\n## Next"
        let headings = MarkdownOutline.headings(in: source)
        XCTAssertEqual(headings.count, 2)

        let ns = source as NSString
        XCTAssertTrue(ns.substring(from: headings[0].utf16Offset).hasPrefix("# 标题"))
        XCTAssertTrue(ns.substring(from: headings[1].utf16Offset).hasPrefix("## Next"))
        XCTAssertEqual(
            MarkdownOutline.lineRange(in: source, lineIndex: 1),
            NSRange(location: ("😀 preface\n" as NSString).length, length: ("# 标题" as NSString).length)
        )
        XCTAssertNil(MarkdownOutline.lineRange(in: source, lineIndex: 99))
    }

    func testCachedHeadingOffsetRebasesAndRejectsStaleOutlineRows() {
        let original = MarkdownOutline.headings(in: "# First\n# Second")
        let second = original[1]
        let edited = "Intro 😀\n# First\nBody\n# Second"
        let current = MarkdownOutline.headings(in: edited)

        XCTAssertEqual(
            MarkdownOutline.currentUTF16Offset(for: second, in: edited),
            current[1].utf16Offset
        )
        XCTAssertNil(
            MarkdownOutline.currentUTF16Offset(for: second, in: "# First\n# Replaced")
        )
        XCTAssertNil(
            MarkdownOutline.currentUTF16Offset(for: second, in: "# Second\n# First")
        )
    }

    func testHeadingFragmentMatchesExactAndSlugWithoutSeeingFencedHeadings() {
        let source = "# Overview\n## Café & 数据\n\n~~~markdown\n## Hidden Heading\n~~~"
        XCTAssertEqual(
            MarkdownOutline.heading(matchingFragment: "Overview", in: source)?.title,
            "Overview"
        )
        XCTAssertEqual(
            MarkdownOutline.heading(matchingFragment: "cafe-数据", in: source)?.title,
            "Café & 数据"
        )
        XCTAssertEqual(
            MarkdownOutline.heading(
                matchingFragment: "Caf%C3%A9%20%26%20%E6%95%B0%E6%8D%AE",
                in: source
            )?.title,
            "Café & 数据"
        )
        XCTAssertNil(MarkdownOutline.heading(matchingFragment: "hidden-heading", in: source))
    }

    func testLinkableHeadingsOmitAmbiguousDuplicateTitles() {
        let source = "# Overview\n## Detail\n## DETAIL\n### Unique"
        XCTAssertEqual(
            MarkdownOutline.linkableHeadings(in: source).map(\.title),
            ["Overview", "Unique"]
        )
    }

    func testDuplicateOutlineHeadingsKeepDistinctSectionTargets() {
        let source = "# Overview\n## Detail\nParagraph\n## Detail\nMore"
        let headings = MarkdownOutline.headings(in: source)
        XCTAssertEqual(headings.map(\.title), ["Overview", "Detail", "Detail"])
        XCTAssertNotEqual(headings[1].sectionID, headings[2].sectionID)
        XCTAssertNotEqual(headings[1].utf16Offset, headings[2].utf16Offset)
    }
}
