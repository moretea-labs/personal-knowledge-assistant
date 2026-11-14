import XCTest
@testable import PKSNotes

final class WorkspaceChromeTests: XCTestCase {
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

    func testDocumentAndActionIconDimensionsShareOneAuthority() {
        XCTAssertEqual(NotesGeometry.documentInset, 32)
        XCTAssertEqual(NotesGeometry.symbolSize, 14)
        XCTAssertEqual(NotesGeometry.railSymbolSize, 16)
        XCTAssertEqual(NotesGeometry.toolbarTarget, 28)
    }
}
