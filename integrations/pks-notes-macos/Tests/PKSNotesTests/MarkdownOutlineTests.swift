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

    func testHeadingOffsetsUseUTF16ForNativeTextViewSelection() {
        let source = "😀 preface\n# 标题\nBody\n## Next"
        let headings = MarkdownOutline.headings(in: source)
        XCTAssertEqual(headings.count, 2)

        let ns = source as NSString
        XCTAssertTrue(ns.substring(from: headings[0].utf16Offset).hasPrefix("# 标题"))
        XCTAssertTrue(ns.substring(from: headings[1].utf16Offset).hasPrefix("## Next"))
    }
}
