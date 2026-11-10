import Foundation
import XCTest
@testable import PKSNotes

final class WorkspaceLinkRelocationTests: XCTestCase {
    func testMovePreservesInternalRelativeLinksAndLeavesExternalSyntaxUntouched() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let originalFolder = root.appendingPathComponent("Before")
        let destinationFolder = root.appendingPathComponent("After")
        try fm.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = originalFolder.appendingPathComponent("Guide.md")
        let destination = destinationFolder.appendingPathComponent("Guide.md")
        let sibling = originalFolder.appendingPathComponent("Sibling.md")
        let pdf = root.appendingPathComponent("Paper.pdf")
        let insideDestination = destinationFolder.appendingPathComponent("Already.md")
        try "# Sibling".write(to: sibling, atomically: true, encoding: .utf8)
        try "# Destination".write(to: insideDestination, atomically: true, encoding: .utf8)
        try Data([37, 80, 68, 70]).write(to: pdf)
        let originalBody = """
        # Guide
        [Sibling](Sibling.md#A) and [[../Paper.pdf#page=2|PDF]]
        [Root](/Before/Sibling.md) and [Self](Guide.md#Intro)
        [External](https://example.org/x) ![Cover](cover.png)
        ~~~markdown
        [Example](Sibling.md)
        ~~~
        """
        try originalBody.write(to: original, atomically: true, encoding: .utf8)

        let preparedResult = try await WorkspaceLinkRelocation.prepare(
            from: original, to: destination, root: root
        )
        let prepared = try XCTUnwrap(preparedResult)
        XCTAssertTrue(prepared.updated.contains("[Sibling](/Before/Sibling#A)"))
        XCTAssertTrue(prepared.updated.contains("[[/Paper.pdf#page=2|PDF]]"))
        XCTAssertTrue(prepared.updated.contains("[Self](/After/Guide#Intro)"))
        XCTAssertTrue(prepared.updated.contains("[Root](/Before/Sibling.md)"))
        XCTAssertTrue(prepared.updated.contains("[External](https://example.org/x)"))
        XCTAssertTrue(prepared.updated.contains("![Cover](cover.png)"))
        XCTAssertTrue(prepared.updated.contains("[Example](Sibling.md)"))

        try fm.moveItem(at: original, to: destination)
        XCTAssertTrue(WorkspaceLinkRelocation.apply(prepared, to: destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), prepared.updated)
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), "# Sibling")
    }

    func testSameFolderRenameOnlyRewritesSelfReferences() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Old.md")
        let renamed = root.appendingPathComponent("New.md")
        let other = root.appendingPathComponent("Other.md")
        try "# Other".write(to: other, atomically: true, encoding: .utf8)
        try "[Self](Old.md#One) and [Other](Other.md)".write(to: source, atomically: true, encoding: .utf8)

        let preparedResult = try await WorkspaceLinkRelocation.prepare(from: source, to: renamed, root: root)
        let prepared = try XCTUnwrap(preparedResult)
        XCTAssertEqual(prepared.updated, "[Self](/New#One) and [Other](Other.md)")
        try fm.moveItem(at: source, to: renamed)
        XCTAssertTrue(WorkspaceLinkRelocation.apply(prepared, to: renamed))
    }

    func testChangedFileRefusesOverwriteAfterMove() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dstFolder = root.appendingPathComponent("Dest")
        try fm.createDirectory(at: dstFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Old.md")
        let target = root.appendingPathComponent("Other.md")
        let moved = dstFolder.appendingPathComponent("Old.md")
        try "# Other".write(to: target, atomically: true, encoding: .utf8)
        try "[Other](Other.md)".write(to: source, atomically: true, encoding: .utf8)
        let preparedResult = try await WorkspaceLinkRelocation.prepare(from: source, to: moved, root: root)
        let prepared = try XCTUnwrap(preparedResult)
        try fm.moveItem(at: source, to: moved)
        try "Modified concurrently".write(to: moved, atomically: true, encoding: .utf8)
        XCTAssertFalse(WorkspaceLinkRelocation.apply(prepared, to: moved))
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "Modified concurrently")
    }

    @MainActor
    func testUnreadableMarkdownRefusesMoveInsteadOfSkippingLinkRepair() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Docs", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = root.appendingPathComponent("Broken.md")
        let moved = folder.appendingPathComponent("Broken.md")
        try Data([0xFF, 0xFE, 0xFD]).write(to: original)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let result = await model.moveItem(original, to: folder)

        XCTAssertNil(result)
        XCTAssertTrue(fm.fileExists(atPath: original.path))
        XCTAssertFalse(fm.fileExists(atPath: moved.path))
        XCTAssertTrue(model.message?.contains(AppLanguage.current.text("Could not prepare path change")) == true)
    }

    @MainActor
    func testModelMovePreservesSourceLinksWithoutChangingOtherNotes() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Docs")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = root.appendingPathComponent("Reading.md")
        let moved = folder.appendingPathComponent("Reading.md")
        let target = root.appendingPathComponent("Reference.md")
        try "# Reference".write(to: target, atomically: true, encoding: .utf8)
        try "[Reference](Reference.md)".write(to: original, atomically: true, encoding: .utf8)
        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let movedResult = await model.moveItem(original, to: folder)
        XCTAssertEqual(movedResult, moved)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "[Reference](/Reference)")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# Reference")
    }
    @MainActor
    func testRenameRepairsIncomingBasenameLinkUsingFreshVaultCandidates() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let target = root.appendingPathComponent("Target.md")
        let renamed = root.appendingPathComponent("Renamed.md")
        let ref = root.appendingPathComponent("Reference.md")
        try "# Target".write(to: target, atomically: true, encoding: .utf8)
        try "See [[Target]]".write(to: ref, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let result = await model.renameItem(target, to: "Renamed")

        XCTAssertEqual(result, renamed)
        XCTAssertEqual(try String(contentsOf: ref, encoding: .utf8), "See [[/Renamed|Target]]")
    }

    @MainActor
    func testRenameReportsAmbiguousIncomingBasenameWithoutGuessingTarget() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstFolder = root.appendingPathComponent("First", isDirectory: true)
        let secondFolder = root.appendingPathComponent("Second", isDirectory: true)
        try fm.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let moving = firstFolder.appendingPathComponent("Target.md")
        let other = secondFolder.appendingPathComponent("Target.md")
        let reference = root.appendingPathComponent("Reference.md")
        try "# First target".write(to: moving, atomically: true, encoding: .utf8)
        try "# Second target".write(to: other, atomically: true, encoding: .utf8)
        try "See [[Target]]".write(to: reference, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let renamed = firstFolder.appendingPathComponent("Renamed.md")
        let result = await model.renameItem(moving, to: "Renamed")

        XCTAssertEqual(result, renamed)
        XCTAssertFalse(fm.fileExists(atPath: moving.path))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "# Second target")
        XCTAssertEqual(try String(contentsOf: reference, encoding: .utf8), "See [[Target]]")
        XCTAssertEqual(
            model.message,
            AppLanguage.current.text("Path changed, but some related links could not be preserved. Review affected notes.")
        )
    }

    @MainActor
    func testMoveAttachmentRepairsMarkdownImageReferenceWithoutCreatingKnowledgeLink() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = root.appendingPathComponent("Note.md")
        let image = assets.appendingPathComponent("cover.png")
        let movedImage = archive.appendingPathComponent("cover.png")
        try "![Cover](assets/cover.png)".write(to: note, atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let result = await model.moveItem(image, to: archive)

        XCTAssertEqual(result, movedImage)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "![Cover](/archive/cover.png)")
        XCTAssertTrue(MindMapOutline.knowledgeLinks(in: try String(contentsOf: note, encoding: .utf8)).isEmpty)
    }

    @MainActor
    func testCopyMarkdownAcrossFoldersPreservesRelativeTargetSemantics() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceFolder = root.appendingPathComponent("Source", isDirectory: true)
        let copies = root.appendingPathComponent("Copies", isDirectory: true)
        try fm.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: copies, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = sourceFolder.appendingPathComponent("Note.md")
        let target = sourceFolder.appendingPathComponent("Reference.md")
        try "# Reference".write(to: target, atomically: true, encoding: .utf8)
        try "[Reference](Reference.md)".write(to: note, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let result = await model.copyItem(note, to: copies)
        let copied = copies.appendingPathComponent("Note.md")

        XCTAssertEqual(result, copied)
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "[Reference](/Source/Reference)")
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "[Reference](Reference.md)")
    }

    @MainActor
    func testCopyFolderPreservesInternalTopologyAndRebasesExternalRelativeLinks() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("Bundle", isDirectory: true)
        let assets = bundle.appendingPathComponent("assets", isDirectory: true)
        let copies = root.appendingPathComponent("Copies", isDirectory: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try fm.createDirectory(at: copies, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = bundle.appendingPathComponent("Note.md")
        let inside = bundle.appendingPathComponent("Inside.md")
        let external = root.appendingPathComponent("External.md")
        let externalImage = root.appendingPathComponent("cover.png")
        let internalImage = assets.appendingPathComponent("inside.png")
        try "# Inside".write(to: inside, atomically: true, encoding: .utf8)
        try "# External".write(to: external, atomically: true, encoding: .utf8)
        try Data([1]).write(to: externalImage)
        try Data([2]).write(to: internalImage)
        try """
        [Inside](Inside.md)
        [Root inside](/Bundle/Inside.md)
        [External](../External.md)
        ![Internal image](assets/inside.png)
        ![External image](../cover.png)
        """.write(to: note, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let result = await model.copyItem(bundle, to: copies)
        let copiedBundle = copies.appendingPathComponent("Bundle", isDirectory: true)
        let copiedNote = copiedBundle.appendingPathComponent("Note.md")
        let copiedBody = try String(contentsOf: copiedNote, encoding: .utf8)

        XCTAssertEqual(result?.standardizedFileURL.path, copiedBundle.standardizedFileURL.path)
        XCTAssertTrue(copiedBody.contains("[Inside](Inside.md)"))
        XCTAssertTrue(copiedBody.contains("[Root inside](/Copies/Bundle/Inside)"))
        XCTAssertTrue(copiedBody.contains("[External](/External)"))
        XCTAssertTrue(copiedBody.contains("![Internal image](assets/inside.png)"))
        XCTAssertTrue(copiedBody.contains("![External image](/cover.png)"))
        XCTAssertEqual(
            try String(contentsOf: note, encoding: .utf8),
            """
            [Inside](Inside.md)
            [Root inside](/Bundle/Inside.md)
            [External](../External.md)
            ![Internal image](assets/inside.png)
            ![External image](../cover.png)
            """
        )
    }

    @MainActor
    func testCopyCurrentDirtyMarkdownSavesCanonicalDraftBeforeCopy() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copies = root.appendingPathComponent("Copies", isDirectory: true)
        try fm.createDirectory(at: copies, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let note = root.appendingPathComponent("Note.md")
        try "# Old".write(to: note, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(note)
        for _ in 0..<80 where model.selected?.standardizedFileURL != note.standardizedFileURL {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.selected?.standardizedFileURL, note.standardizedFileURL)
        model.draft = "# New unsaved draft"

        let copied = await model.copyItem(note, to: copies)
        XCTAssertEqual(copied, copies.appendingPathComponent("Note.md"))
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "# New unsaved draft")
        XCTAssertEqual(try String(contentsOf: copied!, encoding: .utf8), "# New unsaved draft")
    }

}
