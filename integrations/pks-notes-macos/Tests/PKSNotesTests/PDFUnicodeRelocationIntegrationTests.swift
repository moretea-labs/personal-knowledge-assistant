import Foundation
import XCTest
@testable import PKSNotes

final class PDFUnicodeRelocationIntegrationTests: XCTestCase {
    @MainActor
    func testMovingCJKAndReservedCharacterPDFPreservesExactCitationAndResolvesNewPath() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("Leafspan-PDF-08-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = root.appendingPathComponent("学习资料", isDirectory: true)
        let archiveFolder = root.appendingPathComponent("归档 #?", isDirectory: true)
        let decoyFolder = root.appendingPathComponent("Decoys", isDirectory: true)
        try fm.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: archiveFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: decoyFolder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let filename = "夜的钢琴曲(五)（修订）#原版?.pdf"
        let pdf = sourceFolder.appendingPathComponent(filename)
        let movedPDF = archiveFolder.appendingPathComponent(filename)
        let decoy = decoyFolder.appendingPathComponent(filename)
        let note = root.appendingPathComponent("Reading.md")
        let pdfBytes = Data("%PDF-1.4\n% Leafspan PDF-08 fixture\n%%EOF".utf8)
        let decoyBytes = Data("%PDF-1.4\n% same-name decoy\n%%EOF".utf8)
        try pdfBytes.write(to: pdf)
        try decoyBytes.write(to: decoy)

        let fingerprint = try XCTUnwrap(PDFSourceAnchor.fingerprint(for: "夜的钢琴曲 第五乐章"))
        let anchor = try XCTUnwrap(PDFSourceAnchor(
            page: 3,
            normalizedRects: [CGRect(x: 0.12, y: 0.24, width: 0.42, height: 0.06)],
            fingerprint: fingerprint
        ))
        let citation = try XCTUnwrap(PDFPageReference.markdown(
            for: pdf, page: 3, root: root, anchor: anchor
        ))
        try (citation + "\n").write(to: note, atomically: true, encoding: .utf8)

        let originalTarget = try XCTUnwrap(MindMapOutline.links(in: citation).first?.target)
        let originalURL = try XCTUnwrap(URL(string: originalTarget))
        let originalComponents = try XCTUnwrap(
            URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(originalComponents.path, "/学习资料/\(filename)")
        XCTAssertTrue(originalComponents.percentEncodedPath.localizedCaseInsensitiveContains("%23"))
        XCTAssertTrue(originalComponents.percentEncodedPath.localizedCaseInsensitiveContains("%3F"))
        XCTAssertTrue(originalComponents.percentEncodedPath.localizedCaseInsensitiveContains("%28"))
        XCTAssertTrue(originalComponents.percentEncodedPath.localizedCaseInsensitiveContains("%29"))
        XCTAssertEqual(PDFPageReference.page(from: originalURL), 3)
        XCTAssertEqual(PDFPageReference.anchor(from: originalURL), anchor)

        let priorWorkspace = UserDefaults.standard.object(forKey: "PKSNotesWorkspace")
        defer {
            if let priorWorkspace {
                UserDefaults.standard.set(priorWorkspace, forKey: "PKSNotesWorkspace")
            } else {
                UserDefaults.standard.removeObject(forKey: "PKSNotesWorkspace")
            }
        }

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let result = await model.moveItem(pdf, to: archiveFolder)

        XCTAssertEqual(result, movedPDF)
        XCTAssertFalse(fm.fileExists(atPath: pdf.path))
        XCTAssertEqual(try Data(contentsOf: movedPDF), pdfBytes)
        XCTAssertEqual(try Data(contentsOf: decoy), decoyBytes)

        let updatedMarkdown = try String(contentsOf: note, encoding: .utf8)
        let updatedLinks = MindMapOutline.links(in: updatedMarkdown)
        XCTAssertEqual(updatedLinks.count, 1)
        let updatedTarget = try XCTUnwrap(updatedLinks.first?.target)
        let expectedPath = try XCTUnwrap(WorkspaceFiles.canonicalLinkTarget(for: movedPDF, in: root))
        let fragmentStart = try XCTUnwrap(originalTarget.firstIndex(of: "#"))
        let originalFragment = String(originalTarget[fragmentStart...])
        XCTAssertEqual(updatedTarget, expectedPath + originalFragment)

        let updatedURL = try XCTUnwrap(URL(string: updatedTarget))
        let updatedComponents = try XCTUnwrap(
            URLComponents(url: updatedURL, resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(updatedComponents.percentEncodedPath, expectedPath)
        XCTAssertEqual(updatedComponents.path, "/归档 #?/\(filename)")
        XCTAssertTrue(updatedComponents.percentEncodedPath.localizedCaseInsensitiveContains("%23"))
        XCTAssertTrue(updatedComponents.percentEncodedPath.localizedCaseInsensitiveContains("%3F"))
        XCTAssertTrue(updatedComponents.percentEncodedPath.localizedCaseInsensitiveContains("%28"))
        XCTAssertTrue(updatedComponents.percentEncodedPath.localizedCaseInsensitiveContains("%29"))
        XCTAssertEqual(PDFPageReference.page(from: updatedURL), 3)
        XCTAssertEqual(PDFPageReference.anchor(from: updatedURL), anchor)
        XCTAssertEqual(
            WorkspaceFiles.resolveLinkedTarget(updatedTarget, from: note, in: root),
            movedPDF.standardizedFileURL
        )
        XCTAssertEqual(
            model.message,
            AppLanguage.current.text("Path changed and related links were updated.")
        )
    }
}
