import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import PKSNotes

@MainActor
private final class MarkdownFileDropDraftDelegate: NSObject, NSTextViewDelegate {
    let model: NotesModel

    init(model: NotesModel) {
        self.model = model
    }

    func textDidChange(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView else { return }
        model.draft = editor.string
    }
}

@MainActor
final class MarkdownFileDropSafetyTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let firstNote: URL
        let secondNote: URL
        let droppedFile: URL
        let firstOriginal: String
        let secondOriginal: String
        let droppedContent: String
    }

    private struct DropUI {
        let window: NSWindow
        let scrollView: NSScrollView
        let editor: NSTextView
        let delegate: MarkdownFileDropDraftDelegate
        let target: PDFCitationDropTarget
    }

    private struct DefaultsSnapshot {
        let values: [(String, Any?)]
    }

    private func configureDefaults(for root: URL) -> DefaultsSnapshot {
        let keys = [
            "PKSNotesWorkspace",
            "PKSNotesWorkspaceBookmark",
            "PKSNotesLastOpenedMarkdown",
            "PKSNotesRecentByWorkspace",
            "PKSNotesFavoritesByWorkspace",
            "LeafspanActiveAnonymousDraftID",
            "LeafspanAnonymousDraftFolders",
            "LeafspanAnonymousDraftWorkspaces"
        ]
        let defaults = UserDefaults.standard
        let snapshot = DefaultsSnapshot(values: keys.map { ($0, defaults.object(forKey: $0)) })
        defaults.set(root.path, forKey: "PKSNotesWorkspace")
        for key in keys where key != "PKSNotesWorkspace" {
            defaults.removeObject(forKey: key)
        }
        return snapshot
    }

    private func restoreDefaults(_ snapshot: DefaultsSnapshot) {
        let defaults = UserDefaults.standard
        for (key, value) in snapshot.values {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-File-Drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let firstNote = root.appendingPathComponent("Study.md")
        let secondNote = root.appendingPathComponent("Other.md")
        let droppedFile = root.appendingPathComponent("Reference.pdf")
        let firstOriginal = "# Study\nOriginal source content.\n"
        let secondOriginal = "# Other\nA different note.\n"
        let droppedContent = "Drop source must never be modified."
        try firstOriginal.write(to: firstNote, atomically: true, encoding: .utf8)
        try secondOriginal.write(to: secondNote, atomically: true, encoding: .utf8)
        try droppedContent.write(to: droppedFile, atomically: true, encoding: .utf8)

        return Fixture(
            root: root,
            firstNote: firstNote,
            secondNote: secondNote,
            droppedFile: droppedFile,
            firstOriginal: firstOriginal,
            secondOriginal: secondOriginal,
            droppedContent: droppedContent
        )
    }

    private func waitForNote(
        _ model: NotesModel,
        _ note: URL,
        content: String
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(4))
        while (
            model.selected?.standardizedFileURL != note.standardizedFileURL
                || model.loadingNote
                || model.draft != content
        ) && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.selected?.standardizedFileURL, note.standardizedFileURL)
        XCTAssertFalse(model.loadingNote)
        XCTAssertEqual(model.draft, content)
    }

    private func makeDropUI(note: URL, model: NotesModel) throws -> DropUI {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        scrollView.hasVerticalScroller = true
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 34))
        editor.isVerticallyResizable = false
        editor.isEditable = true
        editor.string = model.draft
        let delegate = MarkdownFileDropDraftDelegate(model: model)
        editor.delegate = delegate
        scrollView.documentView = editor
        window.contentView = scrollView

        // Use the same native editor hit-test and caret snapshot as Finder/PDF drops.
        let blankEditorPoint = NSPoint(x: 140, y: 170)
        let screenPoint = window.convertPoint(
            toScreen: scrollView.convert(blankEditorPoint, to: nil)
        )
        let resolvedEditor = try XCTUnwrap(
            PDFCitationDropTarget.editableTextView(at: screenPoint, in: window)
        )
        let target = try XCTUnwrap(PDFCitationDropTarget(
            screenPoint: screenPoint,
            note: note,
            draftRevision: model.draftRevision,
            textView: resolvedEditor
        ))
        return DropUI(
            window: window,
            scrollView: scrollView,
            editor: editor,
            delegate: delegate,
            target: target
        )
    }

    private func delayedFileProvider(for file: URL, delay: TimeInterval) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                completion(file as NSURL, nil)
                progress.completedUnitCount = 1
            }
            return progress
        }
        return provider
    }

    private func loadFile(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let file = item as? URL {
                    continuation.resume(returning: file)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private func makeModel(for fixture: Fixture) async throws -> NotesModel {
        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(fixture.root))
        model.openNote(fixture.firstNote)
        try await waitForNote(model, fixture.firstNote, content: fixture.firstOriginal)
        return model
    }

    func testFileDropInsertsLinkIntoUnsavedDraftWithoutOverwritingEitherFile() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let defaults = configureDefaults(for: fixture.root)
        defer { restoreDefaults(defaults) }

        let model = try await makeModel(for: fixture)
        let unsavedDraft = "# Study\nOriginal source content.\nMy unsaved analysis stays here.\n"
        model.draft = unsavedDraft
        let ui = try makeDropUI(note: fixture.firstNote, model: model)
        let link = try XCTUnwrap(
            WorkspaceFiles.markdownLinkForDrop(for: fixture.droppedFile, in: fixture.root)
        )

        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(ui.target.insert(
            link,
            currentNote: model.selected,
            currentDraftRevision: model.draftRevision,
            canEdit: true,
            asFileLink: true
        ))

        XCTAssertTrue(model.draft.contains("My unsaved analysis stays here."))
        XCTAssertTrue(model.draft.contains(link))
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(
            try String(contentsOf: fixture.firstNote, encoding: .utf8),
            fixture.firstOriginal,
            "Dropping a file must not replace or prematurely save over the source note."
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.droppedFile, encoding: .utf8),
            fixture.droppedContent,
            "A Finder drag is a link insertion, never a move or copy."
        )

        model.save()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(
            try String(contentsOf: fixture.firstNote, encoding: .utf8),
            model.draft
        )
        XCTAssertTrue(try String(contentsOf: fixture.firstNote, encoding: .utf8).contains(link))
        XCTAssertEqual(
            try String(contentsOf: fixture.droppedFile, encoding: .utf8),
            fixture.droppedContent
        )
    }

    func testDelayedFileDropRejectsAStaleTargetAfterTheDraftChanges() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let defaults = configureDefaults(for: fixture.root)
        defer { restoreDefaults(defaults) }

        let model = try await makeModel(for: fixture)
        let draftAtDropStart = "# Study\nDraft at Finder drop start.\n"
        model.draft = draftAtDropStart
        let ui = try makeDropUI(note: fixture.firstNote, model: model)
        let provider = delayedFileProvider(for: fixture.droppedFile, delay: 0.2)
        XCTAssertTrue(provider.canLoadObject(ofClass: NSURL.self))
        let loadTask = Task { try await loadFile(from: provider) }

        // The user continues editing while NSItemProvider resolves the Finder URL.
        let newestDraft = "# Study\nNewer text typed while the file provider is loading.\n"
        ui.editor.string = newestDraft
        model.draft = newestDraft

        let resolvedFile = try await loadTask.value
        let link = try XCTUnwrap(
            WorkspaceFiles.markdownLinkForDrop(for: resolvedFile, in: fixture.root)
        )
        XCTAssertFalse(ui.target.insert(
            link,
            currentNote: model.selected,
            currentDraftRevision: model.draftRevision,
            canEdit: true,
            asFileLink: true
        ))

        XCTAssertEqual(model.draft, newestDraft)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(
            try String(contentsOf: fixture.firstNote, encoding: .utf8),
            fixture.firstOriginal,
            "A late provider callback must not replace the current unsaved draft."
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.droppedFile, encoding: .utf8),
            fixture.droppedContent
        )

        // Cancel the pending autosave so this regression never writes test state
        // after its assertions or leaks changes into another test's fixture.
        model.draft = fixture.firstOriginal
        XCTAssertFalse(model.isDirty)
    }

    func testDelayedFileDropCannotInsertIntoAnotherNoteAfterNavigation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let defaults = configureDefaults(for: fixture.root)
        defer { restoreDefaults(defaults) }

        let model = try await makeModel(for: fixture)
        let dirtyFirstNote = "# Study\nSaved before leaving during a pending Finder drop.\n"
        model.draft = dirtyFirstNote
        let ui = try makeDropUI(note: fixture.firstNote, model: model)
        let provider = delayedFileProvider(for: fixture.droppedFile, delay: 0.6)
        XCTAssertTrue(provider.canLoadObject(ofClass: NSURL.self))
        let loadTask = Task { try await loadFile(from: provider) }

        model.openNote(fixture.secondNote)
        try await waitForNote(model, fixture.secondNote, content: fixture.secondOriginal)

        let resolvedFile = try await loadTask.value
        let link = try XCTUnwrap(
            WorkspaceFiles.markdownLinkForDrop(for: resolvedFile, in: fixture.root)
        )
        XCTAssertFalse(ui.target.insert(
            link,
            currentNote: model.selected,
            currentDraftRevision: model.draftRevision,
            canEdit: true,
            asFileLink: true
        ))

        XCTAssertEqual(model.selected, fixture.secondNote)
        XCTAssertEqual(model.draft, fixture.secondOriginal)
        XCTAssertFalse(model.draft.contains(link))
        XCTAssertEqual(
            try String(contentsOf: fixture.firstNote, encoding: .utf8),
            dirtyFirstNote,
            "Leaving the original note saves its own draft; a late drop cannot reroute it."
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.secondNote, encoding: .utf8),
            fixture.secondOriginal,
            "A drop started over the first note must never insert into the newly selected note."
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.droppedFile, encoding: .utf8),
            fixture.droppedContent
        )
    }
}
