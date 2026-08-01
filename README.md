# Mouse Enhancer

A macOS menu-bar agent that rebinds extra mouse buttons and gestures via a global
`CGEventTap`, configured from a SwiftUI settings window. Changes apply live — the tap
is attached once at launch and reads preferences on every event, so nothing needs
restarting or re-attaching.

## Build

```bash
./build.sh          # release -> ./MouseEnhancer.app
./build.sh debug    # debug build
open MouseEnhancer.app
```

No Xcode project required — it's a Swift package assembled into a bundle by `build.sh`,
which also applies an ad-hoc code signature. Requires macOS 14+.

## First run

The app has no Dock icon (`LSUIElement`). It appears as a cursor icon in the menu bar —
slashed and dimmed when bindings aren't live, solid when they are.

It needs **Accessibility** access (System Settings → Privacy & Security → Accessibility).
On first launch it triggers the system prompt and opens Settings. The event tap starts
automatically the moment permission is granted, and if access is later revoked the app
notices and returns to waiting rather than silently dying.

## Bindings

A binding is **button + exact modifier combination + trigger → action**. Any button from
2–15, any combination of ⌃⌥⇧⌘, and any of these triggers:

| Trigger | Notes |
|---|---|
| Click | |
| Double Click | Only buttons with a double-click binding delay their single click |
| Press & Hold | Delay is configurable |
| Drag Up / Down / Left / Right | Dominant axis decides direction |
| Chord | Held together with a second button, in either order |

Modifier matching is **exact**: ⌘+Button 4 does not also fire the plain Button 4 binding.
A button+modifier combination with no binding passes straight through, so the OS default
(browser back/forward) keeps working.

Actions: **native mouse button**, navigation, Mission Control, App Exposé, Show Desktop,
Launchpad, space left/right, close/minimize/quit under the cursor, play-pause,
next/previous track, volume up/down/mute, screenshot (full and selection),
**custom keystroke** (recorded by pressing it), **launch application**, and
**run Shortcut**.

**Native mouse button** is the "leave it alone" action, and it's what buttons 4 and 5
are bound to by default. macOS already maps them to back/forward system-wide, and apps
that read the buttons directly (browsers, editors, games) do their own thing with them —
a `⌘[` translation only ever reproduced a subset of that. The picker also lets one button
send another's number, so button 5 can be made to act as button 4.

When the only rule on a button is a native click, the press is never suppressed at all:
the real event reaches the OS untouched, with no added latency and authentic click state.
It's only re-posted synthetically when the same button also carries a hold, drag,
double-click or chord binding, which forces the press to be claimed to disambiguate.

Plus middle-clicking a Dock tile to open a second instance of that app.

## Safety

Destructive actions are opt-in dangerous:

- **On-screen feedback** (default on) — a brief HUD naming what fired, so a mis-click is
  attributable. Closing a window has no undo.
- **Ignore the empty desktop** (default on) — a stray click on bare desktop won't reach
  through to whatever is behind it.
- **Per-binding confirmation** — Close Window and Quit App each offer a Confirm checkbox.
- **Exclusions** — apps listed there see their mouse completely untouched. Games,
  remote-desktop clients and drawing apps use these buttons natively.

## Layout

All behaviour lives in the `MouseEnhancerCore` library so it can be unit tested;
`Sources/MouseEnhancer/main.swift` is a nine-line shim.

| File | Role |
|---|---|
| `Model/Modifiers.swift` | `ModifierSet` — the four real modifiers, codable |
| `Model/Keystroke.swift` | Recorded shortcut + key-code names |
| `Model/Actions.swift` | `ActionKind` / `ActionSpec` and their payloads |
| `Model/ActionBinding.swift` | `TriggerKind`, `ActionBinding`, seeded defaults |
| `GestureEngine.swift` | Pure decision logic: suppress? which action? (no `CGEvent`) |
| `EventTapManager.swift` | Tap plumbing, permission recovery, state reporting |
| `ActionDispatcher.swift` | Action → synthetic event / Accessibility call |
| `AccessibilityBridge.swift` | Crash-safe wrappers over the `AXUIElement` C API |
| `UserPreferences.swift` | Storage plus the hot-path lookup index |
| `Services/` | Login item, frontmost-app cache, event log, feedback HUD |
| `UI/` | Binding row, keystroke recorder, exclusions, diagnostics |

The split between `GestureEngine` and `EventTapManager` is what makes the state machine
testable: the engine takes a plain `MouseInput` struct and *emits* action requests rather
than performing them.

## Tests

```bash
swift test
```

53 tests, ~0.07s. They cover exact-modifier matching, modifier latching at press time,
all four drag directions and dominant-axis resolution, hold, double-click timing in both
directions, chording in either order, per-app exclusions, suppression pairing, the
binding lookup index invalidating on change, and persistence round-trips. Timing is
injected (`HoldTiming` with a test clock), so nothing sleeps.

What tests *cannot* cover is the Accessibility layer, which needs a trusted, bundled
process. That's what the **Diagnostics** tab is for — trust, **whether the event tap is
actually installed**, positional hit-testing, the window-list fallback, Dock tile
readability, and competing event taps, checked from inside the running app.

Start with **"Event tap installed"**. Trust reading as granted is not sufficient —
`tapCreate` can still have failed, and in that state the app looks perfectly healthy
while every binding silently does nothing. If that check fails, no other check matters. The **event log** on that tab records every mouse event with the
decision made, which is the fastest way to answer "why didn't my binding fire?"

## Performance

Measured with a 1.1M-event harness (50k drag gestures of 22 events each):

| | ns/event |
|---|---|
| Before optimization | 864 |
| After | ~200 |

What changed:

- **Preference scalars are cached in memory.** `dragThresholdPx` was read through
  `UserDefaults` on *every* drag event — a CFPreferences lookup and dynamic cast in the
  hot path.
- **Binding lookup is a dictionary**, keyed by `(button, modifiers, trigger)` packed into
  one `Int`, rebuilt only when bindings change. It was a predicate scan over the whole
  list, several times per gesture.
- **Log messages are `@autoclosure`.** The call sites interpolate strings; without it
  every event built and discarded a description even with recording off.
- **One window-server snapshot per window action** instead of two.
- **The Dock check rejects geometrically first.** It ran ~80 AX round trips on every
  middle click — including middle-clicking links in a browser. Now a pure-math test
  rules out the common case.
- **The action picker's grouping is precomputed** rather than re-filtered per row per
  redraw.

Memory: 33 MB physical footprint with the settings window open. The window is released
when closed — a background agent spends nearly all its life with no UI. `leaks` reports
nothing from application code (416 bytes of AppKit `NSDisplayLink`/`CGRegion` internals).

Threading: the tap callback only decides and returns. Actions run on a serial background
queue — not the main thread, because an unresponsive target app can block an
Accessibility call for hundreds of milliseconds and would otherwise freeze the settings
window and status menu.

## Notable deviations from the original spec

These are behavioural fixes, not restyling:

1. **`@AppStorage` on an `ObservableObject` does not publish.** It only drives redraws
   inside a `View`; on a class it silently fails, so the UI would not refresh and the
   tap would read stale values. Replaced with `UserDefaults`-backed properties that
   publish explicitly.
2. **Accessibility hit-testing uses `event.location`, not `unflippedLocation`.**
   `AXUIElementCopyElementAtPosition` expects top-left-origin global coordinates; the
   unflipped (bottom-left) point targets the wrong window on any non-centered click.
3. **No force-casts on AX attribute values.** `parent as! AXUIElement` traps whenever an
   attribute exists but holds another type. The bridge checks `CFGetTypeID` and returns
   `nil`. The parent walk is depth-bounded so a cyclic hierarchy can't hang the tap.
4. **Actions take a `CGPoint`, not the `CGEvent`.** The hold gesture fires on a timer
   long after the tap callback returned; retaining the event past its callback isn't
   guaranteed valid.
5. **Tap re-arming is verified.** macOS disables a tap that blocks too long; the callback
   re-enables it and then *checks*, because blindly re-enabling spins forever against a
   permission that no longer exists.
6. **Permission-aware startup and recovery.** `tapCreate` returns `nil` without trust, so
   the manager polls and attaches when it lands — and a health check notices revocation.
7. **Synthetic events are tagged** (`eventSourceUserData`) and skipped by our own tap.
8. **`.cgSessionEventTap` instead of `.cghidEventTap`** — the session tap is the correct
   attachment point for a filter that suppresses events.
9. **Dock app resolution rewritten.** `urlsForApplications(toOpen: URL(fileURLWithPath: "/"))`
   returns handlers for a *directory*, which won't contain the clicked app.
10. **Dock detection does not use positional hit-testing.** Measured on macOS 26.3:
    `AXUIElementCopyElementAtPosition` over a Dock tile returns `kAXErrorNotImplemented`
    (-25208), so the spec's `isCursorOverDock` could never return true. The Dock's
    `AXDockItem` children *do* report usable frames, so the click point is matched
    against those — verified resolving 26/26 tiles from their own centre points. (A
    geometric shortcut isn't available either: the Dock's tile strip no longer appears in
    `CGWindowList`, only its wallpaper windows.)
11. **Middle clicks are never suppressed.** Deciding "is this the Dock?" needs a blocking
    AX call that must not run inside the tap callback, and suppression buys nothing —
    the Dock has no default middle-click behaviour to override.
12. **Closing a window is layered.** Hit-test → window server lookup + AX frame match →
    the app's focused window (only if the click landed inside it).
13. **The close chord is no longer a special case.** ⌃⌥⌘+middle-click is just a seeded
    default binding in the general model, which removed an entire branch of the engine.
14. **Deployment target macOS 14**, not 12 — `ContentUnavailableView` and the modern
    `Section`/`Toggle` styles used in the UI.
15. **Launchpad no longer exists.** macOS 26 removed it: there is no
    `/System/Applications/Launchpad.app` and `com.apple.launchpad.launcher` no longer
    resolves, so the original "open the app bundle" implementation could not succeed on
    a current system. The action now opens the Apps view that replaced it (fn+A),
    falling back to the bundle when it is present on older releases.
16. **Buttons 4 and 5 default to themselves**, not to `⌘[` / `⌘]` — see Bindings above.

### Bugs found by testing

- **Double-fire on a rebound close chord.** With the chord bound to button 5, the chord
  consumed the mouse-down and the mouse-up then fell through to the gesture machine as a
  click — two actions from one press. Caught by `testCloseChordDoesNotLeakIntoButton5Gesture`
  in the pre-refactor suite; the general model now tracks whether the gesture machine
  actually claimed the press.

## Known gaps

- **Ad-hoc signing invalidates Accessibility on every rebuild.** Verified: a
  one-character code change moves the cdhash, and rebuilding identical source can produce
  a third hash. TCC identifies an ad-hoc app by cdhash, so after a rebuild macOS treats it
  as a different binary — the checkbox stays ticked while nothing works.

  This is the single most likely reason a build appears completely dead. `build.sh` now
  prints the remedy after an ad-hoc build:

  ```bash
  tccutil reset Accessibility com.mouseenhancer.MouseEnhancer
  ```

  To stop it recurring, create a self-signed **Code Signing** certificate in Keychain
  Access and build with `MOUSE_ENHANCER_IDENTITY="Mouse Enhancer Dev" ./build.sh`. The
  cdhash then stays stable across rebuilds and the grant sticks.
- `.build/` is ~300 MB and this directory lives in iCloud Drive; consider moving the
  project out of `Mobile Documents`, and putting it under git with `.build/` ignored.
- **Mac Mouse Fix Helper** and **BetterTouchTool** are both running here with active taps
  on `otherMouseDown`/`otherMouseUp`. Whichever tap sits closer to the head of the chain
  sees each event first. The Diagnostics tab reports this under "Competing event taps".
