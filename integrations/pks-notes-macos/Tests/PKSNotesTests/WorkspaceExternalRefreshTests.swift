import CoreServices
import Foundation
import XCTest
@testable import PKSNotes

final class WorkspaceExternalRefreshTests: XCTestCase {
    @MainActor
    private func awaitCondition(
        timeout: Duration = .seconds(3),
        message: String = "The workspace did not reflect the filesystem within the observation window.",
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), message)
    }

    func testFSEventLossFlagsRequireFullRescan() {
        let lostHistoryFlags: [FSEventStreamEventFlags] = [
            FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
            FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        ]
        for flag in lostHistoryFlags {
            XCTAssertTrue(WorkspaceChangeMonitor.requiresFullRescan(for: flag))
        }
        XCTAssertFalse(WorkspaceChangeMonitor.requiresFullRescan(
            for: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        ))
    }

    func testRealFSEventNotificationForExternalFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanMonitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = root.resolvingSymlinksInPath().appendingPathComponent("External.md").path
        let observed = expectation(description: "FSEvents detected the external file")
        observed.assertForOverFulfill = false
        guard let monitor = WorkspaceChangeMonitor(root: root, onChanges: { paths, _ in
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

        // Exercise the real FSEvents → NotesModel → visible-tree path.
        try await awaitCondition(timeout: .seconds(5)) {
            model.files.contains(where: { $0.url == added })
        }
        XCTAssertTrue(model.globalQuickOpenEntries.isEmpty,
                      "The full-vault index must remain lazy after an event.")
    }

    @MainActor
    func testExternalRenameBackRescansPreviouslyExpandedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanRenameBack-\(UUID().uuidString)", isDirectory: true)
        let original = root.appendingPathComponent("Projects", isDirectory: true)
        let nested = original.appendingPathComponent("Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = nested.appendingPathComponent("Original.md")
        try "# Original".write(to: note, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        try await awaitCondition { !model.loadingFiles }
        model.loadExpandedFolders([original.path])
        try await awaitCondition(message: "The original folder did not load its nested directory.") {
            model.files.first(where: { $0.url == original })?.children?.contains(where: { $0.url == nested }) == true
        }
        model.loadExpandedFolders([nested.path])
        try await awaitCondition(message: "The original nested directory did not load its note.") {
            model.files.first(where: { $0.url == original })?.children?
                .first(where: { $0.url == nested })?.children?.contains(where: { $0.url == note }) == true
        }

        let renamed = root.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: renamed)
        model.noteExternalPaths([original.path, renamed.path], in: root)
        try await awaitCondition(timeout: .seconds(5), message: "The file tree did not replace the renamed folder with Archive.") {
            model.files.contains(where: { $0.url == renamed })
        }

        try FileManager.default.moveItem(at: renamed, to: original)
        model.noteExternalPaths([renamed.path, original.path], in: root)
        try await awaitCondition(timeout: .seconds(5), message: "The file tree did not show Projects after renaming Archive back.") {
            model.files.contains(where: { $0.url == original })
        }
        model.loadExpandedFolders([original.path])
        try await awaitCondition(timeout: .seconds(5), message: "The recreated Projects folder was not rescanned.") {
            model.files.first(where: { $0.url == original })?.children?.contains(where: { $0.url == nested }) == true
        }
        model.loadExpandedFolders([nested.path])
        try await awaitCondition(timeout: .seconds(5), message: "The recreated Projects/Deep folder was not rescanned.") {
            model.files.first(where: { $0.url == original })?.children?
                .first(where: { $0.url == nested })?.children?.contains(where: { $0.url == note }) == true
        }
    }

    @MainActor
    func testFullRescanRefreshesEveryMaterializedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanRescan-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = nested.appendingPathComponent("Existing.md")
        try "# Existing".write(to: existing, atomically: true, encoding: .utf8)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        try await awaitCondition { !model.loadingFiles }
        model.loadExpandedFolders([nested.path])
        try await awaitCondition {
            model.files.first(where: { $0.url == nested })?.children?.contains(where: { $0.url == existing }) == true
        }

        let added = nested.appendingPathComponent("Added.md")
        try "# Added".write(to: added, atomically: true, encoding: .utf8)
        model.noteExternalPaths([], in: root, requiresFullRescan: true)
        try await awaitCondition {
            model.files.first(where: { $0.url == nested })?.children?.contains(where: { $0.url == added }) == true
        }
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
        let externalSource = "# External revision\r\n"
        try externalSource.write(to: note, atomically: true, encoding: .utf8)

        model.noteExternalPaths([note.path], in: root)
        try await awaitCondition { model.draft == "# External revision\n" }
        XCTAssertEqual(model.baseline, model.draft)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), externalSource,
                       "External reload must normalize only the editor projection, not the source file.")
    }

    @MainActor
    func testExternalRenameFollowsCleanOpenNoteAndRebasesNavigation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanExternalRename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldNote = root.appendingPathComponent("Before.md")
        let newNote = root.appendingPathComponent("After.md")
        let content = "# Stable note\n"
        try content.write(to: oldNote, atomically: true, encoding: .utf8)

        let defaults = UserDefaults.standard
        let previousWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        let previousLastOpened = defaults.string(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            NoteNavigationStore.removePath(oldNote, in: root)
            NoteNavigationStore.removePath(newNote, in: root)
            if let previousWorkspace {
                defaults.set(previousWorkspace, forKey: "PKSNotesWorkspace")
            } else {
                defaults.removeObject(forKey: "PKSNotesWorkspace")
            }
            if let previousLastOpened {
                defaults.set(previousLastOpened, forKey: "PKSNotesLastOpenedMarkdown")
            } else {
                defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown")
            }
            try? FileManager.default.removeItem(at: root)
        }

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(oldNote)
        try await awaitCondition {
            model.selected == oldNote && !model.loadingNote && model.draft == content
        }
        model.toggleFavorite()
        XCTAssertTrue(model.selectedIsFavorite)

        // Let the real workspace FSEvents stream settle before the external rename.
        try await Task.sleep(for: .milliseconds(350))
        try FileManager.default.moveItem(at: oldNote, to: newNote)

        try await awaitCondition(
            timeout: .seconds(5),
            message: "The open note and navigation metadata did not follow the external rename."
        ) {
            model.selected?.resolvingSymlinksInPath() == newNote.resolvingSymlinksInPath()
                && !model.loadingNote
                && model.draft == content
        }
        XCTAssertTrue(model.recentNotes.contains(newNote))
        XCTAssertTrue(model.favoriteNotes.contains(newNote))
        XCTAssertFalse(model.favoriteNotes.contains(oldNote))
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(model.message)
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
