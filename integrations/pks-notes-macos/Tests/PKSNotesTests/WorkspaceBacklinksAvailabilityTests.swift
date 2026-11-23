import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PKSNotes

@MainActor
final class WorkspaceBacklinksAvailabilityTests: XCTestCase {
    func testPDFLinkedNotesReportUnreadableMarkdownWithoutHidingReadableBacklinks() async throws {
        let defaults = UserDefaults.standard
        let previousWorkspace = defaults.object(forKey: "PKSNotesWorkspace")
        let previousBookmark = defaults.object(forKey: "PKSNotesWorkspaceBookmark")
        let previousLastOpened = defaults.object(forKey: "PKSNotesLastOpenedMarkdown")
        defer {
            if let previousWorkspace { defaults.set(previousWorkspace, forKey: "PKSNotesWorkspace") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspace") }
            if let previousBookmark { defaults.set(previousBookmark, forKey: "PKSNotesWorkspaceBookmark") }
            else { defaults.removeObject(forKey: "PKSNotesWorkspaceBookmark") }
            if let previousLastOpened { defaults.set(previousLastOpened, forKey: "PKSNotesLastOpenedMarkdown") }
            else { defaults.removeObject(forKey: "PKSNotesLastOpenedMarkdown") }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-Backlink-Availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let study = root.appendingPathComponent("Study.md")
        let unreadable = root.appendingPathComponent("Unavailable.md")
        let pdf = root.appendingPathComponent("Source.pdf")
        try "# Study\n\n[Source](/Source.pdf#page=1)\n".write(
            to: study, atomically: true, encoding: .utf8
        )
        try Data([0xFF, 0xFE, 0xFD]).write(to: unreadable)
        let sourceText = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        sourceText.string = "Source material"
        let sourceDocument = try XCTUnwrap(
            PDFDocument(data: sourceText.dataWithPDF(inside: sourceText.bounds))
        )
        XCTAssertTrue(sourceDocument.write(to: pdf))

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        for _ in 0..<200 where model.loadingFiles {
            try await Task.sleep(for: .milliseconds(5))
        }

        model.openFile(pdf)
        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        model.message = nil
        model.loadRelationships()
        for _ in 0..<400 where model.loadingBacklinks {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertFalse(model.loadingBacklinks)
        XCTAssertEqual(model.backlinks.map(\.source), [study.standardizedFileURL])
        XCTAssertEqual(model.backlinkSkippedCloudFiles, 0)
        XCTAssertEqual(
            model.message,
            String(
                format: AppLanguage.current.text("Some notes could not be checked for links: %d"),
                1
            )
        )
    }
}
