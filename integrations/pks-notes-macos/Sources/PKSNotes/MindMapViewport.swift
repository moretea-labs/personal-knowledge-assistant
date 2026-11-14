import AppKit
import SwiftUI

/// Geometry only: the Markdown layout is never rewritten for viewport moves.
enum MindMapViewportGeometry {
    /// Return only node cards that intersect the viewport plus a screen-space
    /// prefetch margin. Connectors remain in the single Canvas, so the full
    /// Markdown layout and infinite navigation geometry stay unchanged.
    static func visibleNodeIDs(
        in layout: MindMapLayoutSnapshot,
        viewport: CGSize,
        offset: CGSize,
        zoom: CGFloat,
        overscan: CGFloat = 320,
        pinnedIDs: Set<Int> = []
    ) -> Set<Int> {
        guard !layout.placements.isEmpty else { return [] }
        guard let visibleRect = visibleRect(
            mapSize: layout.size, viewport: viewport, offset: offset,
            zoom: zoom, overscan: overscan
        ) else {
            return Set(layout.placements.map(\.id))
        }
        return layout.visiblePlacementIDs(in: visibleRect, pinnedIDs: pinnedIDs)
    }

    static func visibleRect(
        mapSize: CGSize,
        viewport: CGSize,
        offset: CGSize,
        zoom: CGFloat,
        overscan: CGFloat = 320
    ) -> CGRect? {
        guard mapSize.width > 0, mapSize.height > 0,
              viewport.width > 0, viewport.height > 0,
              mapSize.width.isFinite, mapSize.height.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              offset.width.isFinite, offset.height.isFinite,
              zoom > 0, zoom.isFinite else { return nil }

        let margin = (overscan.isFinite ? max(0, overscan) : 0) / zoom
        return CGRect(
            x: mapSize.width / 2 + (-viewport.width / 2 - offset.width) / zoom - margin,
            y: mapSize.height / 2 + (-viewport.height / 2 - offset.height) / zoom - margin,
            width: viewport.width / zoom + margin * 2,
            height: viewport.height / zoom + margin * 2
        )
    }

    /// Conservative bounds test for a cubic or orthogonal connector. The
    /// control-point rectangle contains the complete path; stroke width is
    /// included so visible edge caps are never clipped.
    static func connectorIntersectsViewport(
        start: CGPoint,
        end: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        viewport: CGRect,
        lineWidth: CGFloat
    ) -> Bool {
        guard viewport.width > 0, viewport.height > 0,
              viewport.minX.isFinite, viewport.minY.isFinite,
              viewport.maxX.isFinite, viewport.maxY.isFinite,
              start.x.isFinite, start.y.isFinite,
              end.x.isFinite, end.y.isFinite,
              control1.x.isFinite, control1.y.isFinite,
              control2.x.isFinite, control2.y.isFinite else {
            return true
        }

        // Avoid allocating point/map arrays for every edge on every pan frame.
        let minX = min(min(start.x, end.x), min(control1.x, control2.x))
        let maxX = max(max(start.x, end.x), max(control1.x, control2.x))
        let minY = min(min(start.y, end.y), min(control1.y, control2.y))
        let maxY = max(max(start.y, end.y), max(control1.y, control2.y))
        let margin = (lineWidth.isFinite ? max(0, lineWidth) : 0) / 2
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -margin, dy: -margin)
        return bounds.intersects(viewport)
    }

    static func fittingZoom(mapSize: CGSize, viewport: CGSize) -> CGFloat {
        guard mapSize.width > 0, mapSize.height > 0,
              viewport.width > 36, viewport.height > 36,
              mapSize.width.isFinite, mapSize.height.isFinite else { return 1 }
        return min(1.25, max(0.0001, min(
            (viewport.width - 36) / mapSize.width,
            (viewport.height - 36) / mapSize.height
        )))
    }

    /// At 100%, place the root left of center so nearby child columns are
    /// visible immediately, without shrinking the entire mind map.
    static func initialRootOffset(root: CGPoint, mapSize: CGSize, viewport: CGSize) -> CGSize {
        let centered = centeredOffset(for: root, mapSize: mapSize, zoom: 1)
        return CGSize(
            width: centered.width - viewport.width * 0.18,
            height: centered.height
        )
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

    static func contains(_ pointInWindow: NSPoint, in view: NSView, window: NSWindow) -> Bool {
        guard view.window === window else { return false }
        let screenPoint = window.convertPoint(toScreen: pointInWindow)
        return view.bounds.contains(view.convert(screenPoint, from: nil))
    }

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
                      MindMapWheelCapture.contains(event.locationInWindow, in: self, window: window) else {
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
