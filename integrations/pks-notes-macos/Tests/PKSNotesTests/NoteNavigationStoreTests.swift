import Foundation
import XCTest
@testable import PKSNotes

final class NoteNavigationStoreTests: XCTestCase {
    func testRecentAndFavoritesAreWorkspaceScopedAndPathSafe() throws {
        let suite = "PKSNotesTests.Navigation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootA = base.appendingPathComponent("A", isDirectory: true)
        let rootB = base.appendingPathComponent("B", isDirectory: true)
        try fm.createDirectory(at: rootA, withIntermediateDirectories: true)
        try fm.createDirectory(at: rootB, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let a1 = rootA.appendingPathComponent("one.md")
        let a2 = rootA.appendingPathComponent("two.md")
        let b1 = rootB.appendingPathComponent("one.md")
        try "# One".write(to: a1, atomically: true, encoding: .utf8)
        try "# Two".write(to: a2, atomically: true, encoding: .utf8)
        try "# Other".write(to: b1, atomically: true, encoding: .utf8)

        XCTAssertEqual(NoteNavigationStore.recordRecent(a1, in: rootA, defaults: defaults), [a1])
        XCTAssertEqual(NoteNavigationStore.recordRecent(a2, in: rootA, defaults: defaults), [a2, a1])
        XCTAssertEqual(NoteNavigationStore.recordRecent(a1, in: rootA, defaults: defaults), [a1, a2])
        XCTAssertTrue(NoteNavigationStore.recent(in: rootB, defaults: defaults).isEmpty)

        XCTAssertEqual(NoteNavigationStore.toggleFavorite(a2, in: rootA, defaults: defaults), [a2])
        XCTAssertEqual(NoteNavigationStore.favorites(in: rootA, defaults: defaults), [a2])
        XCTAssertTrue(NoteNavigationStore.favorites(in: rootB, defaults: defaults).isEmpty)
    }

    func testRenameMoveAndTrashRebaseNavigationMetadata() throws {
        let suite = "PKSNotesTests.Navigation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let oldFolder = root.appendingPathComponent("Old", isDirectory: true)
        let newFolder = root.appendingPathComponent("New", isDirectory: true)
        try fm.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let oldNote = oldFolder.appendingPathComponent("note.md")
        try "# Note".write(to: oldNote, atomically: true, encoding: .utf8)
        _ = NoteNavigationStore.recordRecent(oldNote, in: root, defaults: defaults)
        _ = NoteNavigationStore.toggleFavorite(oldNote, in: root, defaults: defaults)

        try fm.moveItem(at: oldFolder, to: newFolder)
        NoteNavigationStore.replacePath(oldFolder, with: newFolder, in: root, defaults: defaults)
        let newNote = newFolder.appendingPathComponent("note.md")
        XCTAssertEqual(NoteNavigationStore.recent(in: root, defaults: defaults), [newNote])
        XCTAssertEqual(NoteNavigationStore.favorites(in: root, defaults: defaults), [newNote])

        NoteNavigationStore.removePath(newFolder, in: root, defaults: defaults)
        XCTAssertTrue(NoteNavigationStore.recent(in: root, defaults: defaults).isEmpty)
        XCTAssertTrue(NoteNavigationStore.favorites(in: root, defaults: defaults).isEmpty)
    }

    func testRecentListIsBounded() throws {
        let suite = "PKSNotesTests.Navigation.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        for index in 0..<(NoteNavigationStore.recentLimit + 4) {
            let note = root.appendingPathComponent("\(index).md")
            try "# \(index)".write(to: note, atomically: true, encoding: .utf8)
            _ = NoteNavigationStore.recordRecent(note, in: root, defaults: defaults)
        }

        let recent = NoteNavigationStore.recent(in: root, defaults: defaults)
        XCTAssertEqual(recent.count, NoteNavigationStore.recentLimit)
        XCTAssertEqual(recent.first?.lastPathComponent, "\(NoteNavigationStore.recentLimit + 3).md")
    }
}
