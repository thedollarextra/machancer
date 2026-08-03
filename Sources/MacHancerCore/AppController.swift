import AppKit
import SwiftUI

/// Agent lifecycle: status item, settings window, event tap ownership.
public final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    /// The settings window lives in its own process; this is the handle to it.
    private var settingsProcess: Process?
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

        // The settings window is a separate process, so its writes land in the
        // preference file without this one noticing. Re-read when it says so.
        PreferenceBridge.observeChanges {
            UserPreferences.shared.reload()
            // The log's own switches live in the same file, and it is *this* process
            // that writes the log — so a toggle flipped in the settings window has to
            // land here, or turning logging on would appear to do nothing.
            DebugLog.refreshSettings()
            // Logged because a silent reload is indistinguishable from a missed one, and
            // "settings stopped applying" is the failure this design has to rule out.
            DebugLog.write("preferences reloaded from the settings process")
        }

        // Warm the frontmost-app cache before the first event arrives.
        _ = FrontmostAppTracker.shared
        // And register for space-change notifications before the first switch is asked
        // for — the first one would otherwise have nothing to wait on.
        _ = SpaceMonitor.shared

        // First launch with no permission: show the settings window so the user
        // has somewhere to land after the system prompt.
        if !AX.isTrusted {
            openSettings()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        eventTapManager.stop()
        // Don't outlive the agent: a settings window with nothing behind it can still
        // write preferences no one is listening to.
        if let settingsProcess, settingsProcess.isRunning { settingsProcess.terminate() }
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
            withTitle: "Quit MacHancer",
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
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacHancer")
        button.toolTip = "MacHancer — \(state.description)"
        button.appearsDisabled = !state.isActive
    }

    /// Launches the settings window as a separate process, or brings up the one already
    /// running.
    ///
    /// Deliberately `Process`, not `NSWorkspace.openApplication`: LaunchServices sees the
    /// bundle identifier is already running and would simply activate *this* process
    /// instead of starting a second one. Spawning the executable directly is what gets a
    /// genuinely separate process out of a single bundle.
    @objc private func openSettings() {
        if let existing = settingsProcess, existing.isRunning {
            // Already up — ask it to come forward rather than starting a second one.
            NSRunningApplication(processIdentifier: existing.processIdentifier)?
                .activate(options: [])
            return
        }

        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = [SettingsProcess.flag]
        do {
            try process.run()
            settingsProcess = process
        } catch {
            NSLog("[MacHancer] Could not open Settings: \(error.localizedDescription)")
            settingsProcess = nil
        }
    }

}
