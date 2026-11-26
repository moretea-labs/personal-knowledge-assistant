import Foundation
import XCTest
@testable import PKSNotes

private actor VaultJourneyEmptyLibraryProvider: LibrarySearchProviding {
    func search(
        _ query: String,
        mode: String,
        limit: Int,
        excludeURI: String?
    ) async throws -> [SearchHit] {
        []
    }
}

@MainActor
final class VaultSwitchJourneyTests: XCTestCase {
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

    func testSearchOpenEditSaveAndReturnStayWithinSelectedVault() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("Leafspan-Vault-Journey-\(UUID().uuidString)", isDirectory: true)
        let vaultA = base.appendingPathComponent("Vault-A", isDirectory: true)
        let vaultB = base.appendingPathComponent("Vault-B", isDirectory: true)
        let notesA = vaultA.appendingPathComponent("Notes", isDirectory: true)
        let notesB = vaultB.appendingPathComponent("Notes", isDirectory: true)
        try fileManager.createDirectory(at: notesA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: notesB, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let noteA = notesA.appendingPathComponent("Overview.md")
        let noteB = notesB.appendingPathComponent("Overview.md")
        let originalA = "# Overview\nvault-a-only-needle-journey\n"
        let originalB = "# Overview\nvault-b-only-needle-journey\n"
        let editedA = "# Overview\nvault-a-only-needle-journey\nEdited and saved in Vault A.\n"
        try originalA.write(to: noteA, atomically: true, encoding: .utf8)
        try originalB.write(to: noteB, atomically: true, encoding: .utf8)

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
        let previousWorkspaceValues = workspaceKeys.map { defaults.object(forKey: $0) }
        let previousDraftValues = transientDraftKeys.map { defaults.object(forKey: $0) }
        let metadataKeys = ["PKSNotesRecentByWorkspace", "PKSNotesFavoritesByWorkspace"]
        let previousMetadata = metadataKeys.map { key -> [String: Any] in
            let dictionary = defaults.dictionary(forKey: key) ?? [:]
            return [
                vaultA.path: dictionary[vaultA.path] ?? NSNull(),
                vaultB.path: dictionary[vaultB.path] ?? NSNull()
            ]
        }
        defer {
            for (key, value) in zip(workspaceKeys, previousWorkspaceValues) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            for (key, value) in zip(transientDraftKeys, previousDraftValues) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            for (key, previous) in zip(metadataKeys, previousMetadata) {
                var current = defaults.dictionary(forKey: key) ?? [:]
                for root in [vaultA.path, vaultB.path] {
                    if let value = previous[root], !(value is NSNull) {
                        current[root] = value
                    } else {
                        current.removeValue(forKey: root)
                    }
                }
                defaults.set(current, forKey: key)
            }
        }

        defaults.set(vaultA.path, forKey: "PKSNotesWorkspace")
        defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark")
        defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown")
        for key in transientDraftKeys {
            defaults.removeObject(forKey: key)
        }
        _ = NoteNavigationStore.recordRecent(noteA, in: vaultA)
        _ = NoteNavigationStore.toggleFavorite(noteA, in: vaultA)
        _ = NoteNavigationStore.recordRecent(noteB, in: vaultB)
        _ = NoteNavigationStore.toggleFavorite(noteB, in: vaultB)

        let model = NotesModel(libraryProvider: VaultJourneyEmptyLibraryProvider())
        XCTAssertTrue(model.openWorkspace(vaultA))
        XCTAssertEqual(model.recentNotes, [noteA])
        XCTAssertEqual(model.favoriteNotes, [noteA])

        model.query = "vault-a-only-needle-journey"
        model.search()
        try await awaitCondition(message: "Vault A's unique search result was not published.") {
            !model.searching && model.hits.map(\.uri) == [noteA.path]
        }
        let aHit = try XCTUnwrap(model.hits.first)
        model.openNote(URL(fileURLWithPath: aHit.uri))
        try await awaitCondition(message: "Opening the Vault A search result selected the wrong note.") {
            model.selected == noteA && !model.loadingNote && model.draft == originalA
        }

        model.draft = editedA
        XCTAssertTrue(model.isDirty)
        model.save()
        try await awaitCondition(message: "The Vault A edit was not durably saved.") {
            !model.isDirty && (try? String(contentsOf: noteA, encoding: .utf8)) == editedA
        }
        XCTAssertEqual(try String(contentsOf: noteB, encoding: .utf8), originalB)

        XCTAssertTrue(model.openWorkspace(vaultB))
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertEqual(model.recentNotes, [noteB])
        XCTAssertEqual(model.favoriteNotes, [noteB])

        model.query = "vault-a-only-needle-journey"
        model.search()
        try await awaitCondition(message: "Vault B's negative search did not settle.") {
            !model.searching
        }
        XCTAssertTrue(model.hits.isEmpty, "A Vault A-only search hit must not leak into Vault B.")

        model.query = "vault-b-only-needle-journey"
        model.search()
        try await awaitCondition(message: "Vault B's unique search result was not published.") {
            !model.searching && model.hits.map(\.uri) == [noteB.path]
        }
        let bHit = try XCTUnwrap(model.hits.first)
        model.openNote(URL(fileURLWithPath: bHit.uri))
        try await awaitCondition(message: "Opening the Vault B search result selected the wrong note.") {
            model.selected == noteB && !model.loadingNote && model.draft == originalB
        }

        XCTAssertTrue(model.openWorkspace(vaultA))
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertEqual(model.recentNotes, [noteA])
        XCTAssertEqual(model.favoriteNotes, [noteA])
        model.openNote(noteA)
        try await awaitCondition(message: "Returning to Vault A did not restore its saved document.") {
            model.selected == noteA && !model.loadingNote && model.draft == editedA
        }

        XCTAssertEqual(model.documentIdentity, noteA.standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: noteA, encoding: .utf8), editedA)
        XCTAssertEqual(try String(contentsOf: noteB, encoding: .utf8), originalB)
    }
}

