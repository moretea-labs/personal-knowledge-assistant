import CoreGraphics
import XCTest
@testable import PKSNotes

final class MindMapLayoutDensityTests: XCTestCase {
    func testDensityIsAViewPreferenceAndChineseLabelsArePresent() {
        XCTAssertEqual(MindMapLayoutDensity.allCases.map(\.rawValue),
                       ["compact", "standard", "spacious"])
        XCTAssertEqual(MindMapLayoutDensity.defaultsKey, "PKSNotesMindMapDensity")
        XCTAssertEqual(MindMapLayoutDensity(rawValue: "standard"), .standard)
        XCTAssertNil(MindMapLayoutDensity(rawValue: "unsupported"))
        XCTAssertLessThan(MindMapLayoutDensity.compact.scale,
                          MindMapLayoutDensity.standard.scale)
        XCTAssertLessThan(MindMapLayoutDensity.standard.scale,
                          MindMapLayoutDensity.spacious.scale)
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Layout Density"), "布局密度")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Compact"), "紧凑")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Spacious"), "宽松")
    }

    func testSpacingChangesGeometryWithoutOverlappingOrChangingMarkdownNodes() {
        let branches = (0..<12).map { index in
            "- Branch \(index)\n  - Topic \(index)\n    - Detail \(index)\n    - Reference \(index)"
        }
        let markdown = "# Study Map\n" + branches.joined(separator: "\n")
        let nodes = MindMapOutline.nodes(in: markdown)
        let compact = MindMapSpatialLayout.layout(nodes, density: .compact)
        let standard = MindMapSpatialLayout.layout(nodes)
        let spacious = MindMapSpatialLayout.layout(nodes, density: .spacious)

        XCTAssertEqual(MindMapSpatialLayout.layout(nodes, density: .standard), standard)
        XCTAssertLessThan(compact.size.width, standard.size.width)
        XCTAssertLessThan(standard.size.width, spacious.size.width)
        XCTAssertLessThan(compact.size.height, standard.size.height)
        XCTAssertLessThan(standard.size.height, spacious.size.height)

        for layout in [compact, standard, spacious] {
            XCTAssertEqual(layout.placements.map(\.node), nodes)
            let rects = layout.placements.map { placement in
                CGRect(x: placement.center.x - placement.size.width / 2,
                       y: placement.center.y - placement.size.height / 2,
                       width: placement.size.width, height: placement.size.height)
            }
            for i in rects.indices {
                for j in rects.indices where j > i {
                    XCTAssertFalse(rects[i].intersects(rects[j]),
                                   "Density must not overlap node \(i) with \(j)")
                }
            }
        }
        XCTAssertEqual(MindMapOutline.nodes(in: markdown), nodes)
    }
}
