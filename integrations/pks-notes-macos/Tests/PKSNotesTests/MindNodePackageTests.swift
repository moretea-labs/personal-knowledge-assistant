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

    func testImportsClassicSingleFileFormatArchiveAndPNGWithoutExtraction() throws {
        let (base, package) = try fixture(node: [
            "title": ["text": "<p>Root</p>"],
            "subnodes": [[
                "title": ["text": "<p>Diagram</p>"],
                "subnodes": [],
                "attachment": ["fileName": "TEST-IMG.png", "size": "{1, 1}", "type": 2]
            ]]
        ])
        defer { try? FileManager.default.removeItem(at: base) }
        let resources = package.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aTTQAAAAASUVORK5CYII="
        ))
        try png.write(to: resources.appendingPathComponent("TEST-IMG.png"))

        let archive = base.appendingPathComponent("Fixture-SFF.mindnode")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = package
        zip.arguments = ["-q", "-r", archive.path, "contents.xml", "resources"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        let originalArchive = try Data(contentsOf: archive)
        let originalContents = try Data(contentsOf: package.appendingPathComponent("contents.xml"))
        let originalImage = try Data(contentsOf: resources.appendingPathComponent("TEST-IMG.png"))

        let imported = try MindNodePackage.importDocument(from: archive)
        XCTAssertEqual(imported.images.count, 1)
        XCTAssertEqual(imported.images.first?.png, png)
        XCTAssertTrue(imported.markdown.contains(
            "![MindNode image](\(try XCTUnwrap(imported.images.first).marker))"
        ))
        XCTAssertEqual(
            MindMapOutline.nodes(in: try MindNodePackage.importOutline(from: archive)).map(\.title),
            ["Root", "Diagram"]
        )
        XCTAssertEqual(try Data(contentsOf: archive), originalArchive)
        XCTAssertEqual(
            try Data(contentsOf: package.appendingPathComponent("contents.xml")),
            originalContents
        )
        XCTAssertEqual(
            try Data(contentsOf: resources.appendingPathComponent("TEST-IMG.png")),
            originalImage
        )
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: base.path)),
            Set(["Fixture.mindnode", "Fixture-SFF.mindnode"])
        )
    }

    func testImportsNativeV9MindNodePackageHierarchyIntoMarkdown() throws {
        let (base, package) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(try MindNodePackage.importOutline(from: package),
                       "# Project & Roadmap\n- Feature &lt;A&gt;\n  - Grandchild\n")
        // The imported source remains byte-for-byte unchanged.
        let data = try Data(contentsOf: package.appendingPathComponent("contents.xml"))
        XCTAssertEqual(try (PropertyListSerialization.propertyList(from: data, format: nil)
                             as? [String: Any])?["version"] as? Int, 9)
    }

    func testImportedTopicTitlesRenderAsLiteralMarkdownText() throws {
        let rootTitle = "Study *literal* _under_ ~~strike~~ `code` &amp; <tag> [brackets] (parentheses)"
        let childTitle = "- nested + task. 1"
        func htmlEscaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let tree: [String: Any] = [
            "title": ["text": "<p>\(htmlEscaped(rootTitle))</p>"],
            "subnodes": [[
                "title": ["text": "<p>\(htmlEscaped(childTitle))</p>"],
                "subnodes": []
            ]]
        ]
        let (base, package) = try fixture(node: tree)
        defer { try? FileManager.default.removeItem(at: base) }

        let markdown = try MindNodePackage.importOutline(from: package)
        let nodes = MindMapOutline.nodes(in: markdown)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(
            nodes.map { String(MindMapTitleEmphasis.display($0.title).characters) },
            [rootTitle, childTitle]
        )
    }

    func testImportsVerifiedVersion7PackageTree() throws {
        let (base, package) = try fixture(version: 7)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(try MindNodePackage.importOutline(from: package),
                       "# Project & Roadmap\n- Feature &lt;A&gt;\n  - Grandchild\n")
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
            "note": ["text": "<p><span style='font-size:12px'>&gt; First &amp; second *literal* _under_ `code` &amp;amp; &lt;tag&gt; - bullet</span></p><p>Second paragraph</p>"],
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
                       "# Main\n> &gt; First & second \\*literal\\* \\_under\\_ \\`code\\` &amp;amp; &lt;tag&gt; \\- bullet\n> Second paragraph\n- Child\n  > Nested note\n  - Grandchild\n")
        let nodes = MindMapOutline.nodes(in: markdown)
        XCTAssertEqual(nodes.map(\.title), ["Main", "Child", "Grandchild"])
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 2])
    }

    func testPreservesRichTitleHyperlinksOnTheirOriginalNodes() throws {
        let tree: [String: Any] = [
            "title": ["text": "<p>Root</p>"],
            "subnodes": [
                [
                    "title": ["text": "<p><a style='color: blue' href='https://example.org/diagram?a=1&amp;b=2'>图片链接</a></p>"],
                    "subnodes": []
                ],
                [
                    "title": ["text": "<p><a href='javascript:alert(1)'>Unsafe</a></p>"],
                    "subnodes": []
                ]
            ]
        ]
        let (base, package) = try fixture(node: tree)
        defer { try? FileManager.default.removeItem(at: base) }
        let imported = try MindNodePackage.importOutline(from: package)
        XCTAssertEqual(MindMapOutline.nodes(in: imported).map(\.title),
                       ["Root", "图片链接", "Unsafe"])
        let links = MindMapOutline.linkOccurrences(in: imported)
        XCTAssertEqual(links.count, 1, "Unsafe hrefs must not become clickable links.")
        XCTAssertEqual(links[0].link.label, "图片链接")
        XCTAssertEqual(links[0].link.target, "https://example.org/diagram?a=1&b=2")
        let presentations = MindMapOutline.presentations(in: imported,
                                                     nodes: MindMapOutline.nodes(in: imported))
        let linkedNode = try XCTUnwrap(MindMapOutline.nodes(in: imported).first {
            $0.title == "图片链接"
        })
        XCTAssertEqual(presentations[linkedNode.id]?.links.map(\.target),
                       ["https://example.org/diagram?a=1&b=2"])
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
        var links = 0
        for package in packages {
            let original = try Data(contentsOf: package.appendingPathComponent("contents.xml"))
            let source = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: original, format: nil
            ) as? [String: Any])
            let canvas = try XCTUnwrap(source["canvas"] as? [String: Any])
            let maps = try XCTUnwrap(canvas["mindMaps"] as? [[String: Any]])
            var sourceNotes = 0
            var sourceLinks = 0
            func countNotes(_ node: [String: Any]) {
                if let title = (node["title"] as? [String: Any])?["text"] as? String {
                    let regex = try? NSRegularExpression(pattern: #"(?i)<a\b[^>]+href\s*="#)
                    sourceLinks += regex?.numberOfMatches(
                        in: title, range: NSRange(location: 0, length: (title as NSString).length)
                    ) ?? 0
                }
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
            let extractedLinks = MindMapOutline.linkOccurrences(in: editable)
                .filter { $0.link.target.hasPrefix("https://") || $0.link.target.hasPrefix("http://") }
            XCTAssertEqual(extractedLinks.count, sourceLinks, package.lastPathComponent)
            links += extractedLinks.count
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
        print("REAL_MINDNODE_MIGRATION files=\(files) topics=\(topics) note_nodes=\(notes) image_assets=\(images) retained_title_links=\(links) staged_to_temporary_workspace=true")
    }

    func testRejectsClassicResourcesDirectorySymlinkWithoutReadingExternalAttachment() throws {
        let (base, package) = try fixture(node: [
            "title": ["text": "<p>Root</p>"],
            "subnodes": [[
                "title": ["text": "<p>Diagram</p>"],
                "subnodes": [],
                "attachment": ["fileName": "outside.png", "size": "{1, 1}", "type": 2]
            ]]
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        let outside = base.appendingPathComponent("outside-resources", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aTTQAAAAASUVORK5CYII="
        ))
        let externalImage = outside.appendingPathComponent("outside.png")
        try png.write(to: externalImage)
        try FileManager.default.createSymbolicLink(
            at: package.appendingPathComponent("resources", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try MindNodePackage.importDocument(from: package))
        XCTAssertEqual(try MindNodePackage.importOutline(from: package), "# Root\n- Diagram\n")
        XCTAssertEqual(try Data(contentsOf: externalImage), png)
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
        let imported = try MindNodePackage.importOutline(from: destination)
        XCTAssertEqual(
            MindMapOutline.nodes(in: imported).map {
                String(MindMapTitleEmphasis.display($0.title).characters)
            },
            ["New & Project", "Topic <A>", "Nested \"idea\"", "Second"]
        )
        XCTAssertEqual(try Data(contentsOf: templateFile), before)
        XCTAssertThrowsError(try MindNodePackage.exportOutline(markdown, usingTemplate: template, to: destination))
        XCTAssertEqual(try MindNodePackage.importOutline(from: destination), imported,
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


extension MindNodePackageTests {
    func testMindNodeNextRejectsUnsupportedFormatVersionAndMalformedContents() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = base.appendingPathComponent("Next.mindnode", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let metadata = package.appendingPathComponent("Metadata.json")
        let contents = package.appendingPathComponent("Contents.data")
        try Data(#"{"fileFormatVersion":2,"minFileFormatVersionForReading":1}"#.utf8)
            .write(to: metadata)
        try Data([0x08, 0x01]).write(to: contents)
        XCTAssertThrowsError(try MindNodePackage.importOutline(from: package))

        try Data(#"{"fileFormatVersion":1,"minFileFormatVersionForReading":1}"#.utf8)
            .write(to: metadata)
        try Data([0x0f]).write(to: contents)
        XCTAssertThrowsError(try MindNodePackage.importOutline(from: package))
    }

    func testOfficialMindNodeNextSamplesImportTopicTreesAndPDFAssets() throws {
        guard let path = ProcessInfo.processInfo.environment["LEAFSPAN_REAL_MINDNODE_NEXT_DIR"] else {
            throw XCTSkip("Set LEAFSPAN_REAL_MINDNODE_NEXT_DIR to run official MindNode Next samples.")
        }
        let directory = URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL
        let packages = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { package in
            let values = try? package.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
                && FileManager.default.fileExists(atPath: package.appendingPathComponent("Metadata.json").path)
                && FileManager.default.fileExists(atPath: package.appendingPathComponent("Contents.data").path)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(packages.count, 1)

        for package in packages {
            let contentsURL = package.appendingPathComponent("Contents.data")
            let metadataURL = package.appendingPathComponent("Metadata.json")
            let originalContents = try Data(contentsOf: contentsURL)
            let originalMetadata = try Data(contentsOf: metadataURL)
            let outline = try MindNodePackage.importOutline(from: package)
            let nodes = MindMapOutline.nodes(in: outline)
            XCTAssertGreaterThan(nodes.count, 25, package.lastPathComponent)

            let imported = try MindNodePackage.importDocument(from: package)
            XCTAssertTrue(imported.images.isEmpty, package.lastPathComponent)
            if package.lastPathComponent == "Product-Launch.mindnode" {
                XCTAssertEqual(imported.pdfs.count, 15)
                XCTAssertEqual(
                    MindMapOutline.linkOccurrences(in: imported.markdown)
                        .filter { $0.link.target.hasPrefix("__LEAFSPAN_MINDNODE_PDF_") }.count,
                    15
                )
                XCTAssertTrue(outline.contains("> just a requisite"))
                let lines = imported.markdown.components(separatedBy: "\n")
                let passive = try XCTUnwrap(
                    lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "- Passive" }
                )
                XCTAssertEqual(
                    lines[passive + 1].trimmingCharacters(in: .whitespaces),
                    "> just a requisite"
                )
                XCTAssertEqual(MindMapOutline.nodes(in: imported.markdown).count, nodes.count)
            } else {
                XCTAssertTrue(imported.pdfs.isEmpty, package.lastPathComponent)
                XCTAssertEqual(imported.markdown, outline, package.lastPathComponent)
            }
            XCTAssertEqual(try Data(contentsOf: contentsURL), originalContents, package.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: metadataURL), originalMetadata, package.lastPathComponent)
        }
    }
}


extension MindNodePackageTests {
    func testOfficialMindNodeClassicImageSampleImportsNineImages() throws {
        guard let path = ProcessInfo.processInfo.environment["LEAFSPAN_REAL_MINDNODE_CLASSIC_DIR"] else {
            throw XCTSkip("Set LEAFSPAN_REAL_MINDNODE_CLASSIC_DIR to run the official Classic image sample.")
        }
        let directory = URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL
        let package = directory.appendingPathComponent("MindNode-Logo-Evolution.mindnode", isDirectory: true)
        let contentsURL = package.appendingPathComponent("contents.xml")
        let original = try Data(contentsOf: contentsURL)

        let imported = try MindNodePackage.importDocument(from: package)
        XCTAssertEqual(MindMapOutline.nodes(in: imported.markdown).count, 18)
        XCTAssertEqual(imported.images.count, 9)
        XCTAssertEqual(try Data(contentsOf: contentsURL), original)
    }
}


extension MindNodePackageTests {
    @MainActor
    func testMindNodeNextPDFBecomesNodeLinkAndWorkspaceAttachment() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = base.appendingPathComponent("Next.mindnode", isDirectory: true)
        let assets = package.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func varint(_ input: UInt64) -> Data {
            var value = input, result = Data()
            while value >= 128 { result.append(UInt8(value & 127) | 128); value >>= 7 }
            result.append(UInt8(value)); return result
        }
        func field(_ tag: Int, _ bytes: Data) -> Data {
            var result = varint(UInt64(tag << 3 | 2)); result.append(varint(UInt64(bytes.count))); result.append(bytes); return result
        }
        func number(_ tag: Int, _ value: UInt64) -> Data {
            var result = varint(UInt64(tag << 3)); result.append(varint(value)); return result
        }
        func message(_ fields: Data...) -> Data { fields.reduce(into: Data()) { $0.append($1) } }
        func id(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }
        func title(_ value: String) -> Data { field(1, field(4, field(1, Data(value.utf8)))) }

        let treeID = id(3), rootID = id(1), childID = id(2), filename = "00000000-0000-0000-0000-000000000004_image.pdf"
        let pdf = Data("%PDF-1.4\n".utf8), assetURL = assets.appendingPathComponent(filename); try pdf.write(to: assetURL)
        let attachment = message(field(1, id(4)), field(2, field(1, Data(filename.utf8))))
        let sticker = message(
            field(1, id(5)),
            field(3, message(
                field(1, Data("Star".utf8)),
                field(3, message(field(1, Data(repeating: 0, count: 18))))
            ))
        )
        let emojiSticker = message(
            field(1, id(6)),
            field(4, message(
                field(1, Data("🪩".utf8)),
                field(2, message(field(1, Data(repeating: 0, count: 18))))
            ))
        )
        let noteBody = message(
            field(1, Data()), number(2, 0), number(3, 1),
            field(4, message(field(1, Data("Note *literal* ".utf8)))),
            field(4, message(field(1, Data("[text]".utf8))))
        )
        let notePayload = message(field(1, noteBody))
        let rootNoteBody = message(
            field(1, Data()), number(2, 0), number(3, 1),
            field(4, message(field(1, Data("Root note".utf8))))
        )
        let rootNotePayload = message(field(1, rootNoteBody))
        let root = message(field(1, rootID), field(2, message(
            number(7, 0), field(8, sticker), field(8, emojiSticker),
            field(11, title("Root")), field(12, rootNotePayload)
        )))
        let child = message(field(1, childID), field(2, message(
            number(7, 1), field(8, attachment), field(11, title("PDF source")), field(12, notePayload)
        )))
        let tree = message(field(1, treeID), field(2, message(field(1, rootID), field(2, treeID))), field(2, message(field(1, childID), field(2, rootID))))
        let archive = message(field(1, message(field(1, treeID), field(2, message(field(1, message(field(2, root), field(2, child), field(3, tree))))))))
        try Data(#"{"fileFormatVersion":1,"minFileFormatVersionForReading":1}"#.utf8).write(to: package.appendingPathComponent("Metadata.json"))
        try archive.write(to: package.appendingPathComponent("Contents.data")); let original = try Data(contentsOf: package.appendingPathComponent("Contents.data"))

        let imported = try MindNodePackage.importDocument(from: package)
        XCTAssertEqual(imported.pdfs.count, 1); XCTAssertEqual(MindMapOutline.linkOccurrences(in: imported.markdown).count, 1)
        XCTAssertTrue(imported.markdown.contains("# Root\n> Root note\n"))
        XCTAssertTrue(imported.markdown.contains("> Note \\*literal\\* \\[text\\]"))
        let model = NotesModel(); XCTAssertTrue(model.openWorkspace(base))
        let note = try XCTUnwrap(model.newNote(named: "Imported Next", in: base, initialContent: imported.markdown, importedPDFs: imported.pdfs))
        let markdown = try String(contentsOf: note, encoding: .utf8)
        let link = try XCTUnwrap(MindMapOutline.linkOccurrences(in: markdown).first?.link)
        let target = try XCTUnwrap(WorkspaceFiles.resolveLinkedTarget(link.target, from: note, in: base))
        XCTAssertEqual(try Data(contentsOf: target), pdf); XCTAssertFalse(markdown.contains(imported.pdfs[0].marker))
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Contents.data")), original)
        XCTAssertEqual(try Data(contentsOf: assetURL), pdf)

        let malformedSticker = message(
            field(1, id(7)),
            field(3, message(field(1, Data("not-a-symbol".utf8))))
        )
        let invalidRoot = message(field(1, rootID), field(2, message(
            number(7, 0), field(8, malformedSticker), field(11, title("Root"))
        )))
        let invalidArchive = message(field(1, message(
            field(1, treeID),
            field(2, message(field(1, message(
                field(2, invalidRoot), field(2, child), field(3, tree)
            ))))
        )))
        try invalidArchive.write(to: package.appendingPathComponent("Contents.data"), options: .atomic)
        XCTAssertThrowsError(try MindNodePackage.importDocument(from: package))

        try original.write(to: package.appendingPathComponent("Contents.data"), options: .atomic)
        try Data("unmapped".utf8).write(to: assets.appendingPathComponent("orphan.pdf"))
        XCTAssertThrowsError(try MindNodePackage.importDocument(from: package))
    }
}


private extension MindNodePackageTests {
    func makeSingleFileArchive(from package: URL, in base: URL) throws -> URL {
        let archive = base.appendingPathComponent("Fixture-SFF.mindnode")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = package
        zip.arguments = ["-q", archive.path, "contents.xml"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return archive
    }

    func readUInt16(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) | Int(data[offset + 1]) << 8
    }

    func readUInt32(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) | Int(data[offset + 1]) << 8
            | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
    }

    func writeUInt16(_ value: Int, to data: inout Data, at offset: Int) {
        data.replaceSubrange(offset..<(offset + 2), with: [
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff)
        ])
    }

    func writeUInt32(_ value: Int, to data: inout Data, at offset: Int) {
        data.replaceSubrange(offset..<(offset + 4), with: [
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)
        ])
    }
}

extension MindNodePackageTests {
    func testRejectsUnsupportedZIPGeneralPurposeFlagsInMindNodeSFF() throws {
        let (base, package) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let archive = try makeSingleFileArchive(from: package, in: base)
        var bytes = try Data(contentsOf: archive)
        let local = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x03, 0x04]))?.lowerBound)
        let central = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))?.lowerBound)
        let unsupportedFlags = readUInt16(bytes, at: central + 8) | 0x0040
        writeUInt16(unsupportedFlags, to: &bytes, at: local + 6)
        writeUInt16(unsupportedFlags, to: &bytes, at: central + 8)
        try bytes.write(to: archive, options: .atomic)

        XCTAssertThrowsError(try MindNodePackage.importOutline(from: archive))
    }

    func testRejectsLocalZIPHeaderMethodMismatchInMindNodeSFF() throws {
        let (base, package) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let archive = try makeSingleFileArchive(from: package, in: base)
        var bytes = try Data(contentsOf: archive)
        let local = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x03, 0x04]))?.lowerBound)
        writeUInt16(99, to: &bytes, at: local + 8)
        try bytes.write(to: archive, options: .atomic)

        XCTAssertThrowsError(try MindNodePackage.importOutline(from: archive))
    }

    func testRejectsLocalZIPHeaderFilenameMismatchInMindNodeSFF() throws {
        let (base, package) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let archive = try makeSingleFileArchive(from: package, in: base)
        var bytes = try Data(contentsOf: archive)
        let local = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x03, 0x04]))?.lowerBound)
        let filenameLength = readUInt16(bytes, at: local + 26)
        XCTAssertGreaterThan(filenameLength, 0)
        bytes[local + 30] = bytes[local + 30] ^ 0x01
        try bytes.write(to: archive, options: .atomic)

        XCTAssertThrowsError(try MindNodePackage.importOutline(from: archive))
    }

    func testRejectsZIP64ExtraFieldsInMindNodeSFF() throws {
        let (base, package) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let archive = try makeSingleFileArchive(from: package, in: base)
        var bytes = try Data(contentsOf: archive)
        let central = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))?.lowerBound)
        let eocd = try XCTUnwrap(bytes.range(
            of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards
        )?.lowerBound)
        let nameLength = readUInt16(bytes, at: central + 28)
        let extraLength = readUInt16(bytes, at: central + 30)
        let insertion = central + 46 + nameLength + extraLength
        let centralSize = readUInt32(bytes, at: eocd + 12)

        // Insert a valid empty ZIP64 extra field and keep the directory offsets coherent.
        bytes.insert(contentsOf: [0x01, 0x00, 0x00, 0x00], at: insertion)
        writeUInt16(extraLength + 4, to: &bytes, at: central + 30)
        writeUInt32(centralSize + 4, to: &bytes, at: eocd + 4 + 12)
        try bytes.write(to: archive, options: .atomic)

        XCTAssertThrowsError(try MindNodePackage.importOutline(from: archive))
    }
}


extension MindNodePackageTests {
    func testImportsClassicTaskStatesAsMarkdownCheckboxes() throws {
        let (base, package) = try fixture(node: [
            "title": ["text": "<p>Project</p>"],
            "subnodes": [
                [
                    "title": ["text": "<p>Open task</p>"],
                    "task": ["state": 1, "uuids": [String: Any]()],
                    "subnodes": []
                ],
                [
                    "title": ["text": "<p>Completed task</p>"],
                    "task": ["state": 2, "uuids": [String: Any]()],
                    "subnodes": []
                ],
                ["title": ["text": "<p>Ordinary node</p>"], "subnodes": []]
            ]
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        let markdown = try MindNodePackage.importOutline(from: package)
        XCTAssertEqual(
            markdown,
            "# Project\n- [ ] Open task\n- [x] Completed task\n- Ordinary node\n"
        )
        let nodes = MindMapOutline.nodes(in: markdown)
        XCTAssertEqual(nodes.map(\.title), [
            "Project", "[ ] Open task", "[x] Completed task", "Ordinary node"
        ])
        XCTAssertFalse(try XCTUnwrap(MindMapTaskNode.parse(nodes[1].title)).checked)
        XCTAssertTrue(try XCTUnwrap(MindMapTaskNode.parse(nodes[2].title)).checked)
        XCTAssertNil(MindMapTaskNode.parse(nodes[3].title))
    }

    func testImportsClassicTaskRootAsMarkdownListRoot() throws {
        let (base, package) = try fixture(node: [
            "title": ["text": "<p>Release</p>"],
            "task": ["state": 2, "uuids": [String: Any]()],
            "subnodes": [[
                "title": ["text": "<p>Checklist item</p>"],
                "task": ["state": 1, "uuids": [String: Any]()],
                "subnodes": []
            ]]
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        let markdown = try MindNodePackage.importOutline(from: package)
        XCTAssertEqual(markdown, "- [x] Release\n  - [ ] Checklist item\n")
        let nodes = MindMapOutline.nodes(in: markdown)
        XCTAssertEqual(nodes.map(\.depth), [0, 1])
        XCTAssertTrue(try XCTUnwrap(MindMapTaskNode.parse(nodes[0].title)).checked)
        XCTAssertFalse(try XCTUnwrap(MindMapTaskNode.parse(nodes[1].title)).checked)
    }

    func testRejectsUnknownClassicTaskStateInsteadOfSilentlyDroppingIt() throws {
        let (base, package) = try fixture(node: [
            "title": ["text": "<p>Project</p>"],
            "task": ["state": 3, "uuids": [String: Any]()],
            "subnodes": []
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertThrowsError(try MindNodePackage.importOutline(from: package))
    }

    func testImportsClassicTaskStateZeroAsAnUnmarkedNode() throws {
        let (base, package) = try fixture(node: [
            "title": ["text": "<p>Project</p>"],
            "task": ["state": 0, "uuids": [String: Any]()],
            "subnodes": [[
                "title": ["text": "<p>Child</p>"],
                "subnodes": []
            ]]
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertEqual(
            try MindNodePackage.importOutline(from: package),
            "# Project\n- Child\n"
        )
    }
}


extension MindNodePackageTests {
    func testIgnoresRecognizedClassicBuiltInPDFStickerAttachments() throws {
        let (base, package) = try fixture(node: [
            "title": ["text": "<p>Project</p>"],
            "attachment": [
                "fileName": "12345678-1234-1234-1234-123456789012.pdf",
                "type": 3,
                "clipArtName": "MNSticker_Color_Lightbulb.pdf"
            ],
            "subnodes": [
                ["title": ["text": "<p>Child</p>"], "subnodes": []]
            ]
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        let imported = try MindNodePackage.importDocument(from: package)
        XCTAssertEqual(MindMapOutline.nodes(in: imported.markdown).map(\.title), [
            "Project", "Child"
        ])
        XCTAssertTrue(imported.images.isEmpty)
        XCTAssertTrue(imported.pdfs.isEmpty)
    }

    func testRejectsUnrecognizedClassicPDFAttachmentInsteadOfDroppingIt() throws {
        let (base, package) = try fixture(node: [
            "title": ["text": "<p>Project</p>"],
            "attachment": [
                "fileName": "12345678-1234-1234-1234-123456789012.pdf",
                "type": 3
            ],
            "subnodes": []
        ])
        defer { try? FileManager.default.removeItem(at: base) }

        XCTAssertThrowsError(try MindNodePackage.importDocument(from: package))
    }

    func testOfficialMindNodeClassicSFFSamplesImportPNGAndIgnoreBuiltInPDFStickers() throws {
        guard let path = ProcessInfo.processInfo.environment["LEAFSPAN_REAL_MINDNODE_CLASSIC_SFF_DIR"] else {
            throw XCTSkip("Set LEAFSPAN_REAL_MINDNODE_CLASSIC_SFF_DIR to run official Classic SFF samples.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let logoURL = directory.appendingPathComponent("MindNode-Logo-Evolution.mindnode")
        let stickersURL = directory.appendingPathComponent("What-is-MindNode.mindnode")
        let originalLogo = try Data(contentsOf: logoURL)
        let originalStickers = try Data(contentsOf: stickersURL)

        let logo = try MindNodePackage.importDocument(from: logoURL)
        XCTAssertEqual(MindMapOutline.nodes(in: logo.markdown).count, 18)
        XCTAssertEqual(logo.images.count, 9)
        XCTAssertTrue(logo.pdfs.isEmpty)

        let stickers = try MindNodePackage.importDocument(from: stickersURL)
        XCTAssertFalse(MindMapOutline.nodes(in: stickers.markdown).isEmpty)
        XCTAssertTrue(stickers.images.isEmpty)
        XCTAssertTrue(stickers.pdfs.isEmpty)

        XCTAssertEqual(try Data(contentsOf: logoURL), originalLogo)
        XCTAssertEqual(try Data(contentsOf: stickersURL), originalStickers)
    }
}
