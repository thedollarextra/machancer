import CoreGraphics
import Foundation
import MouseEnhancerCore

// Checks that run without Xcode.
//
// The XCTest suite in Tests/ cannot run on a machine with only the Command Line Tools
// installed — XCTest ships with Xcode — which meant this project had a test directory
// that never executed and implied coverage it wasn't providing. This is a plain
// executable: `swift run MouseEnhancerChecks`, exit 0 on success.
//
// It covers the pure decision logic only. Anything needing a trusted, bundled process
// (Accessibility, the event tap, dock swipes) is deliberately out of scope and belongs
// to the in-app Diagnostics tab.

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
    let engine = GestureEngine(prefs: prefs, timing: timing, log: EventLog(), frontmostBundleID: app)
    engine.onAction = { request in
        switch request {
        case let .run(binding, _):      recorder.kinds.append(binding.action.kind)
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

// MARK: - Result

print("\n\(checks) checks, \(failures) failure\(failures == 1 ? "" : "s")")
exit(failures == 0 ? 0 : 1)
