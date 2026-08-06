import CoreGraphics
import Foundation
import MacHancerCore

// Checks that run without Xcode.
//
// The XCTest suite in Tests/ cannot run on a machine with only the Command Line Tools
// installed — XCTest ships with Xcode — which meant this project had a test directory
// that never executed and implied coverage it wasn't providing. This is a plain
// executable: `swift run MacHancerChecks`, exit 0 on success.
//
// It covers the pure decision logic only. Anything needing a trusted, bundled process
// (Accessibility, the event tap, dock swipes) is deliberately out of scope and is
// diagnosed with the file log instead: `defaults write com.machancer.MacHancer debugLog -bool YES`.

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
var checks = 0

func check(_ name: String, _ passed: Bool) {
    checks += 1
    if passed {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name)")
        failures += 1
    }
}

func section(_ title: String) { print("\n— \(title) —") }

// MARK: - Harness

final class ManualTiming: HoldTiming {
    private(set) var delays: [TimeInterval] = []
    private var pending: [(Int, () -> Void)] = []
    private var nextID = 0
    var currentTime: TimeInterval = 1000
    var now: TimeInterval { currentTime }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> HoldToken {
        nextID += 1
        delays.append(delay)
        pending.append((nextID, work))
        return Token(owner: self, id: nextID)
    }

    func fireAll() {
        let due = pending
        pending.removeAll()
        for item in due { item.1() }
    }

    struct Token: HoldToken {
        let owner: ManualTiming
        let id: Int
        func cancel() { owner.pending.removeAll { $0.0 == id } }
    }
}

final class Recorder {
    var kinds: [ActionKind] = []
    var bindings: [ActionBinding] = []
    var swipeBegins: [DockSwipeSimulator.Axis] = []
    var swipeTargets: [Double] = []
    var swipeEnds: [Double] = []
}

func makePrefs(_ bindings: [ActionBinding] = []) -> UserPreferences {
    let name = UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let prefs = UserPreferences(defaults: defaults)
    prefs.bindings = bindings
    return prefs
}

func makeEngine(
    _ prefs: UserPreferences,
    timing: ManualTiming = ManualTiming(),
    app: @escaping () -> String? = { "com.example.test" }
) -> (GestureEngine, Recorder) {
    let recorder = Recorder()
    let engine = GestureEngine(prefs: prefs, timing: timing, frontmostBundleID: app)
    engine.onAction = { request in
        switch request {
        case let .run(binding, _):
            recorder.kinds.append(binding.action.kind)
            recorder.bindings.append(binding)
        case let .swipeBegin(axis):     recorder.swipeBegins.append(axis)
        case let .swipeUpdate(target):  recorder.swipeTargets.append(target)
        case let .swipeEnd(velocity):   recorder.swipeEnds.append(velocity)
        case .dockMiddleClick:          break
        }
    }
    return (engine, recorder)
}

func down(_ b: Int, _ m: ModifierSet = []) -> MouseInput {
    MouseInput(phase: .down, button: b, location: .zero, modifiers: m)
}
func drag(_ b: Int, _ x: Double, _ y: Double) -> MouseInput {
    MouseInput(phase: .dragged, button: b, location: CGPoint(x: x, y: y))
}
func up(_ b: Int) -> MouseInput { MouseInput(phase: .up, button: b, location: .zero) }

enum SmoothScrollerDirectionProbe {
    static func horizontal(_ p: Double) -> ActionKind? {
        GestureEngine.measuredSwipeAction(axis: .horizontal, progress: p)
    }
    static func vertical(_ p: Double) -> ActionKind? {
        GestureEngine.measuredSwipeAction(axis: .vertical, progress: p)
    }
}

let B4 = MouseButton.button4
let B5 = MouseButton.button5

// MARK: - Native pass-through

section("native button pass-through")
do {
    let prefs = makePrefs([ActionBinding(button: B4, action: ActionSpec(kind: .mouseButton))])
    let (engine, rec) = makeEngine(prefs)
    check("plain native click is not suppressed", engine.handle(down(B4)) == false)
    check("nothing dispatched; the real event does the work", rec.kinds.isEmpty)
}
do {
    let prefs = makePrefs([
        ActionBinding(button: B5, trigger: .click, action: ActionSpec(kind: .mouseButton)),
        ActionBinding(button: B5, trigger: .hold, action: ActionSpec(kind: .appExpose)),
    ])
    let (engine, rec) = makeEngine(prefs)
    check("claimed when a hold shares the button", engine.handle(down(B5)) == true)
    _ = engine.handle(up(B5))
    check("re-posted synthetically", rec.kinds == [.mouseButton])
}
do {
    // The claimed press must come back even with no click rule to bring it back.
    // A hold alone still suppresses the press, and browser back/forward lived there.
    let prefs = makePrefs([ActionBinding(button: B5, trigger: .hold, action: ActionSpec(kind: .appExpose))])
    let (engine, rec) = makeEngine(prefs)
    check("a hold alone still claims the press", engine.handle(down(B5)) == true)
    _ = engine.handle(up(B5))
    check("a plain click is replayed rather than eaten", rec.kinds == [.mouseButton])
}
do {
    // Same for a drag-only button — the shipped default for button 5.
    let prefs = makePrefs([
        ActionBinding(button: B5, trigger: .dragLeft, action: ActionSpec(kind: .spaceRight)),
    ])
    let (e1, r1) = makeEngine(prefs)
    _ = e1.handle(down(B5)); _ = e1.handle(up(B5))
    check("a drag-only button still clicks", r1.kinds == [.mouseButton])

    // ...but a click that became a drag must not also fire the click.
    let (e2, r2) = makeEngine(prefs)
    _ = e2.handle(down(B5)); _ = e2.handle(drag(B5, -60, 0)); _ = e2.handle(up(B5))
    check("a drag does not also replay a click", r2.kinds == [.spaceRight])
}
do {
    // The shipped defaults, end to end: this is the exact case that broke.
    let prefs = makePrefs(ActionBinding.defaults)

    let (e5, r5) = makeEngine(prefs)
    _ = e5.handle(down(B5)); _ = e5.handle(up(B5))
    check("button 5 clicks natively with the shipped defaults", r5.kinds == [.mouseButton])

    let (e4, r4) = makeEngine(prefs)
    check("button 4 is untouched outside Safari", e4.handle(down(B4)) == false)
    check("and dispatches nothing of its own", r4.kinds.isEmpty)
}
do {
    // ...and inside Safari the same two buttons navigate instead.
    let prefs = makePrefs(ActionBinding.defaults)
    let safari = { "com.apple.Safari" as String? }

    let (e4, r4) = makeEngine(prefs, app: safari)
    check("button 4 is claimed in Safari", e4.handle(down(B4)) == true)
    _ = e4.handle(up(B4))
    check("and goes back", r4.kinds == [.navigateBack])

    let (e5, r5) = makeEngine(prefs, app: safari)
    _ = e5.handle(down(B5)); _ = e5.handle(up(B5))
    check("button 5 goes forward", r5.kinds == [.navigateForward])

    // The scoped click must not cost button 5 its gestures.
    let (e6, r6) = makeEngine(prefs, app: safari)
    _ = e6.handle(down(B5)); _ = e6.handle(drag(B5, 0, -60)); _ = e6.handle(up(B5))
    check("a drag in Safari still reaches Mission Control", r6.kinds == [.missionControl])
}

// MARK: - Per-binding overrides

section("per-binding timing overrides")
do {
    var hold = ActionBinding(button: B5, trigger: .hold, action: ActionSpec(kind: .appExpose))
    hold.holdDelay = 0.9
    let prefs = makePrefs([hold])
    prefs.holdThresholdSec = 0.35
    let timing = ManualTiming()
    let (engine, rec) = makeEngine(prefs, timing: timing)
    _ = engine.handle(down(B5))
    check("uses the binding's delay, not the global", timing.delays == [0.9])
    timing.fireAll()
    check("hold fires", rec.kinds == [.appExpose])
}
do {
    var upB = ActionBinding(button: B5, trigger: .dragUp, action: ActionSpec(kind: .missionControl))
    upB.dragDistance = 50
    var downB = ActionBinding(button: B5, trigger: .dragDown, action: ActionSpec(kind: .appExpose))
    downB.dragDistance = 8
    let prefs = makePrefs([upB, downB])
    prefs.dragThresholdPx = 15

    let (e1, r1) = makeEngine(prefs)
    _ = e1.handle(down(B5)); _ = e1.handle(drag(B5, 0, 12))
    check("drag down fires at its own 8px threshold", r1.kinds == [.appExpose])

    let (e2, r2) = makeEngine(prefs)
    _ = e2.handle(down(B5)); _ = e2.handle(drag(B5, 0, -20))
    check("drag up does not fire below its own 50px", r2.kinds.isEmpty)
    _ = e2.handle(drag(B5, 0, -60))
    check("drag up fires past it", r2.kinds == [.missionControl])
}

// MARK: - Swipe

section("hold & swipe")
do {
    let prefs = makePrefs([ActionBinding(button: B5, trigger: .swipe, action: .none)])
    prefs.swipeDistanceXPx = 100
    prefs.swipeDistanceYPx = 100

    let (e1, r1) = makeEngine(prefs)
    _ = e1.handle(down(B5)); _ = e1.handle(drag(B5, -60, 0))
    check("leftward renders natively", r1.swipeBegins == [.horizontal])
    check("leftward progress is positive", (r1.swipeTargets.last ?? 0) > 0)

    let (e2, r2) = makeEngine(prefs)
    _ = e2.handle(down(B5)); _ = e2.handle(drag(B5, 0, 60))
    check("downward drives no visual", r2.swipeBegins.isEmpty && r2.swipeTargets.isEmpty)
    _ = e2.handle(up(B5))
    check("downward fires App Exposé instead", r2.kinds == [.appExpose])

    let (e3, r3) = makeEngine(prefs)
    _ = e3.handle(down(B5)); _ = e3.handle(drag(B5, -600, 0))
    check("progress saturates at 1.0", abs((r3.swipeTargets.last ?? 0) - 1.0) < 0.0001)

    let (e4, r4) = makeEngine(prefs)
    _ = e4.handle(down(B5)); _ = e4.handle(drag(B5, 0, -50)); _ = e4.handle(drag(B5, 0, 300))
    check("a swipe never crosses zero into the opposite gesture",
          r4.swipeTargets.allSatisfy { $0 <= 0.0001 })
}

// MARK: - Smooth scrolling

section("smooth scrolling")
// The reference for all of these is a capture of Mos's live output: 389 events, 44
// bursts. Signature: a small opening event, deltas that rise, and a dead stop on the
// largest delta — zero tail in every burst.
do {
    // One notch, walked at the 100Hz frame rate with the deadline receding as it would.
    var pending = 91.0, velocity = 0.0
    var deltas: [Double] = []
    var t = 0.0
    let settle = 0.09
    while pending != 0, deltas.count < 100 {
        t += 0.01
        let taken = SmoothScroller.advance(pending: &pending, velocity: &velocity,
                                           dt: 0.01, remaining: settle - t, settleSec: settle)
        deltas.append(taken)
    }
    check("every pixel is delivered", abs(deltas.reduce(0,+) - 91) < 0.0001)
    check("it finishes by the deadline", deltas.count <= Int(settle / 0.01) + 1)
    check("the opening event is small, like Mos's 1px kick",
          deltas.first! < deltas.max()! * 0.4)
    check("deltas rise to the end — the burst stops at peak, no tail",
          deltas.max()! == deltas.last!)
    check("no frame moves backwards", deltas.allSatisfy { $0 >= 0 })
}
do {
    // A spin faster than the deadline merges bursts: each notch re-arms the deadline
    // before the previous travel lands, so the output plateaus at the input rate
    // instead of pulsing per notch. (Slower than the deadline, each notch is its own
    // crisp eased hop — which is also what Mos does.)
    var pending = 0.0, velocity = 0.0
    var lastNotch = 0
    var steps: [Double] = []
    for frame in 0..<200 {
        if frame % 5 == 0 { SmoothScroller.add(91, to: &pending); lastNotch = frame }  // 20 notches/s
        let remaining = 0.09 - Double(frame - lastNotch) * 0.01
        let taken = SmoothScroller.advance(pending: &pending, velocity: &velocity,
                                           dt: 0.01, remaining: remaining, settleSec: 0.09)
        if frame > 60 { steps.append(taken) }
    }
    let mean = steps.reduce(0,+) / Double(steps.count)
    check("a fast spin merges into one steady glide",
          (steps.max()! - steps.min()!) / mean < 0.6)
    check("at roughly the input rate", abs(mean - 91.0 / 5) < 4)
}
do {
    // A stalled frame past the deadline lands everything at once — the hard stop —
    // and never more than is owed.
    var pending = 91.0, velocity = 0.0
    let taken = SmoothScroller.advance(pending: &pending, velocity: &velocity,
                                       dt: 10.0, remaining: -5, settleSec: 0.09)
    check("a huge dt still cannot exceed what is owed", taken == 91 && pending == 0)
}
do {
    var pending = 0.0
    SmoothScroller.add(90, to: &pending)
    SmoothScroller.add(90, to: &pending)
    check("notches in the same direction accumulate", abs(pending - 180) < 0.0001)
    SmoothScroller.add(-90, to: &pending)
    check("a reversal cancels rather than nets", abs(pending - -90) < 0.0001)
}
do {
    check("acceleration is off at strength 0",
          SmoothScroller.accelerationFactor(interval: 0.01, strength: 0) == 1)
    check("a first notch has no interval to measure",
          SmoothScroller.accelerationFactor(interval: .infinity, strength: 1) == 1)
    check("unhurried notches are not accelerated",
          SmoothScroller.accelerationFactor(interval: 0.5, strength: 1) == 1)
    check("a fast spin is",
          SmoothScroller.accelerationFactor(interval: 0.02, strength: 1) > 2.9)
    check("strength scales it",
          SmoothScroller.accelerationFactor(interval: 0.02, strength: 0.5)
              < SmoothScroller.accelerationFactor(interval: 0.02, strength: 1.0))
}
do {
    // A hand-edited file must not be able to install a setting that stops scrolling.
    let hostile = "{\"scrollStepPx\":0,\"scrollSmoothingSec\":99,\"scrollAcceleration\":-5}"
    let prefs = makePrefs()
    prefs.importSettings(try! SettingsBundle.decoded(from: Data(hostile.utf8)))
    check("a zero step is clamped", prefs.scrollStepPx >= 10)
    check("an endless glide is clamped", prefs.scrollSmoothingSec <= 0.60)
    check("negative acceleration is clamped", prefs.scrollAcceleration >= 0)
}
do {
    let prefs = makePrefs()
    prefs.smoothScrollEnabled = false
    prefs.scrollStepPx = 150
    prefs.scrollMomentum = false
    prefs.smoothScrollScope = AppScope(mode: .exceptIn, bundleIDs: ["com.example.game"])

    let restored = makePrefs()
    restored.importSettings(try! SettingsBundle.decoded(from: try! prefs.exportSettings().encoded()))
    check("the scroll switch survives export", restored.smoothScrollEnabled == false)
    check("scroll tuning survives export", abs(restored.scrollStepPx - 150) < 0.0001)
    check("the coast switch survives export", restored.scrollMomentum == false)
    check("the scroll scope survives export",
          !restored.smoothScrollScope.allows("com.example.game"))
}
do {
    // An export predating the coast setting must leave it alone, not silently disable it.
    let old = "{\"format\":1,\"smoothScrollEnabled\":true}"
    let prefs = makePrefs()
    prefs.importSettings(try! SettingsBundle.decoded(from: Data(old.utf8)))
    check("an export predating the coast leaves it on", prefs.scrollMomentum)
}

// MARK: - Defaults

section("factory defaults")
do {
    let prefs = makePrefs()
    prefs.resetToDefaults()
    check("the HUD is off out of the box", prefs.showActionFeedback == false)
    check("smooth scrolling is on out of the box", prefs.smoothScrollEnabled)
    // Mos's shape is the default: line events, no gesture phases. Measured off its
    // live stream, not assumed.
    check("line events are the default emission shape", prefs.scrollGesturePhases == false)

    // Button 4's only rule is Safari-scoped, so everywhere else its press is never
    // suppressed — which is what keeps apps that read the button directly working.
    check("button 4's only rule is scoped to Safari",
          ActionBinding.defaults.filter { $0.button == B4 }
              .allSatisfy { $0.effectiveScope.bundleIDs == ["com.apple.Safari"] })
    check("button 4 passes through outside Safari",
          !prefs.hasBinding(button: B4, modifiers: []))
    check("and is bound inside it",
          prefs.hasBinding(button: B4, modifiers: [], app: "com.apple.Safari"))
    check("a plain button 5 click has no unscoped rule",
          prefs.binding(button: B5, modifiers: [], trigger: .click) == nil)

    let triggers = Set(ActionBinding.defaults.filter { $0.button == B5 }.map(\.trigger))
    check("button 5 carries hold, all four drags and a scoped click",
          triggers == [.click, .hold, .dragUp, .dragDown, .dragLeft, .dragRight])
    check("dragging left goes to the space on the right",
          prefs.binding(button: B5, modifiers: [], trigger: .dragLeft)?.action.kind == .spaceRight)
    check("dragging right goes to the space on the left",
          prefs.binding(button: B5, modifiers: [], trigger: .dragRight)?.action.kind == .spaceLeft)
    check("close window keeps its ⌃⌥⌘ middle click",
          prefs.binding(button: MouseButton.middle, modifiers: [.control, .option, .command],
                        trigger: .click)?.action.kind == .closeWindow)
    check("no default rule shadows another", prefs.shadowedBindingIDs.isEmpty)
}

// MARK: - Window tiling

section("window tiling")
do {
    // Two enums that have to stay in step: an ActionKind with no WindowTile is an
    // action that silently does nothing, and a WindowTile no kind maps to is a
    // position the user can never reach.
    let positionKinds = ActionKind.allCases.filter { WindowTile($0) != nil }
    check("every tiling position is offered as an action",
          positionKinds.count == WindowTile.allCases.count)
    check("and no two map to the same one",
          Set(positionKinds.compactMap { WindowTile($0)?.rawValue }).count == WindowTile.allCases.count)

    // The group carries one action that is *not* a position: Restore-or-Minimize picks
    // between two behaviours at run time. Stated rather than tolerated, so a future
    // addition that forgets its WindowTile still fails this.
    let tilingKinds = ActionKind.allCases.filter { $0.group == "Tiling" }
    check("the Tiling group is those positions plus the combined action",
          Set(tilingKinds) == Set(positionKinds).union([.tileRestoreOrMinimize]))
    check("nothing outside the group maps to a position",
          ActionKind.allCases.filter { $0.group != "Tiling" }.allSatisfy { WindowTile($0) == nil })

    check("the Tiling group is in the picker's order",
          ActionKind.groupOrder.contains("Tiling"))
    check("and the picker actually lists all of them",
          ActionKind.grouped.first { $0.group == "Tiling" }?.kinds.count == tilingKinds.count)

    check("tiling needs no configuring before it runs",
          tilingKinds.allSatisfy { !$0.requiresPayload })
    check("and is available inside a macro",
          tilingKinds.allSatisfy { ActionKind.macroInvocable.contains($0) })
}
do {
    // The menu is the only route, and this is why: read off a real menu with
    // AXMenuItemCmdChar, only Center carries a key equivalent at all. A keystroke
    // implementation would have covered one position in eleven — and for the halves it
    // would have collided with space switching and beeped.
    check("only Center has a system shortcut",
          WindowTile.allCases.filter(\.hasSystemShortcut) == [.center])

    check("every position names a menu item",
          WindowTile.allCases.allSatisfy { !$0.menuTitle.isEmpty })
    check("and no two name the same one",
          Set(WindowTile.allCases.map(\.menuTitle)).count == WindowTile.allCases.count)
}

// MARK: - Dock actions

section("dock actions")
do {
    check("default is New Window", DockAction.fallback == .newWindow)
    check("New Window is ⌘N", DockAction.newWindow.keystroke?.keyCode == 0x2D)

    var map = DockActionMap()
    check("unknown app gets the default", map.action(for: "com.a") == .newWindow)
    map.set(.newTab, for: "com.a")
    check("override is stored", map.action(for: "com.a") == .newTab)
    map.set(.newWindow, for: "com.a")
    check("returning to default drops the entry", map.customizedCount == 0)
}

// MARK: - Conflicts

section("shadowed bindings")
do {
    let first = ActionBinding(button: B4, action: ActionSpec(kind: .navigateBack))
    let second = ActionBinding(button: B4, action: ActionSpec(kind: .missionControl))
    let prefs = makePrefs([first, second])
    let shadowed = prefs.shadowedBindingIDs
    check("the later duplicate is flagged", shadowed.contains(second.id))
    check("the first is not", !shadowed.contains(first.id))
}
do {
    // A global rule shadows a scoped one; the reverse is a normal, useful pair.
    let global = ActionBinding(button: B4, action: ActionSpec(kind: .navigateBack))
    var scoped = ActionBinding(button: B4, action: ActionSpec(kind: .missionControl))
    scoped.scope = AppScope(mode: .onlyIn, bundleIDs: ["com.apple.Safari"])

    check("global above scoped shadows it",
          makePrefs([global, scoped]).shadowedBindingIDs.contains(scoped.id))
    check("scoped above global does not",
          makePrefs([scoped, global]).shadowedBindingIDs.isEmpty)
}
do {
    let a = ActionBinding(button: B4, trigger: .click, action: ActionSpec(kind: .navigateBack))
    let b = ActionBinding(button: B4, trigger: .hold, action: ActionSpec(kind: .appExpose))
    check("different triggers on one button never conflict",
          makePrefs([a, b]).shadowedBindingIDs.isEmpty)
}

// MARK: - Settings transfer

section("settings import and export")
do {
    let prefs = makePrefs([ActionBinding(button: B4, action: ActionSpec(kind: .missionControl))])
    prefs.holdThresholdSec = 0.62
    prefs.swipeDistanceXPx = 240
    var dock = prefs.dockActions
    dock.set(.quit, for: "com.example")
    prefs.dockActions = dock

    let data = try! prefs.exportSettings().encoded()
    let restored = makePrefs()
    restored.importSettings(try! SettingsBundle.decoded(from: data))

    check("bindings survive", restored.bindings.first?.action.kind == .missionControl)
    check("calibration survives", abs(restored.holdThresholdSec - 0.62) < 0.0001)
    check("swipe sensitivity survives", abs(restored.swipeDistanceXPx - 240) < 0.0001)
    check("dock choices survive", restored.dockAction(for: "com.example") == .quit)
}
do {
    // An export predating a setting must not reset it.
    let partial = "{\"format\":1,\"holdThresholdSec\":0.5}"
    let prefs = makePrefs()
    prefs.swipeDistanceYPx = 300
    prefs.importSettings(try! SettingsBundle.decoded(from: Data(partial.utf8)))
    check("absent fields are left alone", abs(prefs.swipeDistanceYPx - 300) < 0.0001)
    check("present fields are applied", abs(prefs.holdThresholdSec - 0.5) < 0.0001)
}
do {
    // Hand-edited files must not be able to install an unusable value.
    let hostile = "{\"holdThresholdSec\":0,\"swipeDistanceXPx\":99999}"
    let prefs = makePrefs()
    prefs.importSettings(try! SettingsBundle.decoded(from: Data(hostile.utf8)))
    check("a zero hold delay is clamped", prefs.holdThresholdSec >= 0.10)
    check("an absurd sensitivity is clamped", prefs.swipeDistanceXPx <= 600)
}

// MARK: - Persistence

section("persistence")
do {
    let name = UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let writer = UserPreferences(defaults: defaults)
    var binding = ActionBinding(button: B5, trigger: .swipe, action: .none)
    binding.swipeDistanceX = 123
    writer.bindings = [binding]

    let reader = UserPreferences(defaults: defaults)
    check("per-binding overrides persist", reader.bindings.first?.swipeDistanceX == 123)
}
do {
    let legacy = """
    [{"id":"\(UUID().uuidString)","button":3,"modifiers":0,"trigger":"click",
      "action":{"kind":"navigateBack"},"isEnabled":true,"requiresConfirmation":false}]
    """
    let decoded = try? JSONDecoder().decode([ActionBinding].self, from: Data(legacy.utf8))
    check("bindings saved before these fields existed still decode", decoded?.count == 1)
}

// MARK: - Rename migration

section("preferences survive the rename")
do {
    // Renaming the app changed CFBundleIdentifier, and with it the UserDefaults domain.
    // Without migration every binding and calibration value would silently revert.
    let legacyDomain = "com.mouseenhancer.MouseEnhancer"
    let legacy = UserDefaults(suiteName: legacyDomain)!
    legacy.removePersistentDomain(forName: legacyDomain)
    legacy.set(0.77, forKey: "holdThresholdSec")
    legacy.set(try! JSONEncoder().encode(
        [ActionBinding(button: B4, action: ActionSpec(kind: .missionControl))]
    ), forKey: "bindings")

    let freshName = UUID().uuidString
    let fresh = UserDefaults(suiteName: freshName)!
    fresh.removePersistentDomain(forName: freshName)
    let migrated = UserPreferences(defaults: fresh)

    check("calibration carried over", abs(migrated.holdThresholdSec - 0.77) < 0.0001)
    check("bindings carried over", migrated.bindings.first?.action.kind == .missionControl)

    // A domain that already has settings must never be overwritten by the old one.
    let ownName = UUID().uuidString
    let own = UserDefaults(suiteName: ownName)!
    own.removePersistentDomain(forName: ownName)
    let established = UserPreferences(defaults: own)
    established.bindings = [ActionBinding(button: B5, action: ActionSpec(kind: .appExpose))]
    established.holdThresholdSec = 0.20

    let reopened = UserPreferences(defaults: own)
    check("existing settings are not clobbered by the legacy domain",
          abs(reopened.holdThresholdSec - 0.20) < 0.0001)
    check("existing bindings survive", reopened.bindings.first?.action.kind == .appExpose)

    legacy.removePersistentDomain(forName: legacyDomain)
}

// MARK: - Gestures during someone else's drag

section("surviving a window drag")
do {
    // Off unless asked for: the movement belongs to two gestures at once, which is
    // right for carrying a window to the next space and wrong for most other things.
    let plain = ActionBinding(button: B5, trigger: .swipe, action: .none)
    check("off by default", !plain.survivesWindowDrag)

    var opted = plain
    opted.duringWindowDrag = true
    check("on when asked", opted.survivesWindowDrag)

    let prefs = makePrefs([opted])
    check("the index sees it", prefs.survivesWindowDrag(button: B5, modifiers: []))
    check("and not on an unrelated button", !prefs.survivesWindowDrag(button: B4, modifiers: []))
    check("nor on a different modifier combination",
          !prefs.survivesWindowDrag(button: B5, modifiers: .command))
}
do {
    // Old bindings must still decode, and must default to off.
    let legacy = """
    [{"id":"\(UUID().uuidString)","button":4,"modifiers":0,"trigger":"swipe",
      "action":{"kind":"none"},"isEnabled":true,"requiresConfirmation":false}]
    """
    let decoded = try? JSONDecoder().decode([ActionBinding].self, from: Data(legacy.utf8))
    check("bindings saved before this field decode", decoded?.count == 1)
    check("and default to off", decoded?.first?.survivesWindowDrag == false)
}
do {
    // A foreign drag must move a gesture that opted in, and ignore one that didn't.
    var opted = ActionBinding(button: B5, trigger: .dragLeft, action: ActionSpec(kind: .spaceRight))
    opted.duringWindowDrag = true
    opted.dragDistance = 10
    let (e1, r1) = makeEngine(makePrefs([opted]))
    _ = e1.handle(down(B5))
    e1.handleForeignDrag(at: CGPoint(x: -60, y: 0))
    check("a left-drag drives a gesture that opted in", r1.kinds == [.spaceRight])

    var plain = opted
    plain.duringWindowDrag = nil
    let (e2, r2) = makeEngine(makePrefs([plain]))
    _ = e2.handle(down(B5))
    e2.handleForeignDrag(at: CGPoint(x: -60, y: 0))
    check("and does nothing for one that did not", r2.kinds.isEmpty)
}
do {
    // The cheap exit: this runs for every frame of every ordinary window drag.
    let (engine, rec) = makeEngine(makePrefs())
    engine.handleForeignDrag(at: CGPoint(x: 100, y: 100))
    check("with nothing in flight it is a no-op", rec.kinds.isEmpty)
}

// MARK: - Mid-drag delivery

section("mid-drag space switches are unpaced")
do {
    // Pacing waits up to 0.8s for the previous switch to be confirmed, plus a settle
    // gap. A switch that produced no space change — the end of the row, or macOS
    // declining it — leaves that wait armed for the *next* one, so mid drag the
    // keystroke lands after the mouse button is already up.
    var swipe = ActionBinding(button: B5, trigger: .swipe, action: .none)
    swipe.duringWindowDrag = true
    let prefs = makePrefs([swipe])
    prefs.swipeDistanceXPx = 100

    let (engine, rec) = makeEngine(prefs)
    _ = engine.handle(down(B5))
    engine.handleForeignDrag(at: CGPoint(x: -60, y: 0))
    _ = engine.handle(up(B5))

    // Leftward is positive progress, which is the space to the left — the same
    // direction the rendered dock swipe would have gone. Measured and rendered must
    // agree, or the gesture would reverse depending on whether a window happened to be
    // under the cursor.
    check("a mid-drag swipe delivers a discrete space switch", rec.kinds == [.spaceLeft])
    check("marked as mid-drag so pacing is skipped",
          rec.bindings.first?.survivesWindowDrag == true)
}
do {
    // The ordinary case must stay paced: held repeats only land because of it.
    let prefs = makePrefs([ActionBinding(button: B5, trigger: .swipe, action: .none)])
    prefs.swipeDistanceXPx = 100
    let (engine, rec) = makeEngine(prefs)
    _ = engine.handle(down(B5))
    _ = engine.handle(drag(B5, -60, 0))
    _ = engine.handle(up(B5))
    check("a plain swipe renders instead, and is not marked",
          rec.kinds.isEmpty && rec.bindings.isEmpty)
}

// MARK: - Measured swipes

section("measured swipe direction")
do {
    // A swipe driven by another button's drag is delivered as a discrete action,
    // because the window server will not commit a dock swipe underneath a live drag —
    // measured, with a saturated gesture (progress 1.000, velocity 3.20) leaving the
    // space unchanged. Sign convention matches DockSwipeSimulator: negative horizontal
    // progress travels toward the space on the right.
    check("negative horizontal goes right",
          SmoothScrollerDirectionProbe.horizontal(-0.5) == .spaceRight)
    check("positive horizontal goes left",
          SmoothScrollerDirectionProbe.horizontal(0.5) == .spaceLeft)
    check("positive vertical is App Exposé",
          SmoothScrollerDirectionProbe.vertical(0.5) == .appExpose)
    check("negative vertical is Mission Control",
          SmoothScrollerDirectionProbe.vertical(-0.5) == .missionControl)

    // Below the threshold a swipe means nothing, in either direction.
    check("a short swipe commits to nothing",
          SmoothScrollerDirectionProbe.horizontal(0.01) == nil
              && SmoothScrollerDirectionProbe.horizontal(-0.01) == nil)
    check("and an axis-less gesture likewise",
          GestureEngine.measuredSwipeAction(axis: nil, progress: 1) == nil)
}

// MARK: - Scroll axes and modifiers

section("per-axis scrolling and hold keys")
do {
    let prefs = makePrefs()
    check("both axes smooth out of the box", prefs.smoothVertical && prefs.smoothHorizontal)
    check("neither axis is reversed", !prefs.reverseVertical && !prefs.reverseHorizontal)
    // Mos's own assignments, so its muscle memory carries over.
    check("Dash is Option", prefs.scrollBoostModifier == .option)
    check("Toggle is Shift", prefs.scrollToggleModifier == .shift)
    check("Block is Command", prefs.scrollDisableModifier == .command)
    check("the boost factor is sane", prefs.scrollBoostFactor > 1)

    // Distance per notch is Step x Speed, matching Mos's composition and its numbers.
    check("Step x Speed is about 91 points",
          abs(prefs.scrollStepPx * prefs.scrollSpeed - 90.7) < 1)
    // Mos has no rate-based acceleration at all; its Speed is flat and Dash is manual.
    // Automatic acceleration on top is what made fast spinning run away.
    check("no automatic acceleration, as Mos has none", prefs.scrollAcceleration == 0)

    // The axes must be independent — one natural-scrolling switch for both is exactly
    // the macOS limitation this exists to work around.
    prefs.reverseVertical = true
    check("reversing one axis leaves the other alone", !prefs.reverseHorizontal)
    prefs.smoothHorizontal = false
    check("and smoothing is per axis too", prefs.smoothVertical)
}
do {
    // A hand-edited multiplier must not be able to make one notch cross the screen.
    let prefs = makePrefs()
    prefs.scrollBoostFactor = 1000
    check("an absurd boost is clamped", prefs.scrollBoostFactor <= 10)
    prefs.scrollBoostFactor = 0
    check("and it can never shrink a scroll", prefs.scrollBoostFactor >= 1)
}
do {
    let prefs = makePrefs()
    prefs.reverseVertical = true
    prefs.smoothHorizontal = false
    prefs.scrollBoostModifier = .option
    prefs.scrollBoostFactor = 4

    let restored = makePrefs()
    restored.importSettings(try! SettingsBundle.decoded(from: try! prefs.exportSettings().encoded()))
    check("axis settings survive export",
          restored.reverseVertical && !restored.smoothHorizontal)
    check("hold keys survive export", restored.scrollBoostModifier == .option)
    check("the boost factor survives export", abs(restored.scrollBoostFactor - 4) < 0.0001)
}

// MARK: - Diagnostics logging

section("diagnostic log grants")
do {
    let prefs = makePrefs()
    check("logging is off out of the box", prefs.debugLogging == false)
    check("and key names are not being recorded", prefs.isLoggingKeyNames == false)

    prefs.debugLogging = true
    prefs.isLoggingKeyNames = true
    check("granting key names sets a future expiry",
          prefs.keyNamesUntil > Date().timeIntervalSince1970)
    check("of about an hour",
          abs(prefs.keyNamesUntil - (Date().timeIntervalSince1970 + 3600)) < 5)

    // The grant is a deadline, not a flag: an expired one must read as off with no
    // action taken to revoke it. That lapse is the whole safety property.
    prefs.keyNamesUntil = Date().timeIntervalSince1970 - 1
    check("an elapsed grant reads as off", prefs.isLoggingKeyNames == false)

    prefs.isLoggingKeyNames = true
    prefs.debugLogging = false
    check("turning the log off revokes the grant with it",
          prefs.keyNamesUntil == 0 && prefs.isLoggingKeyNames == false)
}
do {
    // A hand-edited file must not be able to install a grant that never ends.
    let prefs = makePrefs()
    prefs.keyNamesUntil = .infinity
    check("a non-finite expiry is rejected", prefs.isLoggingKeyNames == false)
    prefs.keyNamesUntil = -5
    check("a negative expiry is clamped to off", prefs.keyNamesUntil == 0)
}
do {
    // Mouse buttons are never redacted; only keys are.
    let mouse = DebugLog.label(for: MouseButton.button4)
    let key = DebugLog.label(for: MouseButton.keyButton(0x21))
    check("mouse buttons are named in the log", mouse == MouseButton.label(MouseButton.button4))
    check("keys are not, without a grant", key == "⌨ key")
}

// MARK: - Result

print("\n\(checks) checks, \(failures) failure\(failures == 1 ? "" : "s")")
exit(failures == 0 ? 0 : 1)
