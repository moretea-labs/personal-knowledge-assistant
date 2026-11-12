import AppKit
import SwiftUI

/// Geometry only: the Markdown layout is never rewritten for viewport moves.
enum MindMapViewportGeometry {
    static func fittingZoom(mapSize: CGSize, viewport: CGSize) -> CGFloat {
        guard mapSize.width > 0, mapSize.height > 0,
              viewport.width > 36, viewport.height > 36,
              mapSize.width.isFinite, mapSize.height.isFinite else { return 1 }
        return min(1.25, max(0.0001, min(
            (viewport.width - 36) / mapSize.width,
            (viewport.height - 36) / mapSize.height
        )))
    }

    static func centeredOffset(for node: CGPoint, mapSize: CGSize, zoom: CGFloat) -> CGSize {
        CGSize(
            width: (mapSize.width / 2 - node.x) * zoom,
            height: (mapSize.height / 2 - node.y) * zoom
        )
    }

    /// Preserve the content point under a pinch anchor while the scale changes.
    static func offsetPreservingAnchor(
        _ offset: CGSize,
        from oldZoom: CGFloat,
        to newZoom: CGFloat,
        anchor: CGPoint,
        viewport: CGSize
    ) -> CGSize {
        guard oldZoom > 0, oldZoom.isFinite, newZoom.isFinite else { return offset }
        let x = anchor.x - viewport.width / 2
        let y = anchor.y - viewport.height / 2
        let factor = newZoom / oldZoom
        return CGSize(
            width: x - (x - offset.width) * factor,
            height: y - (y - offset.height) * factor
        )
    }
}

/// A transparent, non-hit-testing receiver for macOS trackpad two-finger
/// scrolling and mouse-wheel panning. Node dragging/selection remain SwiftUI.
struct MindMapWheelCapture: NSViewRepresentable {
    let onScroll: (CGSize) -> Void

    func makeNSView(context: Context) -> WheelView {
        let view = WheelView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: WheelView, context: Context) {
        view.onScroll = onScroll
    }

    final class WheelView: NSView {
        var onScroll: (CGSize) -> Void = { _ in }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window,
                      event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
                    return event
                }
                let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 16
                let delta = CGSize(
                    width: event.scrollingDeltaX * multiplier,
                    height: event.scrollingDeltaY * multiplier
                )
                if delta != .zero { self.onScroll(delta) }
                // This event belongs to the hovered canvas, not a surrounding scroll view.
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
