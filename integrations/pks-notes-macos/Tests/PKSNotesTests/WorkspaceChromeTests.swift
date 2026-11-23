import AppKit
import XCTest
@testable import PKSNotes

final class WorkspaceChromeTests: XCTestCase {
    func testCompactFormattingMenuHasLocalizedVisibleActionLabel() {
        XCTAssertEqual(AppLanguage.english.text("Format"), "Format")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Format"), "格式")
    }

    func testPDFPageOnlyFallbackWarningExplainsQuoteIsNotSaved() {
        let warning = "This PDF selection cannot be highlighted precisely. Only a link to its first page will be saved; the selected quote will not be included. Select a smaller passage on one page to enable precise highlighting."
        XCTAssertEqual(AppLanguage.english.text(warning), warning)
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.text(warning),
            "此 PDF 选区无法精确高亮。只会保存指向所选内容起始页的链接，不会包含所选引文。请在单页中选择更短的内容，以启用精确高亮。"
        )
    }

    func testSplitPaneChromeKeepsHeadersCompactAndDistinct() {
        XCTAssertEqual(NotesGeometry.splitPaneHeaderHeight, 32)
    }

    func testCompactWindowKeepsPDFAndNoteWidthInsteadOfForcingInlineInspector() {
        let splitWidth = NotesGeometry.studySplitThreshold(showingMindMap: false)
        XCTAssertEqual(splitWidth, 820)
        XCTAssertFalse(NotesGeometry.fitsInlineAuxiliary(
            availableWidth: 852, minimumMainWidth: splitWidth
        ))
        XCTAssertTrue(NotesGeometry.fitsInlineAuxiliary(
            availableWidth: 1_200, minimumMainWidth: splitWidth
        ))
    }

    func testMindMapStudySplitNeedsMoreWidthBeforeShowingInspectorInline() {
        let splitWidth = NotesGeometry.studySplitThreshold(showingMindMap: true)
        XCTAssertEqual(splitWidth, 940)
        XCTAssertFalse(NotesGeometry.fitsInlineAuxiliary(
            availableWidth: 1_200, minimumMainWidth: splitWidth
        ))
        XCTAssertTrue(NotesGeometry.fitsInlineAuxiliary(
            availableWidth: 1_300, minimumMainWidth: splitWidth
        ))
    }

    func testMarkdownFormattingToolbarUsesTheDocumentTopInset() {
        XCTAssertEqual(NotesGeometry.markdownFormattingToolbarHeight, 32)
        XCTAssertEqual(NotesGeometry.markdownFormattingToolbarTarget, 30)
        XCTAssertEqual(NotesGeometry.markdownFormattingSymbolSize, 16)
        XCTAssertEqual(NotesGeometry.editorContentTopInset(showingFormattingToolbar: false),
                       NotesGeometry.documentInset)
        XCTAssertEqual(
            NotesGeometry.markdownFormattingToolbarHeight
                + NotesGeometry.editorContentTopInset(showingFormattingToolbar: true),
            NotesGeometry.documentInset
        )
        XCTAssertEqual(
            NotesGeometry.editorContentTopInset(showingFormattingToolbar: true),
            0
        )
    }

    @MainActor
    func testMarkdownEditorNativeTextMetricsAlignWithReadModeContentOrigin() {
        let textView = NSTextView()
        let initialLineFragmentPadding = textView.textContainer?.lineFragmentPadding
        XCTAssertEqual(initialLineFragmentPadding, 5)

        NotesGeometry.configureMarkdownEditorTextView(textView)

        let configuredTextContainerInset = textView.textContainerInset
        let configuredLineFragmentPadding = textView.textContainer?.lineFragmentPadding
        XCTAssertEqual(configuredTextContainerInset,
                       NSSize(width: 0, height: NotesGeometry.markdownSectionVerticalInset))
        XCTAssertEqual(configuredLineFragmentPadding,
                       NotesGeometry.markdownLineFragmentPadding)

        let previewContentTop = NotesGeometry.documentInset
            + NotesGeometry.markdownSectionVerticalInset
        XCTAssertEqual(
            NotesGeometry.editorContentTopInset(showingFormattingToolbar: false)
                + textView.textContainerInset.height,
            previewContentTop
        )
        XCTAssertEqual(
            NotesGeometry.markdownFormattingToolbarHeight
                + NotesGeometry.editorContentTopInset(showingFormattingToolbar: true)
                + textView.textContainerInset.height,
            previewContentTop
        )
    }

    func testStudyPaneChromeSurfaceAdaptsToSystemAppearance() throws {
        let color = NotesGeometry.toolbarSurfaceColor
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        var lightColor: NSColor?
        light.performAsCurrentDrawingAppearance {
            lightColor = color.usingColorSpace(.deviceRGB)
        }
        var darkColor: NSColor?
        dark.performAsCurrentDrawingAppearance {
            darkColor = color.usingColorSpace(.deviceRGB)
        }

        XCTAssertFalse(
            try XCTUnwrap(lightColor).isEqual(try XCTUnwrap(darkColor))
        )
    }

    func testDocumentAndActionIconDimensionsShareOneAuthority() {
        XCTAssertEqual(NotesGeometry.documentInset, 32)
        XCTAssertEqual(NotesGeometry.symbolSize, 14)
        XCTAssertEqual(NotesGeometry.railSymbolSize, 16)
        XCTAssertEqual(NotesGeometry.toolbarTarget, 28)
    }
}
