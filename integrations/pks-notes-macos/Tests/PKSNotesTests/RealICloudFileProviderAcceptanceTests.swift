import Foundation
import XCTest
@testable import PKSNotes

/// Opt-in integration coverage for the real macOS File Provider domain.
/// It creates one UUID-scoped folder inside the configured iCloud vault and
/// removes only that folder after the test. Normal CI runs skip this test.
final class RealICloudFileProviderAcceptanceTests: XCTestCase {
    @MainActor
    func testDatalessMarkdownRenameFolderCopyMoveAndPDFMovePreserveLinks() async throws {
        guard ProcessInfo.processInfo.environment["PKS_NOTES_RUN_REAL_ICLOUD_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set PKS_NOTES_RUN_REAL_ICLOUD_ACCEPTANCE=1 to run against the real iCloud File Provider.")
        }

        let defaults = UserDefaults.standard
        let previousWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        let previousNote = defaults.string(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let previousWorkspace { defaults.set(previousWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousNote { defaults.set(previousNote, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }

        let fileManager = FileManager.default
        let vault = WorkspaceFiles.defaultVault()
        guard fileManager.fileExists(atPath: vault.path) else {
            throw XCTSkip("The configured iCloud Notes vault is not available on this Mac.")
        }

        let root = vault.appendingPathComponent(
            "PKS Notes Forge QA \(UUID().uuidString)",
            isDirectory: true
        )
        XCTAssertFalse(fileManager.fileExists(atPath: root.path))
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: root) }

        guard fileManager.isUbiquitousItem(at: root) else {
            throw XCTSkip("The configured Notes vault is not currently managed by iCloud File Provider.")
        }

        let source = root.appendingPathComponent("Source.md")
        let pdf = root.appendingPathComponent("Book.pdf")
        let reader = root.appendingPathComponent("Reading.md")
        let cloudFolder = root.appendingPathComponent("Cloud Folder", isDirectory: true)
        let deepFolder = cloudFolder.appendingPathComponent("Deep", isDirectory: true)
        let sibling = cloudFolder.appendingPathComponent("Other.md")
        let cloudNote = deepFolder.appendingPathComponent("Cloud.md")
        try "# Source\n[Self](Source.md)\n".write(to: source, atomically: true, encoding: .utf8)
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: pdf)
        try "# Reading\n[Book · p. 5](/Book.pdf#page=5)\n".write(
            to: reader,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.createDirectory(at: deepFolder, withIntermediateDirectories: true)
        try "# Other\n".write(to: sibling, atomically: true, encoding: .utf8)
        try """
        # Cloud
        [Sibling](../Other.md)
        [Root sibling](/Cloud Folder/Other.md)
        [Renamed source](../../Renamed.md)
        """.write(to: cloudNote, atomically: true, encoding: .utf8)

        guard fileManager.isUbiquitousItem(at: source),
              fileManager.isUbiquitousItem(at: pdf),
              fileManager.isUbiquitousItem(at: cloudNote) else {
            throw XCTSkip("The test files have not entered the iCloud File Provider domain.")
        }
        let uploadDeadline = ProcessInfo.processInfo.systemUptime + 180
        try await waitForICloudUpload(source, until: uploadDeadline)
        try await waitForICloudUpload(pdf, until: uploadDeadline)
        try await waitForICloudUpload(cloudNote, until: uploadDeadline)

        try fileManager.evictUbiquitousItem(at: source)
        try await waitForDatalessPlaceholder(source)
        XCTAssertTrue(WorkspaceFiles.isDataless(source), "The Markdown fixture must be a real dataless placeholder.")
        try fileManager.evictUbiquitousItem(at: cloudNote)
        try await waitForDatalessPlaceholder(cloudNote)
        XCTAssertTrue(WorkspaceFiles.isDataless(cloudNote), "The nested Markdown fixture must be a real dataless placeholder.")

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        for _ in 0..<400 where model.loadingFiles {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.loadingFiles)

        let renamedResult = await model.renameItem(source, to: "Renamed")
        let renamed = try XCTUnwrap(renamedResult)
        XCTAssertEqual(renamed.lastPathComponent, "Renamed.md")
        XCTAssertFalse(WorkspaceFiles.isDataless(renamed), "Rename must hydrate the Markdown source before reading and rewriting it.")
        let renamedContent = try String(contentsOf: renamed, encoding: .utf8)
        let expectedSelfTarget = try XCTUnwrap(
            WorkspaceFiles.canonicalLinkTarget(for: renamed, in: root)
        )
        XCTAssertTrue(renamedContent.contains("(\(expectedSelfTarget))"))
        XCTAssertFalse(renamedContent.contains("(Source.md)"))

        let copies = root.appendingPathComponent("Copies", isDirectory: true)
        try fileManager.createDirectory(at: copies, withIntermediateDirectories: false)

        let copiedFolderResult = await model.copyItem(cloudFolder, to: copies)
        let copiedFolder = try XCTUnwrap(copiedFolderResult, model.message ?? "Folder copy failed.")
        let copiedCloudNote = copiedFolder
            .appendingPathComponent("Deep", isDirectory: true)
            .appendingPathComponent("Cloud.md")
        let copiedSibling = copiedFolder.appendingPathComponent("Other.md")
        XCTAssertFalse(WorkspaceFiles.isDataless(cloudNote), "Folder copy must hydrate nested cloud-only Markdown before link repair.")
        let copiedContent = try String(contentsOf: copiedCloudNote, encoding: .utf8)
        let expectedCopiedSiblingTarget = try XCTUnwrap(
            WorkspaceFiles.canonicalLinkTarget(for: copiedSibling, in: root)
        )
        let expectedRenamedTarget = try XCTUnwrap(
            WorkspaceFiles.canonicalLinkTarget(for: renamed, in: root)
        )
        XCTAssertTrue(copiedContent.contains("](../Other.md)"))
        XCTAssertTrue(copiedContent.contains("](\(expectedCopiedSiblingTarget))"))
        XCTAssertTrue(copiedContent.contains("](\(expectedRenamedTarget))"))

        let folderArchive = root.appendingPathComponent("Folder Archive", isDirectory: true)
        try fileManager.createDirectory(at: folderArchive, withIntermediateDirectories: false)
        try fileManager.evictUbiquitousItem(at: cloudNote)
        try await waitForDatalessPlaceholder(cloudNote)
        XCTAssertTrue(WorkspaceFiles.isDataless(cloudNote), "The nested Markdown fixture must be dataless before folder move.")
        let movedFolderResult = await model.moveItem(cloudFolder, to: folderArchive)
        let movedFolder = try XCTUnwrap(movedFolderResult, model.message ?? "Folder move failed.")
        let movedCloudNote = movedFolder
            .appendingPathComponent("Deep", isDirectory: true)
            .appendingPathComponent("Cloud.md")
        let movedSibling = movedFolder.appendingPathComponent("Other.md")
        XCTAssertFalse(WorkspaceFiles.isDataless(movedCloudNote), "Folder move must hydrate nested cloud-only Markdown before link repair.")
        let movedContent = try String(contentsOf: movedCloudNote, encoding: .utf8)
        let expectedMovedSiblingTarget = try XCTUnwrap(
            WorkspaceFiles.canonicalLinkTarget(for: movedSibling, in: root)
        )
        XCTAssertTrue(movedContent.contains("](../Other.md)"))
        XCTAssertTrue(movedContent.contains("](\(expectedMovedSiblingTarget))"))
        XCTAssertTrue(movedContent.contains("](\(expectedRenamedTarget))"))

        try fileManager.evictUbiquitousItem(at: pdf)
        try await waitForDatalessPlaceholder(pdf)
        XCTAssertTrue(WorkspaceFiles.isDataless(pdf), "The PDF fixture must be a real dataless placeholder before copy.")

        let copiedPDFResult = await model.copyItem(pdf, to: copies)
        let copiedPDF = try XCTUnwrap(copiedPDFResult)
        XCTAssertEqual(copiedPDF.standardizedFileURL, copies.appendingPathComponent("Book.pdf").standardizedFileURL)
        XCTAssertFalse(WorkspaceFiles.isDataless(pdf), "Copy must hydrate the original PDF before reading its contents.")
        XCTAssertFalse(WorkspaceFiles.isDataless(copiedPDF), "The copied PDF must contain materialized bytes.")
        XCTAssertEqual(try Data(contentsOf: copiedPDF), Data("%PDF-1.4\n%%EOF".utf8))

        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: false)
        try fileManager.evictUbiquitousItem(at: pdf)
        try await waitForDatalessPlaceholder(pdf)
        XCTAssertTrue(WorkspaceFiles.isDataless(pdf), "The PDF fixture must be a real dataless placeholder before move.")

        let movedPDFResult = await model.moveItem(pdf, to: archive)
        let movedPDF = try XCTUnwrap(movedPDFResult)
        XCTAssertEqual(movedPDF.standardizedFileURL, archive.appendingPathComponent("Book.pdf").standardizedFileURL)
        XCTAssertTrue(fileManager.fileExists(atPath: movedPDF.path))

        let readerContent = try String(contentsOf: reader, encoding: .utf8)
        let expectedPDFTarget = try XCTUnwrap(
            WorkspaceFiles.canonicalLinkTarget(for: movedPDF, in: root)
        )
        XCTAssertTrue(readerContent.contains("(\(expectedPDFTarget)#page=5)"))
        XCTAssertFalse(readerContent.contains("(/Book.pdf#page=5)"))
    }

    @MainActor
    func testUnreadableLastOpenedNoteKeepsRetryablePath() async throws {
        let fileManager = FileManager.default
        let defaults = UserDefaults.standard
        let previousWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        let previousNote = defaults.string(forKey: "PKSNotesLastOpenedMarkdown")
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "PKS Notes Last Opened QA \\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            try? fileManager.removeItem(at: root)
            if let previousWorkspace { defaults.set(previousWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousNote { defaults.set(previousNote, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }

        let note = root.appendingPathComponent("Unreadable.md")
        try Data([0xFF, 0xFE, 0xFD]).write(to: note)
        defaults.set(note.path, forKey: "PKSNotesLastOpenedMarkdown")

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        for _ in 0..<400 where model.loadingNote {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(model.loadingNote)
        XCTAssertNil(model.selected)
        XCTAssertEqual(defaults.string(forKey: "PKSNotesLastOpenedMarkdown"), note.path)
        XCTAssertTrue(
            model.message?.contains(
                AppLanguage.current.text("Could not reopen the last note. Select it again to retry.")
            ) == true
        )
    }

    @MainActor
    func testFolderMoveAndCopyAbortWhenInternalMarkdownCannotBeRead() async throws {
        let fileManager = FileManager.default
        let defaults = UserDefaults.standard
        let previousWorkspace = defaults.string(forKey: "PKSNotesWorkspace")
        let previousNote = defaults.string(forKey: "PKSNotesLastOpenedMarkdown")
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "PKS Notes Folder Relocation QA \\(UUID().uuidString)",
            isDirectory: true
        )
        let source = root.appendingPathComponent("Bundle", isDirectory: true)
        let copies = root.appendingPathComponent("Copies", isDirectory: true)
        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: copies, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: false)
        defer {
            try? fileManager.removeItem(at: root)
            if let previousWorkspace { defaults.set(previousWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousNote { defaults.set(previousNote, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }

        defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown")
        let unreadable = source.appendingPathComponent("Unreadable.md")
        try Data([0xFF, 0xFE, 0xFD]).write(to: unreadable)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))

        let copied = await model.copyItem(source, to: copies)
        XCTAssertNil(copied)
        XCTAssertTrue(fileManager.fileExists(atPath: unreadable.path))
        XCTAssertFalse(fileManager.fileExists(atPath: copies.appendingPathComponent("Bundle").path))
        XCTAssertTrue(
            model.message?.contains(AppLanguage.current.text("Could not prepare file operation")) == true
        )

        let moved = await model.moveItem(source, to: archive)
        XCTAssertNil(moved)
        XCTAssertTrue(fileManager.fileExists(atPath: unreadable.path))
        XCTAssertFalse(fileManager.fileExists(atPath: archive.appendingPathComponent("Bundle").path))
        XCTAssertTrue(
            model.message?.contains(AppLanguage.current.text("Could not prepare path change")) == true
        )
    }

}

private func waitForICloudUpload(_ url: URL, until deadline: TimeInterval) async throws {
    while ProcessInfo.processInfo.systemUptime < deadline {
        try Task.checkCancellation()
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey])
        if values?.ubiquitousItemIsUploaded == true { return }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw XCTSkip("iCloud did not finish uploading the isolated fixtures within the shared 180-second deadline.")
}

private func waitForDatalessPlaceholder(_ url: URL) async throws {
    for _ in 0..<120 {
        try Task.checkCancellation()
        if WorkspaceFiles.isDataless(url) { return }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw XCTSkip("File Provider did not evict the isolated fixture within 30 seconds.")
}
