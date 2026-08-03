import AppKit

/// Caches the frontmost application's bundle identifier.
///
/// The per-app exclusion check runs inside the event-tap callback, on every mouse
/// event. `NSWorkspace.frontmostApplication` is a cross-process lookup and far too
/// expensive for that path, so the value is refreshed from activation notifications
/// instead and read from memory.
public final class FrontmostAppTracker {
    public static let shared = FrontmostAppTracker()

    public private(set) var bundleIdentifier: String?
    public private(set) var localizedName: String?

    private var observer: NSObjectProtocol?

    public init() {
        refresh(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.refresh(app)
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func refresh(_ app: NSRunningApplication?) {
        bundleIdentifier = app?.bundleIdentifier
        localizedName = app?.localizedName
    }
}
