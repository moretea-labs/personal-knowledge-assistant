import XCTest
@testable import PKSNotes

final class PDFOutlineAccessibilityTests: XCTestCase {
    func testOutlineLabelsAnnounceTitleHierarchyAndDestinationPage() {
        let root = PDFOutlineEntry(id: "outline.0", title: "Introduction", depth: 0, pageIndex: 0)
        XCTAssertEqual(
            PDFOutlineAccessibility.label(for: root, language: .english),
            "Introduction · Level 1 · Page 1"
        )

        let nested = PDFOutlineEntry(id: "outline.0.1.2", title: "研究方法", depth: 2, pageIndex: 9)
        XCTAssertEqual(
            PDFOutlineAccessibility.label(for: nested, language: .simplifiedChinese),
            "研究方法 · 层级 3 · 页码 10"
        )
        XCTAssertEqual(
            PDFOutlineAccessibility.label(for: nested, language: .english),
            "研究方法 · Level 3 · Page 10"
        )
    }
}
