import AppKit
import SwiftUI

/// Click-to-record shortcut field.
///
/// SwiftUI has no way to intercept a raw key press with modifiers before the system
/// interprets it, so this drops to an `NSView` that takes first responder and reads
/// `keyDown` directly.
public struct KeystrokeRecorder: NSViewRepresentable {
    @Binding var keystroke: Keystroke?

    public init(keystroke: Binding<Keystroke?>) {
        self._keystroke = keystroke
    }

    public func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { keystroke = $0 }
        return view
    }

    public func updateNSView(_ view: RecorderView, context: Context) {
        view.keystroke = keystroke
        view.needsDisplay = true
    }

    public final class RecorderView: NSView {
        var keystroke: Keystroke?
        var onCapture: ((Keystroke) -> Void)?
        private var isRecording = false

        public override var acceptsFirstResponder: Bool { true }
        public override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

        public override func mouseDown(with event: NSEvent) {
            isRecording = true
            window?.makeFirstResponder(self)
            needsDisplay = true
        }

        public override func resignFirstResponder() -> Bool {
            isRecording = false
            needsDisplay = true
            return true
        }

        public override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }

            // Escape abandons recording rather than binding Escape itself.
            if event.keyCode == 0x35 {
                isRecording = false
                window?.makeFirstResponder(nil)
                needsDisplay = true
                return
            }

            let captured = Keystroke(
                keyCode: event.keyCode,
                modifiers: ModifierSet(nsFlags: event.modifierFlags)
            )
            keystroke = captured
            onCapture?(captured)

            isRecording = false
            window?.makeFirstResponder(nil)
            needsDisplay = true
        }

        /// Swallow key equivalents (⌘Q, ⌘W…) while recording, so binding them doesn't
        /// quit the app instead.
        public override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        public override func draw(_ dirtyRect: NSRect) {
            let radius: CGFloat = 5
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: radius, yRadius: radius)

            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                         : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isRecording ? 2 : 1
            path.stroke()

            let text: String
            let color: NSColor
            if isRecording {
                text = "Press a shortcut…"
                color = .secondaryLabelColor
            } else if let keystroke {
                text = keystroke.display
                color = .labelColor
            } else {
                text = "Click to record"
                color = .secondaryLabelColor
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .regular : .medium),
                .foregroundColor: color,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}
