import Foundation
import XCTest
@testable import PKSNotes

/// Opt-in integration coverage for the real macOS File Provider domain.
/// It creates one UUID-scoped folder inside the configured iCloud vault and
/// removes only that folder after the test. Normal CI runs skip this test.
final class RealICloudFileProviderAcceptanceTests: XCTestCase {
    @MainActor
    func testDatalessMarkdownRenameAndPDFMovePreserveLinks() async throws {
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
        try "# Source\n[Self](Source.md)\n".write(to: source, atomically: true, encoding: .utf8)
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: pdf)
        try "# Reading\n[Book · p. 5](/Book.pdf#page=5)\n".write(
            to: reader,
            atomically: true,
            encoding: .utf8
        )

        guard fileManager.isUbiquitousItem(at: source),
              fileManager.isUbiquitousItem(at: pdf) else {
            throw XCTSkip("The test files have not entered the iCloud File Provider domain.")
        }
        try await waitForICloudUpload(source)
        try await waitForICloudUpload(pdf)

        try fileManager.evictUbiquitousItem(at: source)
        try await waitForDatalessPlaceholder(source)
        XCTAssertTrue(WorkspaceFiles.isDataless(source), "The Markdown fixture must be a real dataless placeholder.")

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

        let archive = root.appendingPathComponent("Archive", isDirectory: true)
        try fileManager.createDirectory(at: archive, withIntermediateDirectories: false)
        try fileManager.evictUbiquitousItem(at: pdf)
        try await waitForDatalessPlaceholder(pdf)
        XCTAssertTrue(WorkspaceFiles.isDataless(pdf), "The PDF fixture must be a real dataless placeholder.")

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

}

private func waitForICloudUpload(_ url: URL) async throws {
    for _ in 0..<240 {
        try Task.checkCancellation()
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey])
        if values?.ubiquitousItemIsUploaded == true { return }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw XCTSkip("iCloud did not finish uploading the isolated fixture within 60 seconds.")
}

private func waitForDatalessPlaceholder(_ url: URL) async throws {
    for _ in 0..<120 {
        try Task.checkCancellation()
        if WorkspaceFiles.isDataless(url) { return }
        try await Task.sleep(for: .milliseconds(250))
    }
    throw XCTSkip("File Provider did not evict the isolated fixture within 30 seconds.")
}
