import XCTest
@testable import PKSNotes

final class MarkdownPreviewSnapshotTests: XCTestCase {
    func testPreviousSnapshotRemainsDisplayableDuringSameDocumentRevisionUpdate() {
        let snapshot = MarkdownPreviewSnapshot(
            identity: "/vault/large-note.md",
            revision: 10,
            matchID: nil,
            sections: []
        )

        XCTAssertTrue(snapshot.canDisplay(identity: "/vault/large-note.md", matchID: nil))
        XCTAssertTrue(snapshot.matches(identity: "/vault/large-note.md", revision: 10, matchID: nil))
        XCTAssertFalse(snapshot.matches(identity: "/vault/large-note.md", revision: 11, matchID: nil))
    }

    func testPreviousSnapshotIsNotReusedAcrossDocumentsOrSearchMatches() {
        let snapshot = MarkdownPreviewSnapshot(
            identity: "/vault/first.md",
            revision: 10,
            matchID: "first-match",
            sections: []
        )

        XCTAssertFalse(snapshot.canDisplay(identity: "/vault/second.md", matchID: "first-match"))
        XCTAssertFalse(snapshot.canDisplay(identity: "/vault/first.md", matchID: "second-match"))
        XCTAssertFalse(snapshot.canDisplay(identity: "/vault/first.md", matchID: nil))
    }
}
