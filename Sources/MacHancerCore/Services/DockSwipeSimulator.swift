import CoreGraphics
import Foundation

/// Synthesizes the trackpad "dock swipe" the window server uses for spaces, Mission
/// Control and App Exposé — the interactive kind that follows your fingers, not the
/// all-or-nothing kind a hotkey produces.
///
/// There is no public API for this, and `CGEventCreateGesture` does not exist. What does
/// work is building an ordinary `CGEvent`, setting its type to the gesture type, and
/// filling in the private fields with the perfectly public `CGEventSetIntegerValueField`.
/// This is how Mac Mouse Fix does it.
///
/// The field numbers below were not guessed — they were read off real three-finger
/// swipes captured from this machine's trackpad with a listen-only tap:
///
///     110 = 23        kIOHIDEventTypeDockSwipe
///     123 / 165       axis: 1 = horizontal (spaces), 2 = vertical (Mission Control)
///     124             cumulative progress, signed; direction is the sign
///     125             delta since the previous event
///     129 / 130       release velocity, present only on the ended event
///     132 / 134       phase: 1 began, 2 changed, 4 ended
///     135             progress AGAIN, as float32 bit-pattern in an integer field
///     138 = 3         finger count
///
/// Field 135 is not redundant in practice: it carries the value the window server
/// actually animates from. Setting only 124 leaves 135 reading zero, and the
/// transition stutters between the two disagreeing sources instead of tracking the
/// drag — and a swipe that never accumulates in 135 fails to commit at release.
/// Every captured sample had 135 equal to 124 to the bit, so they are written together.
///
/// Because progress is continuous, the transition tracks the drag and there is no
/// animation to wait out — which is the actual reason this feels faster than ⌃←.
public enum DockSwipeSimulator {

    public enum Axis {
        case horizontal   // spaces
        case vertical     // Mission Control / App Exposé

        /// Value for fields 123 and 165.
        var code: Int64 { self == .horizontal ? 1 : 2 }
    }

    public enum Phase {
        case began, changed, ended

        /// Value for fields 132 and 134.
        var code: Int64 {
            switch self {
            case .began: return 1
            case .changed: return 2
            case .ended: return 4
            }
        }
    }

    /// `NSEventTypeMagnify`'s raw value — the type the captured dock swipes arrived on.
    /// Named for what it carries here rather than what the enum calls it.
    private static let gestureEventType: UInt32 = 30

    /// Emits one dock-swipe event.
    ///
    /// `progress` is cumulative and signed. Its meaning by axis, as measured:
    /// horizontal negative moves toward the next space on the right; vertical negative
    /// is the "swipe up" that opens Mission Control.
    public static func post(
        axis: Axis, phase: Phase, progress: Double, delta: Double, velocity: Double = 0
    ) {
        guard
            let type = CGEventType(rawValue: gestureEventType),
            let event = CGEvent(source: nil)
        else { return }

        event.type = type

        func setInt(_ field: UInt32, _ value: Int64) {
            guard let f = CGEventField(rawValue: field) else { return }
            event.setIntegerValueField(f, value: value)
        }
        func setDouble(_ field: UInt32, _ value: Double) {
            guard let f = CGEventField(rawValue: field) else { return }
            event.setDoubleValueField(f, value: value)
        }

        // `CGEvent(source:)` pre-populates field 102, which real gesture events leave at
        // zero. Clear it so the payload matches theirs exactly.
        setInt(102, 0)
        setInt(110, 23)             // kIOHIDEventTypeDockSwipe
        setInt(123, axis.code)
        setInt(165, axis.code)
        setDouble(124, progress)
        setDouble(125, delta)
        setInt(132, phase.code)
        setInt(134, phase.code)
        setInt(136, 1)
        setInt(138, 3)              // three fingers

        // The same progress the window server animates from. Must agree with 124.
        setInt(135, Int64(Float(progress).bitPattern))

        // Perpendicular drift (field 126). Real fingers never move on one axis alone,
        // and nearly every captured event carries a small off-axis component, roughly
        // 1-10% of the main delta. Synthesized deterministically from the progress so
        // resumed runs stay reproducible — the point is a plausibly imperfect stream,
        // not a specific value.
        if delta != 0 {
            let wobble = (progress * 37).truncatingRemainder(dividingBy: 0.2) - 0.1
            setDouble(126, delta * 0.06 * (1 + wobble))
        }

        // Deliberately NO direction bitmask (fields 115/117/164).
        //
        // These were once stamped on horizontal events to "match observed traffic" —
        // but the event-level capture shows a real, working leftward swipe carries none
        // of them, and writing the integer fields aliases into the neighbouring double
        // fields (113/114/116/118 read back nonzero garbage once 115/117 are set).
        // The corruption was direction-dependent: value 8 (rightward) happened to be
        // harmless, value 4 (leftward) broke app-cycling in Exposé — the left/right
        // asymmetry that resisted every other explanation. Direction lives in the sign
        // of `progress`, which is where the trackpad itself puts it.

        // Release velocity decides whether a part-way swipe completes or snaps back.
        // Only real swipes carry it, and only on the ended event.
        if phase == .ended, velocity != 0 {
            setDouble(129, velocity)
            setDouble(130, velocity)
        }

        // Tagged like every other event we synthesize, so our own tap ignores it.
        setInt(CGEventField.eventSourceUserData.rawValue,
               ActionDispatcher.syntheticEventUserData)

        event.post(tap: .cghidEventTap)
    }
}
