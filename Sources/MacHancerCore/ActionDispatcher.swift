import AppKit
import ApplicationServices

/// Performs the work the `GestureEngine` asks for. A protocol so tests can
/// substitute a recorder instead of driving the real desktop.
public protocol ActionPerforming: AnyObject {
    func perform(_ request: ActionRequest)
}

/// Translates an `ActionSpec` into synthetic events or Accessibility calls.
///
/// Everything runs on a dedicated serial queue. Two reasons: it must not run inside
/// the tap callback (a blocked callback stalls all system input), and it must not run
/// on the main thread either — an unresponsive target app can block an AX call for
/// hundreds of milliseconds, which would freeze the settings window and status menu.
/// Serial, so actions still fire in the order the user made them.
public final class ActionDispatcher: ActionPerforming {
    public static let shared = ActionDispatcher()

    /// Tags our own synthetic events so the tap can ignore them.
    public static let syntheticEventUserData: Int64 = 0x4D4F5553 // 'MOUS'

    private let prefs: UserPreferences

    /// Posting a synthetic event normally makes the window server ignore *real* input
    /// from the same source for a quarter of a second, so that a scripted sequence isn't
    /// corrupted by the user's hand. That is precisely wrong here: our events are driven
    /// by a drag that is still in progress, and suppressing the mouse mid-gesture
    /// stutters the very input generating it. Zero the interval.
    private let source: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()
    private let queue = DispatchQueue(label: "com.machancer.actions", qos: .userInitiated)

    public init(prefs: UserPreferences = .shared) {
        self.prefs = prefs
    }


    public func perform(_ request: ActionRequest) {
        // Swipe updates bypass the serial queue deliberately. They are ordered already
        // (one per mouse move, from the tap), they must not queue behind a slow
        // Accessibility call, and posting one is a single non-blocking CGEvent — the
        // whole point is that the transition tracks the mouse in real time.
        switch request {
        case let .swipeBegin(axis):
            DockSwipeDriver.shared.begin(axis: axis)
            return
        case let .swipeUpdate(target):
            DockSwipeDriver.shared.update(target: target)
            return
        case let .swipeEnd(velocity):
            DockSwipeDriver.shared.end(velocity: velocity)
            return
        default:
            break
        }

        queue.async { [self] in
            switch request {
            case let .run(binding, location):
                run(binding, at: location)
            case let .dockMiddleClick(location):
                performDockAction(forItemAt: location)
            case .swipeBegin, .swipeUpdate, .swipeEnd:
                break   // handled above, off the serial queue
            }
        }
    }

    /// Fills in payloads that are only knowable from the binding. A `.mouseButton`
    /// action with no explicit number means "the button this fired on".
    private func resolved(_ binding: ActionBinding) -> ActionSpec {
        guard binding.action.kind == .mouseButton, binding.action.mouseButtonNumber == nil
        else { return binding.action }
        var action = binding.action
        action.mouseButtonNumber = binding.button
        return action
    }

    private func run(_ binding: ActionBinding, at location: CGPoint) {
        if binding.requiresConfirmation {
            confirmThenRun(binding, at: location)
            return
        }
        let action = resolved(binding)
        // A gesture made *during* a window drag cannot be paced. Pacing trades latency
        // for delivery, and here latency is the whole failure: the point is that the
        // space changes while the window is still in your hand.
        let succeeded = execute(action, at: location, paced: !binding.survivesWindowDrag)
        announce(action, succeeded: succeeded)
    }

    private func confirmThenRun(_ binding: ActionBinding, at location: CGPoint) {
        DispatchQueue.main.async { [self] in
            let alert = NSAlert()
            alert.messageText = binding.action.displayName + "?"
            alert.informativeText = "Triggered by \(binding.summary)."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            queue.async { [self] in
                let action = resolved(binding)
                let succeeded = execute(action, at: location)
                announce(action, succeeded: succeeded)
            }
        }
    }

    private func announce(_ action: ActionSpec, succeeded: Bool) {
        guard prefs.showActionFeedback else { return }
        let text = succeeded ? action.displayName : "\(action.displayName) — no target"
        DispatchQueue.main.async { FeedbackHUD.shared.show(text) }
    }

    // MARK: - Execution

    @discardableResult
    public func execute(_ action: ActionSpec, at location: CGPoint, paced: Bool = true) -> Bool {
        switch action.kind {
        case .none:
            return false

        case .mouseButton:
            guard let number = action.mouseButtonNumber else { return false }
            return postMouseButton(number, at: location)

        case .macro:
            guard let steps = action.macroSteps else { return false }
            return runMacro(steps, at: location)

        case .navigateBack:      return key(0x21, .command)          // Cmd+[
        case .navigateForward:   return key(0x1E, .command)          // Cmd+]
        case .missionControl:    return missionControlApp(mode: nil)
        case .appExpose:         return missionControlApp(mode: "2")
        case .spaceLeft:         return switchSpace(keyCode: 0x7B, paced: paced)
        case .spaceRight:        return switchSpace(keyCode: 0x7C, paced: paced)
        case .showDesktop:       return missionControlApp(mode: "1", fallbackKey: 0x67)
        case .screenshot:        return key(0x14, [.command, .shift])
        case .screenshotArea:    return key(0x15, [.command, .shift])

        case .launchpad:
            return openLaunchpad()

        case .tileLeft, .tileRight, .tileTop, .tileBottom,
             .tileTopLeft, .tileTopRight, .tileBottomLeft, .tileBottomRight,
             .tileFill, .tileCenter, .tileRestore:
            guard let tile = WindowTile(action.kind) else { return false }
            return applyTile(tile, at: location)

        case .tileRestoreOrMinimize:
            let pid = focusWindow(at: location)
            // Tiled or zoomed → put it back. Otherwise there is nothing to undo, and
            // the useful thing to do with a window you're dismissing is send it away.
            guard WindowTiler.isRestorable(in: pid) else {
                return pressWindowButton(kAXMinimizeButtonAttribute, at: location)
            }
            return WindowTiler.apply(.restore, in: pid)

        case .closeWindow:       return pressWindowButton(kAXCloseButtonAttribute, at: location)
        case .minimizeWindow:    return pressWindowButton(kAXMinimizeButtonAttribute, at: location)
        case .quitApp:           return quitApp(at: location)

        case .playPause:         return mediaKey(NX_KEYTYPE_PLAY)
        case .nextTrack:         return mediaKey(NX_KEYTYPE_NEXT)
        case .previousTrack:     return mediaKey(NX_KEYTYPE_PREVIOUS)
        case .volumeUp:          return mediaKey(NX_KEYTYPE_SOUND_UP)
        case .volumeDown:        return mediaKey(NX_KEYTYPE_SOUND_DOWN)
        case .mute:              return mediaKey(NX_KEYTYPE_MUTE)

        case .customKeystroke:
            guard let stroke = action.keystroke else { return false }
            // Deliberately not naming the key: this fires for any bound keystroke, and
            // the log must not become a record of what was typed. The modifiers and the
            // fact it was posted are what tell you whether the binding reached here.
            DebugLog.write("posting custom keystroke, modifiers=\(stroke.modifiers.rawValue)")
            return key(CGKeyCode(stroke.keyCode), stroke.modifiers)

        case .launchApplication:
            guard let path = action.applicationPath else { return false }
            return openApplication(at: URL(fileURLWithPath: path))

        case .runShortcut:
            guard let name = action.shortcutName, !name.isEmpty,
                  let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)")
            else { return false }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return true
        }
    }

    // MARK: - Spaces

    /// Generation the previously posted switch is still waiting to see move. `nil` when
    /// nothing is outstanding.
    private var pendingSpaceGeneration: Int?

    /// Switches space, holding a rapid repeat back rather than letting it be swallowed.
    ///
    /// The window server ignores a space-switch request while the previous transition is
    /// still animating — so triggering the action three times quickly moves one space,
    /// not three, and the extra presses are simply lost. Nothing about the *trigger*
    /// changes that: a real three-finger trackpad swipe waits on the same animation, and
    /// there is no supported way to synthesize one anyway (`CGEventCreateGesture` does
    /// not exist; `MTDeviceCreateList` only reads trackpads).
    ///
    /// What can be fixed is the losing. This runs on the dispatcher's serial queue, so
    /// waiting out the remainder of the animation turns a dropped repeat into a queued
    /// one — swipe again and the space steps past instead of nothing happening.
    ///
    /// The wait is in two parts, because a fixed delay alone was the bug. It was
    /// measured from *our own post*, which says nothing about when the transition
    /// actually began, let alone ended: a switch that the window server queued or
    /// delayed pushed the whole animation past the gap, and the next request landed
    /// inside it and vanished. So the first part waits for `SpaceMonitor` to confirm the
    /// previous switch really happened, and only then does `spaceSwitchGapSec` run — as
    /// a settle time after a known event rather than a guess from an unrelated one.
    ///
    /// Confirmation is waited on at most once per posted switch. Asking to move past the
    /// last space in the row is a legitimate no-op that never confirms, and it must cost
    /// one timeout, not one on every switch thereafter.
    private func switchSpace(keyCode: CGKeyCode, paced: Bool = true) -> Bool {
        let monitor = SpaceMonitor.shared

        // Unpaced: post now and accept that a repeat arriving mid-animation may be
        // swallowed. That trade is only correct when the request is tied to something
        // the user is physically still doing — a window drag — where arriving a second
        // late is worse than not arriving. Everywhere else pacing is what makes held
        // repeats land at all.
        //
        // The compounding is the real reason this matters. `pendingSpaceGeneration`
        // stays set whenever a switch produced no space change — the end of the row,
        // or macOS declining it — so the *next* switch pays the full 0.8s timeout
        // before it even posts. Two of those and the keystroke lands after the mouse
        // button is already up.
        guard paced else {
            let posted = key(keyCode, .control)
            DebugLog.write("space switch posted unpaced \(keyCode == 0x7B ? "left" : "right")")
            return posted
        }

        if let pending = pendingSpaceGeneration {
            pendingSpaceGeneration = nil
            monitor.waitForChange(after: pending, timeout: 0.8)
        }

        // Confirmation lands with the switch, not at the end of its animation, and a
        // request arriving in that tail is dropped just the same.
        let gap = prefs.spaceSwitchGapSec
        if gap > 0 {
            let elapsed = ProcessInfo.processInfo.systemUptime - monitor.lastChangeTime
            if elapsed < gap {
                usleep(UInt32(min(gap - elapsed, gap) * 1_000_000))
            }
        }

        let generation = monitor.generation
        let posted = key(keyCode, .control)
        if posted { pendingSpaceGeneration = generation }

        // Which display the request lands on is not ours to choose: ⌃← / ⌃→ acts on
        // whichever display holds focus, and with separate Spaces per display that need
        // not be the one under the cursor. Recorded so a switch that goes to the wrong
        // monitor is distinguishable from one that never happened.
        if DebugLog.isEnabled {
            let mouse = CGEvent(source: nil)?.location ?? .zero
            let screen = NSScreen.screens.firstIndex { $0.frame.contains(
                NSPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y)
            ) }
            DebugLog.write("space switch posted \(keyCode == 0x7B ? "left" : "right")"
                           + " | cursor on screen \(screen.map(String.init) ?? "?")"
                           + " of \(NSScreen.screens.count)")
        }
        return posted
    }

    // MARK: - Macros

    /// Runs macro steps in order on the dispatcher queue.
    ///
    /// Sleeping here is legitimate — this queue exists precisely so slow work never
    /// touches the tap callback or the main thread — but it is serial, so a running
    /// macro delays other actions behind it. That's also the correct behaviour:
    /// actions fire in the order the user made them. Delays are clamped so a typo
    /// (600 instead of 0.600) can't wedge the queue for ten minutes.
    private func runMacro(_ steps: [MacroStep], at location: CGPoint) -> Bool {
        var didSomething = false
        for step in steps where step.isConfigured {
            switch step.kind {
            case .delay:
                let seconds = min(max(step.delaySec ?? 0, 0), 10)
                usleep(UInt32(seconds * 1_000_000))

            case .keystroke:
                guard let stroke = step.keystroke else { continue }
                didSomething = key(CGKeyCode(stroke.keyCode), stroke.modifiers) || didSomething

            case .mouseClick:
                guard let button = step.mouseButton else { continue }
                // Click wherever the cursor is *now*, not where the gesture began —
                // an earlier step may have moved focus, and mid-macro the original
                // location is stale.
                let cursor = CGEvent(source: nil)?.location ?? location
                didSomething = postMouseButton(button, at: cursor) || didSomething

            case .action:
                guard let kind = step.actionKind, kind != .macro else { continue }
                didSomething = execute(ActionSpec(kind: kind), at: location) || didSomething
            }
        }
        return didSomething
    }

    // MARK: - Synthetic input

    /// Re-posts a mouse button so the OS handles it natively.
    ///
    /// Only needed when the press had to be claimed anyway — because a hold, drag or
    /// double-click binding shares the same button — since a button with nothing but a
    /// native click on it is never suppressed in the first place.
    ///
    /// `CGMouseButton` only names left/right/center; anything above that is expressed by
    /// posting a `.center` event and overriding `mouseEventButtonNumber`, which is what
    /// the window server actually reads.
    @discardableResult
    private func postMouseButton(_ button: Int, at location: CGPoint) -> Bool {
        let downType: CGEventType
        let upType: CGEventType
        switch button {
        case 0:  (downType, upType) = (.leftMouseDown, .leftMouseUp)
        case 1:  (downType, upType) = (.rightMouseDown, .rightMouseUp)
        default: (downType, upType) = (.otherMouseDown, .otherMouseUp)
        }

        let cgButton = CGMouseButton(rawValue: UInt32(max(0, min(button, 2)))) ?? .center
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: downType,
                               mouseCursorPosition: location, mouseButton: cgButton),
            let up = CGEvent(mouseEventSource: source, mouseType: upType,
                             mouseCursorPosition: location, mouseButton: cgButton)
        else { return false }

        // Whatever the user is physically holding right now. A replayed click is
        // standing in for one that happened a few milliseconds ago, and ⌘-click,
        // ⇧-click and ⌥-click all mean something different from the plain kind — a
        // replay that drops them is a different click from the one that was suppressed.
        let heldModifiers = CGEventSource.flagsState(.combinedSessionState)

        for event in [down, up] {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.flags = heldModifiers
            // Tagged so our own tap ignores it and we don't recurse.
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        DebugLog.write("replayed button \(button) at "
                       + "\(Int(location.x)),\(Int(location.y)) flags=\(heldModifiers.rawValue)")
        return true
    }

    /// Drives Mission Control through its own app, not through synthesized hotkeys.
    ///
    /// The synthetic ⌃↑ / ⌃↓ path posts fine (the HUD confirms the binding fired) but
    /// the window server ignores it for its *own* symbolic hotkeys on this system —
    /// ordinary app shortcuts like ⌘[ work, Mission Control does not. The old direct
    /// entry point (`CGSInvokeSymbolicHotKey`) no longer exists on macOS 26 (verified
    /// via dlsym), so the reliable route is the one Apple ships for exactly this:
    /// `Mission Control.app`, whose binary takes `1` for Show Desktop and `2` for
    /// App Exposé, and toggles Mission Control with no argument. Launching it again
    /// dismisses the view, matching the hotkey's toggle behaviour.
    private func missionControlApp(mode: String?, fallbackKey: CGKeyCode? = nil) -> Bool {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        guard FileManager.default.fileExists(atPath: url.path) else {
            // No app bundle (unexpected): fall back to the keystroke, which needs the
            // matching symbolic hotkey to be enabled.
            if let fallbackKey { return key(fallbackKey, []) }
            return key(mode == "2" ? 0x7D : 0x7E, .control)
        }
        DispatchQueue.main.async {
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = mode.map { [$0] } ?? []
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
        return true
    }

    /// Launchpad was removed in macOS 26 — `/System/Applications/Launchpad.app` no
    /// longer exists and its bundle identifier no longer resolves, so the old
    /// "open the app" implementation could never succeed there. Fall back to the
    /// Apps view that replaced it (fn+A), which `ModifierSet` can't express because
    /// fn isn't one of the four bindable modifiers.
    private func openLaunchpad() -> Bool {
        let legacy = URL(fileURLWithPath: "/System/Applications/Launchpad.app")
        if FileManager.default.fileExists(atPath: legacy.path) {
            return openApplication(at: legacy)
        }

        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: false)
        else { return false }

        for event in [down, up] {
            event.flags = .maskSecondaryFn
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Virtual key codes for the modifier keys themselves.
    private static func modifierKeyCode(_ modifier: ModifierSet) -> CGKeyCode? {
        switch modifier {
        case .control: return 0x3B
        case .option:  return 0x3A
        case .shift:   return 0x38
        case .command: return 0x37
        default:       return nil
        }
    }

    /// The window server handles hotkeys asynchronously. Without a gap between the
    /// modifier transition and the key, the key can be processed while the modifier is
    /// not yet considered down — which is the exact failure this code path had.
    /// Safe to sleep here: this runs on the dispatcher's own serial queue, never on the
    /// tap callback or the main thread.
    private static func settle() { usleep(8_000) }

    private func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
    }

    /// Posts a real modifier transition. A modifier press is a `flagsChanged` event, not
    /// a key event, so the type is overridden after construction.
    private func postFlagsChanged(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        else { return }
        event.type = .flagsChanged
        event.flags = flags
        tag(event)
        event.post(tap: .cghidEventTap)
        Self.settle()
    }

    /// Sends a keystroke by genuinely pressing and releasing its modifiers around it.
    ///
    /// Stamping `flags` onto the key event alone — what this used to do — is enough for
    /// ordinary application shortcuts (⌘[ / ⌘] worked fine), but *not* for the window
    /// server's own hotkeys. Mission Control, App Exposé and space switching match on
    /// real modifier state, which only changes when `flagsChanged` events are posted.
    /// Without them Control was never actually held, the arrow key arrived bare, and the
    /// hotkey silently never matched.
    /// `forceFn` is for the shortcuts that carry Fn on a key that isn't an arrow —
    /// macOS's window tiling puts it on F and C as well, and Fn is not one of the four
    /// modifiers a binding can name.
    @discardableResult
    private func key(_ keyCode: CGKeyCode, _ modifiers: ModifierSet, forceFn: Bool = false) -> Bool {
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }

        let held = ModifierSet.all.filter { modifiers.contains($0) }
        var flags = CGEventFlags()

        for modifier in held {
            guard let code = Self.modifierKeyCode(modifier) else { continue }
            flags.formUnion(modifier.cgFlags)
            postFlagsChanged(code, flags)
        }

        // Arrow keys from real hardware always carry the Fn/NumericPad bits, and the
        // window server's hotkey table stores them that way — space switching (hotkey 79)
        // is Control|Fn = 0x840000, not plain Control. A synthetic arrow without the Fn
        // bit posts fine but matches nothing, which is why ⌘[ worked while every
        // ⌃-arrow hotkey silently didn't. These bits ride only on the key events, never
        // the flagsChanged transitions — real hardware sends no fn transition either.
        var keyFlags = flags
        if (0x7B...0x7E).contains(keyCode) {
            keyFlags.insert(.maskSecondaryFn)
            keyFlags.insert(.maskNumericPad)
        } else if forceFn {
            // NumericPad is an arrow-key property, not an Fn one — a real Fn+F carries
            // only the Fn bit, so only that is added here.
            keyFlags.insert(.maskSecondaryFn)
        }

        down.flags = keyFlags
        up.flags = keyFlags
        tag(down)
        tag(up)

        down.post(tap: .cghidEventTap)
        Self.settle()
        up.post(tap: .cghidEventTap)
        Self.settle()

        // Release in reverse order, so the flag state unwinds the way a human hand would.
        for modifier in held.reversed() {
            guard let code = Self.modifierKeyCode(modifier) else { continue }
            flags.subtract(modifier.cgFlags)
            postFlagsChanged(code, flags)
        }
        return true
    }

    /// Media and volume keys aren't virtual key codes — they're `NSSystemDefined`
    /// events with the key packed into `data1`.
    ///
    /// `NSEvent.otherEvent` is AppKit and must be built on the main thread; this runs on
    /// the dispatcher's background queue. The hop is `sync` so the two events stay
    /// ordered and the result is still returnable — safe because nothing on the main
    /// thread ever blocks waiting on this queue.
    @discardableResult
    private func mediaKey(_ key: Int32) -> Bool {
        var succeeded = true
        DispatchQueue.main.sync {
            for isDown in [true, false] {
                let state = isDown ? 0xA : 0xB
                let data1 = Int((key << 16) | (Int32(state) << 8))
                guard let event = NSEvent.otherEvent(
                    with: .systemDefined,
                    location: .zero,
                    modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    subtype: 8,
                    data1: data1,
                    data2: -1
                ), let cgEvent = event.cgEvent else { succeeded = false; return }
                cgEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
                cgEvent.post(tap: .cghidEventTap)
            }
        }
        return succeeded
    }

    /// `NSWorkspace` is AppKit; launching from the background queue is not supported.
    private func openApplication(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        DispatchQueue.main.async {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
        return true
    }

    // MARK: - Windows under the cursor

    /// Presses a titlebar button (close / minimize) on the window under `location`.
    @discardableResult
    private func pressWindowButton(_ attribute: String, at location: CGPoint) -> Bool {
        guard let window = windowElement(at: location) else { return false }
        if let button = AX.child(window, attribute) {
            return AX.perform(button, kAXPressAction as String)
        }
        // Mission Control / Exposé proxies expose no titlebar buttons but answer AXCancel.
        return attribute == kAXCloseButtonAttribute ? AX.perform(window, "AXCancel") : false
    }

    // MARK: - Tiling

    private func applyTile(_ tile: WindowTile, at location: CGPoint) -> Bool {
        WindowTiler.apply(tile, in: focusWindow(at: location))
    }

    /// Raises the window under the cursor and activates its app, returning that app's
    /// pid so the tiling menu is read from the right menu bar.
    ///
    /// This is what makes tiling act on the window you are pointing at rather than
    /// whatever happened to be frontmost. It is not optional: a tiling action normally
    /// rides a drag or a hold, and *that press was suppressed* to recognise the gesture,
    /// so the window under the cursor never got raised the way an ordinary click would
    /// have raised it. Without this, dragging on a background window tiles a different
    /// window entirely.
    ///
    /// Falls back to the frontmost app when the cursor is over bare desktop, which keeps
    /// the action useful from a keyboard binding where there is no meaningful cursor.
    @discardableResult
    private func focusWindow(at location: CGPoint) -> pid_t? {
        guard let window = windowElement(at: location), let pid = AX.pid(window) else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }

        AX.perform(window, kAXRaiseAction as String)
        if let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
            app.activate()
            // Activation is asynchronous, and the menu is read from the app we just
            // switched to. This is the same settle the synthetic keystrokes use.
            Self.settle()
        }
        return pid
    }

    private func quitApp(at location: CGPoint) -> Bool {
        guard let (pid, _) = frontmostWindow(containing: location),
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return false }
        return app.terminate()
    }

    /// Resolves the window under the cursor.
    ///
    /// Layered on purpose. Positional hit-testing is the clean approach but is not
    /// universally available — the Dock answers `kAXErrorNotImplemented` for it, and
    /// some apps refuse geometry attributes outright — so fall back to locating the
    /// window through the window server, which never depends on the target app
    /// cooperating with hit-tests.
    func windowElement(at location: CGPoint) -> AXUIElement? {
        // One window-server snapshot, reused for both the desktop check and the
        // geometry match below — it used to be taken twice per action.
        let front = frontmostWindow(containing: location)

        // No ordinary window under the point means bare desktop.
        if prefs.closeIgnoresDesktop, front == nil { return nil }

        if let hit = AX.element(at: location), let window = AX.enclosingWindow(of: hit) {
            return window
        }

        guard let (pid, bounds) = front else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        let windows = AX.attribute(appElement, kAXWindowsAttribute as String) as? [AXUIElement] ?? []

        // Prefer an exact geometry match; tolerate rounding and shadow insets.
        if let match = windows.first(where: { window in
            guard let frame = AX.frame(window) else { return false }
            return abs(frame.origin.x - bounds.origin.x) < 4
                && abs(frame.origin.y - bounds.origin.y) < 4
                && abs(frame.width - bounds.width) < 8
                && abs(frame.height - bounds.height) < 8
        }) {
            return match
        }

        // Geometry unavailable (some apps refuse AXPosition): fall back to the app's
        // focused window, but only if the click really landed inside it.
        if let focused = AX.child(appElement, kAXFocusedWindowAttribute as String) {
            if let frame = AX.frame(focused), !frame.contains(location) { return nil }
            return focused
        }
        return nil
    }

    /// Frontmost normal window containing `location`, via the window server.
    /// `CGWindowListCopyWindowInfo` returns windows front-to-back.
    func frontmostWindow(containing location: CGPoint) -> (pid: pid_t, bounds: CGRect)? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for window in windows {
            guard window["kCGWindowLayer"] as? Int == 0,                 // normal windows only
                  let pid = window["kCGWindowOwnerPID"] as? pid_t,
                  let boundsDict = window["kCGWindowBounds"] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(location)
            else { continue }
            return (pid, bounds)
        }
        return nil
    }

    // MARK: - Dock: per-app middle click

    /// Runs the configured action for the Dock tile under `location`.
    ///
    /// Called for *every* plain middle click, so it confirms the cursor really is over a
    /// Dock tile before doing anything at all.
    public func performDockAction(forItemAt location: CGPoint) {
        guard
            let name = dockItemTitle(at: location),
            let url = DockInventory.applicationURL(named: name),
            let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }

        let action = prefs.dockAction(for: bundleID)
        guard action != .none else { return }
        perform(action, on: url, bundleID: bundleID, name: name)
    }

    /// Performs one Dock action against a specific app.
    ///
    /// Keystroke actions have to be *delivered into* the app, which means activating it
    /// first and waiting for the activation to land — a ⌘N posted before the app is
    /// frontmost goes to whatever was. If the app isn't running, launching it produces a
    /// window on its own and no keystroke is needed.
    private func perform(_ action: DockAction, on url: URL, bundleID: String, name: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first

        switch action {
        case .none:
            return

        case .newInstance:
            DispatchQueue.main.async {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: url, configuration: config,
                                                   completionHandler: nil)
            }

        case .activate:
            DispatchQueue.main.async { running?.activate(options: [.activateAllWindows]) }

        case .hide:
            DispatchQueue.main.async { running?.hide() }

        case .quit:
            DispatchQueue.main.async { running?.terminate() }

        case .newWindow, .newTab:
            // "Running" is not the same as "has a window". An app whose windows have all
            // been closed stays in the Dock, and sending it ⌘N in that state is
            // unreliable — plenty of apps disable the menu item until a window exists.
            // Launching it again is what a normal Dock click does, and the app's own
            // reopen handling produces the window.
            guard let running, hasOpenWindow(pid: running.processIdentifier) else {
                _ = openApplication(at: url)
                announceDock(action, name: name)
                return
            }
            guard let stroke = action.keystroke else { return }
            DispatchQueue.main.async { running.activate(options: [.activateAllWindows]) }
            // Activation is asynchronous; the keystroke must follow it, not race it.
            queue.asyncAfter(deadline: .now() + 0.18) { [self] in
                _ = key(stroke.keyCode, stroke.modifiers)
            }
        }
        announceDock(action, name: name)
    }

    /// Does this process currently have any window at all?
    ///
    /// Asked through Accessibility first, because its window list includes minimised and
    /// off-screen windows — a minimised window is still a window, and reopening the app
    /// in that state would be wrong. Falls back to the window server for apps that don't
    /// publish `AXWindows`, counting only normal-layer windows so panels, menus and
    /// status items aren't mistaken for documents.
    ///
    /// Safe to call here: this runs on the dispatcher's serial queue, never on the tap
    /// callback or the main thread.
    private func hasOpenWindow(pid: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        if let windows = AX.attribute(element, kAXWindowsAttribute as String) as? [AXUIElement] {
            return !windows.isEmpty
        }

        guard let listed = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return listed.contains { window in
            window["kCGWindowOwnerPID"] as? pid_t == pid
                && window["kCGWindowLayer"] as? Int == 0
        }
    }

    private func announceDock(_ action: DockAction, name: String) {
        guard prefs.showActionFeedback else { return }
        DispatchQueue.main.async {
            FeedbackHUD.shared.show("\(name) — \(action.shortTitle)")
        }
    }

    /// Title of the Dock tile under `location`, or nil if the point isn't on one.
    ///
    /// The obvious approach — `AXUIElementCopyElementAtPosition` — does not work here:
    /// the Dock returns `kAXErrorNotImplemented` (-25208) for positional hit-tests, on
    /// its tiles and on the strip as a whole. Verified on macOS 26.3. So enumerate the
    /// tiles and match the point against their reported frames instead.
    func dockItemTitle(at location: CGPoint) -> String? {
        // Cheap reject first. Enumerating the tiles costs an AX round trip per tile
        // per attribute — roughly 80 of them on a normal Dock — and this runs on every
        // plain middle click, including middle-clicking links in a browser.
        guard couldBeDock(location) else { return nil }

        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        for list in AX.children(dockElement) {
            for tile in AX.children(list) {
                guard AX.role(tile) == "AXDockItem",
                      let frame = AX.frame(tile),
                      frame.contains(location)
                else { continue }
                return AX.string(tile, kAXTitleAttribute as String)
            }
        }
        return nil
    }

    /// Is this point plausibly on the Dock? Pure geometry, no cross-process calls.
    ///
    /// Two ways to qualify, because either alone gives false negatives: the Dock strip
    /// isn't a normal window, so nothing from the window server sits under it — but a
    /// manually resized window *can* extend beneath the Dock, in which case the second
    /// test (the point lies in the screen's reserved edge, outside `visibleFrame`)
    /// catches it.
    private func couldBeDock(_ location: CGPoint) -> Bool {
        if frontmostWindow(containing: location) == nil { return true }

        for screen in NSScreen.screens {
            let frame = cgRect(screen.frame)
            guard frame.contains(location) else { continue }
            return !cgRect(screen.visibleFrame).contains(location)
        }
        return false
    }

    /// Cocoa screen coordinates (origin bottom-left of the primary display) into the
    /// top-left space `CGEvent` and Accessibility use.
    private func cgRect(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.origin.x,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

}
