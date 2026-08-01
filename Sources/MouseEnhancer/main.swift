import AppKit
import MouseEnhancerCore

// Agent app: no Dock tile, no main menu bar (mirrors LSUIElement).
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
