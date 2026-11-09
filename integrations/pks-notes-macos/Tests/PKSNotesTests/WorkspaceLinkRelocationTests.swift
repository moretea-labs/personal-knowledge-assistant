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
}
