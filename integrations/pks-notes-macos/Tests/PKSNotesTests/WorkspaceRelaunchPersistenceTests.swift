import Foundation
import XCTest
@testable import PKSNotes

@MainActor
final class WorkspaceRelaunchPersistenceTests: XCTestCase {
    private func awaitCondition(
        timeout: Duration = .seconds(4),
        message: String,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message)
    }

    func testRelaunchRestoresActiveVaultLastNoteAndNavigationAfterSavingMultipleNotes() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("Leafspan-Relaunch-\(UUID().uuidString)", isDirectory: true)
        let vaultA = base.appendingPathComponent("Vault-A", isDirectory: true)
        let vaultB = base.appendingPathComponent("Vault-B", isDirectory: true)
        let notesA = vaultA.appendingPathComponent("Notes", isDirectory: true)
        let notesB = vaultB.appendingPathComponent("Notes", isDirectory: true)
        try fileManager.createDirectory(at: notesA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: notesB, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let overview = notesA.appendingPathComponent("Overview.md")
        let research = notesA.appendingPathComponent("Research.md")
        let sameNameInOtherVault = notesB.appendingPathComponent("Research.md")
        let originalOverview = "# Overview\nOriginal A overview.\n"
        let editedOverview = "# Overview\nSaved before navigating to another note.\n"
        let originalResearch = "# Research\nOriginal A research.\n"
        let editedResearch = "# Research\nSaved when the app closes.\n"
        let otherVaultResearch = "# Research\nVault B must remain untouched.\n"
        try originalOverview.write(to: overview, atomically: true, encoding: .utf8)
        try originalResearch.write(to: research, atomically: true, encoding: .utf8)
        try otherVaultResearch.write(to: sameNameInOtherVault, atomically: true, encoding: .utf8)

        let defaults = UserDefaults.standard
        let workspaceKeys = [
            "PKSNotesWorkspace",
            "PKSNotesWorkspaceBookmark",
            "PKSNotesLastOpenedMarkdown"
        ]
        let transientDraftKeys = [
            "LeafspanActiveAnonymousDraftID",
            "LeafspanAnonymousDraftFolders",
            "LeafspanAnonymousDraftWorkspaces"
        ]
        let navigationKeys = [
            "PKSNotesRecentByWorkspace",
            "PKSNotesFavoritesByWorkspace"
        ]
        let allKeys = workspaceKeys + transientDraftKeys + navigationKeys
        let savedValues = allKeys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(allKeys, savedValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        defaults.set(vaultA.path, forKey: "PKSNotesWorkspace")
        defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark")
        defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown")
        for key in transientDraftKeys {
            defaults.removeObject(forKey: key)
        }

        // First launch: open and edit two notes. Navigating away must durably save
        // the first note; normal close must durably save the last active note.
        do {
            let firstLaunch = NotesModel()
            XCTAssertEqual(firstLaunch.root?.standardizedFileURL, vaultA.standardizedFileURL)

            firstLaunch.openNote(overview)
            try await awaitCondition(message: "The first Vault A note did not open.") {
                firstLaunch.selected?.standardizedFileURL == overview.standardizedFileURL
                    && !firstLaunch.loadingNote
                    && firstLaunch.draft == originalOverview
            }
            firstLaunch.toggleFavorite(overview)
            firstLaunch.draft = editedOverview
            XCTAssertTrue(firstLaunch.isDirty)

            firstLaunch.openNote(research)
            try await awaitCondition(message: "The second Vault A note did not open.") {
                firstLaunch.selected?.standardizedFileURL == research.standardizedFileURL
                    && !firstLaunch.loadingNote
                    && firstLaunch.draft == originalResearch
            }
            XCTAssertEqual(
                try String(contentsOf: overview, encoding: .utf8),
                editedOverview,
                "Leaving a dirty note must save it before the next document becomes active."
            )

            firstLaunch.draft = editedResearch
            XCTAssertTrue(firstLaunch.isDirty)
            XCTAssertTrue(firstLaunch.confirmClosingNote(),
                          "A normal close must finish saving the active named note.")
            XCTAssertEqual(
                try String(contentsOf: research, encoding: .utf8),
                editedResearch
            )
        }

        XCTAssertEqual(defaults.string(forKey: "PKSNotesWorkspace"), vaultA.path)
        XCTAssertEqual(defaults.string(forKey: "PKSNotesLastOpenedMarkdown"), research.path)
        XCTAssertEqual(NoteNavigationStore.recent(in: vaultA), [research, overview])
        XCTAssertEqual(NoteNavigationStore.favorites(in: vaultA), [overview])
        XCTAssertEqual(
            try String(contentsOf: sameNameInOtherVault, encoding: .utf8),
            otherVaultResearch,
            "A same-name note in another Vault must not receive either saved draft."
        )

        // A new model instance represents a fresh app process. It must restore
        // the selected Vault and its last note, not a same-name path in another Vault.
        let relaunched = NotesModel()
        try await awaitCondition(message: "Relaunch did not restore the active Vault and last note.") {
            relaunched.root?.standardizedFileURL == vaultA.standardizedFileURL
                && relaunched.selected?.standardizedFileURL == research.standardizedFileURL
                && !relaunched.loadingNote
                && relaunched.draft == editedResearch
        }

        XCTAssertEqual(relaunched.documentIdentity, research.standardizedFileURL.path)
        XCTAssertEqual(relaunched.recentNotes, [research, overview])
        XCTAssertEqual(relaunched.favoriteNotes, [overview])
        XCTAssertEqual(
            try String(contentsOf: overview, encoding: .utf8),
            editedOverview
        )
        XCTAssertEqual(
            try String(contentsOf: research, encoding: .utf8),
            editedResearch
        )
        XCTAssertEqual(
            try String(contentsOf: sameNameInOtherVault, encoding: .utf8),
            otherVaultResearch
        )
    }
}
