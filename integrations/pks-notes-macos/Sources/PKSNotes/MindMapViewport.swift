import AppKit
import SwiftUI

/// Geometry only: the Markdown layout is never rewritten for viewport moves.
enum MindMapViewportGeometry {
    // Preferred floor for overview fitting. Large maps open at the root without auto-disclosure.
    static let minimumInitialZoom: CGFloat = 0.68

    static func initialInset(for dimension: CGFloat) -> CGFloat {
        min(24, max(12, dimension * 0.04))
    }

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

    /// Fit the visible node cards, not the padded infinite-canvas extent.
    /// Center the actual content bounds inside the viewport with the same 18pt inset.
    static func fittingViewport(
        placements: [MindMapPlacement],
        mapSize: CGSize,
        viewport: CGSize
    ) -> (zoom: CGFloat, offset: CGSize)? {
        guard !placements.isEmpty,
              mapSize.width > 0, mapSize.height > 0,
              viewport.width > 36, viewport.height > 36,
              mapSize.width.isFinite, mapSize.height.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              placements.allSatisfy({
                  $0.center.x.isFinite && $0.center.y.isFinite
                      && $0.size.width.isFinite && $0.size.width > 0
                      && $0.size.height.isFinite && $0.size.height > 0
              }) else { return nil }

        let contentBounds = placements.reduce(CGRect.null) { bounds, placement in
            bounds.union(CGRect(
                x: placement.center.x - placement.size.width / 2,
                y: placement.center.y - placement.size.height / 2,
                width: placement.size.width,
                height: placement.size.height
            ))
        }
        guard !contentBounds.isNull,
              contentBounds.minX.isFinite, contentBounds.maxX.isFinite,
              contentBounds.minY.isFinite, contentBounds.maxY.isFinite,
              contentBounds.width > 0, contentBounds.height > 0 else { return nil }

        let zoom = min(1.25, max(0.0001, min(
            (viewport.width - 36) / contentBounds.width,
            (viewport.height - 36) / contentBounds.height
        )))
        let center = CGPoint(x: contentBounds.midX, y: contentBounds.midY)
        return (
            zoom,
            centeredOffset(for: center, mapSize: mapSize, zoom: zoom)
        )
    }

    /// Fit the root and the supplied focus placements on first open.
    /// Large maps stay fully expanded; off-screen descendants remain reachable by pan and zoom.
    static func initialRootViewport(
        root: MindMapPlacement,
        visiblePlacements: [MindMapPlacement],
        mapSize: CGSize,
        viewport: CGSize
    ) -> (zoom: CGFloat, offset: CGSize) {
        guard mapSize.width > 0, mapSize.height > 0,
              viewport.width > 0, viewport.height > 0,
              mapSize.width.isFinite, mapSize.height.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              root.center.x.isFinite, root.center.y.isFinite,
              root.size.width.isFinite, root.size.width > 0,
              root.size.height.isFinite, root.size.height > 0,
              visiblePlacements.allSatisfy({
                  $0.center.x.isFinite && $0.center.y.isFinite
                      && $0.size.width.isFinite && $0.size.width > 0
                      && $0.size.height.isFinite && $0.size.height > 0
              }) else {
            return (1, .zero)
        }

        let rootBounds = CGRect(
            x: root.center.x - root.size.width / 2,
            y: root.center.y - root.size.height / 2,
            width: root.size.width,
            height: root.size.height
        )
        let contentBounds = visiblePlacements.reduce(rootBounds) { bounds, placement in
            bounds.union(CGRect(
                x: placement.center.x - placement.size.width / 2,
                y: placement.center.y - placement.size.height / 2,
                width: placement.size.width,
                height: placement.size.height
            ))
        }
        guard contentBounds.minX.isFinite, contentBounds.maxX.isFinite,
              contentBounds.minY.isFinite, contentBounds.maxY.isFinite else {
            return (1, .zero)
        }

        let contentWidth = max(1, contentBounds.width)
        let contentHeight = max(1, contentBounds.height)
        let horizontalInset = Self.initialInset(for: viewport.width)
        let verticalInset = Self.initialInset(for: viewport.height)
        let availableWidth = max(1, viewport.width - horizontalInset * 2)
        let availableHeight = max(1, viewport.height - verticalInset * 2)
        let fitZoom = min(1, max(0.0001, min(
            availableWidth / contentWidth, availableHeight / contentHeight
        )))

        let minimumRootX = horizontalInset + (root.center.x - contentBounds.minX) * fitZoom
        let maximumRootX = viewport.width - horizontalInset
            - (contentBounds.maxX - root.center.x) * fitZoom
        let preferredRootX = viewport.width * 0.32
        let rootScreenX = min(
            max(preferredRootX, minimumRootX),
            max(minimumRootX, maximumRootX)
        )

        let minimumRootY = verticalInset + (root.center.y - contentBounds.minY) * fitZoom
        let maximumRootY = viewport.height - verticalInset
            - (contentBounds.maxY - root.center.y) * fitZoom
        let preferredRootY = viewport.height / 2
        let rootScreenY = min(
            max(preferredRootY, minimumRootY),
            max(minimumRootY, maximumRootY)
        )

        let offset = CGSize(
            width: rootScreenX - viewport.width / 2
                - (root.center.x - mapSize.width / 2) * fitZoom,
            height: rootScreenY - viewport.height / 2
                - (root.center.y - mapSize.height / 2) * fitZoom
        )
        return (fitZoom, offset)
    }

    /// Detect whether the viewport still shows the untouched opening overview.
    /// Window resizing may recompute that overview, but must not override user navigation.
    static func isAtInitialRootViewport(
        root: MindMapPlacement,
        visiblePlacements: [MindMapPlacement],
        mapSize: CGSize,
        viewport: CGSize,
        zoom: CGFloat,
        offset: CGSize
    ) -> Bool {
        guard viewport.width.isFinite, viewport.height.isFinite,
              zoom > 0, zoom.isFinite,
              offset.width.isFinite, offset.height.isFinite else { return false }
        // GeometryReader can report .zero before the first real layout pass.
        // That is still the untouched opening state when the initial transform
        // has not moved; let the first non-zero size apply the root overview.
        guard viewport.width > 0, viewport.height > 0 else {
            return abs(zoom - 1) < 0.001
                && abs(offset.width) < 0.5
                && abs(offset.height) < 0.5
        }

        let initial = initialRootViewport(
            root: root, visiblePlacements: visiblePlacements, mapSize: mapSize, viewport: viewport
        )
        return abs(zoom - initial.zoom) < 0.001
            && abs(offset.width - initial.offset.width) < 0.5
            && abs(offset.height - initial.offset.height) < 0.5
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
