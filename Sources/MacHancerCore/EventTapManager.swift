import AppKit
import ApplicationServices

/// Owns the global `CGEventTap` and hands events to the `GestureEngine`.
///
/// The tap is attached once and never rebuilt: all behaviour is read live from
/// `UserPreferences` on each event, so settings changes apply immediately.
public final class EventTapManager {

    public enum State: Equatable {
        case stopped
        case waitingForPermission
        case active

        public var isActive: Bool { self == .active }

        public var description: String {
            switch self {
            case .stopped: return "Stopped"
            case .waitingForPermission: return "Waiting for Accessibility access"
            case .active: return "Active"
            }
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var healthTimer: Timer?

    private let engine: GestureEngine
    private let dispatcher: ActionPerforming
    private let prefs: UserPreferences
    private let scroller: SmoothScroller

    /// Keyboard keys whose key-down we swallowed; their autorepeats and key-up must be
    /// swallowed too, or the target app sees a key release it never saw pressed.
    private var claimedKeys: Set<Int> = []

    /// Whether the OS accepted a tap that includes keyboard events. If it refused,
    /// mouse features still run on a narrower tap instead of nothing working at all.
    public private(set) var keyboardCaptureAvailable = false

    public private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Lets the status item reflect reality instead of always looking healthy.
    public var onStateChange: ((State) -> Void)?

    public init(
        prefs: UserPreferences = .shared,
        dispatcher: ActionPerforming = ActionDispatcher.shared,
        scroller: SmoothScroller = .shared
    ) {
        self.dispatcher = dispatcher
        self.prefs = prefs
        self.scroller = scroller
        self.engine = GestureEngine(prefs: prefs)

        // The dispatcher owns its own queue; hand off and return immediately so the
        // tap callback never waits on an Accessibility round trip.
        self.engine.onAction = { [dispatcher] request in
            dispatcher.perform(request)
        }

    }

    // MARK: - Lifecycle

    /// Starts the tap, or waits for Accessibility trust and starts as soon as it lands.
    public func start() {
        guard state != .active else { return }

        if AX.isTrusted {
            attachTap()
        } else {
            AX.requestTrust()
            waitForPermission()
        }
    }

    public func stop() {
        teardownTap()
        permissionTimer?.invalidate()
        permissionTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
        state = .stopped
    }

    private func teardownTap() {
        engine.reset()
        claimedKeys.removeAll()
        scroller.reset()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func waitForPermission() {
        state = .waitingForPermission
        guard permissionTimer == nil else { return }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard AX.isTrusted else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.attachTap()
        }
    }

    private func attachTap() {
        let mouseMask: CGEventMask =
            (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
        let keyMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        func createTap(_ mask: CGEventMask) -> CFMachPort? {
            CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: eventTapCallback,
                userInfo: selfPtr
            )
        }

        // Keyboard interception can be refused independently of mouse (it may want the
        // separate Input Monitoring grant on some systems). Degrade to mouse-only rather
        // than losing everything.
        var tap = createTap(mouseMask | keyMask)
        keyboardCaptureAvailable = tap != nil
        if tap == nil {
            NSLog("[MacHancer] Keyboard tap refused — falling back to mouse-only")
            tap = createTap(mouseMask)
        }
        // This used to be visible only on the Diagnostics tab, which no longer exists.
        // It is the first thing worth knowing when a key binding does nothing at all:
        // a refused keyboard tap looks identical to a binding that never matched, and
        // `NSLog` from this bundled agent does not reach the unified log.
        let captureNote = keyboardCaptureAvailable ? "available" : "REFUSED (mouse only)"
        DebugLog.write("tap attached, keyboard capture " + captureNote)
        guard let tap else {
            NSLog("[MacHancer] Failed to create event tap — Accessibility permission missing?")
            waitForPermission()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        state = .active
        startHealthChecks()

        // An attached tap is the only unambiguous proof we were trusted, so this is
        // where the signature that earned it gets recorded. A ticked box in System
        // Settings proves nothing — that is the whole failure mode.
        PermissionRepair.shared.noteTrusted()
    }

    /// Accessibility can be revoked while we're running. When that happens the tap is
    /// disabled and never recovers on its own, so re-enabling it in a loop would spin
    /// forever against a permission that no longer exists. Verify instead, and drop
    /// back to waiting for the user to grant it again.
    private func startHealthChecks() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, self.state == .active else { return }

            if !AX.isTrusted {
                self.handleLostPermission()
                return
            }
            if let tap = self.eventTap, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) { self.handleLostPermission() }
            }
        }
    }

    private func handleLostPermission() {
        NSLog("[MacHancer] Accessibility access lost — waiting for it to be restored")
        teardownTap()
        healthTimer?.invalidate()
        healthTimer = nil
        waitForPermission()
    }

    /// The system disables a tap that blocks for too long. Re-arm — but confirm it
    /// actually came back, rather than assuming.
    fileprivate func reenableTap() {
        guard let tap = eventTap else { return }
        engine.reset()
        claimedKeys.removeAll()
        scroller.reset()
        CGEvent.tapEnable(tap: tap, enable: true)

        if !CGEvent.tapIsEnabled(tap: tap) {
            handleLostPermission()
        }
    }

    /// Returns `true` to swallow the event.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        // Never react to the keystrokes we synthesize ourselves.
        guard event.getIntegerValueField(.eventSourceUserData) != ActionDispatcher.syntheticEventUserData
        else {
            if DebugLog.isEnabled, type == .otherMouseDown || type == .otherMouseUp {
                DebugLog.write("saw our own button "
                               + "\(event.getIntegerValueField(.mouseEventButtonNumber))"
                               + " \(type == .otherMouseDown ? "down" : "up") — passing it on")
            }
            return false
        }

        if type == .keyDown || type == .keyUp {
            return handleKey(type: type, event: event)
        }

        // Scrolling never reaches the gesture engine: a wheel notch has no press, no
        // release and no button to bind, so it is its own path from here down.
        if type == .scrollWheel {
            return scroller.handleScroll(event)
        }

        let phase: MouseInput.Phase
        switch type {
        case .otherMouseDown: phase = .down
        case .otherMouseDragged: phase = .dragged
        case .otherMouseUp: phase = .up
        default: return false
        }

        let input = MouseInput(
            phase: phase,
            button: Int(event.getIntegerValueField(.mouseEventButtonNumber)),
            location: event.location, // AX space: origin top-left
            modifiers: ModifierSet(cgFlags: event.flags)
        )


        return engine.handle(input)
    }

    /// Keyboard keys ride the same gesture engine as mouse buttons, mapped into the
    /// key namespace — which is what gives a bound key double-press and press-&-hold
    /// for free. Returns `true` to swallow.
    private func handleKey(type: CGEventType, event: CGEvent) -> Bool {
        // Cheapest possible exit for people who never bind a key: every keystroke on
        // the system passes through here once the tap includes keyboard events.
        guard prefs.hasKeyboardBindings else { return false }

        // Never intercept typing into our own UI — the keystroke recorders in Settings
        // must see raw keys, and a binding must not fire while you're editing it.
        if FrontmostAppTracker.shared.bundleIdentifier == Bundle.main.bundleIdentifier {
            return false
        }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let button = MouseButton.keyButton(code)

        // Autorepeat belongs to whoever owns the key: swallowed if we claimed the
        // press (or the target app would type a burst of characters mid-hold), passed
        // through otherwise. It must not reach the engine — each repeat looks like a
        // fresh press and would restart the gesture.
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return claimedKeys.contains(button)
        }

        // Key events carry no useful location; actions that care about the cursor
        // (close window under cursor) want where the pointer is now.
        let location = CGEvent(source: nil)?.location ?? .zero
        let input = MouseInput(
            phase: type == .keyDown ? .down : .up,
            button: button,
            location: location,
            modifiers: ModifierSet(cgFlags: event.flags)
        )


        let suppressed = engine.handle(input)
        if type == .keyDown {
            if suppressed { claimedKeys.insert(button) }
        } else {
            claimedKeys.remove(button)
        }
        return suppressed
    }
}

// MARK: - C callback bridge

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        manager.reenableTap()
        return Unmanaged.passUnretained(event)
    }

    return manager.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}
