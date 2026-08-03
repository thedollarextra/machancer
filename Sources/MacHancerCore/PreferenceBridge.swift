import Foundation

/// Tells the agent that another process changed the preference file.
///
/// The settings window runs as its own process, and the agent holds every preference in
/// memory on purpose — the event tap reads them on each event and must never touch
/// `UserDefaults` on that path. Those two facts together mean a write in one process is
/// invisible to the other until someone says so. This is the someone.
///
/// A Darwin notification rather than a distributed `NotificationCenter`: it is the one
/// mechanism that needs no entitlement, no shared container and no App Group, carries no
/// payload to get wrong, and survives either side not being there. There is nothing to
/// send but the fact that something changed, and the receiver re-reads everything anyway.
public enum PreferenceBridge {

    private static let name = "com.machancer.MacHancer.preferences-changed" as CFString

    /// Called by the settings process after any write.
    public static func broadcastChange() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name),
            nil, nil, true
        )
    }

    /// Called by the agent at launch. `handler` runs on the main thread.
    ///
    /// Coalesced: dragging a slider in the settings window writes on every frame, and
    /// each write would otherwise cost the agent a full re-read plus a lookup-index
    /// rebuild. A short delay collapses a drag into one reload, and settings still apply
    /// far faster than anyone can move a mouse to test them.
    public static func observeChanges(_ handler: @escaping () -> Void) {
        Self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in PreferenceBridge.scheduleReload() },
            name,
            nil,
            .deliverImmediately
        )
    }

    private static var handler: (() -> Void)?
    private static var pending = false

    private static func scheduleReload() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pending = false
            handler?()
        }
    }
}
