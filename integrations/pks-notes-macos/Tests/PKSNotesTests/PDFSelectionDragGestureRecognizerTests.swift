import AppKit
import PDFKit
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

    @MainActor
    func testPDFSelectionHitTestingUsesSelectedLineBoundsAndSmallSlop() throws {
        let pageBounds = NSRect(x: 0, y: 0, width: 612, height: 792)
        let source = NSTextView(frame: pageBounds)
        source.string = "Selected first line\n\n\n\nSelected second line"
        let document = try XCTUnwrap(PDFDocument(data: source.dataWithPDF(inside: pageBounds)))
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(
            document.findString("Selected first line", withOptions: []).first
        )
        selection.add(try XCTUnwrap(
            document.findString("Selected second line", withOptions: []).first
        ))

        let lineSelections = selection.selectionsByLine()
        XCTAssertEqual(lineSelections.count, 2)
        let lineBounds = lineSelections.map { $0.bounds(for: page).standardized }
        let first = try XCTUnwrap(lineBounds.first)
        let second = try XCTUnwrap(lineBounds.last)

        XCTAssertTrue(PDFSelectionHitTesting.contains(
            CGPoint(x: first.midX, y: first.midY), in: selection, on: page
        ))
        XCTAssertTrue(PDFSelectionHitTesting.contains(
            CGPoint(x: second.midX, y: second.midY), in: selection, on: page
        ))
        XCTAssertTrue(PDFSelectionHitTesting.contains(
            CGPoint(x: first.maxX + 2.5, y: first.midY), in: selection, on: page
        ))
        XCTAssertFalse(PDFSelectionHitTesting.contains(
            CGPoint(x: first.maxX + 4, y: first.midY), in: selection, on: page
        ))

        let lower = lineBounds.sorted { $0.midY < $1.midY }
        let gapPoint = CGPoint(
            x: lower[0].midX,
            y: (lower[0].maxY + lower[1].minY) / 2
        )
        XCTAssertGreaterThan(lower[1].minY - lower[0].maxY, 6)
        XCTAssertFalse(
            PDFSelectionHitTesting.contains(gapPoint, in: selection, on: page),
            "Whitespace between selected lines must not start a PDF drag"
        )
    }

}
