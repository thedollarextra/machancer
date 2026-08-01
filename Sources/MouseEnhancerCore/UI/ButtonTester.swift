import AppKit
import SwiftUI

/// "Which button is this, and is it even getting here?" — a click-to-listen field
/// plus a readout of the last press.
///
/// Deliberately not built on the event log: the log shows what the engine *decided*,
/// so a button that never reaches the tap produces exactly the same empty log as a
/// button with no binding. This reads the raw stream instead, and separately reports
/// what AppKit delivered to this window, which separates the two cases outright.
public struct ButtonTester: View {
    @ObservedObject private var monitor = ButtonMonitor.shared
    @State private var isTesting = false
    @State private var lastKey: Keystroke?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ButtonTesterField(
                text: fieldText,
                onBegin: {
                    isTesting = true
                    monitor.start()
                },
                onEnd: {
                    isTesting = false
                    monitor.stop()
                },
                onKey: { lastKey = $0 },
                onWindowButton: { monitor.observeFromWindow(button: $0, modifiers: $1) }
            )
            .frame(height: 44)

            if let observation = monitor.latest {
                details(for: observation)
            }

            if let lastKey {
                caption("Last key: \(lastKey.display)")
            }

            if let observation = monitor.latest, !observation.sources.contains(.tap) {
                warning(
                    "This press reached the settings window but not our event tap. The mouse "
                    + "and macOS are fine — the tap is the broken link, not your bindings."
                )
            }

            if let diagnosis = monitor.diagnosis {
                warning(diagnosis)
            }

            HStack(spacing: 12) {
                Button("Clear") {
                    monitor.clear()
                    lastKey = nil
                }
                .disabled(monitor.latest == nil && lastKey == nil)

                if isTesting {
                    caption("Bindings are paused while listening. Press Escape or click away to stop.")
                } else {
                    caption("Sees every button, whatever your bindings, exclusions, or gesture state say.")
                }
            }
        }
        .onDisappear {
            isTesting = false
            monitor.stop()
        }
    }

    private var fieldText: String {
        if let observation = monitor.latest {
            let modifiers = observation.modifiers.isEmpty ? "" : observation.modifiers.symbols + " "
            return "\(modifiers)\(observation.label)"
        }
        return isTesting
            ? "Listening — press a mouse button or a key…"
            : "Click here, then press a mouse button"
    }

    private func details(for observation: ButtonMonitor.Observation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            row("Name", observation.label)
            row("CGEvent button number", "\(observation.button)")
            row("Modifiers", observation.modifiers.isEmpty ? "none" : observation.modifiers.symbols)
            row("Seen by", observation.seenBy)

            // The number the binding matches on is not the number printed on the mouse,
            // and checking a binding by eye against the wrong one is a dead end.
            caption("Bindings match the CGEvent number, which runs one behind the name: "
                    + "Button 4 is 3, Button 5 is 4.")
                .padding(.top, 2)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(name):")
                .foregroundStyle(.secondary)
            Text(value)
                .monospaced()
            Spacer()
        }
        .font(.caption)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The interactive surface itself.
///
/// An `NSView` for the same reason `KeystrokeRecorder` is one: SwiftUI cannot see a
/// raw key press before the system interprets it, and it has no route to
/// `otherMouseDown` at all — which is precisely the event being diagnosed.
struct ButtonTesterField: NSViewRepresentable {
    var text: String
    var onBegin: () -> Void
    var onEnd: () -> Void
    var onKey: (Keystroke) -> Void
    var onWindowButton: (Int, ModifierSet) -> Void

    func makeNSView(context: Context) -> FieldView {
        let view = FieldView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: FieldView, context: Context) {
        apply(to: view)
        view.needsDisplay = true
    }

    /// Re-captured on every update: SwiftUI hands out fresh closures per render, and
    /// a stale one writes into a state box that is no longer current.
    private func apply(to view: FieldView) {
        view.text = text
        view.onBegin = onBegin
        view.onEnd = onEnd
        view.onKey = onKey
        view.onWindowButton = onWindowButton
    }

    final class FieldView: NSView {
        var text: String = ""
        var onBegin: (() -> Void)?
        var onEnd: (() -> Void)?
        var onKey: ((Keystroke) -> Void)?
        var onWindowButton: ((Int, ModifierSet) -> Void)?

        private var isTesting = false

        override var acceptsFirstResponder: Bool { true }

        /// Start on the click that enters the field, rather than making the user click
        /// once to focus the window and again to begin.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            begin()
        }

        /// The event under test, arriving by the ordinary responder chain. Recorded
        /// even when the field wasn't listening yet — someone reaching for button 4
        /// first and reading the instructions second should still get an answer.
        override func otherMouseDown(with event: NSEvent) {
            begin()
            onWindowButton?(event.buttonNumber, ModifierSet(nsFlags: event.modifierFlags))
        }

        override func keyDown(with event: NSEvent) {
            guard isTesting else { super.keyDown(with: event); return }

            // Escape leaves testing rather than being reported as a key.
            if event.keyCode == 0x35 {
                window?.makeFirstResponder(nil)
                return
            }

            onKey?(Keystroke(keyCode: event.keyCode, modifiers: ModifierSet(nsFlags: event.modifierFlags)))
        }

        /// Swallow key equivalents while listening, so pressing ⌘Q to see what it looks
        /// like doesn't quit the app instead.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isTesting else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        override func resignFirstResponder() -> Bool {
            end()
            return true
        }

        override func viewDidMoveToWindow() {
            if window == nil { end() }
        }

        private func begin() {
            guard !isTesting else { return }
            // Re-targeting first responder when we already hold it makes AppKit resign
            // and re-acquire, which would end the session we are starting.
            if window?.firstResponder !== self {
                window?.makeFirstResponder(self)
            }
            isTesting = true
            onBegin?()
            needsDisplay = true
        }

        private func end() {
            guard isTesting else { return }
            isTesting = false
            onEnd?()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                xRadius: 6,
                yRadius: 6
            )

            (isTesting ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                       : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (isTesting ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isTesting ? 2 : 1
            path.stroke()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: isTesting ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}
