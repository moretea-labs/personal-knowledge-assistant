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

    func testImportsVerifiedVersion7PackageTree() throws {
        let (base, package) = try fixture(version: 7)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(try MindNodePackage.importOutline(from: package),
                       "# Project & Roadmap\n- Feature <A>\n  - Grandchild\n")
    }

    func testUntitledStructuralNodesPromoteVisibleDescendants() throws {
        let structural: [String: Any] = [
            "subnodes": [
                [
                    "subnodes": [
                        ["title": ["text": "<p>First visible topic</p>"], "subnodes": []],
                        ["title": ["text": "<p>Second visible topic</p>"], "subnodes": []]
                    ]
                ]
            ]
        ]
        let (base, package) = try fixture(node: structural)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(try MindNodePackage.importOutline(from: package),
                       "# Mind Maps\n- First visible topic\n- Second visible topic\n")
    }

    @MainActor
    func testImportsPNGAttachmentIntoEditableMarkdownWithoutOriginalDependency() throws {
        let (base, package) = try fixture(node: [
            "title": ["text": "<p>Root</p>"],
            "subnodes": [
                [
                    "title": ["text": "<p>Diagram</p>"],
                    "subnodes": [],
                    "attachment": ["fileName": "TEST-IMG.png", "size": "{1, 1}", "type": 2]
                ]
            ]
        ])
        defer { try? FileManager.default.removeItem(at: base) }
        let resources = package.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let bytes = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aTTQAAAAASUVORK5CYII="
        ))
        try bytes.write(to: resources.appendingPathComponent("TEST-IMG.png"))
        let original = try Data(contentsOf: package.appendingPathComponent("contents.xml"))

        let imported = try MindNodePackage.importDocument(from: package)
        XCTAssertEqual(imported.images.count, 1)
        let asset = try XCTUnwrap(imported.images.first)
        XCTAssertTrue(imported.markdown.contains("![MindNode image](\(asset.marker))"))
        XCTAssertEqual(MindMapOutline.nodes(in: imported.markdown).map(\.title), ["Root", "Diagram"])

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(base))
        let created = try XCTUnwrap(model.newNote(
            named: "Editable Diagram", in: base,
            initialContent: imported.markdown, importedImages: imported.images
        ), model.message ?? "")
        let markdown = try String(contentsOf: created, encoding: .utf8)
        XCTAssertFalse(markdown.contains(asset.marker))
        XCTAssertTrue(markdown.contains("![MindNode image](attachments/mindnode-TEST-IMG.png)"))
        XCTAssertEqual(
            try Data(contentsOf: base.appendingPathComponent("attachments/mindnode-TEST-IMG.png")),
            bytes
        )
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent("contents.xml")),
            original
        )
    }

    func testImportsRichHTMLNotesWithParagraphsOnRootAndNestedNodes() throws {
        let tree: [String: Any] = [
            "title": ["text": "<p>Main</p>"],
            "note": ["text": "<p><span style='font-size:12px'>&gt; First &amp; second</span></p><p>Second paragraph</p>"],
            "subnodes": [
                [
                    "title": ["text": "<p>Child</p>"],
                    "note": ["text": "<p>Nested note</p>"],
                    "subnodes": [
                        ["title": ["text": "<p>Grandchild</p>"], "subnodes": []]
                    ]
                ]
            ]
        ]
        let (base, package) = try fixture(node: tree)
        defer { try? FileManager.default.removeItem(at: base) }
        let markdown = try MindNodePackage.importOutline(from: package)
        XCTAssertEqual(markdown,
                       "# Main\n> > First & second\n> Second paragraph\n- Child\n  > Nested note\n  - Grandchild\n")
        let nodes = MindMapOutline.nodes(in: markdown)
        XCTAssertEqual(nodes.map(\.title), ["Main", "Child", "Grandchild"])
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 2])
    }

    /// Opt-in, read-only regression against the user's actual MindNode corpus.
    /// The current Markdown projection must retain every visible note as body
    /// text without ever writing to the original document packages.
    @MainActor
    func testRealMindNodeLibraryMigratesNoteText() throws {
        guard let path = ProcessInfo.processInfo.environment["LEAFSPAN_REAL_MINDNODE_DIR"] else {
            throw XCTSkip("Set LEAFSPAN_REAL_MINDNODE_DIR to run this read-only migration audit.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let packages = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "mindnode" }
        XCTAssertFalse(packages.isEmpty)
        // Validate the full conversion using a disposable local workspace.
        // Never create or mutate a file inside the user's iCloud source vault.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(destination))
        var files = 0
        var topics = 0
        var notes = 0
        var images = 0
        for package in packages {
            let original = try Data(contentsOf: package.appendingPathComponent("contents.xml"))
            let source = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: original, format: nil
            ) as? [String: Any])
            let canvas = try XCTUnwrap(source["canvas"] as? [String: Any])
            let maps = try XCTUnwrap(canvas["mindMaps"] as? [[String: Any]])
            var sourceNotes = 0
            func countNotes(_ node: [String: Any]) {
                if (node["note"] as? [String: Any])?["text"] is String { sourceNotes += 1 }
                for child in (node["subnodes"] as? [[String: Any]]) ?? [] {
                    countNotes(child)
                }
            }
            for map in maps {
                countNotes(try XCTUnwrap(map["mainNode"] as? [String: Any]))
            }
            let imported = try MindNodePackage.importDocument(from: package)
            images += imported.images.count
            let markdown = imported.markdown
            let created = try XCTUnwrap(model.newNote(
                named: package.deletingPathExtension().lastPathComponent,
                in: destination,
                initialContent: markdown, importedImages: imported.images,
                activateAfterCreation: false
            ), "Failed to migrate \(package.lastPathComponent): \(model.message ?? "unknown error")")
            let editable = try String(contentsOf: created, encoding: .utf8)
            XCTAssertFalse(editable.contains("__LEAFSPAN_MINDNODE_IMAGE_"))
            XCTAssertEqual(MindMapOutline.nodes(in: editable).count,
                           MindMapOutline.nodes(in: markdown).count)
            for image in imported.images {
                let path = destination.appendingPathComponent("attachments")
                    .appendingPathComponent(image.stem + ".png")
                XCTAssertEqual(try Data(contentsOf: path), image.png)
                XCTAssertTrue(editable.contains("attachments/\(image.stem).png"))
            }
            let paragraphs = editable.components(separatedBy: .newlines).filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("> ")
            }
            XCTAssertGreaterThanOrEqual(paragraphs.count, sourceNotes, package.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("contents.xml")), original)
            topics += MindMapOutline.nodes(in: markdown).count
            notes += sourceNotes
            files += 1
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }.count, files)
        print("REAL_MINDNODE_MIGRATION files=\(files) topics=\(topics) note_nodes=\(notes) image_assets=\(images) staged_to_temporary_workspace=true")
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

    func testVerifiedVersion7TemplateExportRoundTripsAndPreservesVersion() throws {
        let (base, template) = try fixture(version: 7)
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("ExportV7.mindnode", isDirectory: true)
        let markdown = "# Legacy Project\n- Topic\n  - Nested\n"
        try MindNodePackage.exportOutline(markdown, usingTemplate: template, to: destination)
        XCTAssertEqual(try MindNodePackage.importOutline(from: destination), markdown)

        let data = try Data(contentsOf: destination.appendingPathComponent("contents.xml"))
        XCTAssertEqual(try (PropertyListSerialization.propertyList(from: data, format: nil)
                             as? [String: Any])?["version"] as? Int, 7)
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

    func testNativeExportRejectsOutlineDeeperThanImporterLimit() throws {
        let (base, template) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let levels = (1...64).map { depth in
            String(repeating: " ", count: (depth - 1) * 2) + "- Level \(depth)"
        }.joined(separator: "\n")
        let source = "# Root\n\(levels)\n"
        let destination = base.appendingPathComponent("TooDeep.mindnode", isDirectory: true)
        XCTAssertThrowsError(try MindNodePackage.exportOutline(
            source, usingTemplate: template, to: destination
        )) { error in
            guard case MindNodePackage.Failure.tooDeep = error else {
                return XCTFail("Expected the explicit maximum-depth error, got: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
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

    func testImportsMultipleMindNodeMapsIntoOneMarkdownOutline() throws {
        let (base, package) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }

        let contentsURL = package.appendingPathComponent("contents.xml")
        let data = try Data(contentsOf: contentsURL)
        var document = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        var canvas = try XCTUnwrap(document["canvas"] as? [String: Any])
        let first: [String: Any] = [
            "title": ["text": "<p>TCP/IP</p>"],
            "subnodes": [["title": ["text": "<p>Network layer</p>"], "subnodes": []]]
        ]
        let second: [String: Any] = [
            "title": ["text": "<p>Transport</p>"],
            "subnodes": [["title": ["text": "<p>TCP</p>"], "subnodes": []]]
        ]
        canvas["mindMaps"] = [["mainNode": first], ["mainNode": second]]
        document["canvas"] = canvas
        let updated = try PropertyListSerialization.data(
            fromPropertyList: document, format: .binary, options: 0
        )
        try updated.write(to: contentsURL, options: .atomic)

        XCTAssertEqual(
            try MindNodePackage.importOutline(from: package),
            "# Mind Maps\n- TCP/IP\n  - Network layer\n- Transport\n  - TCP\n"
        )
    }

}
