import AppKit
import SwiftUI
import XCTest
@testable import PKSNotes

final class MindMapVisualStyleTests: XCTestCase {
    func testThreeDistinctStylesAndSafeRestoration() {
        XCTAssertEqual(MindMapVisualStyle.allCases.map(\.rawValue),
                       ["classic", "colorful", "minimal"])
        XCTAssertEqual(Set(MindMapVisualStyle.allCases.map(\.symbol)).count, 3)
        XCTAssertEqual(MindMapVisualStyle(rawValue: "classic"), .classic)
        XCTAssertNil(MindMapVisualStyle(rawValue: "invalid"))
        XCTAssertEqual(MindMapVisualStyle.defaultsKey, "PKSNotesMindMapStyle")
        XCTAssertTrue(MindMapVisualStyle.colorful.usesBranchColors)
        XCTAssertTrue(MindMapVisualStyle.minimal.angularConnectors)
        XCTAssertFalse(MindMapVisualStyle.classic.angularConnectors)
        XCTAssertGreaterThan(MindMapVisualStyle.colorful.connectorWidth,
                             MindMapVisualStyle.minimal.connectorWidth)
    }

    func testBranchColorsFollowMarkdownAncestryWithoutExtraStorage() throws {
        let markdown = """
        # Main
        - First
          - First detail
            - Deep detail
        - Second
          - Second detail
        - Third
        """
        let nodes = MindMapOutline.nodes(in: markdown)
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 2, 3, 1, 2, 1])
        let branches = MindMapVisualStyle.branchIndices(nodes)
        XCTAssertEqual(nodes.compactMap { branches[$0.id] }, [0, 1, 1, 1, 2, 2, 3])

        let first = try XCTUnwrap(
            NSColor(MindMapVisualStyle.colorful.branchColor(1)).usingColorSpace(.deviceRGB)
        )
        let second = try XCTUnwrap(
            NSColor(MindMapVisualStyle.colorful.branchColor(2)).usingColorSpace(.deviceRGB)
        )
        XCTAssertNotEqual(first.redComponent, second.redComponent)
        XCTAssertNotEqual(first.greenComponent, second.greenComponent)
    }

    func testStylesRemainVisualOnlyAndLocalizeToChinese() {
        let markdown = "# Topic\n- Branch\n  - Detail\n"
        let before = MindMapOutline.nodes(in: markdown)
        for style in MindMapVisualStyle.allCases {
            XCTAssertFalse(style.label.isEmpty)
            XCTAssertFalse(style.symbol.isEmpty)
            XCTAssertEqual(MindMapOutline.nodes(in: markdown), before)
        }
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Mind Map Style"), "导图样式")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Colorful"), "多彩")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Minimal"), "极简")
    }
}
