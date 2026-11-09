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

    func testLongChineseAndEnglishTitlesGrowCardHeightWithoutOverlaps() throws {
        let longChinese = String(repeating: "跨文档关联和搜索结果需要保持准确且容易理解", count: 6)
        let longEnglish = String(repeating: "Knowledge graph navigation and research context ", count: 6)
            .trimmingCharacters(in: .whitespaces)
        let markdown = """
        # Research Notes
        - \(longChinese)
          - Related [[Reference|source note]] and **important** background
        - \(longEnglish)
          - Short
        - Third branch
        """
        let nodes = MindMapOutline.nodes(in: markdown)
        XCTAssertEqual(nodes.count, 6)
        let longChineseID = try XCTUnwrap(nodes.first(where: { $0.title == longChinese })?.id)
        let longEnglishID = try XCTUnwrap(nodes.first(where: { $0.title == longEnglish })?.id)
        for style in MindMapVisualStyle.allCases {
            for density in MindMapLayoutDensity.allCases {
                let layout = MindMapSpatialLayout.layout(nodes, density: density, style: style)
                let chinese = try XCTUnwrap(layout.placements.first(where: { $0.id == longChineseID }))
                let english = try XCTUnwrap(layout.placements.first(where: { $0.id == longEnglishID }))
                XCTAssertGreaterThan(chinese.size.height, 50 * density.scale)
                XCTAssertGreaterThan(english.size.height, 50 * density.scale)
                let rects = layout.placements.map {
                    CGRect(x: $0.center.x - $0.size.width / 2,
                           y: $0.center.y - $0.size.height / 2,
                           width: $0.size.width, height: $0.size.height)
                }
                for i in rects.indices {
                    for j in rects.indices where j > i {
                        XCTAssertFalse(
                            rects[i].intersects(rects[j]),
                            "Long titles must not overlap for style \(style.rawValue), density \(density.rawValue)"
                        )
                    }
                }
            }
        }
        XCTAssertEqual(MindMapOutline.nodes(in: markdown), nodes)
    }

    func testPNGExportBudgetCountsPhysicalPixelsAtRendererScale() {
        XCTAssertTrue(MindMapExportBudget.allowsPNG(size: CGSize(width: 2_000, height: 2_500)))
        XCTAssertFalse(MindMapExportBudget.allowsPNG(size: CGSize(width: 2_001, height: 2_500)))
        XCTAssertTrue(MindMapExportBudget.allowsPNG(
            size: CGSize(width: 4_000, height: 5_000), scale: 1
        ))
        XCTAssertFalse(MindMapExportBudget.allowsPNG(
            size: CGSize(width: 4_000, height: 5_000), scale: 2
        ))
        XCTAssertFalse(MindMapExportBudget.allowsPNG(size: .zero))
    }

    func testSpacingChangesGeometryWithoutOverlappingOrChangingMarkdownNodes() {
        let branches = (0..<32).map { index in
            "- Branch \(index) — \(String(repeating: "跨文档关联与研究资料", count: 2))\n  - Topic \(index)\n    - Detail \(index)\n    - Reference \(index)"
        }
        let markdown = "# Study Map\n" + branches.joined(separator: "\n")
        let nodes = MindMapOutline.nodes(in: markdown)
        XCTAssertEqual(nodes.count, 129)

        for style in MindMapVisualStyle.allCases {
            let compact = MindMapSpatialLayout.layout(nodes, density: .compact, style: style)
            let standard = MindMapSpatialLayout.layout(nodes, density: .standard, style: style)
            let spacious = MindMapSpatialLayout.layout(nodes, density: .spacious, style: style)

            XCTAssertEqual(
                MindMapSpatialLayout.layout(nodes, density: .standard, style: style),
                standard
            )
            XCTAssertLessThan(compact.size.width, standard.size.width)
            XCTAssertLessThan(standard.size.width, spacious.size.width)
            XCTAssertLessThan(compact.size.height, standard.size.height)
            XCTAssertLessThan(standard.size.height, spacious.size.height)

            for (density, layout) in [
                (MindMapLayoutDensity.compact, compact),
                (.standard, standard),
                (.spacious, spacious)
            ] {
                XCTAssertEqual(layout.placements.map(\.node), nodes)
                XCTAssertTrue(layout.size.width.isFinite && layout.size.height.isFinite)
                let rects = layout.placements.map { placement in
                    CGRect(
                        x: placement.center.x - placement.size.width / 2,
                        y: placement.center.y - placement.size.height / 2,
                        width: placement.size.width,
                        height: placement.size.height
                    )
                }
                for i in rects.indices {
                    for j in rects.indices where j > i {
                        XCTAssertFalse(
                            rects[i].intersects(rects[j]),
                            "Style \(style.rawValue), density \(density.rawValue) overlaps nodes \(i) and \(j)"
                        )
                    }
                }
            }
        }
        XCTAssertEqual(MindMapOutline.nodes(in: markdown), nodes)
    }
}
