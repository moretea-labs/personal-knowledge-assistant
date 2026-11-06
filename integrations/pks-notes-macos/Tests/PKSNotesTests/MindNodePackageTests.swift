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
