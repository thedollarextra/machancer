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

        public init(
            stepPx: Double, settleSec: Double, acceleration: Double,
            usePhases: Bool, useMomentum: Bool
        ) {
            self.stepPx = stepPx
            self.settleSec = settleSec
            self.acceleration = acceleration
            self.usePhases = usePhases
            self.useMomentum = useMomentum
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

    /// 120 Hz. Above a ProMotion display's refresh there is nothing left to gain, and
    /// below 60 the tail visibly steps.
    private static let frameInterval = 1.0 / 120.0

    /// Quiet time after the last notch before the remaining travel is relabelled as a
    /// coast. Long enough that the gaps *within* one turn of the wheel don't split a
    /// single gesture into a dozen; short enough that the coast still begins while the
    /// page is visibly moving.
    private static let coastIdleSec = 0.1

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

        // ⌘ and ⌃ ride the wheel as zoom — app zoom and the system's own accessibility
        // zoom. Both count discrete steps, so paying one notch out as a dozen small
        // events would zoom a dozen times.
        let flags = event.flags
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl) else { return false }

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

        let tuning = Tuning(
            stepPx: prefs.scrollStepPx,
            settleSec: prefs.scrollSmoothingSec,
            acceleration: prefs.scrollAcceleration,
            usePhases: prefs.scrollGesturePhases,
            useMomentum: prefs.scrollMomentum
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

        let travel = tuning.stepPx * Self.accelerationFactor(interval: interval,
                                                             strength: tuning.acceleration)
        Self.add(axis1 * travel, to: &pending1)
        Self.add(axis2 * travel, to: &pending2)

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
        if stage == .gesture, tuning.useMomentum, now - lastNotch >= Self.coastIdleSec {
            post(axis1: 0, axis2: 0, scrollPhase: .ended)
            stage = .coasting
        }

        let step1 = Self.step(pending: &pending1, dt: dt, settleSec: tuning.settleSec)
        let step2 = Self.step(pending: &pending2, dt: dt, settleSec: tuning.settleSec)

        emit(axis1: step1, axis2: step2)

        if abs(pending1) < 0.01, abs(pending2) < 0.01 { settle(force: false) }
    }

    /// One frame of exponential approach. `settleSec` is the time to arrive; the time
    /// constant is a quarter of it, which puts the animation within 2% of its target by
    /// the deadline.
    ///
    /// The last pixel is delivered outright rather than approached: the exponential
    /// would spend as long again paying out fractions nobody can see.
    public static func step(pending: inout Double, dt: Double, settleSec: Double) -> Double {
        guard pending != 0 else { return 0 }
        let tau = max(settleSec, 0.02) / 4
        let taken = abs(pending) < 1 ? pending : pending * (1 - exp(-dt / tau))
        pending -= taken
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
        carry1 = 0; carry2 = 0
        lastFrame = 0
        if force { lastNotch = 0 }

        closeOpenStream()
    }

    // MARK: - Event synthesis

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

        // A trackpad's defining field. Without it the deltas below are read as lines
        // and every frame becomes its own jump — worse than the notch we replaced.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)

        // Three fields, three readers. Point delta is what modern AppKit and WebKit
        // use; the fixed-point field carries the same value for anything reading it as
        // a scalar; the line delta exists for older code that only knows about lines,
        // at the conventional ten pixels to the line.
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(axis1))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(axis2))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: axis1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: axis2)
        event.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: axis1 / 10)
        event.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: axis2 / 10)

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
