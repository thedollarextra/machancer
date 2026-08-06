import AppKit
import Foundation

/// Reports when macOS has actually changed space.
///
/// The window server silently drops a space-switch request that arrives while the
/// previous transition is still running, which is why a quick second swipe used to do
/// nothing at all. Spacing repeats by a fixed delay only guesses at how long that
/// transition takes; this waits for the system to say it happened.
///
/// `NSWorkspace.activeSpaceDidChangeNotification` is the public signal for it, and it
/// carries no payload — only the fact. That's enough: the dispatcher needs to know that
/// *a* change landed since it asked for one, not which space it landed on.
public final class SpaceMonitor {
    public static let shared = SpaceMonitor()

    private let condition = NSCondition()
    private var _generation = 0
    private var _lastChange: TimeInterval = 0
    private var observer: NSObjectProtocol?

    public init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil          // posting thread; the wait below is on the action queue
        ) { [weak self] _ in
            self?.note()
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Increments on every space change. Sample it before asking for a switch, and a
    /// higher value afterwards means the switch landed.
    public var generation: Int {
        condition.lock()
        defer { condition.unlock() }
        return _generation
    }

    /// Uptime of the most recent change, or 0 if none has been seen.
    public var lastChangeTime: TimeInterval {
        condition.lock()
        defer { condition.unlock() }
        return _lastChange
    }

    /// Blocks until the generation moves past `generation`, or the timeout expires.
    /// Returns `false` on timeout — which is also what a legitimate no-op looks like,
    /// such as asking to move past the last space in the row.
    @discardableResult
    public func waitForChange(after generation: Int, timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while _generation <= generation {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    private func note() {
        // The other half of the pair: a posted switch that is never followed by this is
        // one macOS declined, which looks identical from the outside to one that landed
        // on a display you were not looking at.
        DebugLog.write("space actually changed")
        condition.lock()
        _generation += 1
        _lastChange = ProcessInfo.processInfo.systemUptime
        condition.broadcast()
        condition.unlock()
    }
}
