import SwiftUI
import XCTest
@testable import PKSNotes

final class MindMapOutlineTests: XCTestCase {
    func testHeadingsAndNestedLists() {
        let nodes = MindMapOutline.nodes(in: "# Root\n- Child\n  - Grandchild\n## Another\n- Next")
        XCTAssertEqual(nodes.map(\.title), ["Root", "Child", "Grandchild", "Another", "Next"])
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 2, 1, 2])
    }

    func testFencedCodeIgnored() {
        let nodes = MindMapOutline.nodes(in: "# Root\n```md\n# Not heading\n- Not node\n```\n- Real")
        XCTAssertEqual(nodes.map(\.title), ["Root", "Real"])
    }
    func testATXHeadingsAcceptTabSeparatorsAndStripOnlyValidClosingHashes() throws {
        let markdown = "#\tRoot\t##\n##\tChild ###\n### Child#\n## Next\n"
        let nodes = MindMapOutline.nodes(in: markdown)

        XCTAssertEqual(nodes.map(\.title), ["Root", "Child", "Child#", "Next"])
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 2, 1])

        let moved = try XCTUnwrap(MindMapOutline.moveNodeToAdjacentSibling(
            in: markdown, nodeID: try XCTUnwrap(nodes.last?.id), direction: .up
        ))
        XCTAssertEqual(
            moved.source,
            "#\tRoot\t##\n## Next\n##\tChild ###\n### Child#\n"
        )
    }


    func testTabIndentedCodeBlocksDoNotCreateNodesOrKnowledgeLinks() {
        let markdown = "# Root\n\t- Fake root node\n\t[Fake root link](/root.pdf)\n- Parent\n\t\t- Fake nested node\n\t\t[Fake nested link](/nested.pdf)\n- Child\n\t[Real child link](/child.pdf)\n- Next\n"
        let nodes = MindMapOutline.nodes(in: markdown)

        XCTAssertEqual(nodes.map(\.title), ["Root", "Parent", "Child", "Next"])
        XCTAssertEqual(MindMapOutline.knowledgeLinks(in: markdown).map(\.target), ["/child.pdf"])
        XCTAssertEqual(MindMapOutline.linkOccurrences(in: markdown).map { $0.link.target }, ["/child.pdf"])
    }

    func testIndentedCodeBlocksDoNotCreateNodesOrKnowledgeLinks() {
        let markdown = """
        # Root
            - Fake root node
            [Fake root link](/root.pdf)
        - Parent
              - Fake nested node
              [Fake nested link](/nested.pdf)
          - Child
            [Real child link](/child.pdf)
        - Next
        """
        let nodes = MindMapOutline.nodes(in: markdown)

        XCTAssertEqual(nodes.map(\.title), ["Root", "Parent", "Child", "Next"])
        XCTAssertEqual(MindMapOutline.knowledgeLinks(in: markdown).map(\.target), ["/child.pdf"])
        XCTAssertEqual(MindMapOutline.linkOccurrences(in: markdown).map { $0.link.target }, ["/child.pdf"])
    }

    func testWorkspaceFileLinksAttachToOnlyTheTargetListNodeAndAreIdempotent() throws {
        let markdown = "# Root\n- Parent\n  - Child\n- Sibling\n"
        let noteLink = "[Study](/Study.md)"
        let pdfLink = "[Reading.pdf](/Reading.pdf)"
        let withNote = try XCTUnwrap(
            MindMapOutline.appendMarkdownLinkToNodeBody(noteLink, in: markdown, nodeID: 1)
        )
        let withPDF = try XCTUnwrap(
            MindMapOutline.appendMarkdownLinkToNodeBody(pdfLink, in: withNote, nodeID: 1)
        )
        let nodes = MindMapOutline.nodes(in: withPDF)
        let parent = try XCTUnwrap(nodes.first(where: { $0.title == "Parent" }))
        let child = try XCTUnwrap(nodes.first(where: { $0.title == "Child" }))
        let sibling = try XCTUnwrap(nodes.first(where: { $0.title == "Sibling" }))
        let links = MindMapOutline.presentations(in: withPDF, nodes: nodes)

        XCTAssertEqual(
            Set(links[parent.id]?.links.map(\.target) ?? []),
            Set(["/Study.md", "/Reading.pdf"])
        )
        XCTAssertTrue(links[child.id]?.links.isEmpty ?? true)
        XCTAssertTrue(links[sibling.id]?.links.isEmpty ?? true)
        XCTAssertEqual(
            MindMapOutline.appendMarkdownLinkToNodeBody(pdfLink, in: withPDF, nodeID: parent.id),
            withPDF
        )
    }

    func testPDFCitationLinkStaysWithNodeWhenSubtreeReparented() throws {
        let link = "/Reading.pdf#page=2&rects=0.1,0.2,0.3,0.04&fp=1234567890abcdef"
        let markdown = """
        # Plan
        - Source
          - Evidence
            [Reading.pdf · p. 2](\(link))
            > Selected fact
        - Destination
        """
        let nodes = MindMapOutline.nodes(in: markdown)
        let evidence = try XCTUnwrap(nodes.first { $0.title == "Evidence" })
        let destination = try XCTUnwrap(nodes.first { $0.title == "Destination" })

        let moved = try XCTUnwrap(MindMapOutline.moveNodeSubtreeWithOutcome(
            in: markdown,
            nodeID: evidence.id,
            relativeTo: destination.id,
            placement: .child
        ))
        XCTAssertEqual(
            moved.source,
            "# Plan\n- Source\n- Destination\n  - Evidence\n    [Reading.pdf · p. 2](\(link))\n    > Selected fact"
        )

        let movedNodes = MindMapOutline.nodes(in: moved.source)
        let movedEvidence = try XCTUnwrap(movedNodes.first { $0.title == "Evidence" })
        let movedDestination = try XCTUnwrap(movedNodes.first { $0.title == "Destination" })
        let links = MindMapOutline.presentations(in: moved.source, nodes: movedNodes)
        XCTAssertEqual(links[movedEvidence.id]?.links.map(\.target), [link])
        XCTAssertTrue(links[movedDestination.id]?.links.isEmpty ?? true)
    }

    func testWorkspaceFileLinksCanAttachToHeadingNodes() throws {
        let markdown = "# Root\n## Child\n"
        let updated = try XCTUnwrap(
            MindMapOutline.appendMarkdownLinkToNodeBody("[Guide](/Guide.md)", in: markdown, nodeID: 0)
        )
        let nodes = MindMapOutline.nodes(in: updated)
        let root = try XCTUnwrap(nodes.first(where: { $0.title == "Root" }))
        let child = try XCTUnwrap(nodes.first(where: { $0.title == "Child" }))
        let links = MindMapOutline.presentations(in: updated, nodes: nodes)

        XCTAssertEqual(links[root.id]?.links.map(\.target), ["/Guide.md"])
        XCTAssertTrue(links[child.id]?.links.isEmpty ?? true)
    }

    func testWorkspaceFileDropLinkResolvesToTheOriginalPDF() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-MindMap-File-Drop-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let activeNote = root.appendingPathComponent("Active.md")
        let pdf = root.appendingPathComponent("Reading (v2).pdf")
        try "# Active".write(to: activeNote, atomically: true, encoding: .utf8)
        try Data().write(to: pdf)

        let link = try XCTUnwrap(WorkspaceFiles.markdownLinkForDrop(for: pdf, in: root))
        let markdown = "# Root\n- Reading\n"
        let updated = try XCTUnwrap(
            MindMapOutline.appendMarkdownLinkToNodeBody(link, in: markdown, nodeID: 1)
        )
        let nodes = MindMapOutline.nodes(in: updated)
        let reading = try XCTUnwrap(nodes.first(where: { $0.title == "Reading" }))
        let target = try XCTUnwrap(
            MindMapOutline.presentations(in: updated, nodes: nodes)[reading.id]?.links.first?.target
        )
        let resolved = WorkspaceFiles.resolveLinkedTarget(target, from: activeNote, in: root)

        XCTAssertEqual(resolved?.standardizedFileURL, pdf.standardizedFileURL)
    }

    func testCollapsedNodeLineIndexMapTracksInsertedAndDeletedMarkdownLines() {
        let original = MindMapOutline.nodes(in: "# Root\n- A\n  - A1\n- B\n- C")
        let inserted = MindMapOutline.nodes(in: "# Root\n- A\n  - New\n  - A1\n- B\n- C")
        let insertionMap = MindMapOutline.lineIndexMap(from: original, to: inserted)

        XCTAssertEqual(insertionMap[2], 3)
        XCTAssertEqual(insertionMap[3], 4)
        XCTAssertEqual(insertionMap[4], 5)

        let deleted = MindMapOutline.nodes(in: "# Root\n- A\n- C")
        let deletionMap = MindMapOutline.lineIndexMap(from: original, to: deleted)

        XCTAssertNil(deletionMap[2])
        XCTAssertNil(deletionMap[3])
        XCTAssertEqual(deletionMap[4], 2)
    }

    func testCollapsedNodeLineIndexMapFollowsReparentedSubtreesAndPreservesRename() {
        let original = MindMapOutline.nodes(in: "# Root\n- A\n  - A1\n- B\n- C")
        let moved = MindMapOutline.nodes(in: "# Root\n- B\n- A\n  - A1\n- C")
        let moveMap = MindMapOutline.lineIndexMap(from: original, to: moved)

        XCTAssertEqual(moveMap[1], 2)
        XCTAssertEqual(moveMap[2], 3)
        XCTAssertEqual(moveMap[3], 1)
        XCTAssertEqual(moveMap[4], 4)

        let renamed = MindMapOutline.nodes(in: "# Root\n- A renamed\n- B")
        let renameMap = MindMapOutline.lineIndexMap(
            from: MindMapOutline.nodes(in: "# Root\n- A\n- B"),
            to: renamed
        )
        XCTAssertEqual(renameMap[1], 1)
        XCTAssertEqual(renameMap[2], 2)
    }

    func testLargeOutlineReorderKeepsEveryNodeMapped() {
        let originalTitles = Array(0..<1_000)
        let reorderedTitles = Array(originalTitles.dropFirst(500)) + Array(originalTitles.prefix(500))
        let original = "# Root\n" + originalTitles.map { "- Node \($0)" }.joined(separator: "\n")
        let reordered = "# Root\n" + reorderedTitles.map { "- Node \($0)" }.joined(separator: "\n")

        let oldNodes = MindMapOutline.nodes(in: original)
        let newNodes = MindMapOutline.nodes(in: reordered)
        let mapping = MindMapOutline.lineIndexMap(from: oldNodes, to: newNodes)
        let newIDsByTitle = Dictionary(uniqueKeysWithValues: newNodes.map { ($0.title, $0.id) })

        XCTAssertEqual(mapping.count, oldNodes.count)
        for node in oldNodes {
            XCTAssertEqual(mapping[node.id], newIDsByTitle[node.title], node.title)
        }
    }

    func testCreatedNodeSnapshotMapSurvivesAnOldLineIndexCollision() throws {
        let original = MindMapOutline.nodes(in: "# Plan\n- A\n  - A1\n- B")
        XCTAssertEqual(try XCTUnwrap(original.first(where: { $0.title == "A1" })).id, 2)

        let creationSnapshot = MindMapOutline.nodes(
            in: "# Plan\n- A\n  - New idea\n  - A1\n- B"
        )
        let createdID = try XCTUnwrap(
            creationSnapshot.first(where: { $0.title == "New idea" })
        ).id
        XCTAssertEqual(createdID, 2)

        let latest = MindMapOutline.nodes(
            in: "# Plan\n- A\n  - Extra\n  - New idea\n  - A1\n- B"
        )
        let creationMap = MindMapOutline.lineIndexMap(from: creationSnapshot, to: latest)

        XCTAssertEqual(creationMap[createdID], 3)
        XCTAssertEqual(try XCTUnwrap(latest.first(where: { $0.title == "New idea" })).id, 3)
    }

    func testIndentedCodeLinksStayInertAcrossPresentationPreviewAndRetargeting() {
        let source = """
        # Root
            [[/root-code.pdf]]
        - Parent
              [[/nested-code.pdf]]
          - Child
            [[/child.pdf]]
        """
        let nodes = MindMapOutline.nodes(in: source)
        let presentations = MindMapOutline.presentations(in: source, nodes: nodes)

        XCTAssertEqual(nodes.map(\.title), ["Root", "Parent", "Child"])
        XCTAssertEqual(presentations[0]?.links, [])
        XCTAssertEqual(presentations[2]?.links, [])
        XCTAssertEqual(
            presentations[4]?.links,
            [.init(label: "/child.pdf", target: "/child.pdf")]
        )
        XCTAssertNil(MindMapOutline.retargetLinks(
            in: source, from: "/root-code.pdf", to: "/new-root.pdf"
        ))
        XCTAssertNil(MindMapOutline.retargetLinks(
            in: source, from: "/nested-code.pdf", to: "/new-nested.pdf"
        ))

        let preview = """
        # Root
            [[/root-code.pdf]]
        - Parent
              [[/nested-code.pdf]]
          - Child
            [/child.pdf](/child.pdf)
        """
        XCTAssertEqual(MindMapOutline.previewMarkdown(in: source), preview)

        let retargeted = """
        # Root
            [[/root-code.pdf]]
        - Parent
              [[/nested-code.pdf]]
          - Child
            [[/new-child.pdf|/child.pdf]]
        """
        XCTAssertEqual(
            MindMapOutline.retargetLinks(in: source, from: "/child.pdf", to: "/new-child.pdf"),
            retargeted
        )
    }

    func testFourColumnIndentedCodeDoesNotConsumeFollowingMarkdownBlocks() {
        for fenceLine in ["    ```", "\t```"] {
            let markdown = "# Root\n\(fenceLine)\n- Real\n  [Real link](/real.pdf)\n```\n- Next\n```"
            let nodes = MindMapOutline.nodes(in: markdown)

            XCTAssertEqual(nodes.map(\.title), ["Root", "Real"], fenceLine)
            let flags = MindMapOutline.blockCodeLineFlags(in: markdown)
            XCTAssertFalse(flags[2], fenceLine)
            let realOffset = (markdown as NSString).range(of: "- Real").location
            XCTAssertFalse(MindMapOutline.isInsideCode(in: markdown, at: realOffset), fenceLine)
            XCTAssertEqual(MindMapOutline.linkOccurrences(in: markdown).map { $0.link.target }, ["/real.pdf"], fenceLine)
        }
    }

    func testFencedCodeUsesNestedListContentIndent() {
        let markdown = """
        # Root
        - Parent
          - Child
            ```swift
            - Fake nested node
            [Fake nested link](/fake.pdf)
            ```
          - Real sibling
            [Real sibling link](/real.pdf)
        - End
        """
        let nodes = MindMapOutline.nodes(in: markdown)

        XCTAssertEqual(nodes.map(\.title), ["Root", "Parent", "Child", "Real sibling", "End"])
        let flags = MindMapOutline.blockCodeLineFlags(in: markdown)
        XCTAssertTrue(flags[4])
        XCTAssertFalse(flags[7])
        let fakeOffset = (markdown as NSString).range(of: "- Fake nested node").location
        XCTAssertTrue(MindMapOutline.isInsideCode(in: markdown, at: fakeOffset))
        XCTAssertEqual(MindMapOutline.linkOccurrences(in: markdown).map { $0.link.target }, ["/real.pdf"])
        let realLinkOffset = (markdown as NSString).range(of: "Real sibling link").location
        XCTAssertFalse(MindMapOutline.isInsideCode(in: markdown, at: realLinkOffset))
    }

    func testLongerFenceDoesNotCloseOnShorterEmbeddedFence() {
        let markdown = """
        # Root
        - Parent
          ````swift
          ```
          - Fake nested node
          [Fake nested link](/nested.pdf)
          ````
        - Real
        """
        let nodes = MindMapOutline.nodes(in: markdown)

        XCTAssertEqual(nodes.map(\.title), ["Root", "Parent", "Real"])
        XCTAssertEqual(MindMapOutline.knowledgeLinks(in: markdown), [])
        XCTAssertEqual(MindMapOutline.linkOccurrences(in: markdown), [])
        XCTAssertTrue(MindMapOutline.isInsideCode(
            in: markdown, at: (markdown as NSString).range(of: "Fake nested link").location
        ))
    }
}

extension MindMapOutlineTests {
    func testRenamePreservesMarkdownSyntax() {
        XCTAssertEqual(MindMapOutline.rename(in: "# Root\n  - Child", nodeID: 1, to: "Updated"), "# Root\n  - Updated")
        XCTAssertEqual(MindMapOutline.rename(in: "# Root", nodeID: 0, to: "Changed"), "# Changed")
        XCTAssertNil(MindMapOutline.rename(in: "# Root", nodeID: 0, to: ""))
    }

    func testAddSiblingOnHeadingCreatesSameLevelAfterItsWholeSection() throws {
        let source = """
        # Root
        Root introduction.
        ## A
        A introduction.
        ### A1
        A1 body.
        - A1 claim
        ## B
        B body.
        """
        let nodes = MindMapOutline.nodes(in: source)
        let a = try XCTUnwrap(nodes.first { $0.title == "A" })
        let outcome = try XCTUnwrap(
            MindMapOutline.addSiblingWithOutcome(in: source, nodeID: a.id)
        )
        XCTAssertEqual(outcome.source, """
        # Root
        Root introduction.
        ## A
        A introduction.
        ### A1
        A1 body.
        - A1 claim
        ## New idea
        ## B
        B body.
        """)
        let inserted = try XCTUnwrap(
            MindMapOutline.nodes(in: outcome.source).first { $0.id == outcome.nodeID }
        )
        XCTAssertEqual(inserted.title, "New idea")
        XCTAssertEqual(inserted.depth, a.depth)
    }

    func testAddSiblingOnListRemainsAtTheSameIndentAfterItsSubtree() throws {
        let source = "# Root\n- A\n  - A1\n- B\n"
        let nodes = MindMapOutline.nodes(in: source)
        let a = try XCTUnwrap(nodes.first { $0.title == "A" })
        let outcome = try XCTUnwrap(
            MindMapOutline.addSiblingWithOutcome(in: source, nodeID: a.id)
        )
        XCTAssertEqual(outcome.source, "# Root\n- A\n  - A1\n- New idea\n- B\n")
    }

    func testAddingChildPreservesHierarchy() {
        XCTAssertEqual(MindMapOutline.addChild(in: "# Root\n- Existing", parentID: 0), "# Root\n- New idea\n- Existing")
        XCTAssertEqual(MindMapOutline.addChild(in: "# Root\n- Existing", parentID: 1), "# Root\n- Existing\n  - New idea")
    }
}

extension MindMapOutlineTests {
    func testDeleteHeadingSubtreeRemovesItsCompleteSectionAndPreservesSiblingContent() throws {
        let citation = "[Textbook · p. 4](/Books/Study.pdf#page=4&rects=0.1,0.2,0.3,0.04&fp=0123456789abcdef)"
        let source = """
        # Plan
        Introduction remains.
        ## Reading
        Reading notes.
        \(citation)
        ### Detail
        Detail notes.
        - Claim
        ## Target
        Target notes.
        """
        let nodes = MindMapOutline.nodes(in: source)
        let reading = try XCTUnwrap(nodes.first { $0.title == "Reading" })
        let updated = try XCTUnwrap(
            MindMapOutline.deleteNodeSubtree(in: source, nodeID: reading.id)
        )
        XCTAssertEqual(updated, """
        # Plan
        Introduction remains.
        ## Target
        Target notes.
        """)
    }

    func testDeleteHeadingSubtreePreservesOneRemainingRootAndRejectsDeletingOnlyMap() throws {
        let multipleRoots = """
        # First
        First section.
        # Second
        Second section.
        """
        let first = try XCTUnwrap(MindMapOutline.nodes(in: multipleRoots).first)
        XCTAssertEqual(
            MindMapOutline.deleteNodeSubtree(in: multipleRoots, nodeID: first.id),
            "# Second\nSecond section."
        )

        for source in [
            "# Root\nRoot notes.\n",
            "# Root\n## Child\nChild notes.\n"
        ] {
            let root = try XCTUnwrap(MindMapOutline.nodes(in: source).first)
            XCTAssertNil(MindMapOutline.deleteNodeSubtree(in: source, nodeID: root.id))
        }

        let emptyLeaf = "# Root\n## Empty\n"
        let leaf = try XCTUnwrap(MindMapOutline.nodes(in: emptyLeaf).last)
        XCTAssertNil(MindMapOutline.deleteNodeSubtree(in: emptyLeaf, nodeID: leaf.id))
        XCTAssertNotNil(MindMapOutline.deleteLeaf(in: emptyLeaf, nodeID: leaf.id))
    }

    func testDeleteNodeSubtreeKeepsUnrelatedHeadingsAndSiblings() {
        XCTAssertEqual(MindMapOutline.deleteNodeSubtree(
            in: "# Root\n- Parent\n  - Child A\n    - Grandchild\n  - Child B\n- Another",
            nodeID: 1
        ), "# Root\n- Another")
        XCTAssertEqual(MindMapOutline.deleteNodeSubtree(
            in: "# Root\n- Parent\n  - Child\n", nodeID: 1
        ), "# Root\n")
        XCTAssertEqual(MindMapOutline.deleteNodeSubtree(
            in: "# Root\n- Parent\n  - Child\n- Another", nodeID: 2
        ), "# Root\n- Parent\n- Another")
        XCTAssertNil(MindMapOutline.deleteNodeSubtree(
            in: "# Root\n- Child", nodeID: 0
        ))
    }

    func testDeleteNodeSubtreeRejectsNonListContentInsideBranch() {
        for source in [
            "# Root\n- Parent\n  - Child\n  Attached notes\n- Next",
            "# Root\n- Parent\n  ~~~swift\n  print(1)\n  ~~~\n  - Child\n- Next",
            "# Root\n- Parent\n  - Child\n  ![photo](photo.png)\n- Next",
            "# Root\n- Parent\n  - Child\n  - \n- Next"
        ] {
            XCTAssertNil(MindMapOutline.deleteNodeSubtree(in: source, nodeID: 1), source)
        }
    }

    func testDeleteLeafRejectsProseAndCodeThatBelongToTheItem() {
        for source in [
            "# Root\n- A\n  Explanation belongs to A\n- B",
            "# Root\n- A\n\n    A second paragraph\n- B",
            "# Root\n- A\n  ```swift\n  print(1)\n  ```\n- B",
            "# Root\n- A\n  ![Image](attachments/a.png)\n- B"
        ] {
            XCTAssertNil(MindMapOutline.deleteLeaf(in: source, nodeID: 1), source)
        }
        XCTAssertEqual(
            MindMapOutline.deleteLeaf(in: "# Root\n- A\n\n- B", nodeID: 1),
            "# Root\n\n- B"
        )
    }

    func testAddChildPreservesAttachedMarkdownAndRejectsAmbiguousListBoundaries() {
        let heading = "# Root\nThis is a paragraph.\n- Existing"
        XCTAssertEqual(
            MindMapOutline.addChild(in: heading, parentID: 0),
            "# Root\nThis is a paragraph.\n- New idea\n- Existing"
        )

        let list = "# Root\n- A\n  Attached paragraph\n- B"
        XCTAssertEqual(
            MindMapOutline.addChild(in: list, parentID: 1),
            "# Root\n- A\n  Attached paragraph\n  - New idea\n- B"
        )

        let unsafe = "# Root\n- A\nOutside paragraph\n- B"
        XCTAssertNil(MindMapOutline.addChild(in: unsafe, parentID: 1))
        XCTAssertEqual(
            MindMapOutline.addChild(in: "# Root\n\n- A", parentID: 0),
            "# Root\n\n- New idea\n- A"
        )
    }

    func testLeafDeletionDoesNotDiscardDescendantsOrHeadings() {
        XCTAssertEqual(MindMapOutline.deleteLeaf(in: "# Root\n- A\n- B", nodeID: 1), "# Root\n- B")
        XCTAssertNil(MindMapOutline.deleteLeaf(in: "# Root\n- Parent\n  - Child", nodeID: 1))
        XCTAssertNil(MindMapOutline.deleteLeaf(in: "# Root\n- Child", nodeID: 0))
    }
}


extension MindMapOutlineTests {
    func testWikiAndMarkdownLinksRemainCanonical() {
        let source = "# Project\n- [[Notes/Design|Design notes]]\n- [Spec](../spec.md)"
        let nodes = MindMapOutline.nodes(in: source)
        XCTAssertEqual(MindMapOutline.links(in: nodes[1].title), [.init(label: "Design notes", target: "Notes/Design")])
        XCTAssertEqual(MindMapOutline.links(in: nodes[2].title), [.init(label: "Spec", target: "../spec.md")])
        XCTAssertEqual(MindMapOutline.rename(in: source, nodeID: 1, to: "[[Notes/Architecture]]"), "# Project\n- [[Notes/Architecture]]\n- [Spec](../spec.md)")
    }

    func testRetargetLinksPreservesLabelsImagesAndFencedExamples() {
        let source = """
        # Root
        🌿 [Old path](/Notes/Old) and [[/Notes/Old|Reading]] ![Cover](/Notes/Old)
        ~~~markdown
        [Example](/Notes/Old)
        ~~~
        Unrelated /Notes/Old
        """
        let expected = """
        # Root
        🌿 [Old path](/Notes/New) and [[/Notes/New|Reading]] ![Cover](/Notes/Old)
        ~~~markdown
        [Example](/Notes/Old)
        ~~~
        Unrelated /Notes/Old
        """
        XCTAssertEqual(MindMapOutline.retargetLinks(
            in: source, from: "/Notes/Old", to: "/Notes/New"
        ), expected)
        XCTAssertNil(MindMapOutline.retargetLinks(
            in: source, from: "/Notes/Missing", to: "/Notes/New"
        ))
        XCTAssertEqual(
            MindMapOutline.retargetLinks(
                in: "See [[Old]]", from: "Old", to: "/Archive/New"
            ),
            "See [[/Archive/New|Old]]"
        )
        XCTAssertEqual(
            MindMapOutline.retargetLinks(
                in: "![[cover.png]]", from: "cover.png", to: "/assets/cover.png",
                includeImages: true
            ),
            "![[/assets/cover.png]]"
        )
    }

    func testRetargetLinksCanOptImagesIntoPathRepairWithoutChangingKnowledgeLinks() {
        let source = "![Cover](assets/old.png) and ![[assets/old.png|Preview]] and [Reference](assets/old.png)"
        let expected = "![Cover](/assets/new.png) and ![[/assets/new.png|Preview]] and [Reference](/assets/new.png)"

        XCTAssertEqual(
            MindMapOutline.retargetLinks(
                in: source,
                from: "assets/old.png",
                to: "/assets/new.png",
                includeImages: true
            ),
            expected
        )
        XCTAssertEqual(
            MindMapOutline.linkOccurrences(in: source).map(\.link.target),
            ["assets/old.png"]
        )
        XCTAssertEqual(
            MindMapOutline.linkOccurrences(in: source, includeImages: true).map(\.link.target),
            ["assets/old.png", "assets/old.png", "assets/old.png"]
        )
    }

    func testPreviewWikiLinksIgnoreCodeAndKeepMarkdownSource() {
        let source = "# Guide\nSee [[/Notes/A.md|A]] and [[/Notes/B.md]].\n`[[Code.md]]`\n~~~md\n[[Fenced.md]]\n~~~"
        let rendered = "# Guide\nSee [A](/Notes/A.md) and [/Notes/B.md](/Notes/B.md).\n`[[Code.md]]`\n~~~md\n[[Fenced.md]]\n~~~"
        XCTAssertEqual(MindMapOutline.previewMarkdown(in: source), rendered)
        XCTAssertEqual(MindMapOutline.linkOccurrences(in: source).map(\.link.target),
                       ["/Notes/A.md", "/Notes/B.md"])
    }

    func testPreviewWikiLinksPreserveEscapedLiteralsAndEncodeCommonPathCharacters() {
        let source = #"See \[[Literal.md]] and [[/Notes/My File (draft).md|Draft v2]]."#
        let rendered = #"See \[[Literal.md]] and [Draft v2](/Notes/My%20File%20%28draft%29.md)."#
        XCTAssertEqual(MindMapOutline.previewMarkdown(in: source), rendered)
        XCTAssertEqual(MindMapOutline.linkOccurrences(in: source).map(\.link.target),
                       ["/Notes/My File (draft).md"])
    }

    func testMarkdownImagesDoNotBecomeKnowledgeLinks() {
        let line = "![Cover](assets/cover.png) and [Reference](/Refs.md)"
        XCTAssertEqual(MindMapOutline.links(in: line),
                       [.init(label: "Reference", target: "/Refs.md")])
        XCTAssertEqual(
            MindMapOutline.linkOccurrences(in: line, includeImages: true).map(\.link.target),
            ["assets/cover.png", "/Refs.md"]
        )
        XCTAssertEqual(MindMapOutline.linkOccurrences(in: line).map(\.link.target),
                       ["/Refs.md"])
        XCTAssertEqual(MindMapOutline.presentation(for: line).title,
                       "![Cover](assets/cover.png) and Reference")
    }

    func testNodePresentationUsesHumanLabelsAndKeepsEveryLinkInSourceOrder() {
        let raw = "Compare [Spec](../spec.md) with [[Notes/Design|Design notes]] and [[Roadmap]]"
        let presentation = MindMapOutline.presentation(for: raw)

        XCTAssertEqual(presentation.title, "Compare Spec with Design notes and Roadmap")
        XCTAssertEqual(
            presentation.links,
            [
                .init(label: "Spec", target: "../spec.md"),
                .init(label: "Design notes", target: "Notes/Design"),
                .init(label: "Roadmap", target: "Roadmap")
            ]
        )
        XCTAssertEqual(
            raw,
            "Compare [Spec](../spec.md) with [[Notes/Design|Design notes]] and [[Roadmap]]",
            "Presentation must never mutate the canonical Markdown title."
        )
    }

    func testAppendWikiLinkWritesOnlyCanonicalNodeLineAndIsIdempotent() {
        let source = "# Root\n- Topic\n  - Child"
        let linked = MindMapOutline.appendWikiLink(
            in: source,
            nodeID: 1,
            target: "/References/Design%20Spec",
            label: "Design Spec"
        )

        XCTAssertEqual(
            linked,
            "# Root\n- Topic [[/References/Design%20Spec|Design Spec]]\n  - Child"
        )
        XCTAssertEqual(
            MindMapOutline.appendWikiLink(
                in: linked!,
                nodeID: 1,
                target: "/References/Design%20Spec",
                label: "Design Spec"
            ),
            linked,
            "Connecting the same target twice must not duplicate the link."
        )
    }
}


extension MindMapOutlineTests {
    func testShiftListSubtreeChangesHierarchyWithoutLosingChildren() {
        let source = "# Root\n- A\n- B\n  - B1\n- C"
        let deeper = MindMapOutline.shiftNodeSubtree(in: source, nodeID: 2, deeper: true)
        XCTAssertEqual(deeper, "# Root\n- A\n  - B\n    - B1\n- C")
        XCTAssertEqual(
            MindMapOutline.shiftNodeSubtree(in: deeper!, nodeID: 2, deeper: false),
            source
        )
    }

    func testShiftListSubtreeRejectsUnsafeOrImpossibleChanges() {
        XCTAssertNil(MindMapOutline.shiftNodeSubtree(in: "# Root\n- First", nodeID: 1, deeper: true))
        XCTAssertNil(MindMapOutline.shiftNodeSubtree(in: "# Root\n- Parent\nparagraph\n- Next", nodeID: 1, deeper: true))
        XCTAssertNil(MindMapOutline.shiftNodeSubtree(in: "# Root\n- Root item", nodeID: 1, deeper: false))
    }

    func testHeadingPromoteAndDemotePreserveNestedSectionsAndPDFEvidence() throws {
        let citation = "/Books/Study.pdf#page=5&rects=0.2,0.3,0.4,0.05&fp=abcdef0123456789"
        let source = """
        # Root
        ## Parent
        ### First
        ### Move
        [Textbook · p. 5](\(citation))
        > Selected passage
        #### Detail
        ##### Deep
        ### Next
        ## Other
        """
        let nodes = MindMapOutline.nodes(in: source)
        let moved = try XCTUnwrap(nodes.first { $0.title == "Move" })
        let availability = MindMapOutline.actionAvailability(in: source, nodeID: moved.id)
        XCTAssertTrue(availability.canPromote)
        XCTAssertTrue(availability.canDemote)

        let demoted = try XCTUnwrap(
            MindMapOutline.shiftNodeSubtree(in: source, nodeID: moved.id, deeper: true)
        )
        XCTAssertEqual(demoted, """
        # Root
        ## Parent
        ### First
        #### Move
        [Textbook · p. 5](\(citation))
        > Selected passage
        ##### Detail
        ###### Deep
        ### Next
        ## Other
        """)
        let demotedNodes = MindMapOutline.nodes(in: demoted)
        let demotedMove = try XCTUnwrap(demotedNodes.first { $0.title == "Move" })
        XCTAssertEqual(
            MindMapOutline.presentations(in: demoted, nodes: demotedNodes)[demotedMove.id]?.links.map(\.target),
            [citation]
        )

        let promoted = try XCTUnwrap(
            MindMapOutline.shiftNodeSubtree(in: demoted, nodeID: moved.id, deeper: false)
        )
        XCTAssertEqual(promoted, source)
    }

    func testHeadingPromoteDemoteRespectMarkdownLevelBounds() throws {
        let root = "# Root\n"
        XCTAssertFalse(MindMapOutline.actionAvailability(in: root, nodeID: 0).canPromote)

        let deep = "# Root\n###### Last\n###### Next\n"
        let nodes = MindMapOutline.nodes(in: deep)
        let next = try XCTUnwrap(nodes.first { $0.title == "Next" })
        let availability = MindMapOutline.actionAvailability(in: deep, nodeID: next.id)
        XCTAssertTrue(availability.canPromote)
        XCTAssertFalse(availability.canDemote)
        XCTAssertNil(MindMapOutline.shiftNodeSubtree(in: deep, nodeID: next.id, deeper: true))
    }

    func testDeleteLeafSupportsEmptyHeadingLeavesButRetainsTheOnlyRoot() throws {
        let source = "# Root\n## Empty\n## Keep\n"
        let empty = try XCTUnwrap(MindMapOutline.nodes(in: source).first { $0.title == "Empty" })

        XCTAssertEqual(MindMapOutline.deleteLeaf(in: source, nodeID: empty.id), "# Root\n## Keep\n")
        XCTAssertTrue(MindMapOutline.actionAvailability(in: source, nodeID: empty.id).canDeleteLeaf)

        let onlyRoot = "# Only\n"
        XCTAssertNil(MindMapOutline.deleteLeaf(in: onlyRoot, nodeID: 0))
        XCTAssertFalse(MindMapOutline.actionAvailability(in: onlyRoot, nodeID: 0).canDeleteLeaf)
    }

    func testDeleteLeafRejectsHeadingWithAttachedContentOrDescendants() throws {
        let source = "# Root\n## With prose\n> Keep this quote\n## With child\n- Child\n"
        let nodes = MindMapOutline.nodes(in: source)
        let prose = try XCTUnwrap(nodes.first { $0.title == "With prose" })
        let branch = try XCTUnwrap(nodes.first { $0.title == "With child" })

        XCTAssertNil(MindMapOutline.deleteLeaf(in: source, nodeID: prose.id))
        XCTAssertNil(MindMapOutline.deleteLeaf(in: source, nodeID: branch.id))
        XCTAssertFalse(MindMapOutline.actionAvailability(in: source, nodeID: prose.id).canDeleteLeaf)
        XCTAssertFalse(MindMapOutline.actionAvailability(in: source, nodeID: branch.id).canDeleteLeaf)
    }

    func testActionAvailabilityMatchesCanonicalMutations() {
        let source = "# Root\n- First\n- Second\n  - Child\n- With prose\n  details"

        for nodeID in [0, 1, 2, 3, 4] {
            let availability = MindMapOutline.actionAvailability(in: source, nodeID: nodeID)
            XCTAssertEqual(
                availability.canMoveUp,
                MindMapOutline.moveNodeToAdjacentSibling(in: source, nodeID: nodeID, direction: .up) != nil
            )
            XCTAssertEqual(
                availability.canMoveDown,
                MindMapOutline.moveNodeToAdjacentSibling(in: source, nodeID: nodeID, direction: .down) != nil
            )
            XCTAssertEqual(
                availability.canPromote,
                MindMapOutline.shiftNodeSubtree(in: source, nodeID: nodeID, deeper: false) != nil
            )
            XCTAssertEqual(
                availability.canDemote,
                MindMapOutline.shiftNodeSubtree(in: source, nodeID: nodeID, deeper: true) != nil
            )
            XCTAssertEqual(
                availability.canDeleteLeaf,
                MindMapOutline.deleteLeaf(in: source, nodeID: nodeID) != nil
            )
        }

        XCTAssertEqual(
            MindMapOutline.actionAvailability(in: source, nodeID: 3),
            .init(
                canMoveUp: false, canMoveDown: false,
                canPromote: true, canDemote: false, canDeleteLeaf: true
            )
        )
        XCTAssertFalse(MindMapOutline.actionAvailability(in: source, nodeID: 4).canDeleteLeaf)
    }

    func testSiblingReorderMovesWholeMarkdownSubtreesAndPreservesSelectionIdentity() throws {
        let source = "# Root\n- First\n  First context.\n  - First child\n- Second\n  - Second child\n- Third"
        let nodes = MindMapOutline.nodes(in: source)
        let first = try XCTUnwrap(nodes.first { $0.title == "First" })
        let third = try XCTUnwrap(nodes.first { $0.title == "Third" })

        let down = try XCTUnwrap(MindMapOutline.moveNodeToAdjacentSibling(
            in: source, nodeID: first.id, direction: .down
        ))
        XCTAssertEqual(
            down.source,
            "# Root\n- Second\n  - Second child\n- First\n  First context.\n  - First child\n- Third"
        )
        let movedFirst = try XCTUnwrap(MindMapOutline.nodes(in: down.source).first { $0.title == "First" })
        XCTAssertEqual(MindMapOutline.lineIndexMap(from: nodes, to: MindMapOutline.nodes(in: down.source))[first.id], movedFirst.id)

        let up = try XCTUnwrap(MindMapOutline.moveNodeToAdjacentSibling(
            in: source, nodeID: third.id, direction: .up
        ))
        XCTAssertEqual(
            up.source,
            "# Root\n- First\n  First context.\n  - First child\n- Third\n- Second\n  - Second child"
        )
    }

    func testSiblingReorderKeepsHeadingSectionsAndRejectsUnsafeOrDifferentTypeNeighbors() throws {
        let headings = "# Root\n## First\nFirst body.\n### Child\n## Second\n### Second child\n## Third"
        let nodes = MindMapOutline.nodes(in: headings)
        let first = try XCTUnwrap(nodes.first { $0.title == "First" })
        let third = try XCTUnwrap(nodes.first { $0.title == "Third" })
        let moved = try XCTUnwrap(MindMapOutline.moveNodeToAdjacentSibling(
            in: headings, nodeID: third.id, direction: .up
        ))
        XCTAssertEqual(
            moved.source,
            "# Root\n## First\nFirst body.\n### Child\n## Third\n## Second\n### Second child"
        )
        XCTAssertNil(MindMapOutline.moveNodeToAdjacentSibling(
            in: headings, nodeID: first.id, direction: .up
        ))

        let unsafe = "# Root\n- First\nUnindented text\n- Second"
        let unsafeNodes = MindMapOutline.nodes(in: unsafe)
        let unsafeFirst = try XCTUnwrap(unsafeNodes.first { $0.title == "First" })
        XCTAssertNil(MindMapOutline.moveNodeToAdjacentSibling(
            in: unsafe, nodeID: unsafeFirst.id, direction: .down
        ))
        XCTAssertFalse(MindMapOutline.actionAvailability(in: unsafe, nodeID: unsafeFirst.id).canMoveDown)

        let mixed = "- Root item\n# Heading"
        XCTAssertNil(MindMapOutline.moveNodeToAdjacentSibling(
            in: mixed, nodeID: 0, direction: .down
        ))
    }
}


extension MindMapOutlineTests {
    func testMoveNodeSubtreeReparentsWholeBranch() {
        let source = "# Root\n- A\n  - A1\n- B\n- C"
        XCTAssertEqual(
            MindMapOutline.moveNodeSubtree(in: source, nodeID: 1, asChildOf: 3),
            "# Root\n- B\n  - A\n    - A1\n- C"
        )
        XCTAssertEqual(
            MindMapOutline.moveNodeSubtree(in: source, nodeID: 4, asChildOf: 1),
            "# Root\n- A\n  - C\n  - A1\n- B"
        )
    }

    func testMoveNodeSubtreeCanAttachToHeadingAndRejectCycles() {
        let source = "# Root\n- A\n  - A1\n- B"
        XCTAssertEqual(
            MindMapOutline.moveNodeSubtree(in: source, nodeID: 3, asChildOf: 0),
            "# Root\n- B\n- A\n  - A1"
        )
        XCTAssertNil(MindMapOutline.moveNodeSubtree(in: source, nodeID: 1, asChildOf: 2))
        XCTAssertNil(MindMapOutline.moveNodeSubtree(in: source, nodeID: 0, asChildOf: 3))
    }

    func testMoveNodeSubtreeOutcomeReportsNewNodeLineForSelection() {
        // Moving a later node forward: C (line 4) becomes child of A (line 1).
        // After removal of C (1 line), target adjusts to 1; C lands at line 2.
        let forward = "# Root\n- A\n  - A1\n- B\n- C"
        let forwardOutcome = MindMapOutline.moveNodeSubtreeWithOutcome(
            in: forward, nodeID: 4, asChildOf: 1
        )
        XCTAssertEqual(forwardOutcome?.source, "# Root\n- A\n  - C\n  - A1\n- B")
        XCTAssertEqual(forwardOutcome?.movedNodeID, 2)

        // Moving an earlier node backward: A subtree (lines 1-2) becomes child
        // of B (line 3). After removal of 2 lines, target adjusts to 1; A lands at line 2.
        let backward = "# Root\n- A\n  - A1\n- B\n- C"
        let backwardOutcome = MindMapOutline.moveNodeSubtreeWithOutcome(
            in: backward, nodeID: 1, asChildOf: 3
        )
        XCTAssertEqual(backwardOutcome?.source, "# Root\n- B\n  - A\n    - A1\n- C")
        XCTAssertEqual(backwardOutcome?.movedNodeID, 2)

        // The moved line must be a real outline node in the updated source.
        if let outcome = forwardOutcome {
            XCTAssertTrue(MindMapOutline.nodes(in: outcome.source).contains { $0.id == outcome.movedNodeID })
        }
    }
}


extension MindMapOutlineTests {
    func testKnowledgeLinksIgnoreFencedCodeAndDeduplicate() {
        let source = """
        # Root
        [[Alpha]]
        [Beta](Beta.md)
        [[Alpha]]
        ~~~
        [[Hidden]]
        ~~~
        """
        XCTAssertEqual(
            MindMapOutline.knowledgeLinks(in: source),
            [
                .init(label: "Alpha", target: "Alpha"),
                .init(label: "Beta", target: "Beta.md")
            ]
        )
    }
}

extension MindMapOutlineTests {
    func testSpatialLayoutInfersParentsAndSeparatesDepthColumns() {
        let nodes = MindMapOutline.nodes(in: "# Root\n- A\n  - A1\n- B")
        let layout = MindMapSpatialLayout.layout(nodes)
        let byID = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })

        XCTAssertEqual(byID[0]?.parentID, nil)
        XCTAssertEqual(byID[1]?.parentID, 0)
        XCTAssertEqual(byID[2]?.parentID, 1)
        XCTAssertEqual(byID[3]?.parentID, 0)
        XCTAssertGreaterThan(byID[1]!.center.x, byID[0]!.center.x)
        XCTAssertGreaterThan(byID[2]!.center.x, byID[1]!.center.x)
        XCTAssertLessThan(byID[1]!.center.y, byID[3]!.center.y)
        XCTAssertGreaterThan(layout.size.width, 560)
    }

    func testSpatialLayoutHandlesSixHundredSiblingsWithoutRepeatedPlacementLookup() {
        let nodes = [MindMapNode(id: 0, depth: 0, title: "Root")]
            + (1...600).map { MindMapNode(id: $0, depth: 1, title: "Child \($0)") }
        let snapshot = MindMapSpatialLayout.layout(nodes)
        XCTAssertEqual(snapshot.placements.count, 601)
        XCTAssertEqual(snapshot.placements.first?.id, 0)
        let leaves = Array(snapshot.placements.dropFirst())
        XCTAssertTrue(leaves.allSatisfy { $0.parentID == 0 })
        XCTAssertEqual(snapshot.placements[0].center.y,
                       (leaves[0].center.y + leaves[599].center.y) / 2,
                       accuracy: 0.001)
        XCTAssertTrue(zip(leaves, leaves.dropFirst()).allSatisfy {
            $1.center.y > $0.center.y + $0.size.height
        })
    }

    func testSpatialLayoutSupportsMultipleRoots() {
        let nodes = MindMapOutline.nodes(in: "# One\n- A\n# Two\n- B")
        let layout = MindMapSpatialLayout.layout(nodes)
        let roots = layout.placements.filter { $0.parentID == nil }
        XCTAssertEqual(roots.map(\.node.title), ["One", "Two"])
        XCTAssertLessThan(roots[0].center.y, roots[1].center.y)
    }
}


extension MindMapOutlineTests {
    func testSourceLineRangeUsesUTF16AndExactMarkdownLine() {
        let source = "# 根节点\n- Alpha 😀\n  - Child\nParagraph"
        XCTAssertEqual(
            MindMapOutline.sourceLineRange(in: source, nodeID: 1),
            NSRange(location: 6, length: 10)
        )
        XCTAssertEqual(
            MindMapOutline.sourceLineRange(in: source, nodeID: 2),
            NSRange(location: 17, length: 9)
        )
        XCTAssertNil(MindMapOutline.sourceLineRange(in: source, nodeID: 3))
    }

    func testCaretResolvesToNearestPrecedingMindMapNode() {
        let source = "# Root\nIntro paragraph\n- Topic\n  supporting prose\n  - Child"
        let ns = source as NSString
        XCTAssertEqual(MindMapOutline.nodeID(atUTF16Offset: 0, in: source), 0)
        XCTAssertEqual(
            MindMapOutline.nodeID(atUTF16Offset: ns.range(of: "Intro").location, in: source),
            0
        )
        XCTAssertEqual(
            MindMapOutline.nodeID(atUTF16Offset: ns.range(of: "supporting").location, in: source),
            2
        )
        XCTAssertEqual(
            MindMapOutline.nodeID(atUTF16Offset: ns.range(of: "Child").location, in: source),
            4
        )
    }
}


extension MindMapOutlineTests {
    func testLinkParserHandlesWholeMultilineDocumentInOnePass() {
        let source = """
        # Project
        [[Alpha|A]]
        prose
        [Beta](Nested/Beta.md)
        [[Gamma]]
        """
        XCTAssertEqual(
            MindMapOutline.links(in: source),
            [
                .init(label: "A", target: "Alpha"),
                .init(label: "Gamma", target: "Gamma"),
                .init(label: "Beta", target: "Nested/Beta.md")
            ]
        )
    }
}

extension MindMapOutlineTests {
    func testKeyboardCommandsCoverNavigationCreationEditingAndZoomWithoutModifierLeakage() {
        let cases: [(KeyEquivalent, EventModifiers, MindMapKeyboard.Command)] = [
            (.upArrow, [], .previous),
            (.downArrow, [], .next),
            (.leftArrow, [], .parentOrCollapse),
            (.rightArrow, [], .childOrExpand),
            (.tab, [], .addChild),
            (.return, [], .addSibling),
            ("e", [], .rename),
            (.space, [], .toggleBranch),
            (.delete, [], .deleteLeaf),
            (.delete, .command, .deleteBranch),
            ("0", .command, .fit),
            ("-", .command, .zoomOut),
            ("=", .command, .zoomIn),
            ("+", [.command, .shift], .zoomIn),
            (.escape, [], .clearSelection)
        ]
        for (key, modifiers, expected) in cases {
            XCTAssertEqual(
                MindMapKeyboard.command(for: key, modifiers: modifiers),
                expected, "Unexpected shortcut command for key \(key)"
            )
        }
        XCTAssertNil(MindMapKeyboard.command(for: .tab, modifiers: .shift))
        XCTAssertNil(MindMapKeyboard.command(for: .tab, modifiers: .command))
        XCTAssertNil(MindMapKeyboard.command(for: .return, modifiers: .shift))
        XCTAssertNil(MindMapKeyboard.command(for: "e", modifiers: .option))
        XCTAssertNil(MindMapKeyboard.command(for: .rightArrow, modifiers: .command))
        XCTAssertNil(MindMapKeyboard.command(for: .delete, modifiers: [.command, .option]))
        XCTAssertNil(MindMapKeyboard.command(for: .delete, modifiers: [.command, .shift]))
    }

    func testNineLevelMarkdownChainIsReachableAndReversibleWithKeyboard() throws {
        let nested = (2...9).map { level in
            String(repeating: "  ", count: level - 2) + "- Level \(level)"
        }
        let source = (["# Root"] + nested + ["- Sibling"]).joined(separator: "\n")
        let outline = MindMapOutline.nodes(in: source)

        XCTAssertEqual(outline.map(\.depth), Array(0...8) + [1])
        XCTAssertEqual(
            outline.map(\.title), ["Root"] + (2...9).map { "Level \($0)" } + ["Sibling"]
        )
        var selected = try XCTUnwrap(outline.first?.id)
        for level in 2...9 {
            selected = try XCTUnwrap(
                MindMapKeyboard.selection(from: selected, in: outline, moving: .childOrExpand)
            )
            XCTAssertEqual(outline.first(where: { $0.id == selected })?.title, "Level \(level)")
        }

        XCTAssertNil(
            MindMapKeyboard.selection(from: selected, in: outline, moving: .childOrExpand),
            "The last deep node must not treat its shallow sibling as a child"
        )
        XCTAssertEqual(
            MindMapKeyboard.selection(from: selected, in: outline, moving: .next),
            outline.last?.id,
            "Linear traversal must continue beyond the deepest branch"
        )

        for depth in stride(from: 7, through: 0, by: -1) {
            selected = try XCTUnwrap(
                MindMapKeyboard.selection(from: selected, in: outline, moving: .parentOrCollapse)
            )
            XCTAssertEqual(outline.first(where: { $0.id == selected })?.depth, depth)
        }
        XCTAssertEqual(selected, outline.first?.id)
    }

    func testKeyboardParentChildAndLinearNavigationFollowVisibleMarkdownOutline() {
        let outline = MindMapOutline.nodes(in: "# Root\n- A\n  - A1\n- B\n## Another")
        XCTAssertEqual(outline.map(\.id), [0, 1, 2, 3, 4])
        XCTAssertEqual(
            MindMapKeyboard.selection(from: 1, in: outline, moving: .childOrExpand), 2
        )
        XCTAssertEqual(
            MindMapKeyboard.selection(from: 2, in: outline, moving: .parentOrCollapse), 1
        )
        XCTAssertEqual(
            MindMapKeyboard.selection(from: 3, in: outline, moving: .parentOrCollapse), 0
        )
        XCTAssertEqual(
            MindMapKeyboard.selection(from: 1, in: outline, moving: .next), 2
        )
        XCTAssertEqual(
            MindMapKeyboard.selection(from: 0, in: outline, moving: .previous), 0
        )
        XCTAssertEqual(
            MindMapKeyboard.selection(from: 4, in: outline, moving: .next), 4
        )
        // Collapsed branches are absent from the visible list; navigation cannot
        // target a hidden descendant or invent a separate tree.
        let collapsed = outline.filter { $0.id != 2 }
        XCTAssertNil(MindMapKeyboard.selection(from: 1, in: collapsed, moving: .childOrExpand))
        XCTAssertEqual(
            MindMapKeyboard.selection(from: 1, in: collapsed, moving: .next), 3
        )
        XCTAssertEqual(MindMapKeyboard.selection(from: nil, in: outline, moving: .next), 0)
    }
}


extension MindMapOutlineTests {
    func testCancelledProjectionParsingStopsAtCancellationCheckpoints() async {
        let markdown = (0..<2_000)
            .map { "- Node \($0)\n  [Reference](/ref-\($0).pdf)" }
            .joined(separator: "\n")

        let nodesStopped = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return MindMapOutline.nodes(in: markdown).isEmpty
        }.value
        XCTAssertTrue(nodesStopped)

        let presentationsStopped = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            let root = MindMapNode(id: 0, depth: 0, title: "Root")
            return MindMapOutline.presentations(in: markdown, nodes: [root]).isEmpty
        }.value
        XCTAssertTrue(presentationsStopped)

        let linksStopped = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return MindMapOutline.linkOccurrences(in: markdown).isEmpty
        }.value
        XCTAssertTrue(linksStopped)
    }
}


extension MindMapOutlineTests {
    func testInlineRenamePreservesConnectedSourcesWithoutExposingLinkSyntax() throws {
        let source = "# Study\n- 观察🧠 [[Notes/资料|资料]] [原文](../Books/Study.pdf#page=3)\n  - Detail\n"
        let node = try XCTUnwrap(MindMapOutline.nodes(in: source).first { $0.title.hasPrefix("观察") })
        XCTAssertEqual(MindMapOutline.titleForInlineEditing(node.title), "观察🧠")
        let updated = try XCTUnwrap(MindMapOutline.renameInlineTitle(in: source, nodeID: node.id, to: "新观察"))
        XCTAssertEqual(updated, "# Study\n- 新观察 [[Notes/资料|资料]] [原文](../Books/Study.pdf#page=3)\n  - Detail\n")
        XCTAssertEqual(MindMapOutline.links(in: try XCTUnwrap(MindMapOutline.nodes(in: updated).first { $0.id == node.id }).title).map(\.target), ["Notes/资料", "../Books/Study.pdf#page=3"])
    }

    func testInlineTaskRenameKeepsCheckboxAndCanonicalSourceLink() throws {
        let source = "# Tasks\n- [x] Read chapter [[/Books/Chapter.pdf|Source]]\n"
        let node = try XCTUnwrap(MindMapOutline.nodes(in: source).first { $0.title.hasPrefix("[x]") })
        let visible = MindMapOutline.titleForInlineEditing(node.title)
        XCTAssertEqual(MindMapTaskNode.titleForEditing(visible), "Read chapter")
        let replacement = try XCTUnwrap(MindMapTaskNode.replacingTitle("Review chapter", in: visible))
        XCTAssertEqual(MindMapOutline.renameInlineTitle(in: source, nodeID: node.id, to: replacement),
                       "# Tasks\n- [x] Review chapter [[/Books/Chapter.pdf|Source]]\n")
    }

    func testInlineRenameOnlyRetainsActualTrailingLinks() throws {
        let original = "# Root\n- Open [[Source|label]] and compare\n- \\[[Literal]]\n- [Only linked](../src.pdf)\n"
        let nodes = MindMapOutline.nodes(in: original)
        XCTAssertEqual(MindMapOutline.titleForInlineEditing(nodes[1].title), "Open [[Source|label]] and compare")
        XCTAssertEqual(MindMapOutline.titleForInlineEditing(nodes[2].title), "\\[[Literal]]")
        XCTAssertEqual(MindMapOutline.titleForInlineEditing(nodes[3].title), "Only linked")
        let renamed = try XCTUnwrap(MindMapOutline.renameInlineTitle(in: original, nodeID: nodes[1].id, to: "Changed"))
        XCTAssertTrue(renamed.contains("- Changed\n"))
        XCTAssertFalse(renamed.contains("Source|label"))
    }
}


extension MindMapOutlineTests {
    func testLinkOnlyNodeRenameEditsHumanLabelAndPreservesCanonicalTarget() throws {
        let source = "# Root\n- [[/References/Plan|Plan source]]\n- [Old PDF](../source.pdf#page=4)\n- [ ] [[/Tasks/Read|Read source]]\n"
        let nodes = MindMapOutline.nodes(in: source)
        let wiki = try XCTUnwrap(nodes.first { $0.title.contains("/References/Plan") })
        let markdown = try XCTUnwrap(nodes.first { $0.title.contains("../source.pdf") })
        let task = try XCTUnwrap(nodes.first { $0.title.contains("/Tasks/Read") })

        XCTAssertEqual(MindMapOutline.titleForInlineEditing(wiki.title), "Plan source")
        XCTAssertEqual(MindMapOutline.titleForInlineEditing(markdown.title), "Old PDF")
        XCTAssertEqual(MindMapTaskNode.titleForEditing(MindMapOutline.titleForInlineEditing(task.title)), "Read source")

        let wikiRename = try XCTUnwrap(MindMapOutline.renameInlineTitle(in: source, nodeID: wiki.id, to: "Plan overview"))
        XCTAssertEqual(wikiRename, "# Root\n- [[/References/Plan|Plan overview]]\n- [Old PDF](../source.pdf#page=4)\n- [ ] [[/Tasks/Read|Read source]]\n")
        let markdownRename = try XCTUnwrap(MindMapOutline.renameInlineTitle(in: source, nodeID: markdown.id, to: "PDF overview"))
        XCTAssertEqual(markdownRename, "# Root\n- [[/References/Plan|Plan source]]\n- [PDF overview](../source.pdf#page=4)\n- [ ] [[/Tasks/Read|Read source]]\n")
        let taskTitle = try XCTUnwrap(MindMapTaskNode.replacingTitle(
            "Reading notes", in: MindMapOutline.titleForInlineEditing(task.title)
        ))
        let taskRename = try XCTUnwrap(MindMapOutline.renameInlineTitle(in: source, nodeID: task.id, to: taskTitle))
        XCTAssertEqual(taskRename, "# Root\n- [[/References/Plan|Plan source]]\n- [Old PDF](../source.pdf#page=4)\n- [ ] [[/Tasks/Read|Reading notes]]\n")

        let multipleSources = "# Root\n- [[/References/Plan|Plan source]] [Extra](../extra.pdf)\n"
        let multipleNode = try XCTUnwrap(MindMapOutline.nodes(in: multipleSources).first { $0.id == 1 })
        XCTAssertEqual(MindMapOutline.titleForInlineEditing(multipleNode.title), "Plan source")
        XCTAssertEqual(
            MindMapOutline.renameInlineTitle(in: multipleSources, nodeID: multipleNode.id, to: "Overview"),
            "# Root\n- [[/References/Plan|Overview]] [Extra](../extra.pdf)\n"
        )
    }
}


extension MindMapOutlineTests {
    func testPDFLinkLabelsRenderAndEditAsLiteralFilenamesAcrossMapAndBacklinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-PDF-MindMap-Link-Label-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let filename = "Plan &amp; [draft] <final>.pdf"
        let pdf = root.appendingPathComponent(filename)
        try Data().write(to: pdf)
        let reference = try XCTUnwrap(PDFPageReference.markdown(for: pdf, page: 3, root: root))
        let source = "# Root\n- \(reference)\n"
        let node = try XCTUnwrap(MindMapOutline.nodes(in: source).first { $0.id == 1 })
        let expected = "\(filename) · p. 3"

        XCTAssertEqual(MindMapOutline.titleForInlineEditing(node.title), expected)
        let presentation = MindMapOutline.presentation(for: node.title)
        XCTAssertEqual(presentation.title, expected)
        XCTAssertEqual(presentation.links.first?.label, expected)
        XCTAssertEqual(
            MindMapOutline.linkOccurrences(in: source, includeContext: true).first?.context,
            "- \(expected)"
        )

        let replacementLabel = "Notes &amp; [draft] <final>"
        let renamed = try XCTUnwrap(
            MindMapOutline.renameInlineTitle(in: source, nodeID: node.id, to: replacementLabel)
        )
        let updatedNode = try XCTUnwrap(MindMapOutline.nodes(in: renamed).first { $0.id == node.id })
        XCTAssertEqual(MindMapOutline.titleForInlineEditing(updatedNode.title), replacementLabel)
        XCTAssertTrue(renamed.contains("[Notes &amp;amp; &#91;draft&#93; &lt;final&gt;]"))
        XCTAssertEqual(
            MindMapOutline.linkOccurrences(in: renamed).first?.link.target,
            MindMapOutline.linkOccurrences(in: source).first?.link.target
        )
    }
}


extension MindMapOutlineTests {
    func testCollapsedBranchKeepsItsDisclosureFromTheCompleteMarkdownProjection() {
        let nodes = MindMapOutline.nodes(in: """
        # Root
        - Deep branch
          - Level 2
            - Level 3
        - Short branch
          - Visible child
        """)
        let root = nodes.first { $0.title == "Root" }!
        let deepBranch = nodes.first { $0.title == "Deep branch" }!
        let shortBranch = nodes.first { $0.title == "Short branch" }!
        let visibleChild = nodes.first { $0.title == "Visible child" }!

        var hiddenBelow: Int?
        let collapsedVisibleNodes = nodes.filter { node in
            if let depth = hiddenBelow {
                if node.depth > depth { return false }
                hiddenBelow = nil
            }
            if node.id == deepBranch.id { hiddenBelow = node.depth }
            return true
        }

        let fullParentIDs = MindMapOutline.parentIDs(in: nodes)
        let visibleParentIDs = MindMapOutline.parentIDs(in: collapsedVisibleNodes)
        XCTAssertTrue(fullParentIDs.contains(root.id))
        XCTAssertTrue(fullParentIDs.contains(deepBranch.id))
        XCTAssertFalse(visibleParentIDs.contains(deepBranch.id))
        XCTAssertTrue(fullParentIDs.contains(shortBranch.id))
        XCTAssertFalse(fullParentIDs.contains(visibleChild.id))
    }
}


extension MindMapOutlineTests {
    func testFourSpaceNestedListsUseOneDepthPerListItem() {
        let markdown = "# Root\n- Parent\n    - Child\n        - Grandchild\n  - Sibling\n- Next"
        let nodes = MindMapOutline.nodes(in: markdown)

        XCTAssertEqual(nodes.map(\.title), ["Root", "Parent", "Child", "Grandchild", "Sibling", "Next"])
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 2, 3, 2, 1])
    }

    func testTabIndentedNestedListsUseOneDepthPerListItem() {
        let markdown = "# Root\n- Parent\n\t- Child\n\t\t- Grandchild\n- Next"
        let nodes = MindMapOutline.nodes(in: markdown)

        XCTAssertEqual(nodes.map(\.title), ["Root", "Parent", "Child", "Grandchild", "Next"])
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 2, 3, 1])
    }
}


extension MindMapOutlineTests {
    func testListNestingRequiresParentContentIndent() {
        let bulletMarkdown = "# Root\n- Parent\n - Misaligned\n- Next"
        let bulletNodes = MindMapOutline.nodes(in: bulletMarkdown)
        XCTAssertEqual(bulletNodes.map(\.title), ["Root", "Parent", "Misaligned", "Next"])
        XCTAssertEqual(bulletNodes.map(\.depth), [0, 1, 1, 1])

        let orderedMarkdown = "# Root\n10. Parent\n  - Misaligned\n    - Child\n- Next"
        let orderedNodes = MindMapOutline.nodes(in: orderedMarkdown)
        XCTAssertEqual(orderedNodes.map(\.title), ["Root", "Parent", "Misaligned", "Child", "Next"])
        XCTAssertEqual(orderedNodes.map(\.depth), [0, 1, 1, 2, 1])
    }

    func testBlankLineEndsListForUnindentedParagraphButKeepsIndentedContinuation() {
        let separateBlock = "# Root\n- Parent\n\nOutside paragraph\n  - Independent"
        let separateNodes = MindMapOutline.nodes(in: separateBlock)
        XCTAssertEqual(separateNodes.map(\.title), ["Root", "Parent", "Independent"])
        XCTAssertEqual(separateNodes.map(\.depth), [0, 1, 1])

        let continuedItem = "# Root\n- Parent\n\n  Supporting prose\n  - Child"
        let continuedNodes = MindMapOutline.nodes(in: continuedItem)
        XCTAssertEqual(continuedNodes.map(\.title), ["Root", "Parent", "Child"])
        XCTAssertEqual(continuedNodes.map(\.depth), [0, 1, 2])
    }
}


extension MindMapOutlineTests {
    func testListMarkersRequireASCIICommonMarkWhitespace() {
        let markdown = "# Root\n-\u{3000}Full-width space\n-\u{00A0}Non-breaking space\n-\tTab bullet\n1.\u{3000}Unicode ordered separator\n2.\tTab ordered item\n1234567890. Too many digits"
        let nodes = MindMapOutline.nodes(in: markdown)

        XCTAssertEqual(nodes.map(\.title), ["Root", "Tab bullet", "Tab ordered item"])
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 1])
    }
}

extension MindMapOutlineTests {
    func testEvenBackslashesBeforeInlineCodeKeepExamplePDFLinksOutOfKnowledgeGraph() throws {
        let markdown = #"""
        # Plan
        - Evidence
          See \\`[Example](/Fake.pdf)` and [Real](/Real.pdf).
        """#
        let occurrences = MindMapOutline.linkOccurrences(in: markdown)
        XCTAssertEqual(occurrences.map(\.link.target), ["/Real.pdf"])
        let codeOffset = (markdown as NSString).range(of: "[Example]").location + 2
        XCTAssertTrue(MindMapOutline.isInsideCode(in: markdown, at: codeOffset))
        let nodes = MindMapOutline.nodes(in: markdown)
        let evidence = try XCTUnwrap(nodes.first(where: { $0.title == "Evidence" }))
        XCTAssertEqual(
            MindMapOutline.presentations(in: markdown, nodes: nodes)[evidence.id]?.links.map(\.target),
            ["/Real.pdf"]
        )
    }

    func testOddVersusEvenBackslashesBeforeMarkdownAndWikiLinks() {
        let markdown = #"""
        # Plan
        - Evidence
          Escaped \[Literal](/Ignored.pdf), real \\[Real](/Real.pdf).
          Escaped \[[Ignored]], real \\[[Research|Study]].
        """#
        XCTAssertEqual(
            MindMapOutline.linkOccurrences(in: markdown).map(\.link.target),
            ["/Real.pdf", "Research"]
        )
    }
}


extension MindMapOutlineTests {
    func testParentLevelFenceAfterNestedChildDoesNotHideParentSibling() {
        let markdown = """
        # Root
        - Outer
          - Parent
            - Child
            ```
            - Fake parent code node
            [Fake parent code link](/fake-parent.pdf)
            ```
            - Parent sibling
              [Parent sibling link](/parent-sibling.pdf)
          - Outer sibling
        - End
        """
        let nodes = MindMapOutline.nodes(in: markdown)

        XCTAssertEqual(
            nodes.map(\.title),
            ["Root", "Outer", "Parent", "Child", "Parent sibling", "Outer sibling", "End"]
        )

        let flags = MindMapOutline.blockCodeLineFlags(in: markdown)
        XCTAssertTrue(flags[5])
        XCTAssertTrue(flags[6])
        XCTAssertTrue(flags[7])
        XCTAssertFalse(flags[8])
        XCTAssertFalse(flags[9])

        let fakeOffset = (markdown as NSString).range(of: "Fake parent code link").location
        let realOffset = (markdown as NSString).range(of: "Parent sibling link").location
        XCTAssertTrue(MindMapOutline.isInsideCode(in: markdown, at: fakeOffset))
        XCTAssertFalse(MindMapOutline.isInsideCode(in: markdown, at: realOffset))
        XCTAssertEqual(
            MindMapOutline.linkOccurrences(in: markdown).map { $0.link.target },
            ["/parent-sibling.pdf"]
        )
    }
}
