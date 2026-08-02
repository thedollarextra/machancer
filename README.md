# Mouse Enhancer

A macOS menu-bar agent that rebinds extra mouse buttons, keyboard keys and gestures via a
global `CGEventTap`, configured from a SwiftUI settings window. Changes apply live — the
tap is attached once at launch and reads preferences on every event, so nothing needs
restarting or re-attaching.

Built and verified on macOS 26.5. Deployment target is macOS 14.

## Build

```bash
./build.sh                    # release -> ./MouseEnhancer.app
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

**Native mouse button** is the "leave it alone" action, and the default for buttons 4 and
5. macOS already maps them to back/forward, and apps that read them directly keep working
— a `⌘[` translation only ever reproduced a subset. When it's the only rule on a button the
press isn't suppressed at all; it's re-posted synthetically only when a hold, drag,
double-click or chord on the same button forces the press to be claimed.

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

- **On-screen feedback** (default on) — a brief HUD naming what fired.
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

All behaviour lives in `MouseEnhancerCore` so it can be tested; `Sources/MouseEnhancer/main.swift`
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
| `Services/` | Dock swipe driver, login item, HUD, event log, permission repair |
| `UI/` | Binding row, recorders, scope editor, Dock tab, diagnostics |

The split between `GestureEngine` and `EventTapManager` is what makes the state machine
testable: the engine takes a plain `MouseInput` and *emits* action requests rather than
performing them.

## Tests

```bash
swift run MouseEnhancerChecks    # 35 checks, no Xcode needed
```

Covers pass-through and suppression, per-binding timing overrides, swipe direction and
saturation, Dock action defaults and persistence, shadowed-binding detection, and
settings round-trips including clamping of hostile values. Timing is injected, so nothing
sleeps.

There is also an XCTest suite in `Tests/`, but **XCTest ships with Xcode** — on a machine
with only the Command Line Tools it cannot run at all. `MouseEnhancerChecks` exists so the
repository doesn't imply coverage it can't deliver.

What tests cannot cover is the Accessibility layer, which needs a trusted, bundled process.
That's what the **Debug** tab is for: trust, whether the tap is actually installed,
positional hit-testing, Dock tile readability, and competing event taps, checked from
inside the running app. Start with **"Event tap installed"** — trust reading as granted is
not sufficient, and that combination is exactly how a completely inert app looks healthy.

The **Button Tester** on the same tab sits ahead of the engine, so it sees buttons no
binding claims, and reports the raw `CGEvent` number — "Button 4" is button number 3, which
is the kind of off-by-one that makes a binding look broken.

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
- **Log messages are `@autoclosure`**, so recording off costs one boolean.
- **The Dock check rejects geometrically first**, instead of ~80 AX round trips on every
  middle click.
- **Dock icons are loaded once**, not rebuilt per SwiftUI redraw.

Idle: **13 MB**, 0.0% CPU, 4 threads. Around 33 MB with the settings window open — SwiftUI
is the cost, it loads lazily on first open, and the window is released on close. No timer
runs while idle except a 5-second permission health check.

Threading: the tap callback only decides and returns. Actions run on a serial background
queue — not the main thread, because an unresponsive target app can block an Accessibility
call for hundreds of milliseconds and would otherwise freeze the settings window.

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
13. **Buttons 4 and 5 default to themselves**, not to `⌘[` / `⌘]`.

## Known gaps

- **Space switching is queued, not instant.** macOS drops a switch that arrives
  mid-animation, so repeats are spaced out to land instead of vanishing. Turning on Reduce
  Motion is the only thing that shortens the animation itself.
- **App Exposé is binary, not continuous**, for the reason described under Swipes.
- **Leftward swipes don't cycle apps inside Exposé.** They work for spaces; the in-Exposé
  case remains unexplained.
- **`shadowedBindingIDs` is O(n²)** and recomputed per redraw of the Bindings list. At
  realistic counts this is microseconds and it never touches the event path.
- **No update mechanism.** Version is visible under General → About; there's no check for
  new builds.
