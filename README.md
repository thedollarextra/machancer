# MacHancer

A macOS menu-bar agent that rebinds extra mouse buttons, keyboard keys and gestures via a
global `CGEventTap`, configured from a SwiftUI settings window. Changes apply live — the
tap is attached once at launch and reads preferences on every event, so nothing needs
restarting or re-attaching.

Built and verified on macOS 26.5. Deployment target is macOS 14.

## Build

```bash
./build.sh                    # release -> ./MacHancer.app
./build.sh debug              # debug build
./build.sh --create-identity  # one-time: stable signing certificate
```

No Xcode project — it's a Swift package assembled into a bundle by `build.sh`, which also
signs it and stamps the build number from the current git commit.

Builds go to `$TMPDIR`, never into the source tree. That's deliberate: this project used
to live in iCloud Drive, where SwiftPM's intermediates fought the sync daemon and a full
rebuild took over ten minutes against about fifty seconds on local disk.

## First run

No Dock icon (`LSUIElement`). It appears as a cursor in the menu bar — slashed and dimmed
when bindings aren't live, solid when they are.

It needs **Accessibility** access. On first launch it triggers the system prompt and opens
Settings. The tap starts the moment permission lands, and if access is later revoked the
app notices and returns to waiting rather than silently dying.

If bindings do nothing while System Settings shows the checkbox ticked, the grant is stale
— see [Signing](#signing).

## Bindings

A binding is **input + exact modifier combination + trigger → action**.

Input is a mouse button (2–15) or a keyboard key. Both share one namespace, so a bound key
gets click, double-click and hold behaviour from the same state machine, with no parallel
implementation.

| Trigger | Notes |
|---|---|
| Click | |
| Double Click | Only buttons with a double-click binding delay their single click |
| Press & Hold | Delay configurable, globally or per binding |
| Drag Up / Down / Left / Right | Dominant axis decides direction |
| Chord | Held together with a second button, in either order |
| Hold & Swipe | Live trackpad-style gesture — see [Swipes](#swipes) |

Modifier matching is **exact**: ⌘+Button 4 does not also fire the plain Button 4 binding. A
combination with no binding passes straight through, so OS defaults keep working.

Rows can be dragged to reorder. Order decides which of two matching rules wins, and a rule
that can never fire because an earlier one already covers it is flagged in the row.

Actions: **native mouse button**, navigation, Mission Control, App Exposé, Show Desktop,
Launchpad, space left/right, close/minimize/quit under the cursor, play-pause,
next/previous track, volume, screenshots, **custom keystroke**, **launch application**,
**run Shortcut**, and **macros** (keystrokes, clicks, actions and delays in sequence).

**Native mouse button** is the "leave it alone" action: apps that read the button directly
keep working, and the event they see is a real one. When it's the only rule on a button the
press isn't suppressed at all; it's re-posted synthetically only when a hold, drag,
double-click or chord on the same button forces the press to be claimed.

A press that is claimed but turns out to be a plain click is **always** put back, whether or
not a click rule exists. Bind only a hold to a button and its click still works. This was
not always true, and the failure was invisible: the press was suppressed at mouse-down to
find out whether a hold or drag was coming, and when the answer was "neither" there was
nothing left to deliver. The only cure was to know that a redundant-looking
`Click → Native Mouse Button` row was what handed it back.

> **Buttons 4 and 5 are not back/forward.** macOS has no system-wide mapping for them, and
> **Safari ignores them entirely** — it treats any unrecognised extra button the way it
> treats a middle click, which is why clicking one over an image opens it in a new tab.
> Chromium browsers work only because Chromium implements it itself. If you want
> back/forward everywhere, bind **Navigate Back / Navigate Forward** (`⌘[` / `⌘]`) rather
> than leaving the button native — "leave it alone" preserves a behaviour Safari never had.

### Out of the box

| Input | Action | Scope |
|---|---|---|
| Button 4 · Click | Navigate Back (`⌘[`) | Safari only |
| Button 5 · Click | Navigate Forward (`⌘]`) | Safari only |
| Button 5 · Press & Hold | App Exposé | |
| Button 5 · Drag Up | Mission Control | |
| Button 5 · Drag Down | App Exposé | |
| Button 5 · Drag Left | Space Right | |
| Button 5 · Drag Right | Space Left | |
| ⌃⌥⌘ + Middle Click | Close Window under Cursor | |

The gestures all hang off Button 5. Button 4 carries nothing but its scoped click, so
outside Safari its press is never suppressed at all — apps that read the button directly
see a genuine event, not a replayed one.

The two navigation rules are **scoped to Safari deliberately**, not globally, for the reason
in the note above: Safari is the one browser where those buttons are otherwise unreachable,
Chromium browsers already handle them natively, and `⌘[` means "outdent" in enough editors
that a global rule would take that with it.

The drags are crossed on purpose: dragging left pushes the current space out to the left,
bringing the one on the right into view. Same convention as natural scrolling.

### While another button is dragging

Any drag or swipe binding can tick **While dragging** to keep working when a window is
already being dragged — press the button mid-drag, swipe, and the window travels with you
to the next space.

It needs its own switch because macOS reports mouse motion under whichever button owns the
drag. Once the left button is down, every move arrives as `leftMouseDragged`, so a gesture
started afterwards with button 5 is claimed and then *starved* — it never sees the mouse
move at all. The tap watches left and right drags purely to forward those coordinates to
any gesture that opted in, and never suppresses them: the drag underneath has to keep
following the cursor, since both happening at once is the entire point.

Mid-drag, the swipe is **measured rather than rendered**. The window server animates a
dock swipe underneath a live mouse drag but will not commit it — a captured gesture
reaching progress 1.000 with release velocity 3.20, saturated and with a textbook trackpad
velocity, still left the space unchanged. macOS's own answer to that case is ⌃← / ⌃→, which
is how it moves a window between spaces while you drag it, so the gesture is tracked for
its threshold and the discrete space switch is invoked on release. Same treatment the
downward swipe already gets, for the same reason.

Off by default, and per binding rather than global, because it costs the gesture its
exclusivity — the movement belongs to two gestures simultaneously. Right for carrying a
window to another space, wrong for anything that would fight the drag underneath it.

### Scope

Every binding can apply everywhere, only in listed apps, or everywhere except them. There
is also an app-wide scope on the **Apps** tab that gates the whole app — outside it every
button behaves natively, whatever the individual rules say.

Scope is resolved at press time and latched for the gesture, so switching apps mid-drag
can't swap the rules underneath.

## Swipes

**Hold & Swipe** emits a real trackpad dock swipe that tracks the drag: up is Mission
Control, down App Exposé, left/right spaces. Because progress is continuous there is no
animation to wait out, which is why it responds faster than a hotkey.

There is no public API for this. `CGEventCreateGesture` does not exist and
`CGSInvokeSymbolicHotKey` was removed in macOS 26 (both verified by `dlsym`). What works is
building an ordinary `CGEvent`, setting its type, and filling private fields with the
entirely public `CGEventSetIntegerValueField`.

The field numbers were **not guessed** — they were read off real three-finger swipes
captured from a trackpad with a listen-only tap:

| Field | Meaning |
|---|---|
| 110 = 23 | `kIOHIDEventTypeDockSwipe` |
| 123 / 165 | axis: 1 horizontal, 2 vertical |
| 124 | cumulative progress, signed; direction is the sign |
| 125 | delta since the previous event |
| 126 | perpendicular drift |
| 129 / 130 | release velocity, on the ended event only |
| 132 / 134 | phase: 1 began, 2 changed, 4 ended |
| 135 | progress again, as a float32 bit pattern |
| 138 = 3 | finger count |

Four things had to match real input before the window server would accept the stream, each
found by diffing our events against a captured trackpad swipe:

- **Field 135 must agree with 124.** Setting only 124 leaves 135 at zero and the transition
  stutters between two disagreeing sources.
- **Velocity is per second, not per event.** A real swipe releases around ±3; per-event
  arithmetic gave ±0.05 and later ±50, and the recogniser rejects an implausible value as
  readily as a null one.
- **Emission must be paced.** Posting one event per mouse move ties gesture timing to
  pointer reporting; a timer walks emitted progress toward a target instead, at
  trackpad-sized steps.
- **No direction bitmask.** Writing fields 115/117/164 aliases into neighbouring double
  fields. The corruption was direction-dependent, which is why left-swipes failed in Exposé
  while right-swipes worked.

Downward swipes are measured rather than rendered: this system animates them and then
refuses to commit however they are fed, so the gesture is tracked for its threshold and
App Exposé invoked on release. **Gestures → Machine-Specific** has a toggle to try the live
transition instead, since whether that works is a property of the machine.

## Tiling

Eleven actions under **Tiling** drive macOS's own window tiling: the four halves, the four
quarters, Fill, Center, Return to Previous Size, and one combined **Restore, or Minimize**.

They act on the **window under the cursor**, not on whatever is frontmost. That isn't a
nicety — a tiling action normally rides a drag or a hold, and *that press was suppressed*
to recognise the gesture, so the window under the cursor never got raised the way an
ordinary click would have raised it. It is raised and its app activated first, then the
menu is read from that app's menu bar.

**Restore, or Minimize** asks macOS rather than measuring anything: Return to Previous Size
is greyed out for an ordinary window and live for a tiled or zoomed one, so that flag *is*
the answer. Comparing the frame against the screen would have to guess at margins, menu bar,
Dock and multi-display layout, and would still disagree with macOS at the edges.

### Why the menu and not the shortcut

Every published summary of macOS tiling says these are keyboard shortcuts. Reading a real
menu with `AXMenuItem` says otherwise, and two things came out of it:

- **Fill and Center are not in Move & Resize.** They sit directly in the Window menu, one
  level up. Move & Resize holds the eight positions, the Arrange family, and the restore.
- **Only Center reports a key equivalent at all.** Fill, all four halves and all four
  quarters report none. A keystroke implementation would have covered one position in
  eleven.

So the menu item is pressed directly. It also survives the user turning the tiling shortcuts
off, and — the part that matters for honest feedback — a press reports whether it worked,
where a posted keystroke only reports that the event left the building.

Setting the window's frame directly was the other option and is rejected on purpose: it
produces a window that merely happens to be half-screen-sized, with no tiling group, no
margins setting, and nothing for Return to Previous Size to undo.

One localized string is depended on: `"Move & Resize"`. The Window menu is deliberately not
matched by name — the menu *containing* a Move & Resize item is the Window menu, whatever it
calls itself, which halves the exposure. On a non-English system the walk fails and falls
back to the documented shortcuts, which covers the halves and little else.

Not implemented: the **Arrange** family (Left & Right, Top & Quarters, and six more). Those
tile two windows and prompt for the second, which is a poor fit for a mouse button.

### Snapping by direction

There is no special trigger for this. Bind the drag directions on one button:

| Input | Action |
|---|---|
| Button N · Drag Left | Tile Left |
| Button N · Drag Right | Tile Right |
| Button N · Drag Up | Fill Screen |
| Button N · Drag Down | Restore, or Minimize |

Hold the button over a window, flick a direction, and it snaps. Each direction is an
independent binding, so any of the eleven positions can go on any of the four.

**Hold & Swipe** is deliberately not the mechanism here: it streams a live gesture whose
whole point is tracking your movement continuously, and macOS tiling is discrete — there is
no half-tiled state to track toward.

## Scrolling

**Smooth scrolling** (on by default, **Scrolling** tab) replaces a wheel notch with the
stream a trackpad produces. A notch is one event carrying a whole line of travel, and that
is exactly what it looks like: the page jumps. The notch is swallowed and the same distance
paid out over a fifth of a second as pixel-unit events shaped like a trackpad's.

The interpolation curve is **measured, not designed**: a listen-only capture of Mos's live
output (389 events, 44 bursts) showed every burst opening with a ~1px event, deltas *rising*
— 1, 10, 39, 55, 62… — and a dead stop on the largest delta, with zero tail in all 44.
The model that reproduces this is a deadline: everything owed lands within `Duration` of the
last notch, target speed is `pending / timeRemaining`, and actual speed chases it through a
~30ms time constant. Slow scrolling gives crisp per-notch hops; a spin faster than the
deadline merges into one steady glide at the input rate. Emission is 100Hz line events
(`isContinuous=0`, no phases — also measured), with trackpad-gesture emission available as
an option for rubber-band overscroll at the cost of phased-swipe misreads.

Step, Speed, and the Dash/Toggle/Block keys mirror Mos's panel with its default values, so
its numbers and muscle memory transfer directly. There is no automatic rate-based
acceleration by default, because Mos has none — its Speed is flat and Dash is manual.

A wheel is identified by Mos's discriminator rather than by `IsContinuous` alone: continuous
input also stamps a `ScrollPhase`, a `MomentumPhase` or a `ScrollCount`, and a wheel stamps
none of the four. The extra reach matters for third-party drivers — Logitech Options,
SteerMouse — which smooth the wheel themselves and emit phased events that `IsContinuous`
would not catch, so they'd be smoothed a second time.

Left alone entirely: trackpads and Magic Mice (already continuous — smoothing something
smooth only adds latency), and ⌘/⌃+wheel, which are zoom and count discrete steps.

### Coasting

A real gesture is two streams, not one. While the finger is down, `phase` runs
began → changed → ended with `momentumPhase` at none; once the finger lifts and the device
coasts, `momentumPhase` runs began → changed → ended with `phase` at none. Notches arriving
are the finger; 100 ms of quiet hands the remaining travel over as the coast. A notch during
the coast ends the momentum and begins a fresh gesture — a hand landing on a trackpad
mid-glide — carrying the outstanding travel with it, since reaching for more scroll is not a
request to start from a standstill.

The distance is identical either way. What changes is what the app is told the movement
*is*, which is what decides how it snaps, paginates and rubber-bands at the end. Both fields
are always written, never left at whatever the constructor produced: an event carrying a
value in both is one no device ever emits.

**Coast after the wheel stops** turns it off, for the few apps that discard momentum events
outright and would otherwise appear to lose the last part of a scroll.

Two things that caused a delayed lurch after the scroll appeared to stop, both fixed:

- **Re-injection level.** Synthesized scrolls go to `.cgSessionEventTap`, the level they
  were intercepted at — never `.cghidEventTap`. The HID point sits upstream of the window
  server's scroll acceleration, which is driven by line delta and event rate and keeps its
  own accumulator. Handing it 120 events a second gives back an amplified stream with a
  tail of its own.
- **App Nap.** This is an `LSUIElement` agent with no window — precisely App Nap's target.
  It suspends and coalesces timers, and a coalesced animation frame still measures real
  elapsed time, so the deferred distance arrives all at once when the timer is released.
  A run holds a `beginActivity(.latencyCritical)` for its duration and no longer.

`momentumPhase` is explicitly zeroed. A real gesture sets one phase or the other, never
both: the user-driven half runs `phase` began→changed→ended with `momentumPhase` at none,
and only when the *device* takes over does `momentumPhase` run while `phase` reads none. We
are always the user-driven half, and this animation already coasts — a consumer reading a
stray momentum value would coast on top of it.

`Distance per step`, `Smoothness` and `Acceleration` tune the feel; acceleration lengthens a
notch when notches arrive quickly, which is the one thing a wheel does better than a
trackpad. Gesture phases can be turned off for an app that reads them as a swipe, and the
whole feature has its own app scope — separate from the app-wide one, because an app that
wants its raw wheel back is rarely one you want every binding disabled in.

## Dock

Middle-clicking a Dock tile runs a per-app action, configured on the **Dock** tab, which
populates itself from the Dock.

The default is **New Window** (⌘N), not a second instance of the app — `createsNewApplicationInstance`
launches a whole extra copy, which most apps refuse and the rest handle badly. If the app
has no window open, or isn't running, it is launched instead; "running" and "has a window"
are not the same thing, and ⌘N is unreliable in the gap between them.

Choices are keyed by bundle identifier, so rearranging the Dock or removing and re-adding
an app leaves them intact. Only non-default choices are stored.

The press is suppressed so the Dock's context menu doesn't appear over the action. That
needs a Dock hit-test inside the tap callback, where a blocking cross-process call is
forbidden — `DockProbe` keeps the tile strip's frame cached and refreshes it off-thread, so
the callback only does a rectangle test.

## Safety

- **On-screen feedback** (default **off**) — a brief HUD naming what fired. It's a
  confirmation aid for a setup you don't trust yet; once you do, a banner on every click is
  noise about actions you just asked for and can see happen.
- **Ignore the empty desktop** (default on) — a stray click on bare desktop won't reach
  through to whatever is behind it.
- **Per-binding confirmation** — Close Window and Quit App each offer a Confirm checkbox.
- **App scope** — apps outside it see their mouse completely untouched.

## Backup

**General → Backup** exports every binding, calibration value, Dock choice and scope to one
JSON file. Absent fields are left alone on import, so a file predating a setting doesn't
silently reset it, and every value is clamped on the way in — a hand-edited file cannot
install an unusable hold delay.

## Layout

All behaviour lives in `MacHancerCore` so it can be tested; `Sources/MacHancer/main.swift`
is a nine-line shim.

| File | Role |
|---|---|
| `Model/Modifiers.swift` | `ModifierSet` — the four real modifiers, codable |
| `Model/Keystroke.swift` | Recorded shortcut + key-code names |
| `Model/Actions.swift` | `ActionKind` / `ActionSpec`, macro steps |
| `Model/ActionBinding.swift` | `TriggerKind`, `ActionBinding`, seeded defaults |
| `Model/AppScope.swift` | Where a binding applies |
| `Model/DockAction.swift` | Per-app Dock middle-click behaviour |
| `Model/SettingsBundle.swift` | Import / export document |
| `GestureEngine.swift` | Pure decision logic: suppress? which action? (no `CGEvent`) |
| `EventTapManager.swift` | Tap plumbing, permission recovery, state reporting |
| `ActionDispatcher.swift` | Action → synthetic event / Accessibility call |
| `AccessibilityBridge.swift` | Crash-safe wrappers over the `AXUIElement` C API |
| `DockProbe.swift` | Cached "is this point on the Dock?" |
| `UserPreferences.swift` | Storage plus the hot-path lookup index |
| `Services/SmoothScroller.swift` | Wheel notch → trackpad-shaped pixel stream |
| `Services/SpaceMonitor.swift` | When macOS actually finished changing space |
| `Services/` | Dock swipe driver, login item, HUD, event log, permission repair |
| `UI/` | Binding row, recorders, scope editor, Dock tab |

The split between `GestureEngine` and `EventTapManager` is what makes the state machine
testable: the engine takes a plain `MouseInput` and *emits* action requests rather than
performing them.

## Tests

```bash
swift run MacHancerChecks    # 137 checks, no Xcode needed
```

Covers pass-through and suppression, per-binding timing overrides, swipe direction and
saturation, the smooth-scroll curve (delivers exactly the distance owed, settles by its
deadline, cancels on reversal, survives a stalled frame), Dock action defaults and
persistence, shadowed-binding detection, the shipped defaults, and settings round-trips
including clamping of hostile values. Timing is injected, so nothing sleeps.

There is also an XCTest suite in `Tests/`, but **XCTest ships with Xcode** — on a machine
with only the Command Line Tools it cannot run at all. `MacHancerChecks` exists so the
repository doesn't imply coverage it can't deliver.

What tests cannot cover is the Accessibility layer, which needs a trusted, bundled process.
The in-app Diagnostics tab and Button Tester that used to fill that gap were removed to keep
the agent small; the file log replaces them and is strictly more useful, since it records the
decision for every press without needing a window open over the app being diagnosed:

```bash
defaults write com.machancer.MacHancer debugLog -bool YES
```

Turn it on under **General → Diagnostics**, which also reveals the file in Finder. It takes
effect immediately — no relaunch — because the settings window is a separate process and
the agent re-reads on the change notification.

Keyboard keys ride the same engine as mouse buttons, so **every keystroke on the system
reaches the logger**. Key names are therefore withheld by default and log as `⌨ key`,
leaving the modifiers and the engine's decision, which is what diagnosing a binding
actually needs.

**"Include key names" is a grant, not a switch.** It is stamped with an expiry an hour out
and lapses on its own, whether or not anyone goes back to turn it off — the risk was never
the hour, it was forgetting. The toggle counts down while it is live, an elapsed grant reads
as off with no action taken, and turning the log off revokes any grant with it. A
hand-edited expiry that is negative or infinite is rejected rather than honoured.

The older `debugLogKeys` boolean is deliberately not migrated: it had no expiry, so anyone
who set it once is still exposed by it, and lapsing back to redaction is the safe direction
to fail.

Relaunch, and `~/Library/Logs/MacHancer.log` gets a line per event — `claimed`, `passed`,
`click -> ...`, the synthetic replays, and whether each was suppressed. This is what
identified a swallowed click that three passes of reading the code had missed. Note that
what the UI calls "Button 4" is button number 3.

## Performance

Measured with a 1.1M-event harness (50k drag gestures of 22 events each):

| | ns/event |
|---|---|
| Before optimization | 864 |
| After | ~200 |

- **Preference scalars are cached in memory.** `dragThresholdPx` was read through
  `UserDefaults` on *every* drag event.
- **Binding lookup is a dictionary**, keyed by `(button, modifiers, trigger)` packed into
  one `Int`, rebuilt only when bindings change, and merged per frontmost app with the
  result cached — the app changes a few times a minute, events arrive hundreds of times a
  second.
- **Log messages are `@autoclosure`**, so logging off costs one boolean.
- **The Dock check rejects geometrically first**, instead of ~80 AX round trips on every
  middle click.
- **Dock icons are loaded once**, not rebuilt per SwiftUI redraw.
- **The code signature is read once.** Every property on `CodeSignature` used to call
  `SecCodeCopySigningInformation` fresh, and the settings window asked for the hash once a
  second. A process cannot change its own signature.

### Measured

| State | Agent | Settings process |
|---|---|---|
| Idle, settings never opened | **14 MB**, 0.0% CPU | — |
| Settings window open | 19 MB | 37 MB |
| After closing | **19 MB**, flat over repeated cycles | gone |

No timer runs while idle except a five-second permission health check, and the
smooth-scroll timer exists only while a scroll is animating.

### The settings window is its own process

Building that UI costs about 21 MB that never comes back. Repeated open/close cycles
plateau, so there is no leak, but the memory is not returned either:
`malloc_zone_pressure_relief` was tried and measured to reclaim none of it, because of the
~26 MB held after closing only about 2 MB reads as reclaimable. The rest is live
allocations SwiftUI and CoreAutoLayout still reference, and there is no API to purge those.
The only thing that returns them is process exit.

So `--settings` re-executes **this same binary** as a second process, and closing the window
terminates it. Re-executing rather than shipping a helper binary is what makes it cheap:

- **Same code signature.** TCC keys an Accessibility grant to the code requirement, so a
  separate helper would have its own trust state and `AXIsProcessTrusted` in the settings
  window would answer about the wrong process. One cdhash means the trust banner is simply
  correct, with no IPC carrying agent state across.
- **Same bundle.** One preferences domain, and `SMAppService.mainApp` still refers to the
  app rather than to a helper, so launch-at-login keeps working.

It is spawned with `Process`, not `NSWorkspace.openApplication` — LaunchServices sees the
bundle identifier already running and would activate the agent instead of starting anything.

That leaves one thing to arrange: the agent holds every preference in memory so the tap
never touches `UserDefaults`, so a write in the other process is invisible to it.
`PreferenceBridge` posts a Darwin notification on every write and the agent re-reads,
coalesced so that dragging a slider costs one reload rather than one per frame. Every write
broadcasts, including the agent's own, because a missed broadcast would show up as settings
that mysteriously don't apply until relaunch — and the wasted re-read costs nothing.

## Signing

TCC keys an Accessibility grant to a code requirement. For an **ad-hoc** signature that
requirement is the cdhash, which moves on essentially every rebuild — so the grant silently
stops applying while the checkbox stays ticked, and the app looks authorised while every
binding is inert.

```bash
./build.sh --create-identity   # once
```

creates a self-signed certificate, after which the requirement is certificate-based and
survives rebuilds. **Settings → General → Repair Permission…** clears a stale record and
restarts so the grant is made against the current build.

Moving the bundle still requires re-granting: TCC keys on path as well.

## Notable deviations from the original spec

These are behavioural fixes, not restyling.

1. **`@AppStorage` on an `ObservableObject` does not publish.** Replaced with
   `UserDefaults`-backed properties that publish explicitly.
2. **Accessibility hit-testing uses `event.location`, not `unflippedLocation`.**
3. **No force-casts on AX attribute values**; the parent walk is depth-bounded.
4. **Actions take a `CGPoint`, not the `CGEvent`** — hold fires long after the callback
   returned, and retaining the event past it isn't guaranteed valid.
5. **Tap re-arming is verified**, because blindly re-enabling spins forever against a
   permission that no longer exists.
6. **Synthetic events are tagged** (`eventSourceUserData`) and skipped by our own tap.
7. **`.cgSessionEventTap`**, the correct attachment point for a filter that suppresses.
8. **Dock detection does not use positional hit-testing** — `AXUIElementCopyElementAtPosition`
   returns `kAXErrorNotImplemented` over a Dock tile. Tile frames are matched instead.
9. **Mission Control, App Exposé and Show Desktop go through `Mission Control.app`**, not
   synthesized hotkeys, which the window server ignores for its own symbolic hotkeys here.
10. **Arrow keys carry the Fn/NumericPad bits**, as real ones do. Space switching is stored
    as Control+Fn, so a plain ⌃-arrow matched nothing — which is why letter shortcuts like
    ⌘[ worked while every ⌃-arrow hotkey silently didn't.
11. **`localEventsSuppressionInterval` is zeroed.** Posting a synthetic event otherwise
    makes the window server ignore real input for 0.25s — disastrous when the events are
    driven by a drag still in progress.
12. **Launchpad no longer exists** in macOS 26; the action opens the Apps view instead.
13. **Buttons 4 and 5 default to themselves**, not to `⌘[` / `⌘]`. Button 4 goes further and
    carries no rule at all, which keeps it out of the engine entirely.
14. **Smooth scrolling sends gesture phases only vertically.** A phased horizontal scroll is
    what Safari reads as a two-finger back/forward swipe, so a tilt wheel would navigate
    instead of scrolling sideways.

## Known gaps

- **Space switching is queued, not instant.** macOS silently drops a switch that arrives
  mid-animation. A repeat now waits for `NSWorkspace.activeSpaceDidChangeNotification` to
  confirm the previous switch actually landed, then for `Repeat spacing` on top — a settle
  time after a known event, rather than a guess measured from our own post, which was why a
  swipe during the animation used to do nothing at all. Confirmation is waited on at most
  once per switch, so reaching the end of the row costs one timeout and not one per gesture
  thereafter. Turning on Reduce Motion is still the only thing that shortens the animation.
- **App Exposé is binary, not continuous**, for the reason described under Swipes.
- **Leftward swipes don't cycle apps inside Exposé.** They work for spaces; the in-Exposé
  case remains unexplained.
- **`shadowedBindingIDs` is O(n²)** and recomputed per redraw of the Bindings list. At
  realistic counts this is microseconds and it never touches the event path.
- **No update mechanism.** Version is visible under General → About; there's no check for
  new builds.
