import AppKit
import XCTest
@testable import PKSNotes

final class PDFSelectionDragGestureRecognizerTests: XCTestCase {
    @MainActor
    func testRetainsOriginalMouseDownEventUntilGestureReset() throws {
        let recognizer = PDFSelectionDragGestureRecognizer()
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 30),
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        recognizer.mouseDown(with: event)

        XCTAssertTrue(recognizer.initialMouseDownEvent === event)
        XCTAssertEqual(recognizer.initialMouseDownEvent?.type, .leftMouseDown)

        recognizer.reset()
        XCTAssertNil(recognizer.initialMouseDownEvent)
    }
}
