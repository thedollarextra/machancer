import CoreGraphics
import Foundation
import QuartzCore

/// Turns a mouse wheel's discrete notches into the continuous, decelerating stream a
/// trackpad produces.
///
/// A notch arrives as a single event carrying a whole line of travel, and that is
/// exactly what it looks like on screen: the page jumps. A trackpad instead delivers a
/// dense stream of small *pixel* deltas wrapped in a gesture phase, which is why Safari
/// glides under two fingers and lurches under a wheel — WebKit and AppKit both take a
/// different, smoother path for phased continuous scrolls, and no amount of tuning the
/// wheel itself reaches it.
///
/// So the notch is swallowed and the same distance is paid out over a fifth of a second
/// as pixel-unit events shaped like the trackpad's. The curve is an exponential
/// approach: each frame delivers a fixed *fraction* of what is still owed, which gives
/// the fast start and long tail of a real flick and — the reason it was chosen over a
/// fixed-duration easing curve — composes correctly when the next notch lands
/// mid-animation. A new notch simply adds to the outstanding distance; there is no
/// animation to restart, retarget or cross-fade.
///
/// All animation state lives on `queue`. The tap callback only reads the incoming event
/// (which is valid for the duration of the callback and nowhere else), packages it, and
/// returns — a tap that blocks is a tap the system disables.
public final class SmoothScroller {
    public static let shared = SmoothScroller()

    /// Everything the animation needs from preferences, sampled on the tap thread at
    /// the moment of the notch. Snapshotting keeps `UserPreferences` — which the
    /// settings window writes on the main thread — off the animation queue entirely.
    public struct Tuning: Equatable {
        public var stepPx: Double
        public var settleSec: Double
        public var acceleration: Double
        public var usePhases: Bool
        public var useMomentum: Bool
        /// Per axis: 1 = vertical, 2 = horizontal, matching the `CGEvent` field names.
        public var smooth1: Bool
        public var smooth2: Bool
        public var boost: Double

        public init(
            stepPx: Double, settleSec: Double, acceleration: Double,
            usePhases: Bool, useMomentum: Bool,
            smooth1: Bool = true, smooth2: Bool = true, boost: Double = 1
        ) {
            self.stepPx = stepPx
            self.settleSec = settleSec
            self.acceleration = acceleration
            self.usePhases = usePhases
            self.useMomentum = useMomentum
            self.smooth1 = smooth1
            self.smooth2 = smooth2
            self.boost = boost
        }
    }

    /// Where a run is in the two-part life of a real scroll gesture.
    ///
    /// A trackpad flick is two streams, not one: while the finger is down, `phase` runs
    /// began → changed → ended with `momentumPhase` at none; once the finger lifts and
    /// the device coasts, `momentumPhase` runs began → changed → ended with `phase` at
    /// none. Notches arriving are the finger; the tail after they stop is the coast.
    private enum Stage {
        /// Nothing open. Unphased runs never leave this.
        case idle
        /// `phase` began sent, `ended` not yet.
        case gesture
        /// `phase` ended sent; the coast has not announced itself yet.
        case coasting
        /// `momentumPhase` began sent, `ended` not yet.
        case momentum
    }

    private let prefs: UserPreferences
    private let queue = DispatchQueue(label: "com.machancer.scroll", qos: .userInteractive)

    /// Same reasoning as `ActionDispatcher`: posting a synthetic event normally makes
    /// the window server ignore real input from the same source for a quarter of a
    /// second. Here the user's hand is still on the wheel, so that would swallow the
    /// very notches driving the animation.
    private let source: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    // MARK: - Animation state (queue only)

    /// Pixels still owed, per axis. Axis 1 is vertical, axis 2 horizontal — the same
    /// numbering the `CGEvent` fields use.
    private var pending1 = 0.0
    private var pending2 = 0.0
    /// Sub-pixel remainder. The point-delta field is an integer, so fractions below one
    /// pixel are carried to the next frame rather than rounded away — over a 120 Hz
    /// tail that is most of the frames.
    private var carry1 = 0.0
    private var carry2 = 0.0
    /// Current speed in points per second, carried between frames. This being *state*
    /// rather than a fresh function of `pending` is what makes the motion continuous;
    /// see `advance`.
    private var velocity1 = 0.0
    private var velocity2 = 0.0

    private var tuning = Tuning(stepPx: 90, settleSec: 0.22, acceleration: 0.4,
                                usePhases: true, useMomentum: true)
    private var flags: CGEventFlags = []

    private var timer: DispatchSourceTimer?
    /// Held only while a run is in flight — see `startTimer`.
    private var activity: NSObjectProtocol?
    private var lastFrame = 0.0
    /// Wheel-notch spacing drives acceleration, so it is kept across runs — two notches
    /// either side of a settled animation are still a fast scroll.
    private var lastNotch = 0.0
    /// A stream left unterminated leaves the target app rubber-banded, so whatever is
    /// open is closed on teardown as well as on settle.
    private var stage: Stage = .idle

    /// 100 Hz — the cadence measured off Mos's stream (median inter-event gap 10.0ms).
    private static let frameInterval = 1.0 / 100.0

    /// Quiet time after the last notch before the remaining travel is relabelled as a
    /// coast.
    ///
    /// This was 0.1s and that was far too eager. Wheel notches at a comfortable pace
    /// arrive 100-200ms apart, so the threshold sat *inside* the normal rhythm of
    /// scrolling: each notch got its own `began → changed → ended`, and the next one
    /// tore the momentum down and opened another gesture. WebKit and AppKit re-latch on
    /// every `began`, so a steady scroll arrived as a burst of unrelated gestures —
    /// which reads as the scroll refusing new input until it has finished, when in fact
    /// the input was accepted and then handed over as something disconnected.
    ///
    /// A wheel gives no fingers-up signal, so "stopped" has to be inferred from silence,
    /// and the inference must be slower than the fastest rhythm it could mistake for a
    /// stop. A third of a second is past any comfortable notch spacing.
    private static let coastIdleSec = 0.35

    /// ...and the coast may not begin while there is still real travel outstanding.
    /// Handing over mid-glide splits one continuous movement into two differently
    /// labelled halves, which is the same discontinuity by another route.
    private static let coastMaxPending = 12.0

    public init(prefs: UserPreferences = .shared) {
        self.prefs = prefs
    }

    // MARK: - Tap entry point

    /// Returns `true` when the notch was taken over and the original event must be
    /// swallowed.
    public func handleScroll(_ event: CGEvent) -> Bool {
        guard prefs.smoothScrollEnabled else { return false }

        // A trackpad or Magic Mouse already sends continuous pixel deltas, and smoothing
        // something smooth only adds latency. `isContinuous` is the obvious tell, but it
        // is not the only one, and this is Mos's stricter discriminator: continuous
        // input also stamps a scroll phase, a momentum phase or a scroll count, and a
        // wheel stamps none of them. That extra reach matters for third-party drivers —
        // Logitech Options, SteerMouse — which smooth the wheel themselves and emit
        // phased events that would otherwise be smoothed a second time.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0,
              event.getIntegerValueField(.scrollWheelEventScrollCount) == 0
        else { return false }

        let flags = event.flags
        let held = ModifierSet(cgFlags: flags)

        // The user's own modifier assignments are consulted first, so choosing ⌃ as the
        // boost key isn't silently overruled by the zoom rule below.
        let disableMod = prefs.scrollDisableModifier
        if !disableMod.isEmpty, held.contains(disableMod) { return false }

        let boostMod = prefs.scrollBoostModifier
        let boosting = !boostMod.isEmpty && held.contains(boostMod)
        // Mos calls this the Toggle Key, and it sends vertical movement sideways.
        let toggleMod = prefs.scrollToggleModifier
        let swapAxes = !toggleMod.isEmpty && held.contains(toggleMod)

        // ⌘ and ⌃ ride the wheel as zoom — app zoom and the system's own accessibility
        // zoom. Both count discrete steps, so paying one notch out as a dozen small
        // events would zoom a dozen times. Skipped when the user has claimed that
        // modifier for scrolling, since then they have said what it means.
        let claimed = disableMod.union(boostMod).union(toggleMod)
        if flags.contains(.maskCommand), !claimed.contains(.command) { return false }
        if flags.contains(.maskControl), !claimed.contains(.control) { return false }

        guard prefs.smoothScrollScope.allows(FrontmostAppTracker.shared.bundleIdentifier)
        else { return false }

        // Line delta is what a notch carries. A high-resolution wheel can report zero
        // lines with a point delta, so fall back to that rather than dropping the event.
        var axis1 = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        var axis2 = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        if axis1 == 0, axis2 == 0 {
            axis1 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) / 10
            axis2 = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) / 10
        }
        guard axis1 != 0 || axis2 != 0 else { return false }

        // Direction inversion is applied to whichever axes ask for it. macOS has one
        // natural-scrolling switch covering both axes, so this is the only way to have
        // them disagree.
        if prefs.reverseVertical { axis1 = -axis1 }
        if prefs.reverseHorizontal { axis2 = -axis2 }

        // Vertical becomes horizontal while the Toggle Key is held.
        if swapAxes, axis1 != 0 {
            axis2 = axis1
            axis1 = 0
        }

        let smooth1 = prefs.smoothVertical
        let smooth2 = prefs.smoothHorizontal

        // Nothing to smooth and nothing to flip: leave the real event alone. Passing
        // the original through beats re-posting a copy — no latency, and the click
        // state and timestamps stay authentic.
        if !smooth1, !smooth2, !prefs.reverseVertical, !prefs.reverseHorizontal,
           !boosting, !swapAxes {
            return false
        }

        let tuning = Tuning(
            // Distance per notch is Step x Speed, exactly as Mos composes them.
            stepPx: prefs.scrollStepPx * prefs.scrollSpeed,
            settleSec: prefs.scrollSmoothingSec,
            acceleration: prefs.scrollAcceleration,
            usePhases: prefs.scrollGesturePhases,
            useMomentum: prefs.scrollMomentum,
            smooth1: smooth1,
            smooth2: smooth2,
            boost: boosting ? prefs.scrollBoostFactor : 1
        )

        queue.async { [self] in
            accept(axis1: axis1, axis2: axis2, flags: flags, tuning: tuning)
        }
        return true
    }

    /// Abandons whatever is in flight. Called when the tap goes away, so no app is left
    /// holding an unterminated scroll gesture.
    public func reset() {
        queue.async { [self] in settle(force: true) }
    }

    // MARK: - Animation

    private func accept(axis1: Double, axis2: Double, flags: CGEventFlags, tuning: Tuning) {
        self.flags = flags
        self.tuning = tuning

        let now = CACurrentMediaTime()
        let interval = lastNotch == 0 ? .infinity : now - lastNotch
        lastNotch = now

        // A notch during the coast is a finger landing on a trackpad mid-glide: it ends
        // the momentum and begins a new gesture rather than joining the old one. The
        // travel still carries over — putting a hand down to scroll further is not a
        // request to start from a standstill.
        if stage == .momentum || stage == .coasting {
            closeOpenStream()
        }

        let travel = tuning.stepPx * tuning.boost
            * Self.accelerationFactor(interval: interval, strength: tuning.acceleration)

        // An axis with smoothing off still comes through here — it may have been
        // reversed or boosted, which the original event cannot express — but it is paid
        // out in one event rather than animated. Unphased, because a single discrete
        // delivery is not a gesture and labelling it as one would open and close a
        // WebKit scroll gesture per notch.
        if !tuning.smooth1, axis1 != 0 {
            post(axis1: (axis1 * travel).rounded(), axis2: 0)
        } else {
            Self.add(axis1 * travel, to: &pending1)
        }
        if !tuning.smooth2, axis2 != 0 {
            post(axis1: 0, axis2: (axis2 * travel).rounded())
        } else {
            Self.add(axis2 * travel, to: &pending2)
        }

        guard pending1 != 0 || pending2 != 0 else { return }
        startTimer(now: now)
    }

    /// Adds outstanding travel, cancelling first on a reversal.
    ///
    /// Netting a backwards notch against a forwards one leaves the page crawling to a
    /// stop and then creeping back — the user flicked the other way, and means it.
    public static func add(_ amount: Double, to pending: inout Double) {
        guard amount != 0 else { return }
        if pending != 0, (amount < 0) != (pending < 0) { pending = 0 }
        pending += amount
    }

    /// How much further one notch travels when notches are arriving quickly.
    ///
    /// 150 ms apart is reading; 40 ms apart is someone spinning the wheel to get down a
    /// long page, and that intent is worth honouring — it is the one thing a wheel does
    /// better than a trackpad. `strength` is the user's dial: 0 disables it, 1 triples
    /// the distance at full speed.
    public static func accelerationFactor(interval: Double, strength: Double) -> Double {
        guard strength > 0, interval.isFinite else { return 1 }
        let fast = 0.040, slow = 0.150
        let t = min(max((slow - interval) / (slow - fast), 0), 1)
        return 1 + strength * 2 * t
    }

    private func startTimer(now: Double) {
        guard timer == nil else { return }
        lastFrame = now

        // This is an `LSUIElement` agent with no window and no Dock tile, which is
        // exactly the profile App Nap targets: it suspends timers and coalesces the
        // survivors into batches. A batched animation frame is not a dropped frame — the
        // elapsed time is real, so the deferred distance is delivered in full whenever
        // the timer is let go, which reads as the scroll stopping and then lurching on
        // afterwards. The activity is scoped to the run, not the process lifetime.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "smooth scroll animation"
        )
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.frameInterval,
            repeating: Self.frameInterval,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in self?.frame() }
        timer.resume()
        self.timer = timer
    }

    private func frame() {
        let now = CACurrentMediaTime()
        // Clamped: a stalled queue must not deliver the whole remaining distance in one
        // jump, and a zero dt would deliver nothing forever.
        let dt = min(max(now - lastFrame, 0.001), 0.050)
        lastFrame = now

        // The finger has left the wheel: hand the rest of the travel over as a coast.
        // Announced *before* this frame's pixels so the boundary event carries no
        // distance of its own, which is how a real device hands over.
        let outstanding = max(abs(pending1), abs(pending2))
        if stage == .gesture, tuning.useMomentum,
           now - lastNotch >= Self.coastIdleSec, outstanding <= Self.coastMaxPending {
            post(axis1: 0, axis2: 0, scrollPhase: .ended)
            stage = .coasting
        }

        // Deadline: everything owed lands within `settleSec` of the last notch —
        // the measured Mos behaviour, where no burst has any tail past its peak.
        let remaining = (lastNotch + tuning.settleSec) - now
        let step1 = Self.advance(pending: &pending1, velocity: &velocity1,
                                 dt: dt, remaining: remaining, settleSec: tuning.settleSec)
        let step2 = Self.advance(pending: &pending2, velocity: &velocity2,
                                 dt: dt, remaining: remaining, settleSec: tuning.settleSec)

        emit(axis1: step1, axis2: step2)

        if abs(pending1) < 0.01, abs(pending2) < 0.01 { settle(force: false) }
    }

    /// One frame of motion, matching the curve measured off Mos's live stream.
    ///
    /// Every captured burst has the same signature: a ~1px opening event, deltas that
    /// *rise* — 1, 10, 39, 55, 62… — and a dead stop on the largest one. Zero tail, in
    /// 44 out of 44 bursts. That is the opposite of an exponential decay (big first,
    /// long fade), and the difference is exactly what made the two feel unalike.
    ///
    /// The shape falls out of one rule: the outstanding travel must be delivered by a
    /// **deadline** a fixed interval after the last notch. Target speed is
    /// `pending / timeRemaining`; as the deadline nears, the denominator shrinks, so
    /// speed climbs and everything lands at peak velocity — the hard stop. A new notch
    /// both adds travel and pushes the deadline out, so a steady spin holds a steady
    /// speed, and actual velocity chases the target through a short time constant so
    /// motion still eases in rather than snapping.
    ///
    /// `remaining` is the time left until that deadline, kept by the caller as
    /// `settleSec` past the most recent notch.
    public static func advance(
        pending: inout Double,
        velocity: inout Double,
        dt: Double,
        remaining: Double,
        settleSec: Double
    ) -> Double {
        guard pending != 0 else { velocity = 0; return 0 }

        // Past the deadline there is nothing to pace: land it. This is the measured
        // hard stop, not a shortcut.
        if remaining <= dt {
            let taken = pending
            pending = 0
            velocity = 0
            return taken
        }

        let target = pending / remaining
        // Short and independent of the total duration: the ramp-in is the first
        // ~30-40ms of the measured curve regardless of how long the burst runs.
        let tau = min(max(settleSec, 0.02) / 3, 0.03)
        velocity += (target - velocity) * (1 - exp(-dt / tau))

        var taken = velocity * dt
        // Never overshoot, never reverse — both read as a twitch at the end.
        if abs(taken) > abs(pending) || (taken < 0) != (pending < 0) {
            taken = pending
        }
        pending -= taken
        if pending == 0 { velocity = 0 }
        return taken
    }

    private func emit(axis1: Double, axis2: Double) {
        carry1 += axis1
        carry2 += axis2
        let pixels1 = carry1.rounded(.towardZero)
        let pixels2 = carry2.rounded(.towardZero)
        carry1 -= pixels1
        carry2 -= pixels2
        guard pixels1 != 0 || pixels2 != 0 else { return }

        // Gesture phases are what unlock the smooth, elastic path in WebKit and
        // AppKit — but they are also what Safari reads as a two-finger swipe, so a
        // horizontal phased scroll navigates back instead of scrolling sideways. Only
        // the vertical axis is phased, and only while ⇧ is up: ⇧+wheel is the standard
        // "scroll sideways" and AppKit swaps the axis after we post.
        let phased = tuning.usePhases && pixels2 == 0 && !flags.contains(.maskShift)

        if pixels1 != 0 {
            if phased {
                switch stage {
                case .idle:
                    stage = .gesture
                    post(axis1: pixels1, axis2: 0, scrollPhase: .began)
                case .gesture:
                    post(axis1: pixels1, axis2: 0, scrollPhase: .changed)
                case .coasting:
                    stage = .momentum
                    post(axis1: pixels1, axis2: 0, momentumPhase: .began)
                case .momentum:
                    post(axis1: pixels1, axis2: 0, momentumPhase: .changed)
                }
            } else {
                post(axis1: pixels1, axis2: 0)
            }
        }
        if pixels2 != 0 {
            post(axis1: 0, axis2: pixels2)
        }
    }

    /// Terminates whichever of the two streams is open, leaving `stage` at `.idle`.
    ///
    /// `.coasting` has already sent its `phase` ended and has not yet announced a
    /// momentum, so it has nothing outstanding — the coast simply never materialised.
    private func closeOpenStream() {
        switch stage {
        case .gesture:  post(axis1: 0, axis2: 0, scrollPhase: .ended)
        case .momentum: post(axis1: 0, axis2: 0, momentumPhase: .ended)
        case .coasting, .idle: break
        }
        stage = .idle
    }

    private func settle(force: Bool) {
        timer?.cancel()
        timer = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        pending1 = 0; pending2 = 0
        velocity1 = 0; velocity2 = 0
        carry1 = 0; carry2 = 0
        lastFrame = 0
        if force { lastNotch = 0 }

        closeOpenStream()
    }

    // MARK: - Event synthesis

    /// Whether the run in flight is emitting trackpad-shaped events. Read by `post`.
    private var usesPhases: Bool { tuning.usePhases }

    private func post(
        axis1: Double,
        axis2: Double,
        scrollPhase: CGScrollPhase? = nil,
        momentumPhase: CGScrollPhase? = nil
    ) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0, wheel2: 0, wheel3: 0
        ) else { return }

        // Two emission shapes, and the difference is not cosmetic.
        //
        // Trackpad mode marks the event continuous and carries pixel-valued deltas, so
        // WebKit and AppKit route it down the path they use for real gestures — which is
        // what buys rubber-band overscroll and the smoothest scrolling in Safari.
        //
        // Line mode marks it *non*-continuous with line-valued deltas, which is what Mos
        // does. Measured off its live stream: `isContinuous`, `scrollPhase`,
        // `momentumPhase` and `scrollCount` were zero on every one of 389 captured
        // events, with `fixedPtDelta` exactly a tenth of `pointDelta`. Its smoothness is
        // bought purely with volume and rate — roughly eight small events per notch —
        // and none of it depends on the system believing a gesture is happening. That
        // costs the elastic path, and in exchange nothing downstream can mistake a
        // scroll for a swipe or discard its tail as momentum.
        let trackpadMode = usesPhases
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: trackpadMode ? 1 : 0)

        // Point delta is the pixel amount either way — it is what modern AppKit and
        // WebKit read. The other two carry the same movement in the unit their reader
        // expects: points when the event claims to be continuous, lines when it doesn't,
        // at the conventional ten pixels to the line.
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(axis1))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(axis2))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1,
                                  value: trackpadMode ? axis1 : axis1 / 10)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2,
                                  value: trackpadMode ? axis2 : axis2 / 10)
        event.setDoubleValueField(.scrollWheelEventDeltaAxis1,
                                  value: trackpadMode ? axis1 / 10 : (axis1 / 10).rounded())
        event.setDoubleValueField(.scrollWheelEventDeltaAxis2,
                                  value: trackpadMode ? axis2 / 10 : (axis2 / 10).rounded())

        // Both fields are always written, never left at whatever the constructor
        // produced. A real gesture sets exactly one of them: while the finger is down
        // `phase` runs began → changed → ended with `momentumPhase` at none, and once
        // the device coasts `momentumPhase` runs while `phase` reads none. An event
        // carrying a stray value in the other field is one no device ever emits, and a
        // consumer would coast on top of an animation that already coasts.
        event.setIntegerValueField(.scrollWheelEventScrollPhase,
                                   value: scrollPhase?.rawValue ?? 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase,
                                   value: momentumPhase?.rawValue ?? 0)

        // Carried through unchanged. ⇧ decides the axis in most apps and ⌥ changes the
        // unit in some; dropping them would silently change what the scroll means.
        event.flags = flags

        // Tagged so our own tap ignores it, exactly as the dock-swipe events are.
        event.setIntegerValueField(.eventSourceUserData,
                                   value: ActionDispatcher.syntheticEventUserData)

        // Session tap, *not* HID. The HID point is upstream of the window server's own
        // scroll processing — the natural-direction flip and, crucially, the scroll
        // acceleration curve, which is driven by the line delta and the rate events
        // arrive at. Re-injecting there hands 120 events a second to an accelerator that
        // has its own accumulator and decay, so the stream comes back amplified and with
        // a tail of its own after the gesture has ended.
        //
        // We intercepted at the session tap; a filter re-injects at the level it
        // intercepted. Our own tap sees these and skips them on the user-data tag.
        event.post(tap: .cgSessionEventTap)
    }
}

/// The values `kCGScrollWheelEventScrollPhase` takes. Named here because the phase of a
/// scroll is otherwise a bare integer at the one place it matters.
enum CGScrollPhase: Int64 {
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
}
