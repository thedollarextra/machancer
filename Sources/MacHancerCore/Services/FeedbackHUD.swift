import AppKit

/// Brief on-screen confirmation of what just fired.
///
/// Mostly a safety feature: "Close Window under Cursor" destroys something with no
/// undo, and without feedback a mis-click is silent and unattributable.
///
/// The panel is created once and reused — building an `NSPanel` per action would
/// allocate a window server backing store on every click.
@MainActor
public final class FeedbackHUD {
    public static let shared = FeedbackHUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    public init() {}

    public func show(_ text: String) {
        let panel = existingOrNewPanel()
        label?.stringValue = text

        // Follow the cursor's screen, not the "main" one.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let frame = screen?.frame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + frame.height * 0.18
            ))
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 15, weight: .medium)
        text.textColor = .labelColor
        text.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.addSubview(text)

        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 20),
            text.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -20),
            text.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true          // never steal a click
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        self.panel = panel
        self.label = text
        return panel
    }
}
