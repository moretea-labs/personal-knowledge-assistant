import SwiftUI
import XCTest
@testable import PKSNotes

final class MindMapFunctionalShortcutsTests: XCTestCase {
    func testNodeStyleShortcutsUseNativeMacKeyBindingsWithoutHijackingTextInput() {
        XCTAssertNil(MindMapKeyboard.command(for: "b", modifiers: .command))
        XCTAssertNil(MindMapKeyboard.command(for: "i", modifiers: .command))
        XCTAssertNil(MindMapKeyboard.command(for: .return, modifiers: .command))
        XCTAssertNil(MindMapKeyboard.command(for: "b", modifiers: [.command, .shift]))
        XCTAssertNil(MindMapKeyboard.command(for: "i", modifiers: [.command, .option]))
        XCTAssertNil(MindMapKeyboard.command(for: "b", modifiers: []))
        XCTAssertEqual(MindMapKeyboard.command(for: .tab, modifiers: []), .addChild)
        XCTAssertEqual(MindMapKeyboard.command(for: .return, modifiers: []), .addSibling)
    }

    func testNodeStyleShortcutsKeepOneCanonicalMarkdownWriter() throws {
        let original = "# Research\n- [Linked](Docs/Readme.md)\n- Important\n"
        let nodes = MindMapOutline.nodes(in: original)
        let id = try XCTUnwrap(nodes.first(where: { $0.title == "Important" })?.id)
        let boldTitle = MindMapTitleEmphasis.toggle("Important", marker: "**")
        let bold = try XCTUnwrap(MindMapOutline.rename(in: original, nodeID: id, to: boldTitle))
        XCTAssertEqual(bold, "# Research\n- [Linked](Docs/Readme.md)\n- **Important**\n")
        let italicTitle = MindMapTitleEmphasis.toggle(boldTitle, marker: "*")
        let combined = try XCTUnwrap(MindMapOutline.rename(in: bold, nodeID: id, to: italicTitle))
        XCTAssertEqual(combined, "# Research\n- [Linked](Docs/Readme.md)\n- ***Important***\n")
        XCTAssertEqual(MindMapOutline.nodes(in: combined).map(\.depth), nodes.map(\.depth))
        XCTAssertEqual(MindMapOutline.links(in: combined).map(\.target), ["Docs/Readme.md"])
    }

    func testNewNodeCancellationRestoresOnlyTheExactOriginalDraft() throws {
        let original = "# Project\n- Existing\n"
        let inserted = try XCTUnwrap(MindMapOutline.addChild(in: original, parentID: 0))
        XCTAssertEqual(inserted, "# Project\n- New idea\n- Existing\n")
        XCTAssertEqual(
            MindMapPendingCreation.rollback(in: inserted, expected: inserted, nodeID: 1),
            original
        )
        XCTAssertNil(MindMapPendingCreation.rollback(
            in: inserted + "- Different\n", expected: inserted, nodeID: 1
        ))
        XCTAssertNil(MindMapPendingCreation.rollback(
            in: original, expected: original, nodeID: 1
        ))
    }

    func testAddingChildrenRefusesToReparentAttachedMarkdown() {
        let protected = "# Topic\nAn explanation that belongs to the original heading.\n- Next\n"
        XCTAssertNil(MindMapOutline.addChild(in: protected, parentID: 0))
        XCTAssertEqual(
            MindMapOutline.addChild(in: "# Topic\n- Existing\n", parentID: 0),
            "# Topic\n- New idea\n- Existing\n"
        )
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.text(
                "Cannot add a node here without changing attached Markdown. Use the editor."
            ),
            "此处存在关联的 Markdown 正文或代码，无法安全新增节点；请在编辑器中调整。"
        )
        XCTAssertEqual(
            AppLanguage.simplifiedChinese.text("Enter a nonempty, single-line node title."),
            "请输入非空的单行节点标题。"
        )
    }

    func testCheckboxTaskTogglesInCanonicalMarkdownWithoutTouchingOtherLines() throws {
        let markdown = """
        # Study
        - [ ] Read [paper](Docs/Research.md)
        - [x] Complete the outline
        - [X] Finished early
        - Regular list item
        """
        let nodes = MindMapOutline.nodes(in: markdown)
        XCTAssertEqual(nodes.map(\.id), [0, 1, 2, 3, 4])
        XCTAssertEqual(MindMapTaskNode.parse(nodes[1].title),
                       .init(title: "Read [paper](Docs/Research.md)", checked: false))
        XCTAssertEqual(MindMapTaskNode.parse(nodes[2].title),
                       .init(title: "Complete the outline", checked: true))
        XCTAssertEqual(MindMapTaskNode.parse(nodes[3].title),
                       .init(title: "Finished early", checked: true))
        XCTAssertNil(MindMapTaskNode.parse(nodes[4].title))

        let checked = try XCTUnwrap(MindMapTaskNode.toggle(in: markdown, nodeID: 1))
        XCTAssertEqual(checked, markdown.replacingOccurrences(
            of: "- [ ] Read [paper](Docs/Research.md)",
            with: "- [x] Read [paper](Docs/Research.md)"
        ))
        XCTAssertEqual(MindMapOutline.links(in: checked).map(\.target),
                       ["Docs/Research.md"])
        let undone = try XCTUnwrap(MindMapTaskNode.toggle(in: checked, nodeID: 1))
        XCTAssertEqual(undone, markdown)
        XCTAssertEqual(
            MindMapTaskNode.toggle(in: markdown, nodeID: 2),
            markdown.replacingOccurrences(
                of: "- [x] Complete the outline",
                with: "- [ ] Complete the outline"
            )
        )
        XCTAssertNil(MindMapTaskNode.toggle(in: markdown, nodeID: 4))
        XCTAssertNil(MindMapTaskNode.toggle(in: markdown, nodeID: 0))
    }

    func testTitleStylingAndCheckboxTogglingRemainComposable() throws {
        let base = "# Tasks\n- [ ] Review [paper](Docs/Research.md)\n"
        let originalID = try XCTUnwrap(MindMapOutline.nodes(in: base).last?.id)
        let title = try XCTUnwrap(MindMapOutline.nodes(in: base).last?.title)
        let emphasized = MindMapTitleEmphasis.toggle(title, marker: "**")
        XCTAssertEqual(emphasized, "[ ] **Review [paper](Docs/Research.md)**")
        let styled = try XCTUnwrap(MindMapOutline.rename(
            in: base, nodeID: originalID, to: emphasized
        ))
        let checked = try XCTUnwrap(MindMapTaskNode.toggle(in: styled, nodeID: originalID))
        XCTAssertEqual(checked, "# Tasks\n- [x] **Review [paper](Docs/Research.md)**\n")
        let italic = MindMapTitleEmphasis.toggle("[x] **Review**", marker: "*")
        XCTAssertEqual(italic, "[x] ***Review***")
        XCTAssertEqual(MindMapTitleEmphasis.toggle(italic, marker: "*"), "[x] **Review**")
        XCTAssertEqual(
            MindMapTitleEmphasis.toggle("[ ]", marker: "**"), "[ ]",
            "A checkbox-only task cannot lose its marker when styling empty text."
        )
        XCTAssertEqual(MindMapOutline.links(in: checked).map(\.target),
                       ["Docs/Research.md"])
        XCTAssertEqual(MindMapTaskNode.toggle(in: checked, nodeID: originalID), styled)
    }

    func testEmptyTaskAndFencedExampleSafety() throws {
        let source = "# Tasks\n- [ ]\n- [x]\n\n~~~markdown\n- [ ] Example only\n~~~\n"
        let nodes = MindMapOutline.nodes(in: source)
        XCTAssertEqual(nodes.map(\.id), [0, 1, 2])
        XCTAssertEqual(MindMapTaskNode.parse(nodes[1].title),
                       .init(title: "", checked: false))
        XCTAssertEqual(MindMapTaskNode.parse(nodes[2].title),
                       .init(title: "", checked: true))
        XCTAssertEqual(
            MindMapTaskNode.toggle(in: source, nodeID: 1),
            source.replacingOccurrences(of: "- [ ]\n", with: "- [x]\n")
        )
        XCTAssertNil(MindMapTaskNode.toggle(in: source, nodeID: 5))
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Mark task complete"),
                       "标记任务完成")
        XCTAssertEqual(AppLanguage.simplifiedChinese.text("Toggle task completion"),
                       "切换任务完成状态")
    }

}
