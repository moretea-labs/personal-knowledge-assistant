import Foundation
import XCTest
@testable import PKSNotes

private actor RelationshipJourneyEmptyLibraryProvider: LibrarySearchProviding {
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
final class RelationshipGraphJourneyTests: XCTestCase {
    private func awaitCondition(
        timeout: Duration = .seconds(5),
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

    func testBacklinkMoveAndMindMapReturnResolveTheSameTarget() async throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("Leafspan-Relationship-Journey-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        let docs = root.appendingPathComponent("Docs", isDirectory: true)
        let references = root.appendingPathComponent("References", isDirectory: true)
        let mapFolder = root.appendingPathComponent("Map", isDirectory: true)
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        let decoyFolder = root.appendingPathComponent("Decoy", isDirectory: true)
        for folder in [docs, references, mapFolder, archive, decoyFolder] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: base) }

        let target = docs.appendingPathComponent("Target.md")
        let movedTarget = archive.appendingPathComponent("Target.md")
        let source = references.appendingPathComponent("Source.md")
        let mapNote = mapFolder.appendingPathComponent("Study.md")
        let decoy = decoyFolder.appendingPathComponent("Target.md")

        let targetContents = "# Target\n## Intro\nCanonical target body.\n"
        let sourceContents = "# Source\n[Target](../Docs/Target.md#Intro)\n"
        let mapContents = "# Study\n- Reading\n  [Target](../Docs/Target.md#Intro)\n- Keep\n"
        let decoyContents = "# Different target\nThis is not the linked file.\n"
        try targetContents.write(to: target, atomically: true, encoding: .utf8)
        try sourceContents.write(to: source, atomically: true, encoding: .utf8)
        try mapContents.write(to: mapNote, atomically: true, encoding: .utf8)
        try decoyContents.write(to: decoy, atomically: true, encoding: .utf8)

        let defaults = UserDefaults.standard
        let workspaceKeys = [
            "PKSNotesWorkspace",
            "PKSNotesWorkspaceBookmark",
            "PKSNotesLastOpenedMarkdown"
        ]
        let previousWorkspaceValues = workspaceKeys.map { defaults.object(forKey: $0) }
        let metadataKeys = ["PKSNotesRecentByWorkspace", "PKSNotesFavoritesByWorkspace"]
        let previousMetadata = metadataKeys.map { defaults.dictionary(forKey: $0)?[root.path] }
        defer {
            for (key, value) in zip(workspaceKeys, previousWorkspaceValues) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            for (key, previous) in zip(metadataKeys, previousMetadata) {
                var current = defaults.dictionary(forKey: key) ?? [:]
                if let previous { current[root.path] = previous }
                else { current.removeValue(forKey: root.path) }
                defaults.set(current, forKey: key)
            }
        }

        let model = NotesModel(libraryProvider: RelationshipJourneyEmptyLibraryProvider())
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(target)
        try await awaitCondition(message: "The initial target note did not open.") {
            model.selected == target.standardizedFileURL && !model.loadingNote
        }

        model.loadRelationships()
        try await awaitCondition(message: "Initial target backlinks did not finish scanning.") {
            !model.loadingBacklinks
        }
        let initialBacklinkSources = Set(model.backlinks.map { $0.source.standardizedFileURL })
        XCTAssertEqual(
            initialBacklinkSources,
            Set([source.standardizedFileURL, mapNote.standardizedFileURL]),
            "Both the ordinary note and the Mind Map note must appear as backlinks."
        )

        let sourceBacklink = try XCTUnwrap(
            model.backlinks.first { $0.source.standardizedFileURL == source.standardizedFileURL }
        )
        XCTAssertEqual(sourceBacklink.count, 1)
        model.openNote(sourceBacklink.source)
        try await awaitCondition(message: "Opening the target's backlink did not select its source note.") {
            model.selected == source.standardizedFileURL && !model.loadingNote
        }
        XCTAssertEqual(model.draft, sourceContents)
        XCTAssertTrue(model.openKnowledgeLink("../Docs/Target.md#Intro"))
        try await awaitCondition(message: "Following the original outgoing link did not return to the target.") {
            model.selected == target.standardizedFileURL && !model.loadingNote
        }

        model.openNote(source)
        try await awaitCondition(message: "The source note did not reopen before target relocation.") {
            model.selected == source.standardizedFileURL && !model.loadingNote
        }
        let moveResult = await model.moveItem(target, to: archive)
        XCTAssertEqual(moveResult, movedTarget.standardizedFileURL)
        XCTAssertFalse(fileManager.fileExists(atPath: target.path))
        XCTAssertTrue(fileManager.fileExists(atPath: movedTarget.path))

        let canonical = try XCTUnwrap(
            WorkspaceFiles.canonicalLinkTarget(for: movedTarget, in: root)
        )
        let relocatedSourceContents = "# Source\n[Target](\(canonical)#Intro)\n"
        let relocatedMapContents = "# Study\n- Reading\n  [Target](\(canonical)#Intro)\n- Keep\n"
        XCTAssertEqual(
            try String(contentsOf: source, encoding: .utf8),
            relocatedSourceContents
        )
        XCTAssertEqual(
            try String(contentsOf: mapNote, encoding: .utf8),
            relocatedMapContents
        )
        XCTAssertEqual(try String(contentsOf: movedTarget, encoding: .utf8), targetContents)
        XCTAssertEqual(try String(contentsOf: decoy, encoding: .utf8), decoyContents)

        model.openNote(movedTarget)
        try await awaitCondition(message: "The relocated target did not reopen.") {
            model.selected == movedTarget.standardizedFileURL && !model.loadingNote
        }
        model.loadRelationships()
        try await awaitCondition(message: "Relocated target backlinks did not refresh.") {
            !model.loadingBacklinks
        }
        let relocatedBacklinkSources = Set(model.backlinks.map { $0.source.standardizedFileURL })
        XCTAssertEqual(
            relocatedBacklinkSources,
            Set([source.standardizedFileURL, mapNote.standardizedFileURL]),
            "Both relationships must still resolve to the relocated target."
        )

        let relocatedSourceBacklink = try XCTUnwrap(
            model.backlinks.first { $0.source.standardizedFileURL == source.standardizedFileURL }
        )
        model.openNote(relocatedSourceBacklink.source)
        try await awaitCondition(message: "The relocated target's backlink did not reopen its source.") {
            model.selected == source.standardizedFileURL && !model.loadingNote
        }
        XCTAssertTrue(model.openKnowledgeLink("\(canonical)#Intro"))
        try await awaitCondition(message: "The repaired source link did not reopen the relocated target.") {
            model.selected == movedTarget.standardizedFileURL && !model.loadingNote
        }

        model.openNote(mapNote)
        try await awaitCondition(message: "The Mind Map source note did not reopen.") {
            model.selected == mapNote.standardizedFileURL && !model.loadingNote
        }
        let nodes = MindMapOutline.nodes(in: model.draft)
        let reading = try XCTUnwrap(nodes.first { $0.title == "Reading" })
        let presentation = try XCTUnwrap(
            MindMapOutline.presentations(in: model.draft, nodes: nodes)[reading.id]
        )
        XCTAssertEqual(presentation.links.map(\.target), ["\(canonical)#Intro"])
        XCTAssertTrue(model.openKnowledgeLink(try XCTUnwrap(presentation.links.first?.target)))
        try await awaitCondition(message: "Following the Mind Map relationship did not reopen the same relocated target.") {
            model.selected == movedTarget.standardizedFileURL && !model.loadingNote
        }

        XCTAssertEqual(try String(contentsOf: movedTarget, encoding: .utf8), targetContents)
        XCTAssertEqual(try String(contentsOf: decoy, encoding: .utf8), decoyContents)
        XCTAssertFalse(fileManager.fileExists(atPath: target.path))
    }

    func testBacklinkCyclesRepeatedLinksAndSelfLinksStayStableAcrossRefresh() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("Leafspan-REL-07-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let noteA = root.appendingPathComponent("A.md")
        let noteB = root.appendingPathComponent("B.md")
        let noteAContents = """
        # A
        [B](B.md)
        [B again](B.md)
        [Self](A.md)
        """
        let noteBContents = """
        # B
        [A](A.md)
        [A again](A.md)
        """
        try noteAContents.write(to: noteA, atomically: true, encoding: .utf8)
        try noteBContents.write(to: noteB, atomically: true, encoding: .utf8)

        let defaults = UserDefaults.standard
        let workspaceKeys = [
            "PKSNotesWorkspace",
            "PKSNotesWorkspaceBookmark",
            "PKSNotesLastOpenedMarkdown"
        ]
        let previousWorkspaceValues = workspaceKeys.map { defaults.object(forKey: $0) }
        let metadataKeys = ["PKSNotesRecentByWorkspace", "PKSNotesFavoritesByWorkspace"]
        let previousMetadata = metadataKeys.map { defaults.dictionary(forKey: $0)?[root.path] }
        defer {
            for (key, value) in zip(workspaceKeys, previousWorkspaceValues) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            for (key, previous) in zip(metadataKeys, previousMetadata) {
                var current = defaults.dictionary(forKey: key) ?? [:]
                if let previous { current[root.path] = previous }
                else { current.removeValue(forKey: root.path) }
                defaults.set(current, forKey: key)
            }
        }

        let model = NotesModel(libraryProvider: RelationshipJourneyEmptyLibraryProvider())
        XCTAssertTrue(model.openWorkspace(root))
        model.openNote(noteA)
        try await awaitCondition(message: "A did not open for the cyclic relationship fixture.") {
            model.selected == noteA.standardizedFileURL && !model.loadingNote
        }

        model.loadRelationships()
        try await awaitCondition(message: "A backlinks did not finish scanning the A ↔ B cycle.") {
            !model.loadingBacklinks
        }
        XCTAssertEqual(model.backlinks.map { $0.source.standardizedFileURL }, [noteB.standardizedFileURL])
        let backlinkToA = try XCTUnwrap(model.backlinks.first)
        XCTAssertEqual(backlinkToA.count, 2, "Repeated links from B must remain occurrence-counted.")
        XCTAssertEqual(backlinkToA.locations.map(\.lineIndex), [1, 2])
        XCTAssertFalse(
            model.backlinks.contains { $0.source.standardizedFileURL == noteA.standardizedFileURL },
            "A self-link must not create a self-backlink."
        )

        model.openNote(noteB)
        try await awaitCondition(message: "B did not open for the reverse side of the cycle.") {
            model.selected == noteB.standardizedFileURL && !model.loadingNote
        }
        model.loadRelationships()
        try await awaitCondition(message: "B backlinks did not finish scanning the reverse cycle.") {
            !model.loadingBacklinks
        }
        XCTAssertEqual(model.backlinks.map { $0.source.standardizedFileURL }, [noteA.standardizedFileURL])
        let backlinkToB = try XCTUnwrap(model.backlinks.first)
        XCTAssertEqual(backlinkToB.count, 2)
        XCTAssertEqual(backlinkToB.locations.map(\.lineIndex), [1, 2])
        XCTAssertFalse(
            model.backlinks.contains { $0.source.standardizedFileURL == noteB.standardizedFileURL },
            "B self-links must not create self-backlinks."
        )

        for iteration in 0..<6 {
            let target = iteration.isMultiple(of: 2) ? noteA : noteB
            let expectedSource = iteration.isMultiple(of: 2) ? noteB : noteA
            model.openNote(target)
            try await awaitCondition(message: "Relationship target did not switch during repeated refresh.") {
                model.selected == target.standardizedFileURL && !model.loadingNote
            }
            model.loadRelationships()
            try await awaitCondition(message: "Repeated relationship refresh did not finish.") {
                !model.loadingBacklinks
            }
            XCTAssertEqual(
                model.backlinks.map { $0.source.standardizedFileURL },
                [expectedSource.standardizedFileURL],
                "Switching targets must not accumulate duplicate backlink rows."
            )
            XCTAssertEqual(model.backlinks.first?.count, 2)
        }

        let updatedBContents = noteBContents + "\n[Another link to A](A.md)\n"
        try updatedBContents.write(to: noteB, atomically: true, encoding: .utf8)
        model.openNote(noteA)
        try await awaitCondition(message: "A did not reopen after the external backlink edit.") {
            model.selected == noteA.standardizedFileURL && !model.loadingNote
        }
        model.loadRelationships()
        try await awaitCondition(message: "Backlinks did not refresh after B changed on disk.") {
            !model.loadingBacklinks
        }
        XCTAssertEqual(model.backlinks.map { $0.source.standardizedFileURL }, [noteB.standardizedFileURL])
        XCTAssertEqual(
            model.backlinks.first?.count,
            3,
            "A refreshed scan must observe the new occurrence without duplicating the source row."
        )
    }
}
