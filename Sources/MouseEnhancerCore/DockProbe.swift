import AppKit
import ApplicationServices
import CoreGraphics

/// Answers "is this point over the Dock's tiles?" cheaply enough to call from the
/// event-tap callback.
///
/// Three approaches were tried. Positional hit-testing (`AXUIElementCopyElementAtPosition`)
/// returns `kAXErrorNotImplemented` for the Dock. Asking the window server for a Dock
/// window doesn't work either — on macOS 26 the only Dock-owned window is a permanent
/// full-screen one, and the tile strip is not a window at all. What does work is the
/// union of the tiles' own AX frames, which they report accurately.
///
/// That union costs an AX round trip per tile, far too much for the tap callback, so it
/// is computed on a background queue and cached; the callback only ever does a rectangle
/// containment test. Until the first refresh lands, the screen's reserved edge stands in
/// — the Dock is the reason that edge exists, so it approximates well and needs no
/// cross-process call at all.
public final class DockProbe {
    private let queue = DispatchQueue(label: "com.mouseenhancer.dockprobe", qos: .utility)
    private let ttl: CFTimeInterval

    /// Written on the main thread only (the refresh hops back), read from the tap
    /// callback which also runs on the main run loop.
    private var cachedRect: CGRect?
    private var cachedAt: CFTimeInterval = 0
    private var isRefreshing = false

    public init(cacheTTL: CFTimeInterval = 3.0) {
        self.ttl = cacheTTL
    }

    /// Cheap and non-blocking: never performs a cross-process call on the caller's thread.
    public func contains(_ point: CGPoint) -> Bool {
        if CACurrentMediaTime() - cachedAt > ttl { refreshInBackground() }
        if let rect = cachedRect { return rect.contains(point) }
        return reservedEdgeContains(point)
    }

    /// Force the next query to re-read (Dock moved, hid, or resized).
    public func invalidate() { cachedAt = 0 }

    // MARK: - Refresh

    private func refreshInBackground() {
        guard !isRefreshing else { return }
        isRefreshing = true
        // Stamped now rather than on completion: a Dock that yields nothing must not
        // start a fresh AX enumeration on every subsequent mouse event.
        cachedAt = CACurrentMediaTime()

        queue.async { [weak self] in
            let rect = Self.tileUnion()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                if let rect { self.cachedRect = rect }
            }
        }
    }

    /// Union of every Dock tile's frame, in AX coordinates (origin top-left).
    private static func tileUnion() -> CGRect? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        var union: CGRect?
        for list in AX.children(dockElement) {
            for tile in AX.children(list) {
                guard AX.role(tile) == "AXDockItem", let frame = AX.frame(tile) else { continue }
                union = union.map { $0.union(frame) } ?? frame
            }
        }
        // Slack: the strip's background extends a little past the tiles, and a click a
        // pixel outside one is still a click on the Dock.
        return union?.insetBy(dx: -6, dy: -6)
    }

    /// Fallback: the screen edge the Dock has reserved for itself.
    ///
    /// `visibleFrame` excludes what the Dock and menu bar have claimed, so the difference
    /// at the Dock's edge is the strip. Pure `NSScreen` arithmetic with no cross-process
    /// call, but it spans the full screen width, so it is coarser than the tile union and
    /// is used only until the first refresh completes.
    private func reservedEdgeContains(_ point: CGPoint) -> Bool {
        guard let primary = NSScreen.screens.first else { return false }
        let flipTo = primary.frame.maxY

        for screen in NSScreen.screens {
            let frame = screen.frame
            let visible = screen.visibleFrame
            // Both converted to AX space (origin top-left of the primary display).
            let frameTop = flipTo - frame.maxY
            let frameBottom = flipTo - frame.minY
            guard point.x >= frame.minX, point.x <= frame.maxX,
                  point.y >= frameTop, point.y <= frameBottom else { continue }

            let bottomInset = visible.minY - frame.minY
            if bottomInset > 1, point.y > frameBottom - bottomInset { return true }

            let leftInset = visible.minX - frame.minX
            if leftInset > 1, point.x < frame.minX + leftInset { return true }

            let rightInset = frame.maxX - visible.maxX
            if rightInset > 1, point.x > frame.maxX - rightInset { return true }

            return false
        }
        return false
    }
}
