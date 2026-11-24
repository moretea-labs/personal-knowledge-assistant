import AppKit
import Combine
import PDFKit
import XCTest
@testable import PKSNotes

@MainActor
final class PDFOpenPublicationTests: XCTestCase {
    func testIdlePDFOpenPublishesOnlyTheNewPDFIdentity() async throws {
        let defaults = UserDefaults.standard
        let keys = [
            "PKSNotesWorkspace",
            "PKSNotesWorkspaceBookmark",
            "PKSNotesLastOpenedMarkdown"
        ]
        let prior = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in prior {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Leafspan-PDF-Publications-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = NSTextView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        source.string = "Publication baseline"
        let pdf = root.appendingPathComponent("Source.pdf")
        let document = try XCTUnwrap(PDFDocument(data: source.dataWithPDF(inside: source.bounds)))
        XCTAssertTrue(document.write(to: pdf))

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        for _ in 0..<400 where model.loadingFiles || model.indexingFiles {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.loadingFiles)
        XCTAssertFalse(model.indexingFiles)

        var publicationCount = 0
        let cancellable = model.objectWillChange.sink { publicationCount += 1 }
        model.openFile(pdf)

        XCTAssertEqual(model.previewPDF, pdf.standardizedFileURL)
        XCTAssertEqual(
            publicationCount, 1,
            "Opening a plain PDF from an idle workspace should publish only previewPDF, not unchanged cleanup state."
        )

        publicationCount = 0
        let firstNavigationSequence = model.previewPDFNavigationSequence
        model.openFile(pdf, pdfPage: 0)
        XCTAssertEqual(model.previewPDFPage, Optional(0))
        XCTAssertEqual(model.previewPDFNavigationSequence, firstNavigationSequence + 1)
        XCTAssertEqual(
            publicationCount, 2,
            "A same-PDF page request should publish the changed page and navigation sequence, not the unchanged anchor."
        )

        publicationCount = 0
        let repeatedNavigationSequence = model.previewPDFNavigationSequence
        model.openFile(pdf, pdfPage: 0)
        XCTAssertEqual(model.previewPDFNavigationSequence, repeatedNavigationSequence + 1)
        XCTAssertEqual(
            publicationCount, 1,
            "Repeating the same page request should only publish a new navigation sequence."
        )
        withExtendedLifetime(cancellable) {}
    }
}
