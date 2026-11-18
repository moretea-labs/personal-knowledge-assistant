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

    @MainActor
    func testPanBeginsAfterPointerMovementAndRetainsTheInitiatingEvent() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 120),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
        let view = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = view

        let recognizer = PDFSelectionDragGestureRecognizer()
        view.addGestureRecognizer(recognizer)

        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 30),
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let dragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 44, y: 30),
            modifierFlags: [],
            timestamp: timestamp + 0.1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        window.sendEvent(down)
        window.sendEvent(dragged)

        XCTAssertTrue(
            recognizer.state == .began || recognizer.state == .changed,
            "A pan threshold crossing delivered through AppKit must leave .possible"
        )
        XCTAssertTrue(recognizer.initialMouseDownEvent === down)

        recognizer.reset()
        XCTAssertNil(recognizer.initialMouseDownEvent)
    }

}
