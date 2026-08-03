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
do {
    // The exponential approach must arrive, and must not overshoot on the way.
    var pending = 100.0
    var delivered = 0.0
    var frames = 0
    var everOvershot = false
    while pending != 0, frames < 1000 {
        let taken = SmoothScroller.step(pending: &pending, dt: 1.0 / 120, settleSec: 0.22)
        if taken <= 0 || taken > 100 { everOvershot = true }
        delivered += taken
        frames += 1
    }
    check("every step stays within the outstanding travel", !everOvershot)
    check("every pixel is eventually delivered", abs(delivered - 100) < 0.0001)
    check("it lands rather than approaching forever", frames < 200)

    // "Settles in `settleSec`" has to mean something measurable.
    var quick = 100.0
    for _ in 0..<Int(0.22 * 120) { _ = SmoothScroller.step(pending: &quick, dt: 1.0 / 120, settleSec: 0.22) }
    check("98% is delivered by the settle time", quick < 2)
}
do {
    // A frame that arrives late must not dump the whole remaining distance at once.
    var pending = 100.0
    let taken = SmoothScroller.step(pending: &pending, dt: 10.0, settleSec: 0.22)
    check("a huge dt still cannot exceed what is owed", taken <= 100.0001)
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
    check("so are gesture phases and the coast",
          prefs.scrollGesturePhases && prefs.scrollMomentum)

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
    // The menu is the only route to these, which is the reason WindowTiler presses menu
    // items rather than posting the shortcut. If Apple ever ships keys for them this
    // check fails, which is the right moment to reconsider that.
    let keyless = Set(WindowTile.allCases.filter { $0.shortcut == nil }.map(\.rawValue))
    check("the quarters and restore have no macOS shortcut",
          keyless == ["topLeft", "topRight", "bottomLeft", "bottomRight", "restore"])

    let halves = [WindowTile.left, .right, .top, .bottom]
    check("each half maps to its own arrow key",
          Set(halves.compactMap { $0.shortcut?.key }) == [0x7B, 0x7C, 0x7D, 0x7E])
    check("and every shortcut carries Control",
          WindowTile.allCases.compactMap(\.shortcut).allSatisfy { $0.modifiers == .control })

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
