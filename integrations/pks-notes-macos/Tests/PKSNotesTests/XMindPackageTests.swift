import Foundation
import XCTest
@testable import PKSNotes

final class XMindPackageTests: XCTestCase {
    private func archive(_ payload: String, entry: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeafspanXMind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try payload.write(to: root.appendingPathComponent(entry), atomically: true, encoding: .utf8)
        let target = root.appendingPathComponent("Fixture.xmind")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", target.path, entry]
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
                       "# Central Topic\n- Feature 1\n  - Nested A\n- Feature 2\n")
        XCTAssertEqual(try Data(contentsOf: file), before, "Import must not mutate the .xmind archive.")
    }

    func testImportsJSONNoteBodyWithoutCreatingNewTopics() throws {
        let content = #"""
        [{
          "rootTopic":{
            "title":"Map",
            "notes":{"plain":{"content":"Root note\nSecond line"}},
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
        XCTAssertEqual(markdown, "# Map\n> Root note\n> Second line\n- Child\n  > Child note\n")
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
}
