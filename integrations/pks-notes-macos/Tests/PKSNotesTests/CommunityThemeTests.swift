import AppKit
import Foundation
import XCTest
@testable import PKSNotes

final class CommunityThemeTests: XCTestCase {
    private var sampleURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/quiet-study.leafspan-theme")
    }

    func testImportPreviewTokensExportAndDelete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CommunityThemeStore(directory: root.appendingPathComponent("Themes"))
        let theme = try store.importFile(sampleURL)

        XCTAssertEqual(theme.id, "quiet-study")
        XCTAssertEqual(theme.name, "Quiet Study")
        XCTAssertEqual(store.installed(), [theme])
        XCTAssertEqual(store.load(id: theme.id), theme)
        XCTAssertEqual(NotesTheme.community(theme).rawValue, "community:quiet-study")
        XCTAssertEqual(NotesTheme.community(theme).typography.pageWidth, 730)
        XCTAssertEqual(NotesTheme.community(theme).quoteRuleWidth, 2)
        XCTAssertTrue(NotesTheme.community(theme).quoteItalic)

        let exported = root.appendingPathComponent("export.leafspan-theme")
        try store.export(theme, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), try Data(contentsOf: sampleURL))

        XCTAssertThrowsError(try store.importFile(sampleURL)) { error in
            XCTAssertEqual(error as? CommunityThemeError, .duplicate)
        }
        try store.delete(id: theme.id)
        XCTAssertNil(store.load(id: theme.id))
        XCTAssertEqual(store.installed(), [])
    }

    func testRejectsUnsupportedDataUnsafeIDsAndUnusableContrast() throws {
        let raw = try Data(contentsOf: sampleURL)
        XCTAssertEqual(try CommunityThemeStore.decode(raw).id, "quiet-study")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])

        func rejects(_ change: (inout [String: Any]) -> Void) {
            var modified = original
            change(&modified)
            let data = try! JSONSerialization.data(withJSONObject: modified)
            XCTAssertThrowsError(try CommunityThemeStore.decode(data))
        }

        rejects { $0["formatVersion"] = 999 }
        rejects { $0["id"] = "../escape" }
        rejects { $0["assets"] = ["../../unsafe"] }
        rejects { $0["name"] = "\n" }
        rejects {
            var palette = $0["colors"] as! [String: Any]
            palette["ink"] = ["light": "#FFFFFF", "dark": "#000000"]
            $0["colors"] = palette
        }
        rejects {
            var typography = $0["typography"] as! [String: Any]
            typography["bodySize"] = -42
            $0["typography"] = typography
        }
        XCTAssertThrowsError(try CommunityThemeStore.decode(Data(repeating: 65, count: 65_537)))
        XCTAssertNil(CommunityThemeStore(directory: FileManager.default.temporaryDirectory).load(id: "../escape"))
        XCTAssertEqual(NotesTheme.restored("community:missing-package"), .system)
        XCTAssertEqual(NotesTheme.allCases.count, 5)
    }

    func testRejectsSymbolicLinkAndDirectoryInputs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CommunityThemeStore(directory: root.appendingPathComponent("Themes"))
        let symlink = root.appendingPathComponent("linked.leafspan-theme")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sampleURL)
        XCTAssertThrowsError(try store.importFile(symlink))
        let directory = root.appendingPathComponent("folder.leafspan-theme", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.importFile(directory))
    }

    func testCommunityPaletteRespectsLightDarkContrast() throws {
        let theme = try CommunityThemeStore.decode(Data(contentsOf: sampleURL))
        let colors = theme.colors
        XCTAssertTrue(colors.isValid)
        XCTAssertGreaterThanOrEqual(
            CommunityReadingTheme.ColorPair.contrast(colors.canvas.light, colors.ink.light), 4.5
        )
        XCTAssertGreaterThanOrEqual(
            CommunityReadingTheme.ColorPair.contrast(colors.canvas.dark, colors.ink.dark), 4.5
        )
    }
}
