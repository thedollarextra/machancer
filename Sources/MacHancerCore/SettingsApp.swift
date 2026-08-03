import AppKit
import SwiftUI

/// The settings window, running as its own short-lived process.
///
/// Building this UI costs the process about 21 MB that never comes back — SwiftUI and
/// CoreAutoLayout hold it as live allocations, so there is nothing for the allocator to
/// release and no API to purge it. Measured, `malloc_zone_pressure_relief` reclaims
/// none of it. The only thing that returns that memory is process exit, which is the
/// whole reason this is a separate process: the agent is meant to sit in the menu bar
/// for weeks, and it should not carry the cost of a window you opened once.
///
/// It is the *same binary* re-executed with `--settings`, not a helper of its own, and
/// that choice is what makes the arrangement cheap:
///
/// - **Same code signature.** TCC keys an Accessibility grant to the code requirement,
///   so a separate helper binary would have its own trust state and `AXIsProcessTrusted`
///   here would answer about the wrong process. Sharing a cdhash means the trust banner
///   is simply correct, with no IPC to carry the agent's state across.
/// - **Same bundle.** One preferences domain, and `SMAppService.mainApp` still refers to
///   the app rather than to a helper, so the launch-at-login toggle keeps working.
///
/// What is left to arrange is that the agent hears about writes, which is
/// `PreferenceBridge`.
public final class SettingsApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacHancer Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.delegate = self
        window.contentMinSize = NSSize(width: 860, height: 480)
        window.setFrameAutosaveName("MacHancerSettings")
        if !window.setFrameUsingName("MacHancerSettings") { window.center() }
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closing the window ends the process — that *is* the feature.
    public func windowWillClose(_ notification: Notification) {
        // Writes are already on disk; the agent has been told. Leave promptly rather
        // than lingering to be tidy, because lingering is the cost being avoided.
        NSApp.terminate(nil)
    }

    /// Someone asked for settings while this process is already up — a second click of
    /// the menu item. Come forward instead of doing nothing.
    public func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        return true
    }
}

public enum SettingsProcess {
    /// The argument that makes this binary the settings window instead of the agent.
    public static let flag = "--settings"

    /// Runs the settings UI. Never returns.
    public static func run() -> Never {
        let app = NSApplication.shared
        let delegate = SettingsApp()
        app.delegate = delegate
        // `.regular` rather than the agent's `.accessory`: this one owns a real window
        // and needs a menu bar, keyboard focus and a place in ⌘-Tab while it is up.
        app.setActivationPolicy(.regular)
        app.run()
        exit(0)
    }
}
