import AppKit

/// Screen frames, captured on the main thread and readable from anywhere.
///
/// `NSScreen.screens` is AppKit state and is only safe to read on the main thread. The
/// action dispatcher runs on its own serial queue by design — an Accessibility call can
/// block for hundreds of milliseconds and must never sit on the main thread — so any
/// screen question it asks has to be answered from a snapshot rather than from AppKit
/// directly. Read off the main thread the list can come back stale or empty, and an
/// empty list turns a geometry test into a silent "no".
public final class ScreenGeometry {
    public static let shared = ScreenGeometry()

    /// Full frame and visible frame per screen, in CGEvent coordinates (origin
    /// top-left), which is the space every location in this app is expressed in.
    public struct Screen: Sendable {
        public let full: CGRect
        public let visible: CGRect
    }

    private let lock = NSLock()
    private var cached: [Screen] = []
    private var observer: NSObjectProtocol?

    public init() {
        refresh()
        // The Dock moving, a display being plugged in, or resolution changing all land
        // here — which is exactly when a cached frame would otherwise go wrong.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public var screens: [Screen] {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    private func refresh() {
        let snapshot: [Screen]
        if Thread.isMainThread {
            snapshot = Self.capture()
        } else {
            snapshot = DispatchQueue.main.sync { Self.capture() }
        }
        lock.lock()
        cached = snapshot
        lock.unlock()
    }

    /// AppKit's origin is bottom-left of the *primary* screen; every coordinate in this
    /// app is a `CGEvent` location, which is top-left. Converted once, here, rather than
    /// at each call site.
    private static func capture() -> [Screen] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let height = primary.frame.maxY

        func flip(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        return screens.map { Screen(full: flip($0.frame), visible: flip($0.visibleFrame)) }
    }
}
