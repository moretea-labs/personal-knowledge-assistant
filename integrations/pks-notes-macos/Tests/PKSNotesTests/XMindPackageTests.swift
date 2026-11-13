import AppKit
import Foundation
import XCTest
@testable import PKSNotes

final class XMindPackageTests: XCTestCase {
    private func archive(_ payload: String, entry: String) throws -> (URL, URL) {
        try archive([entry: Data(payload.utf8)])
    }

    private func archive(_ entries: [String: Data]) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanXMind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (entry, data) in entries {
            let file = root.appendingPathComponent(entry)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: file, options: .atomic)
        }
        let target = root.appendingPathComponent("Fixture.xmind")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", target.path] + entries.keys.sorted()
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return (root, target)
    }

    func testImportsModernJSONHierarchyFromNativeXMindArchive() throws {
        let content = """
        [{
          "title":"Document",
          "rootTopic":{
            "title":"Central Topic",
            "children":{"attached":[
              {"title":"Feature 1","children":{"attached":[{"title":"Nested A"}]}},
              {"title":"Feature 2","children":{"attached":[]}}
            ]}
          }
        }]
        """
        let (root, file) = try archive(content, entry: "content.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: file)
        XCTAssertEqual(try XMindPackage.importOutline(from: file),
                       "# Central Topic\n> Sheet: Document\n- Feature 1\n  - Nested A\n- Feature 2\n")
        XCTAssertEqual(try Data(contentsOf: file), before, "Import must not mutate the .xmind archive.")
    }

    func testRejectsSymlinkedAndNonRegularXMindSourcesBeforeReading() throws {
        let (root, file) = try archive(#"[{"rootTopic":{"title":"Valid"}}]"#, entry: "content.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("Alias.xmind")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let directory = root.appendingPathComponent("Directory.xmind", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try XMindPackage.importOutline(from: alias))
        XCTAssertThrowsError(try XMindPackage.importOutline(from: directory))
    }

    func testImportsJSONNoteBodyWithoutCreatingNewTopics() throws {
        let content = #"""
        [{
          "rootTopic":{
            "title":"Map",
            "notes":{"plain":{"content":"Root *note*\nSecond line &amp; literal <tag> - bullet"}},
            "children":{"attached":[{
              "title":"Child",
              "notes":{"plain":{"content":"Child note"}}
            }]}
          }
        }]
        """#
        let (base, file) = try archive(content, entry: "content.json")
        defer { try? FileManager.default.removeItem(at: base) }
        let markdown = try XMindPackage.importOutline(from: file)
        XCTAssertEqual(markdown, "# Map\n> Root \\*note\\*\n> Second line &amp;amp; literal &lt;tag&gt; \\- bullet\n- Child\n  > Child note\n")
        XCTAssertEqual(MindMapOutline.nodes(in: markdown).count, 2)
    }

    func testImportsLegacyXMLHierarchy() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0">
          <sheet><title>Sheet</title><topic id="root">
            <title>Legacy Root</title><children><topics type="attached">
              <topic><title>Alpha</title></topic>
              <topic><title>Beta</title></topic>
            </topics></children>
          </topic></sheet>
        </xmap-content>
        """
        let (root, file) = try archive(content, entry: "content.xml")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try XMindPackage.importOutline(from: file),
                       "# Legacy Root\n- Alpha\n- Beta\n")
    }

    func testImportsLegacyXMLPlainNotes() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0"><sheet>
          <topic><title>Legacy Root</title><notes><plain>Note &amp; detail</plain></notes></topic>
        </sheet></xmap-content>
        """
        let (base, file) = try archive(content, entry: "content.xml")
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(try XMindPackage.importOutline(from: file),
                       "# Legacy Root\n> Note & detail\n")
    }

    func testMultipleSheetsPreserveAllRoots() throws {
        let content = """
        [
          {"rootTopic":{"title":"First","children":{"attached":[{"title":"A"}]}}},
          {"rootTopic":{"title":"Second","children":{"attached":[{"title":"B"}]}}}
        ]
        """
        let (root, file) = try archive(content, entry: "content.json")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try XMindPackage.importOutline(from: file),
                       "# Mind Maps\n- First\n  - A\n- Second\n  - B\n")
    }

    func testRejectsCorruptZIPEntryCRCWithoutExtractingFiles() throws {
        let (base, file) = try archive(
            #"[{"rootTopic":{"title":"Untrusted"}}]"#, entry: "content.json"
        )
        defer { try? FileManager.default.removeItem(at: base) }
        var bytes = try Data(contentsOf: file)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        let header = try XCTUnwrap(bytes.range(of: signature))
        let checksumStart = header.lowerBound + 16
        bytes.replaceSubrange(checksumStart..<(checksumStart + 4),
                              with: [0, 0, 0, 0])
        try bytes.write(to: file, options: .atomic)
        XCTAssertThrowsError(try XMindPackage.importOutline(from: file))
    }

    func testInvalidJSONDoesNotSilentlyDiscardMap() throws {
        let (root, file) = try archive(#"[{"title":"No root"}]"#, entry: "content.json")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try XMindPackage.importOutline(from: file))
    }

    func testPreservesJSONTopicMetadataLinksAndRelationshipDescriptions() throws {
        let content = #"""
        [{
          "title":"Study sheet",
          "rootTopic":{
            "id":"root","title":"Study","labels":"exam, biology",
            "markers":[{"markerId":"priority-1"},{"markerId":"task-done"}],
            "href":"https://example.com/study",
            "image":{"src":"xap:resources/diagram.png"},
            "children":{
              "attached":[{"id":"child","title":"Cell","href":"https://example.com/cell"}],
              "summary":[{"id":"summary","title":"Key points"}],
              "callout":[{"id":"callout","title":"Remember","href":"mailto:study@example.com"}]
            }
          },
          "relationships":[{"id":"r1","title":"supports","end1Id":"root","end2Id":"child"}]
        }]
        """#
        let (root, file) = try archive(content, entry: "content.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = try XMindPackage.importOutline(from: file)

        XCTAssertTrue(markdown.contains("> Sheet: Study sheet"))
        XCTAssertTrue(markdown.contains("> Labels: exam, biology"))
        XCTAssertTrue(markdown.contains("> Markers: priority\\-1, task\\-done"))
        XCTAssertTrue(markdown.contains("> [Open link](https://example.com/study)"))
        XCTAssertTrue(markdown.contains("Image reference: xap:resources/diagram.png"))
        XCTAssertTrue(markdown.contains("Relationship: Study ↔ Cell — supports"))
        XCTAssertTrue(markdown.contains("- \\[Summary\\] Key points"))
        XCTAssertTrue(markdown.contains("- \\[Callout\\] Remember"))
        XCTAssertTrue(markdown.contains("> Link reference: mailto:study@example.com"))

        let nodes = MindMapOutline.nodes(in: markdown)
        let rootNode = try XCTUnwrap(nodes.first)
        let presentations = MindMapOutline.presentations(in: markdown, nodes: nodes)
        let rootPresentation = try XCTUnwrap(presentations[rootNode.id])
        XCTAssertTrue(rootPresentation.links.contains(where: { $0.target == "https://example.com/study" }))
        let childNode = try XCTUnwrap(nodes.first(where: { $0.title == "Cell" }))
        let childPresentation = try XCTUnwrap(presentations[childNode.id])
        XCTAssertTrue(childPresentation.links.contains(where: { $0.target == "https://example.com/cell" }))
        let calloutNode = try XCTUnwrap(nodes.first(where: { $0.title.contains("Remember") }))
        let calloutPresentation = try XCTUnwrap(presentations[calloutNode.id])
        XCTAssertFalse(calloutPresentation.links.contains(where: { $0.target.hasPrefix("mailto:") }))
    }

    func testImportedTopicTitlesRenderAsLiteralMarkdownText() throws {
        let rootTitle = "Study *literal* _under_ ~~strike~~ `code` &amp; <tag> [brackets] (parentheses)"
        let childTitle = "- nested + task. 1"
        let rootTopic: [String: Any] = [
            "title": rootTitle,
            "children": ["attached": [["title": childTitle]]]
        ]
        let payload = try JSONSerialization.data(withJSONObject: [["rootTopic": rootTopic]])
        let (root, file) = try archive(["content.json": payload])
        defer { try? FileManager.default.removeItem(at: root) }

        let markdown = try XMindPackage.importOutline(from: file)
        let nodes = MindMapOutline.nodes(in: markdown)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(
            nodes.map { String(MindMapTitleEmphasis.display($0.title).characters) },
            [rootTitle, childTitle]
        )
    }

}


extension XMindPackageTests {
    @MainActor
    func testImportDocumentCopiesEmbeddedPNGImagesAsMarkdownAttachmentsAndDeduplicatesResources() throws {
        let content = #"""
        [{
          "rootTopic":{
            "id":"root",
            "title":"Study",
            "image":{"src":"xap:resources/diagram.png"},
            "children":{"attached":[{
              "id":"child",
              "title":"Cell",
              "image":{"src":"xap:resources/diagram.png"}
            }]}
          },
          "relationships":[{"end1Id":"root","end2Id":"child","title":"related"}]
        }]
        """#
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII="
        ))
        let (root, file) = try archive([
            "content.json": Data(content.utf8),
            "resources/diagram.png": png
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: file)

        let imported = try XMindPackage.importDocument(from: file)
        XCTAssertEqual(imported.images.count, 1)
        let image = try XCTUnwrap(imported.images.first)
        XCTAssertEqual(image.png, png)
        XCTAssertTrue(imported.markdown.contains("![XMind image](\(image.marker))"))
        XCTAssertEqual(
            imported.markdown.components(separatedBy: image.marker).count - 1,
            2,
            "One archive resource referenced by multiple topics should be copied once."
        )
        let nodes = MindMapOutline.nodes(in: imported.markdown)
        XCTAssertEqual(nodes.map(\.title), ["Study", "Cell"])
        let imageLines = imported.markdown.components(separatedBy: .newlines)
            .filter { $0.contains("![XMind image](\(image.marker))") }
        XCTAssertEqual(imageLines.count, 2)
        XCTAssertTrue(imported.markdown.contains("Relationship: Study ↔ Cell — related"))

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let created = try XCTUnwrap(model.newNote(
            named: "Editable Diagram",
            in: root,
            initialContent: imported.markdown,
            importedImages: imported.images,
            activateAfterCreation: false
        ), model.message ?? "")
        let savedMarkdown = try String(contentsOf: created, encoding: .utf8)
        XCTAssertFalse(savedMarkdown.contains(image.marker))
        XCTAssertTrue(savedMarkdown.contains("![XMind image](attachments/xmind-image-1.png)"))
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("attachments/xmind-image-1.png")),
            png
        )
        XCTAssertEqual(try Data(contentsOf: file), original, "The source archive must remain unchanged.")
    }

    @MainActor
    func testImportDocumentNormalizesJPEGAndTIFFResourcesToMarkdownPNGAttachments() throws {
        let formats: [(String, NSBitmapImageRep.FileType)] = [
            ("diagram.jpg", .jpeg),
            ("diagram.tiff", .tiff)
        ]

        for (resourceName, format) in formats {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ))
            bitmap.setColor(NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1), atX: 0, y: 0)
            let sourceImage = try XCTUnwrap(bitmap.representation(using: format, properties: [:]))
            let content = """
            [{"rootTopic":{"title":"Study","image":{"src":"xap:resources/\(resourceName)"}}}]
            """
            let (root, file) = try archive([
                "content.json": Data(content.utf8),
                "resources/\(resourceName)": sourceImage
            ])
            defer { try? FileManager.default.removeItem(at: root) }
            let originalArchive = try Data(contentsOf: file)

            let imported = try XMindPackage.importDocument(from: file)
            let image = try XCTUnwrap(imported.images.first)
            XCTAssertTrue(image.png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
            XCTAssertNotEqual(image.png, sourceImage)

            let model = NotesModel()
            XCTAssertTrue(model.openWorkspace(root))
            let note = try XCTUnwrap(model.newNote(
                named: "Editable Diagram",
                in: root,
                initialContent: imported.markdown,
                importedImages: imported.images,
                activateAfterCreation: false
            ), model.message ?? "")
            let savedMarkdown = try String(contentsOf: note, encoding: .utf8)
            XCTAssertFalse(savedMarkdown.contains(image.marker))
            XCTAssertTrue(savedMarkdown.contains("attachments/xmind-image-1.png"))
            let attachment = try Data(contentsOf: root.appendingPathComponent("attachments/xmind-image-1.png"))
            XCTAssertTrue(attachment.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
            XCTAssertEqual(attachment, image.png)
            XCTAssertEqual(try Data(contentsOf: file), originalArchive)
        }
    }

    func testImportDocumentRejectsUnsafeOrMissingEmbeddedImageResources() throws {
        let unsafe = #"""
        [{"rootTopic":{"title":"Study","image":{"src":"xap:resources/../outside.png"}}}]
        """#
        let (unsafeRoot, unsafeFile) = try archive(unsafe, entry: "content.json")
        defer { try? FileManager.default.removeItem(at: unsafeRoot) }
        XCTAssertThrowsError(try XMindPackage.importDocument(from: unsafeFile))

        let missing = #"""
        [{"rootTopic":{"title":"Study","image":{"src":"xap:resources/missing.png"}}}]
        """#
        let (missingRoot, missingFile) = try archive(missing, entry: "content.json")
        defer { try? FileManager.default.removeItem(at: missingRoot) }
        XCTAssertThrowsError(try XMindPackage.importDocument(from: missingFile))
    }
}


extension XMindPackageTests {
    @MainActor
    func testImportLegacyXMLCopiesAndDeduplicatesEmbeddedPNGAttachments() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0"
                      xmlns:xhtml="http://www.w3.org/1999/xhtml">
          <sheet><topic id="root"><title>Legacy Root</title>
            <xhtml:img xhtml:src="xap:attachments/diagram.png"/>
            <children><topics type="attached"><topic id="child"><title>Child</title>
              <xhtml:img xhtml:src="xap:attachments/diagram.png"/>
            </topic></topics></children>
          </topic></sheet>
        </xmap-content>
        """
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII="
        ))
        let (root, file) = try archive([
            "content.xml": Data(content.utf8),
            "attachments/diagram.png": png
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: file)

        let imported = try XMindPackage.importDocument(from: file)
        XCTAssertEqual(imported.images.count, 1)
        let image = try XCTUnwrap(imported.images.first)
        XCTAssertEqual(imported.markdown.components(separatedBy: image.marker).count - 1, 2)

        let model = NotesModel()
        XCTAssertTrue(model.openWorkspace(root))
        let note = try XCTUnwrap(model.newNote(
            named: "Legacy Diagram",
            in: root,
            initialContent: imported.markdown,
            importedImages: imported.images,
            activateAfterCreation: false
        ), model.message ?? "")
        let savedMarkdown = try String(contentsOf: note, encoding: .utf8)
        XCTAssertEqual(
            savedMarkdown.components(separatedBy: "attachments/xmind-image-1.png").count - 1,
            2
        )
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("attachments/xmind-image-1.png")),
            png
        )
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testImportLegacyXMLRejectsUnsafeAndMissingImageAttachments() throws {
        let unsafe = """
        <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0"
                      xmlns:xhtml="http://www.w3.org/1999/xhtml">
          <sheet><topic><title>Unsafe</title>
            <xhtml:img xhtml:src="xap:attachments/../outside.png"/>
          </topic></sheet>
        </xmap-content>
        """
        let (unsafeRoot, unsafeFile) = try archive(["content.xml": Data(unsafe.utf8)])
        defer { try? FileManager.default.removeItem(at: unsafeRoot) }
        XCTAssertThrowsError(try XMindPackage.importDocument(from: unsafeFile))

        let missing = """
        <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0"
                      xmlns:xhtml="http://www.w3.org/1999/xhtml">
          <sheet><topic><title>Missing</title>
            <xhtml:img xhtml:src="xap:attachments/missing.png"/>
          </topic></sheet>
        </xmap-content>
        """
        let (missingRoot, missingFile) = try archive(["content.xml": Data(missing.utf8)])
        defer { try? FileManager.default.removeItem(at: missingRoot) }
        XCTAssertThrowsError(try XMindPackage.importDocument(from: missingFile))
    }

    func testRealWorldXMindCorpusImportsWithoutMutatingSourceArchives() throws {
        guard let path = ProcessInfo.processInfo.environment["LEAFSPAN_REAL_XMIND_CORPUS"] else {
            throw XCTSkip("Set LEAFSPAN_REAL_XMIND_CORPUS to run the public real-world XMind corpus.")
        }
        let directory = URL(
            fileURLWithPath: path,
            relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ).standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "xmind" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 4)

        let expectedImageCounts = [
            "test_case_by_xmind_v1.xmind": 0,
            "test_case_by_xmind_v2.xmind": 1,
            "DRAW-feature-mindmap.xmind": 55,
            "DRAW-youtube-playlist.xmind": 0
        ]
        for file in files {
            let original = try Data(contentsOf: file)
            let imported = try XMindPackage.importDocument(from: file)
            XCTAssertFalse(imported.markdown.isEmpty, file.lastPathComponent)
            XCTAssertFalse(MindMapOutline.nodes(in: imported.markdown).isEmpty, file.lastPathComponent)
            XCTAssertEqual(
                imported.images.count,
                expectedImageCounts[file.lastPathComponent],
                file.lastPathComponent
            )
            XCTAssertEqual(try Data(contentsOf: file), original, file.lastPathComponent)
        }
    }
}


extension XMindPackageTests {
    func testCorruptModernEntryDoesNotFallBackToLegacyXML() throws {
        let json = Data(#"[{"rootTopic":{"title":"Modern"}}]"#.utf8)
        let xml = Data("<xmap-content><sheet><topic><title>Stale legacy</title></topic></sheet></xmap-content>".utf8)
        let (root, file) = try archive(["content.json": json, "content.xml": xml])
        defer { try? FileManager.default.removeItem(at: root) }

        var bytes = try Data(contentsOf: file)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        var cursor = 0
        var corrupted = false
        while let header = bytes.range(of: signature, in: cursor..<bytes.count) {
            let start = header.lowerBound
            guard start + 46 <= bytes.count else { break }
            let nameLength = Int(bytes[start + 28]) | Int(bytes[start + 29]) << 8
            let extraLength = Int(bytes[start + 30]) | Int(bytes[start + 31]) << 8
            let commentLength = Int(bytes[start + 32]) | Int(bytes[start + 33]) << 8
            let nameStart = start + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd + extraLength + commentLength <= bytes.count else { break }
            if String(data: bytes.subdata(in: nameStart..<nameEnd), encoding: .utf8) == "content.json" {
                bytes.replaceSubrange((start + 16)..<(start + 20), with: [0, 0, 0, 0])
                corrupted = true
                break
            }
            cursor = nameEnd + extraLength + commentLength
        }
        XCTAssertTrue(corrupted)
        try bytes.write(to: file, options: .atomic)
        XCTAssertThrowsError(try XMindPackage.importOutline(from: file))
    }
}
