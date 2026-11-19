import XCTest
@testable import PKSNotes

final class MarkdownPreviewSoftBreakTests: XCTestCase {
    func testSingleNewlineRemainsSoftBreakAndBlankLineStartsNewParagraphForLFAndCRLF() throws {
        let lfSource = "第一行\n第二行\n\n第三段\n第四行"
        let crlfSource = lfSource.replacingOccurrences(of: "\n", with: "\r\n")

        let lf = try XCTUnwrap(MarkdownPreviewParsing.prepare(lfSource, match: nil).first)
        let crlf = try XCTUnwrap(MarkdownPreviewParsing.prepare(crlfSource, match: nil).first)

        XCTAssertEqual(lf.source.markdown, lfSource)
        XCTAssertEqual(crlf.source.markdown, crlfSource)
        XCTAssertEqual(lf.content.renderMarkdown(), lfSource)
        XCTAssertEqual(crlf.content.renderMarkdown(), lf.content.renderMarkdown())

        let html = lf.content.renderHTML()
        XCTAssertTrue(html.contains("<p>第一行\n第二行</p>"))
        XCTAssertTrue(html.contains("<p>第三段\n第四行</p>"))
    }

    func testHardBreaksListsBlockquotesAndFencedCodeKeepTheirMarkdownSemantics() throws {
        let source = [
            "Paragraph first\\",
            "Paragraph second",
            "",
            "- List first",
            "  list continuation\\",
            "  list hard break",
            "",
            "> Quote first",
            "> quote continuation",
            "",
            "```text",
            "code first",
            "code second",
            "```"
        ].joined(separator: "\n")
        let crlfSource = source.replacingOccurrences(of: "\n", with: "\r\n")

        let lf = try XCTUnwrap(MarkdownPreviewParsing.prepare(source, match: nil).first)
        let crlf = try XCTUnwrap(MarkdownPreviewParsing.prepare(crlfSource, match: nil).first)
        let html = lf.content.renderHTML()

        XCTAssertEqual(lf.source.markdown, source)
        XCTAssertEqual(crlf.source.markdown, crlfSource)
        XCTAssertEqual(crlf.content.renderHTML(), html)
        XCTAssertEqual(html.components(separatedBy: "<br />").count - 1, 2)
        XCTAssertTrue(html.contains("List first\nlist continuation<br />\nlist hard break"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("Quote first\nquote continuation"))
        XCTAssertTrue(html.contains("code first\ncode second"))
    }
}
