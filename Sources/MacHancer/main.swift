import AppKit
import MacHancerCore

// One binary, two programs.
//
// With `--settings` this is the settings window and nothing else; without it, the
// menu-bar agent. Re-executing the same binary rather than shipping a separate helper is
// what keeps the settings process sharing the agent's code signature — and therefore its
// Accessibility trust — and its preferences domain. See `SettingsApp`.
if CommandLine.arguments.contains(SettingsProcess.flag) {
    SettingsProcess.run()
}

// Agent app: no Dock tile, no main menu bar (mirrors LSUIElement).
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
