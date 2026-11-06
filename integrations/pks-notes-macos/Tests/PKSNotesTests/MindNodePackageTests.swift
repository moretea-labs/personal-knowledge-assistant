import Foundation
import XCTest
@testable import PKSNotes

final class MindNodePackageTests: XCTestCase {
    private func fixture(version: Int = 9, node: [String: Any]? = nil) throws -> (URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("Fixture.mindnode", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = node ?? [
            "title": ["text": "<p>Project &amp; Roadmap</p>"],
            "subnodes": [
                [
                    "title": ["text": "<p>Feature &lt;A&gt;</p>"],
                    "subnodes": [
                        ["title": ["text": "<p>Grandchild</p>"], "subnodes": []]
                    ]
                ]
            ]
        ]
        let document: [String: Any] = [
            "version": version,
            "canvas": ["mindMaps": [["mainNode": root]]]
        ]
        let bytes = try PropertyListSerialization.data(fromPropertyList: document,
                                                       format: .binary, options: 0)
        try bytes.write(to: folder.appendingPathComponent("contents.xml"))
        return (base, folder)
    }

    func testImportsNativeV9MindNodePackageHierarchyIntoMarkdown() throws {
        let (base, package) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(try MindNodePackage.importOutline(from: package),
                       "# Project & Roadmap\n- Feature <A>\n  - Grandchild\n")
        // The imported source remains byte-for-byte unchanged.
        let data = try Data(contentsOf: package.appendingPathComponent("contents.xml"))
        XCTAssertEqual(try (PropertyListSerialization.propertyList(from: data, format: nil)
                             as? [String: Any])?["version"] as? Int, 9)
    }

    func testRejectsUnsupportedVersionAndMalformedNodeTree() throws {
        let (oldBase, old) = try fixture(version: 8)
        defer { try? FileManager.default.removeItem(at: oldBase) }
        XCTAssertThrowsError(try MindNodePackage.importOutline(from: old))

        let malformed: [String: Any] = [
            "title": ["text": "<p>Root</p>"],
            "subnodes": "not an array"
        ]
        let (invalidBase, invalid) = try fixture(node: malformed)
        defer { try? FileManager.default.removeItem(at: invalidBase) }
        XCTAssertThrowsError(try MindNodePackage.importOutline(from: invalid))
    }

    func testNativeV9TemplateExportRoundTripsAndDoesNotModifySource() throws {
        let (base, template) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let templateFile = template.appendingPathComponent("contents.xml")
        let before = try Data(contentsOf: templateFile)
        let destination = base.appendingPathComponent("Export.mindnode", isDirectory: true)
        let markdown = "# New & Project\n- Topic <A>\n  - Nested \"idea\"\n- Second\n"
        try MindNodePackage.exportOutline(markdown, usingTemplate: template, to: destination)
        XCTAssertEqual(try MindNodePackage.importOutline(from: destination), markdown)
        XCTAssertEqual(try Data(contentsOf: templateFile), before)
        XCTAssertThrowsError(try MindNodePackage.exportOutline(markdown, usingTemplate: template, to: destination))
        XCTAssertEqual(try MindNodePackage.importOutline(from: destination), markdown,
                       "A collision must never overwrite the existing export")
    }

    func testNativeExportRejectsProseAndMultipleRootsWithoutCreatingFiles() throws {
        let (base, template) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("Invalid.mindnode", isDirectory: true)
        for invalid in [
            "An ordinary note without a map",
            "# First\n# Second\n",
            "# Root\nA paragraph must not silently disappear.\n- Topic",
            "# Root\n- A\n    - Indentation gap"
        ] {
            XCTAssertThrowsError(try MindNodePackage.exportOutline(
                invalid, usingTemplate: template, to: destination
            ), invalid)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testNativeExportDoesNotCarryTemplateAttachmentsOrPreview() throws {
        let (base, template) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = FileManager.default
        let resources = template.appendingPathComponent("resources", isDirectory: true)
        let quickLook = template.appendingPathComponent("QuickLook", isDirectory: true)
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        try manager.createDirectory(at: quickLook, withIntermediateDirectories: true)
        try Data("private original image bytes".utf8)
            .write(to: resources.appendingPathComponent("user-image.png"))
        try Data("stale preview".utf8)
            .write(to: quickLook.appendingPathComponent("Preview.jpg"))

        let output = base.appendingPathComponent("Export.mindnode", isDirectory: true)
        try MindNodePackage.exportOutline("# Fresh\n- Topic\n", usingTemplate: template, to: output)
        XCTAssertEqual(try MindNodePackage.importOutline(from: output), "# Fresh\n- Topic\n")
        XCTAssertFalse(manager.fileExists(atPath: output.appendingPathComponent("resources").path))
        XCTAssertFalse(manager.fileExists(atPath: output.appendingPathComponent("QuickLook").path))
        XCTAssertTrue(manager.fileExists(atPath: resources.appendingPathComponent("user-image.png").path))
        XCTAssertTrue(manager.fileExists(atPath: quickLook.appendingPathComponent("Preview.jpg").path))
    }

    func testNativeExportRejectsRichMarkdownInsteadOfFlatteningIt() throws {
        let (base, template) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("Rich.mindnode")
        for source in [
            "# Root\n- [ ] Pending",
            "# Root\n- [x] Completed",
            "# Root\n- ![screenshot](attachments/image.png)",
            "# Root\n- [Linked note](other.md)",
            "# Root\n- [[Some note]]"
        ] {
            XCTAssertThrowsError(try MindNodePackage.exportOutline(
                source, usingTemplate: template, to: destination
            ), source)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testNativeExportRejectsTemplateSymlinks() throws {
        let (base, template) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(
            at: template.appendingPathComponent("Unsafe"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        let destination = base.appendingPathComponent("UnsafeOutput.mindnode", isDirectory: true)
        XCTAssertThrowsError(try MindNodePackage.exportOutline(
            "# Root\n- Child\n", usingTemplate: template, to: destination
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRejectsNonPackageFileAndMissingContents() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let plain = base.appendingPathComponent("Fake.mindnode")
        try Data("not a package".utf8).write(to: plain)
        XCTAssertThrowsError(try MindNodePackage.importOutline(from: plain))
        try FileManager.default.removeItem(at: plain)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertThrowsError(try MindNodePackage.importOutline(from: plain))
    }
}
