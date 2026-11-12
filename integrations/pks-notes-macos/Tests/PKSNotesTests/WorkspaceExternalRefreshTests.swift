import Foundation
import XCTest
@testable import PKSNotes

final class WorkspaceExternalRefreshTests: XCTestCase {
    @MainActor
    private func awaitCondition(
        timeout: Duration = .seconds(3),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "The workspace did not reflect the filesystem within the observation window.")
    }

    func testRealFSEventNotificationForExternalFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = root.resolvingSymlinksInPath().appendingPathComponent("External.md").path
        let observed = expectation(description: "FSEvents detected the external file")
        observed.assertForOverFulfill = false
        guard let monitor = WorkspaceChangeMonitor(root: root, onChanges: { paths in
            if paths.contains(where: { $0.hasSuffix("/External.md") }) {
                observed.fulfill()
            }
        }) else {
            return XCTFail("FSEventStream failed to initialize for writable folder")
        }
        try await Task.sleep(for: .milliseconds(350))
        try "# External".write(
            to: URL(fileURLWithPath: expected), atomically: true, encoding: .utf8
        )
        await fulfillment(of: [observed], timeout: 5)
        withExtendedLifetime(monitor) {}
    }

    func testMindNodePackagesAppearAsDocumentsNotRecursiveFolders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanPackage-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Concept.mindnode", isDirectory: true)
        let internalPreview = package.appendingPathComponent("QuickLook", isDirectory: true)
        try FileManager.default.createDirectory(at: internalPreview, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: package.appendingPathComponent("contents.xml"))
        try Data([4]).write(to: internalPreview.appendingPathComponent("Preview.jpg"))

        let tree = WorkspaceFiles.tree(in: root, recursive: true)
        XCTAssertEqual(tree.count, 1)
        XCTAssertFalse(tree[0].isFolder)
        XCTAssertTrue(tree[0].isMindMapPackage)
        var indexed: [URL] = []
        WorkspaceFiles.visitFlatFiles(in: root) { indexed.append($0) }
        XCTAssertEqual(indexed, [package])
    }

    @MainActor
    func testExternalDirectoryAdditionRefreshesVisibleFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanExternal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        try await awaitCondition { !model.loadingFiles }
        let added = root.appendingPathComponent("Added.md")
        try "# Added\n".write(to: added, atomically: true, encoding: .utf8)

        model.noteExternalPaths([added.path], in: root)
        try await awaitCondition { model.files.contains(where: { $0.url == added }) }
        XCTAssertTrue(model.globalQuickOpenEntries.isEmpty,
                      "The full-vault index must remain lazy after an event.")
    }

    @MainActor
    func testExternalModificationReloadsCleanOpenDocument() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanExternal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("Note.md")
        try "# First\n".write(to: note, atomically: true, encoding: .utf8)
        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(note)
        try await awaitCondition { model.selected == note && !model.loadingNote }
        XCTAssertEqual(model.draft, "# First\n")
        try "# External revision\n".write(to: note, atomically: true, encoding: .utf8)

        model.noteExternalPaths([note.path], in: root)
        try await awaitCondition { model.draft == "# External revision\n" }
        XCTAssertEqual(model.baseline, model.draft)
        XCTAssertFalse(model.isDirty)
    }

    @MainActor
    func testExternalModificationNeverOverwritesDirtyDraft() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanExternal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("Note.md")
        try "# First\n".write(to: note, atomically: true, encoding: .utf8)
        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(note)
        try await awaitCondition { model.selected == note && !model.loadingNote }
        model.draft = "# Unsaved in Leafspan\n"
        try "# External revision\n".write(to: note, atomically: true, encoding: .utf8)

        model.noteExternalPaths([note.path], in: root)
        try await awaitCondition { model.message != nil }
        XCTAssertEqual(model.draft, "# Unsaved in Leafspan\n")
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "# External revision\n")
        XCTAssertTrue(model.isDirty)
    }
}
