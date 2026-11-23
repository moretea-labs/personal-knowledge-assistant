import AppKit
import SwiftUI
import XCTest
@testable import PKSNotes

final class MarkdownPreviewSoftBreakTests: XCTestCase {
    @MainActor
    private func renderedHeight(_ markdown: String) throws -> CGFloat {
        let content = try XCTUnwrap(
            MarkdownPreviewParsing.prepare(markdown, match: nil).first
        ).content
        let hostingView = NSHostingView(
            rootView: MarkdownPreviewContentView(content: content).frame(width: 720)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 1_200)
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.height
    }

    @MainActor
    func testSingleNewlineRendersAsLineBreakAndBlankLineRemainsAParagraph() throws {
        let lfSource = "第一行\n第二行"
        let crlfSource = lfSource.replacingOccurrences(of: "\n", with: "\r\n")

        let lf = try XCTUnwrap(MarkdownPreviewParsing.prepare(lfSource, match: nil).first)
        let crlf = try XCTUnwrap(MarkdownPreviewParsing.prepare(crlfSource, match: nil).first)
        XCTAssertEqual(lf.source.markdown, lfSource)
        XCTAssertEqual(crlf.source.markdown, crlfSource)

        let softBreakHeight = try renderedHeight(lfSource)
        let crlfHeight = try renderedHeight(crlfSource)
        let sameLineHeight = try renderedHeight("第一行 第二行")
        let paragraphHeight = try renderedHeight("第一行\n\n第二行")

        XCTAssertGreaterThan(softBreakHeight, sameLineHeight + 2)
        XCTAssertEqual(crlfHeight, softBreakHeight, accuracy: 1)
        XCTAssertGreaterThan(paragraphHeight, softBreakHeight + 2)
    }

    @MainActor
    func testSoftBreaksInsideListsAndBlockquotesRenderAsLines() throws {
        XCTAssertGreaterThan(
            try renderedHeight("- 列表第一行\n  列表第二行"),
            try renderedHeight("- 列表第一行 列表第二行") + 2
        )
        XCTAssertGreaterThan(
            try renderedHeight("> 引用第一行\n> 引用第二行"),
            try renderedHeight("> 引用第一行 引用第二行") + 2
        )
    }

    @MainActor
    func testHardBreaksAndFencedCodeKeepTheirLineBreaks() throws {
        XCTAssertGreaterThan(
            try renderedHeight("普通第一行  \n普通第二行"),
            try renderedHeight("普通第一行 普通第二行") + 2
        )
        XCTAssertGreaterThan(
            try renderedHeight("```text\ncode first\ncode second\n```"),
            try renderedHeight("```text\ncode first code second\n```") + 2
        )
    }
}
