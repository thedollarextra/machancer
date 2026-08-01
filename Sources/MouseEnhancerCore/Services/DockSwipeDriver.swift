import CoreGraphics
import Foundation

/// Emits a dock swipe at a steady cadence, independent of how fast mouse events arrive.
///
/// The naive approach — post one gesture event per `otherMouseDragged` — produces a
/// stream whose timing is dictated by mouse reporting and pointer acceleration: a slow
/// drag starves it, a flick delivers a huge jump, and subdividing that jump in place
/// just emits N events in a burst carrying nearly identical timestamps. The window
/// server reads the *timing* of a gesture, not only its values, so a burst reads as one
/// discontinuous lurch rather than a swipe. That is the jerkiness.
///
/// So the mouse only ever updates a *target*, and a timer walks the emitted progress
/// toward it at a fixed interval — the same shape a trackpad's own stream has, and the
/// same shape Mac Mouse Fix uses (its helper exports a `dockSwipeTimerFired:` selector).
/// Each event is created at the moment it is posted, so timestamps are genuinely
/// spaced rather than back-filled.
///
/// Thread-safety: every mutation happens on `queue`. The tap callback only enqueues.
public final class DockSwipeDriver {
    public static let shared = DockSwipeDriver()

    /// Emission cadence. A real trackpad reports at roughly this rate, and the observed
    /// per-event deltas (~0.015) are what this pairs with to feel native.
    private static let tickInterval = DispatchTimeInterval.milliseconds(5)
    /// Largest progress change per tick.
    ///
    /// A captured trackpad swipe covered 0.50 in 76 events — about 0.0065 each. Ours was
    /// covering the same distance in 21 events of ~0.019, three times coarser and nearly
    /// four times sparser, which is both what made it feel steppy and part of why the
    /// stream did not read as a genuine gesture.
    private static let maxStep = 0.012
    /// Fraction of the outstanding distance covered per tick. Below 1 so the emitted
    /// value eases toward the target instead of snapping to it.
    private static let gain = 0.4
    /// Below this, treat emitted and target as equal and stop emitting.
    private static let epsilon = 0.0005

    private let queue = DispatchQueue(label: "com.mouseenhancer.dockswipe", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private var axis: DockSwipeSimulator.Axis = .horizontal
    private var emitted: Double = 0
    private var target: Double = 0
    private var isActive = false
    /// The began event is held until there is movement to put in it: a real trackpad's
    /// first event already carries the first delta, never a zero placeholder.
    private var beganSent = false
    /// Delta of the most recent event — the ended event repeats it, as real ones do.
    private var lastStep: Double = 0

    public init() {}

    /// Starts a swipe. Any swipe already in flight is ended first — two overlapping
    /// gestures would fight over the same transition.
    public func begin(axis: DockSwipeSimulator.Axis) {
        queue.async { [self] in
            if isActive { finish(velocity: 0) }
            self.axis = axis
            emitted = 0
            target = 0
            lastStep = 0
            beganSent = false
            isActive = true
            startTimer()
        }
    }

    /// Sets where the swipe should be. Called once per mouse move; cheap and non-blocking.
    public func update(target newTarget: Double) {
        queue.async { [self] in
            guard isActive else { return }
            target = newTarget
        }
    }

    /// Ends the swipe, handing over release momentum.
    ///
    /// Any distance the timer has not yet emitted is flushed first: releasing at 80%
    /// emitted when the mouse said 100% would otherwise silently lose the difference,
    /// and that difference is often what decides commit versus snap-back.
    public func end(velocity: Double) {
        queue.async { [self] in
            guard isActive else { return }
            finish(velocity: velocity)
        }
    }

    /// Abandons a swipe without committing — used when the tap is torn down mid-gesture.
    public func cancel() {
        queue.async { [self] in
            guard isActive else { return }
            finish(velocity: 0)
        }
    }

    // MARK: - Internals (queue-confined)

    private func finish(velocity: Double) {
        stopTimer()
        // Close any outstanding distance with one *bounded* step, never the whole
        // remainder. A fast flick can leave the target far ahead of what has been
        // emitted, and dumping that gap as a single event produced steps of ~1.0 where a
        // real trackpad never exceeds ~0.012 — a visible lurch right at the moment of
        // release. The release velocity is what tells the window server the gesture
        // meant to travel further; it does not need to see the distance all at once.
        if abs(target - emitted) > Self.epsilon {
            var step = target - emitted
            if abs(step) > Self.maxStep { step = Self.maxStep * (step < 0 ? -1 : 1) }
            emitted += step
            post(phase: .changed, step: step)
        }
        // A gesture that never moved has nothing to end.
        guard beganSent else { isActive = false; emitted = 0; target = 0; return }
        // Real ended events repeat the final movement's delta rather than zero.
        DockSwipeSimulator.post(axis: axis, phase: .ended, progress: emitted,
                                delta: lastStep, velocity: velocity)
        isActive = false
        emitted = 0
        target = 0
    }

    private func startTimer() {
        stopTimer()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard isActive else { return }
        let remaining = target - emitted
        guard abs(remaining) > Self.epsilon else { return }   // idle: nothing to send

        // Ease toward the target, capped so no single event exceeds a trackpad-sized
        // step even when the mouse jumped a long way.
        var step = remaining * Self.gain
        if abs(step) > Self.maxStep { step = Self.maxStep * (step < 0 ? -1 : 1) }
        // Don't creep forever on the last sliver.
        if abs(remaining) < Self.maxStep, abs(step) < Self.epsilon * 4 { step = remaining }

        emitted += step
        post(phase: .changed, step: step)
    }

    /// Posts one event, promoting the first movement to the began phase — a real
    /// trackpad's began already carries its first delta.
    private func post(phase: DockSwipeSimulator.Phase, step: Double) {
        lastStep = step
        if !beganSent {
            beganSent = true
            DockSwipeSimulator.post(axis: axis, phase: .began, progress: emitted, delta: step)
            return
        }
        DockSwipeSimulator.post(axis: axis, phase: phase, progress: emitted, delta: step)
    }
}
