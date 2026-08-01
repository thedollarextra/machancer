import AppKit
import Combine
import Foundation

/// Live "what did I just press?" probe, sitting ahead of the gesture engine in the tap.
///
/// It answers the one question the Bindings tab cannot: did the event reach us at all?
/// A button that does nothing is either never arriving — no tap attached, or another
/// app's tap eating it first — or arriving and matching no binding. From the outside
/// those are indistinguishable, and the event log doesn't separate them either, because
/// an event that never arrives and an event with no binding both produce silence.
public final class ButtonMonitor: ObservableObject {
    public static let shared = ButtonMonitor()

    /// Where an observation came from. The distinction is the whole diagnostic: AppKit
    /// delivers to the focused window through the ordinary responder chain, while our
    /// tap sees the session-wide stream. A press the window sees and the tap doesn't
    /// means the mouse, its driver, and macOS are all fine — our tap is the broken link.
    public enum Source: String, Hashable, Sendable {
        case tap
        case window
    }

    public struct Observation: Identifiable, Equatable {
        public let id: UInt64
        public var sources: Set<Source>
        public let button: Int
        public let modifiers: ModifierSet
        public let at: Date

        /// What the UI calls it. Worth showing next to the raw number, because they
        /// disagree: "Button 4" is `CGEvent` button 3, and that off-by-one is the
        /// classic reason a hand-checked binding looks correct but never fires.
        public var label: String { MouseButton.label(button) }

        public var seenBy: String {
            var parts: [String] = []
            if sources.contains(.tap) { parts.append("event tap") }
            if sources.contains(.window) { parts.append("settings window") }
            return parts.joined(separator: " + ")
        }
    }

    public static let historyLimit = 8

    /// Consulted on every tapped event, so it is a plain stored property: an
    /// `@Published` here would put Combine on the hot path for a value that is false
    /// almost all the time.
    public private(set) var isActive = false

    @Published public private(set) var latest: Observation?
    @Published public private(set) var history: [Observation] = []
    @Published public private(set) var diagnosis: String?

    /// Lets the tap drop any half-finished gesture as testing starts or stops, so a
    /// button held across the transition can't resume against stale state.
    public var onActiveChange: ((Bool) -> Void)?

    private var nextID: UInt64 = 0

    /// A tap press and the window press it turns into are the same physical click.
    /// Merge them instead of reporting two events, so "seen by" reads as one line.
    private static let mergeWindow: TimeInterval = 0.5

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        guard !isActive else { return }
        isActive = true
        refreshDiagnosis()
        onActiveChange?(true)
    }

    public func stop() {
        guard isActive else { return }
        isActive = false
        onActiveChange?(false)
    }

    public func clear() {
        latest = nil
        history = []
        refreshDiagnosis()
    }

    // MARK: - Observation

    /// Called from the tap callback, ahead of the gesture engine.
    ///
    /// The tap's run-loop source lives on the main run loop, so this — and the
    /// `@Published` writes it makes — is already on the main thread.
    ///
    /// Only presses are recorded. Drags would bury the one event the user is looking
    /// for under hundreds of its own, and a release identifies nothing a press didn't.
    public func observe(_ input: MouseInput) {
        guard isActive, input.phase == .down else { return }
        append(.tap, button: input.button, modifiers: input.modifiers)
    }

    /// Called from the tester field's own `otherMouseDown`, i.e. the ordinary AppKit
    /// delivery path.
    public func observeFromWindow(button: Int, modifiers: ModifierSet) {
        guard isActive else { return }
        append(.window, button: button, modifiers: modifiers)
    }

    private func append(_ source: Source, button: Int, modifiers: ModifierSet) {
        let now = Date()

        if var current = latest,
           current.button == button,
           current.modifiers == modifiers,
           now.timeIntervalSince(current.at) < Self.mergeWindow {
            guard !current.sources.contains(source) else { return }
            current.sources.insert(source)
            latest = current
            if let index = history.firstIndex(where: { $0.id == current.id }) {
                history[index] = current
            }
            refreshDiagnosis()
            return
        }

        nextID &+= 1
        let observation = Observation(
            id: nextID,
            sources: [source],
            button: button,
            modifiers: modifiers,
            at: now
        )
        latest = observation
        history.insert(observation, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        refreshDiagnosis()
    }

    // MARK: - Why nothing is showing up

    /// The reasons a press might not arrive, in the order worth checking. Recomputed
    /// on state changes rather than read from the view body, since it enumerates the
    /// system tap list.
    public func refreshDiagnosis() {
        var notes: [String] = []

        let tap = Diagnostics.ownTapStatus()
        if !tap.attached {
            notes.append(
                "No event tap is attached, so no mouse button can reach the app. Grant "
                + "Accessibility access — and if Mouse Enhancer is already ticked in System "
                + "Settings, remove it with “−” and add it again. A rebuilt binary no longer "
                + "matches the old entry, which stays ticked while doing nothing."
            )
        } else if !tap.enabled {
            notes.append(
                "The event tap is attached but has been disabled by the system. It is "
                + "re-armed automatically — try again in a moment."
            )
        }

        let competing = Diagnostics.competingTapNames()
        if !competing.isEmpty {
            notes.append(
                "Also tapping these buttons: \(competing.joined(separator: ", ")). If one of "
                + "them binds this button, it can consume the event before we see it."
            )
        }

        diagnosis = notes.isEmpty ? nil : notes.joined(separator: "\n\n")
    }
}
