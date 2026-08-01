import AppKit
import SwiftUI

/// Agent lifecycle: status item, settings window, event tap ownership.
public final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private let eventTapManager = EventTapManager()

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Off unless the `debugLog` default is set, so this costs one bool check at
        // launch. It stays because it is the only way to confirm the diagnostic channel
        // is alive: without a line that always writes, an empty log is ambiguous between
        // "nothing happened" and "logging is broken".
        DebugLog.write("launched, pid \(ProcessInfo.processInfo.processIdentifier)")
        setUpStatusItem()

        eventTapManager.onStateChange = { [weak self] state in
            self?.updateStatusItem(for: state)
        }
        eventTapManager.start()
        updateStatusItem(for: eventTapManager.state)

        // Warm the frontmost-app cache before the first event arrives.
        _ = FrontmostAppTracker.shared

        // First launch with no permission: show the settings window so the user
        // has somewhere to land after the system prompt.
        if !AX.isTrusted {
            openSettings()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        eventTapManager.stop()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        let settings = menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Mouse Enhancer",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu
    }

    /// The icon reflects whether bindings are actually live — a missing permission
    /// used to look identical to a working app.
    private func updateStatusItem(for state: EventTapManager.State) {
        guard let button = statusItem?.button else { return }
        let symbol = state.isActive ? "cursorarrow.click" : "cursorarrow.slash"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mouse Enhancer")
        button.toolTip = "Mouse Enhancer — \(state.description)"
        button.appearsDisabled = !state.isActive
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Mouse Enhancer Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }

        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Drop the window on close. This is a background agent — it spends nearly all its
    /// life with no UI, and holding a SwiftUI hosting view plus a window backing store
    /// the whole time costs more than rebuilding it on the rare reopen.
    public func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        settingsWindow?.contentView = nil
        settingsWindow = nil
    }
}
