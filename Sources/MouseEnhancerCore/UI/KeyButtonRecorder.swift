import AppKit
import SwiftUI

/// Click-to-record field capturing a single keyboard key as a binding's input.
///
/// The sibling of `KeystrokeRecorder`, but it deliberately captures only the key code:
/// a binding's modifiers come from the row's ⌃⌥⇧⌘ toggles, so recording them here too
/// would give the same fact two owners.
struct KeyButtonRecorder: NSViewRepresentable {
    /// The binding's input in `MouseButton` namespace terms (`keyNamespace + keyCode`).
    @Binding var button: Int

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { button = MouseButton.keyButton($0) }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.label = MouseButton.label(button)
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var label: String = ""
        var onCapture: ((UInt16) -> Void)?
        private var isRecording = false

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 118, height: 24) }

        override func mouseDown(with event: NSEvent) {
            isRecording = true
            window?.makeFirstResponder(self)
            needsDisplay = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            needsDisplay = true
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }

            // Escape abandons recording rather than binding Escape itself.
            if event.keyCode == 0x35 {
                isRecording = false
                window?.makeFirstResponder(nil)
                needsDisplay = true
                return
            }

            onCapture?(event.keyCode)
            isRecording = false
            window?.makeFirstResponder(nil)
            needsDisplay = true
        }

        /// Swallow key equivalents (⌘Q, ⌘W…) while recording, so pressing one binds
        /// it instead of quitting the app.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 5, yRadius: 5)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                         : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isRecording ? 2 : 1
            path.stroke()

            let text = isRecording ? "Press a key…" : label
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: isRecording ? .regular : .medium),
                .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}
