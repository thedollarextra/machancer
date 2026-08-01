import CoreGraphics
import Foundation

/// A mouse event reduced to what the decision logic actually needs.
/// Keeping this free of `CGEvent` is what makes the engine testable.
public struct MouseInput: Equatable {
    public enum Phase: Equatable {
        case down, dragged, up

        var label: String {
            switch self {
            case .down: return "down"
            case .dragged: return "drag"
            case .up: return "up"
            }
        }
    }

    public let phase: Phase
    public let button: Int
    public let location: CGPoint   // AX space: origin top-left
    public let modifiers: ModifierSet

    public init(phase: Phase, button: Int, location: CGPoint, modifiers: ModifierSet = []) {
        self.phase = phase
        self.button = button
        self.location = location
        self.modifiers = modifiers
    }
}

/// Work the engine wants performed. Emitted, never executed inline.
public enum ActionRequest: Equatable {
    case run(ActionBinding, CGPoint)
    /// Middle click landed on the Dock; the dispatcher resolves which app and
    /// runs that app's configured action.
    case dockMiddleClick(CGPoint)
    /// A live dock-swipe update. Unlike every other request this is a *stream* — one
    /// `began`, many `changed`, one `ended` — because the whole point is that the
    /// transition tracks the drag instead of playing a fixed animation.
    /// Start a swipe on this axis.
    case swipeBegin(DockSwipeSimulator.Axis)
    /// Where the swipe should be, as absolute progress. The emitter walks toward it at
    /// its own cadence — the engine reports intent, not individual events.
    case swipeUpdate(target: Double)
    /// Release, handing over momentum.
    case swipeEnd(velocity: Double)
}

/// Deferred work, injectable so tests don't sleep.
public protocol HoldTiming {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> HoldToken
    /// Monotonic seconds; used for double-click spacing.
    var now: TimeInterval { get }
}

public protocol HoldToken {
    func cancel()
}

public struct MainQueueTiming: HoldTiming {
    public init() {}

    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> HoldToken {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return WorkItemToken(item: item)
    }

    private struct WorkItemToken: HoldToken {
        let item: DispatchWorkItem
        func cancel() { item.cancel() }
    }
}

/// Decides, for each mouse event, whether to swallow it and what to run.
///
/// Actions are *emitted* via `onAction` rather than performed inline. The caller runs
/// them off the event-tap callback: Accessibility calls block on the target process,
/// and a tap callback that blocks gets summarily disabled by the window server (or
/// deadlocks against an app that is itself waiting on the tap).
public final class GestureEngine {

    /// Per-button gesture state. A struct in a small dictionary keyed by button
    /// number — several buttons can legitimately be mid-gesture at once (that is
    /// what chording is).
    private struct ButtonState {
        var origin: CGPoint = .zero
        var modifiers: ModifierSet = []
        /// Frontmost app at press time. Scoped-binding lookups for the rest of the
        /// gesture use this, so switching apps mid-drag can't swap the rules underneath.
        var app: String?
        var gestureFired = false
        var claimed = false
        var holdToken: HoldToken?

        /// Live dock-swipe state, set once this press is recognised as a swipe.
        var swipeAxis: DockSwipeSimulator.Axis?
        var swipeStarted = false
        var swipeProgress: Double = 0
        /// Where the last swipe sample was taken, so each move contributes its own delta.
        var swipeAnchor: CGPoint = .zero
        /// Smoothed recent rate of change, handed over as release momentum.
        var swipeVelocity: Double = 0
        /// Direction this swipe committed to (-1 / +1), or 0 before it is established.
        var swipeSign: Double = 0
        /// Clock reading of the previous swipe sample, for per-second velocity.
        var swipeSampledAt: TimeInterval = 0
        /// Track the gesture but drive no visual — used for downward swipes, which the
        /// window server will not commit however they are fed.
        var swipeMeasureOnly = false
    }

    private let prefs: UserPreferences
    private let timing: HoldTiming
    private let log: EventLog
    /// Bundle identifier of the frontmost app, for exclusion checks.
    private let frontmostBundleID: () -> String?
    /// Cheap cached "is this over the Dock?" test.
    private let dockProbe: DockProbe

    public var onAction: (ActionRequest) -> Void = { _ in }

    private var states: [Int: ButtonState] = [:]
    private var pressedButtons: Set<Int> = []

    // Double-click tracking: last click time and location per (button, modifiers).
    private var lastClickAt: [Int: TimeInterval] = [:]
    private var pendingClick: [Int: HoldToken] = [:]

    public init(
        prefs: UserPreferences = .shared,
        timing: HoldTiming = MainQueueTiming(),
        log: EventLog = .shared,
        frontmostBundleID: @escaping () -> String? = { FrontmostAppTracker.shared.bundleIdentifier },
        dockProbe: DockProbe = DockProbe()
    ) {
        self.prefs = prefs
        self.timing = timing
        self.log = log
        self.frontmostBundleID = frontmostBundleID
        self.dockProbe = dockProbe
    }

    /// Returns `true` to swallow the event.
    public func handle(_ input: MouseInput) -> Bool {
        let app = frontmostBundleID()

        // Excluded apps see their mouse untouched — games and remote-desktop clients
        // use these buttons natively.
        if prefs.isExcluded(bundleID: app) {
            record(input, "excluded app", suppressed: false)
            return false
        }

        // Continue a sequence we already claimed.
        if input.phase != .down, states[input.button]?.claimed == true {
            let suppressed = continueGesture(input)
            if input.phase == .up { finish(input.button) }
            return suppressed
        }

        switch input.phase {
        case .down:
            return handleDown(input, app: app)
        case .dragged, .up:
            // Not ours; make sure nothing is left dangling.
            if input.phase == .up { pressedButtons.remove(input.button) }
            record(input, "passed through", suppressed: false)
            return false
        }
    }

    /// Drops all pending state — call when the tap stops or is re-armed.
    public func reset() {
        for (_, state) in states { state.holdToken?.cancel() }
        for (_, token) in pendingClick { token.cancel() }
        states.removeAll(keepingCapacity: true)
        pendingClick.removeAll(keepingCapacity: true)
        pressedButtons.removeAll(keepingCapacity: true)
        lastClickAt.removeAll(keepingCapacity: true)
    }

    // MARK: - Press

    private func handleDown(_ input: MouseInput, app: String?) -> Bool {
        let button = input.button
        let modifiers = input.modifiers

        // Chord: this press completes a pair with something already held.
        for held in pressedButtons where held != button {
            if let chord = prefs.chordBinding(held, button, modifiers: modifiers, app: app) {
                pressedButtons.insert(button)
                // Both buttons are now spoken for; neither should fire its own action.
                markChordConsumed(held)
                var state = ButtonState()
                state.claimed = true
                state.gestureFired = true
                state.modifiers = modifiers
                states[button] = state

                emit(chord, at: input.location)
                record(input, "chord → \(chord.action.displayName)", suppressed: true)
                return true
            }
        }

        pressedButtons.insert(button)

        // Dock middle-click, and it *is* suppressed.
        //
        // This used to pass through, on the reasoning that deciding "is this the Dock?"
        // needed a blocking AX call the tap callback must not make, and that the Dock had
        // no middle-click behaviour worth overriding anyway. The second half was wrong:
        // middle-clicking a tile opens the Dock's context menu, which appears over
        // whatever action we ran. Swallowing the press is the only way to stop it.
        //
        // The first half is handled by `DockProbe`, which keeps the tile strip's frame
        // cached and refreshes it off this thread, so the test here is a rectangle
        // containment and nothing more.
        if button == MouseButton.middle, modifiers.isEmpty, prefs.dockNewInstanceEnabled,
           dockProbe.contains(input.location) {
            onAction(.dockMiddleClick(input.location))

            // Claim it so the matching mouse-up is swallowed too. Releasing an
            // unmatched button over the Dock is what actually raises the menu, so
            // suppressing only the press would change nothing.
            var state = ButtonState()
            state.origin = input.location
            state.modifiers = modifiers
            state.app = app
            state.claimed = true
            state.gestureFired = true
            states[button] = state

            record(input, "dock middle-click", suppressed: true)
            return true
        }

        // Bound to "stay yourself", with nothing else on this combination that would
        // need the press held back. Don't touch it — the OS keeps its built-in
        // behaviour for buttons 4 and 5, and apps that read the button directly still
        // see a genuine event rather than a replayed one.
        if prefs.isNativePassthrough(button: button, modifiers: modifiers, app: app) {
            record(input, "native button (passed through)", suppressed: false)
            return false
        }

        guard prefs.hasBinding(button: button, modifiers: modifiers, app: app) else {
            record(input, "no binding", suppressed: false)
            return false
        }

        var state = ButtonState()
        state.origin = input.location
        state.modifiers = modifiers
        state.app = app
        state.claimed = true

        if let hold = prefs.binding(button: button, modifiers: modifiers, trigger: .hold, app: app) {
            let location = input.location
            state.holdToken = timing.schedule(after: hold.holdDelay ?? prefs.holdThresholdSec) { [weak self] in
                guard let self, self.states[button]?.gestureFired == false else { return }
                self.states[button]?.gestureFired = true
                self.emit(hold, at: location)
            }
        }

        states[button] = state
        record(input, "claimed", suppressed: true)
        return true
    }

    // MARK: - Drag & release

    private func continueGesture(_ input: MouseInput) -> Bool {
        let button = input.button
        guard var state = states[button] else { return true }

        switch input.phase {
        case .dragged:
            // A swipe binding takes the whole drag: it streams for as long as the button
            // is held, rather than firing once and being done.
            if let swipe = prefs.binding(button: button, modifiers: state.modifiers,
                                         trigger: .swipe, app: state.app) {
                continueSwipe(&state, input: input, binding: swipe)
                states[button] = state
                return true
            }

            guard !state.gestureFired else { return true }

            let dx = input.location.x - state.origin.x
            let dy = state.origin.y - input.location.y   // positive == up the screen

            // Direction is resolved *before* distance now. Each drag binding can carry
            // its own distance, so there is no longer a single global threshold that can
            // decide whether a drag happened at all — you have to know which direction
            // is being asked about before you know how far it must travel.
            // Dominant axis wins, so a slightly diagonal swipe still reads as intended.
            let trigger: TriggerKind = abs(dy) >= abs(dx)
                ? (dy > 0 ? .dragUp : .dragDown)
                : (dx > 0 ? .dragRight : .dragLeft)

            let binding = prefs.binding(button: button, modifiers: state.modifiers, trigger: trigger, app: state.app)
            let threshold = binding?.dragDistance ?? prefs.dragThresholdPx
            guard max(abs(dx), abs(dy)) > threshold else { return true }

            state.holdToken?.cancel()
            state.holdToken = nil
            state.gestureFired = true
            states[button] = state

            if let binding {
                emit(binding, at: input.location)
                record(input, "\(trigger.title) → \(binding.action.displayName)", suppressed: true)
            } else {
                record(input, "\(trigger.title) (unbound)", suppressed: true)
            }
            return true

        case .up:
            state.holdToken?.cancel()
            state.holdToken = nil

            // Close an in-flight swipe. The window server needs the `ended` phase to
            // decide whether the drag went far enough to commit or should snap back;
            // without it the transition hangs half-open.
            if state.swipeStarted {
                if state.swipeMeasureOnly {
                    // No visual was driven, so there is nothing to release. Invoke the
                    // action directly if the gesture travelled far enough to mean it.
                    if state.swipeProgress >= Self.swipeActionThreshold {
                        let action = ActionBinding(button: button,
                                                   action: ActionSpec(kind: .appExpose))
                        onAction(.run(action, input.location))
                        record(input, "swipe → App Exposé", suppressed: true)
                    } else {
                        record(input, "swipe cancelled (too short)", suppressed: true)
                    }
                } else {
                    // Hand the window server the momentum of the last movement, the way
                    // a lifted finger does. Without it a part-way swipe always snaps
                    // back instead of completing on a flick.
                    onAction(.swipeEnd(velocity: state.swipeVelocity))
                    record(input, "swipe ended", suppressed: true)
                }
                state.swipeStarted = false
                state.gestureFired = true
            }
            states[button] = state

            if !state.gestureFired {
                resolveClick(button: button, modifiers: state.modifiers, app: state.app,
                             at: input.location, input: input)
            }
            return true

        case .down:
            return true
        }
    }

    /// A release with no gesture is a click — unless a double-click binding exists,
    /// in which case the single click waits to see if a second one lands.
    private func resolveClick(button: Int, modifiers: ModifierSet, app: String?, at location: CGPoint, input: MouseInput) {
        let single = prefs.binding(button: button, modifiers: modifiers, trigger: .click, app: app)

        guard prefs.hasDoubleClickBinding(button: button, modifiers: modifiers, app: app) else {
            if let single {
                emit(single, at: location)
                record(input, "click → \(single.action.displayName)", suppressed: true)
            } else {
                record(input, "click (unbound)", suppressed: true)
            }
            return
        }

        // The spacing that counts as a double click belongs to the double-click binding,
        // so a row that overrides it also governs how long its single click is deferred.
        let double = prefs.binding(button: button, modifiers: modifiers, trigger: .doubleClick, app: app)
        let interval = double?.doubleClickInterval ?? prefs.doubleClickIntervalSec

        let now = timing.now
        if let previous = lastClickAt[button], now - previous <= interval {
            pendingClick[button]?.cancel()
            pendingClick[button] = nil
            lastClickAt[button] = nil

            if let double {
                emit(double, at: location)
                record(input, "double click → \(double.action.displayName)", suppressed: true)
            }
            return
        }

        lastClickAt[button] = now
        guard let single else {
            record(input, "click (awaiting second)", suppressed: true)
            return
        }

        // Hold the single click back just long enough to rule out a double.
        pendingClick[button] = timing.schedule(after: interval) { [weak self] in
            guard let self else { return }
            self.pendingClick[button] = nil
            self.lastClickAt[button] = nil
            self.emit(single, at: location)
        }
        record(input, "click (deferred for double)", suppressed: true)
    }

    /// Feeds one mouse move into a live dock swipe.
    ///
    /// The axis is locked on the first movement that clears the threshold and never
    /// changes for the rest of the press — a swipe that could flip between "spaces" and
    /// "Mission Control" mid-drag would be unusable. After that, horizontal movement
    /// drives horizontal progress and vertical drives vertical, each move contributing
    /// its own delta so the transition follows the mouse the way it follows fingers.
    ///
    /// Progress is normalised so `swipeDistancePx` of travel equals a full swipe (1.0).
    /// Signs match what real trackpad swipes produce, measured: moving the mouse right
    /// sends negative horizontal progress (toward the next space), moving it up sends
    /// negative vertical progress (Mission Control).
    private func continueSwipe(_ state: inout ButtonState, input: MouseInput, binding: ActionBinding) {
        if state.swipeAxis == nil {
            let dx = input.location.x - state.origin.x
            let dy = input.location.y - state.origin.y
            // Wait for a deliberate movement before committing to an axis; picking one
            // from the first stray pixel gets it wrong about half the time.
            guard max(abs(dx), abs(dy)) > prefs.swipeAxisLockPx else { return }
            state.swipeAxis = abs(dy) > abs(dx) ? .vertical : .horizontal
            state.swipeAnchor = state.origin
        }
        guard let axis = state.swipeAxis else { return }

        // Sensitivity is per axis, resolved only once the axis is known.
        let horizontal = axis == .horizontal
        let distance = binding.swipeDistance(
            horizontal: horizontal,
            globalX: prefs.swipeDistanceXPx,
            globalY: prefs.swipeDistanceYPx
        )

        let travelled = horizontal
            ? input.location.x - state.swipeAnchor.x
            : input.location.y - state.swipeAnchor.y
        guard travelled != 0 else { return }
        state.swipeAnchor = input.location

        // The two axes need opposite signs, because they disagree about which way is
        // "positive" once AX coordinates are taken into account.
        //
        // Vertical: y grows *downward* in AX space, so moving the mouse up already
        // yields a negative `travelled` — and negative vertical progress is what the
        // recorded trackpad swipe used for Mission Control. Pass it through unchanged.
        // Negating it here is what previously sent up-swipes into empty space and made
        // down-swipes open Mission Control.
        //
        // Horizontal: moving right must read as advancing to the next space, which is
        // negative progress, so that axis does need the flip.
        let raw = travelled / distance
        let delta = horizontal ? -raw : raw

        if state.swipeSampledAt == 0 {
            state.gestureFired = true
            state.swipeSampledAt = timing.now
        }

        // Release velocity, in progress units *per second*.
        //
        // The per-event rate this used to send was wrong by whatever the mouse's report
        // rate happened to be — roughly 1000x too small, measured against a real
        // trackpad (which releases at ±2.7 to ±3.5 where we were sending ±0.004). The
        // window server weighs velocity heavily when deciding whether a part-way swipe
        // commits or snaps back, so a near-zero value meant our gestures had to be
        // carried by raw distance alone. A real trackpad swipe commits from barely 0.44
        // progress precisely because its velocity does the work.
        let now = timing.now
        let elapsed = max(now - state.swipeSampledAt, 0.001)
        state.swipeSampledAt = now
        // Smoothed hard, then clamped to what a trackpad actually produces.
        //
        // `delta / elapsed` alone explodes on a high-polling mouse: big pointer-
        // accelerated deltas arriving sub-millisecond apart yielded a release velocity of
        // 50.6 against a real trackpad's 2.71 on the same gesture at the same distance.
        // Having previously been ~1000x too small, it ended up ~19x too large — and the
        // recogniser rejects an implausible velocity just as readily as a null one.
        let instantaneous = delta / elapsed
        state.swipeVelocity = state.swipeVelocity * 0.8 + instantaneous * 0.2
        state.swipeVelocity = min(max(state.swipeVelocity, -Self.maxSwipeVelocity),
                                  Self.maxSwipeVelocity)

        // Report where the swipe should be and return. Turning that into a paced
        // stream of events is the emitter's job — doing it here would tie gesture
        // timing to the mouse's reporting rate, which is what made it lurch.
        state.swipeProgress += delta

        // A vertical swipe means opposite things either side of zero: negative opens
        // Mission Control, positive opens App Exposé. Letting one drag cross zero hands
        // the window server a gesture that reverses its own meaning mid-flight, which is
        // what produced the "drag back down past zero and the windows balloon" state —
        // it was still driving the *same* transition, now past its own origin, rather
        // than starting the opposite one.
        //
        // So a swipe commits to the direction it started in. Dragging back toward zero
        // still cancels (that is how a trackpad backs out of a gesture); it simply stops
        // at zero instead of inverting. The opposite gesture needs its own press.
        if state.swipeSign == 0, abs(state.swipeProgress) > Self.swipeDirectionCommit {
            state.swipeSign = state.swipeProgress < 0 ? -1 : 1
        }
        if state.swipeSign > 0 {
            state.swipeProgress = max(0, state.swipeProgress)
        } else if state.swipeSign < 0 {
            state.swipeProgress = min(0, state.swipeProgress)
        }

        // Never drive past a completed swipe.
        //
        // 1.0 *is* the completion point, and a real trackpad never goes near it: captured
        // three-finger swipes peak around 0.42-0.56 and commit from there. Ours were
        // running to +3.08 — the transition driven to three times its own end — and the
        // window server treats that as out of range rather than as emphatic, which is why
        // long drags silently failed while short trackpad flicks worked. Clamping keeps
        // every gesture inside the range the recogniser actually accepts, and makes a
        // drag past the threshold hold at "complete" instead of sailing through it.
        state.swipeProgress = min(max(state.swipeProgress, -Self.maxSwipeProgress),
                                  Self.maxSwipeProgress)

        // Direction is only known once the gesture commits to one, which is why the
        // visual starts here rather than on the first pixel of movement.
        guard state.swipeSign != 0 else { return }

        if !state.swipeStarted {
            state.swipeStarted = true

            // Only the *downward* swipe is measured rather than rendered.
            //
            // It refuses to commit however it is fed — logged past +1.7 progress with a
            // release velocity matching a real trackpad's — and driving a transition
            // that will never land buys nothing but artefacts: the dimmed top edge that
            // goes nowhere, and windows ballooning when the gesture is pushed past its
            // own origin. So it is tracked only for its threshold and App Exposé is
            // invoked on release.
            //
            // Horizontal is deliberately NOT treated this way, in either direction.
            // Leftward looked like the same "positive progress won't commit" quirk, but
            // it commits perfectly well for space switching; it only fails to cycle apps
            // while Mission Control or Exposé is already open, which is a much narrower
            // problem. Converting it to a keystroke "fixed" that one case and broke
            // ordinary space switching, which had been working.
            state.swipeMeasureOnly = (axis == .vertical && state.swipeSign > 0)
                && !prefs.nativeDownSwipe

            if !state.swipeMeasureOnly {
                onAction(.swipeBegin(axis))
            }
            record(input,
                   state.swipeMeasureOnly
                       ? "swipe began (App Exposé, measured)"
                       : "swipe began (\(axis == .horizontal ? "spaces" : "Mission Control"))",
                   suppressed: true)
        }

        guard !state.swipeMeasureOnly else { return }
        onAction(.swipeUpdate(target: state.swipeProgress))
    }

    /// Progress at which a swipe stops being noise and commits to its direction.
    private static let swipeDirectionCommit = 0.02
    /// How far a measured-only swipe must travel before it counts as intended.
    private static let swipeActionThreshold = 0.22
    /// A completed swipe. Real trackpad gestures peak well below this; going beyond it
    /// pushes the transition out of the range the window server will commit.
    private static let maxSwipeProgress = 1.0
    /// Ceiling on release momentum, measured from real three-finger swipes (~2.7-3.5).
    private static let maxSwipeVelocity = 3.2

    private func finish(_ button: Int) {
        states[button]?.holdToken?.cancel()
        states.removeValue(forKey: button)
        pressedButtons.remove(button)
    }

    /// The other half of a chord must not fire its own click on release.
    private func markChordConsumed(_ button: Int) {
        guard var state = states[button] else { return }
        state.holdToken?.cancel()
        state.holdToken = nil
        state.gestureFired = true
        states[button] = state
    }

    // MARK: - Emission

    private func emit(_ binding: ActionBinding, at location: CGPoint) {
        guard binding.isActive else { return }
        onAction(.run(binding, location))
    }

    /// `@autoclosure` matters here: these call sites interpolate strings, and without
    /// it every mouse event would build and throw away a description even when
    /// nothing is recording.
    private func record(_ input: MouseInput, _ outcome: @autoclosure () -> String, suppressed: Bool) {
        guard log.isRecording else { return }
        let outcome = outcome()
        log.record(
            button: input.button,
            phase: input.phase.label,
            modifiers: input.modifiers,
            outcome: outcome,
            suppressed: suppressed
        )
    }
}
