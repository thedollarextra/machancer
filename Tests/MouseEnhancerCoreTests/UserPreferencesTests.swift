import XCTest
import CoreGraphics
@testable import MouseEnhancerCore

final class UserPreferencesTests: XCTestCase {

    private func freshDefaults() -> (UserDefaults, String) {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    func testSeedsDefaultBindingsOnFirstRun() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let prefs = UserPreferences(defaults: defaults)
        XCTAssertEqual(prefs.bindings.count, ActionBinding.defaults.count)
        XCTAssertEqual(prefs.bindings.first?.action.kind, .mouseButton)
    }

    func testDefaultsMatchOriginalSpecBehaviour() {
        let prefs = UserPreferences(defaults: freshDefaults().0)

        // Buttons 4 and 5 stay native by default: the OS already knows what they mean.
        XCTAssertEqual(prefs.binding(button: MouseButton.button4, modifiers: [], trigger: .click)?.action.kind,
                       .mouseButton)
        XCTAssertEqual(prefs.binding(button: MouseButton.button5, modifiers: [], trigger: .click)?.action.kind,
                       .mouseButton)
        XCTAssertEqual(prefs.binding(button: MouseButton.button5, modifiers: [], trigger: .hold)?.action.kind,
                       .appExpose)
        XCTAssertEqual(prefs.binding(button: MouseButton.button5, modifiers: [], trigger: .dragUp)?.action.kind,
                       .missionControl)
        // The spec's ⌃⌥⌘ + middle-click close chord, now an ordinary binding.
        XCTAssertEqual(
            prefs.binding(button: MouseButton.middle,
                          modifiers: [.control, .option, .command],
                          trigger: .click)?.action.kind,
            .closeWindow
        )
        XCTAssertEqual(prefs.holdThresholdSec, 0.35, accuracy: 0.0001)
        XCTAssertEqual(prefs.dragThresholdPx, 15.0, accuracy: 0.0001)
    }

    func testBindingsRoundTripThroughUserDefaults() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let writer = UserPreferences(defaults: defaults)
        writer.bindings = [
            ActionBinding(
                button: MouseButton.button5,
                modifiers: [.command, .shift],
                trigger: .dragLeft,
                action: ActionSpec(kind: .customKeystroke,
                                   keystroke: Keystroke(keyCode: 0x7B, modifiers: [.control]))
            )
        ]

        // A second instance over the same store: proves persistence, not memoization.
        let reader = UserPreferences(defaults: defaults)
        XCTAssertEqual(reader.bindings.count, 1)
        let restored = reader.bindings[0]
        XCTAssertEqual(restored.modifiers, [.command, .shift])
        XCTAssertEqual(restored.trigger, .dragLeft)
        XCTAssertEqual(restored.action.keystroke?.keyCode, 0x7B)
        XCTAssertEqual(restored.action.keystroke?.modifiers, [.control])
    }

    func testScalarPreferencesRoundTrip() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let writer = UserPreferences(defaults: defaults)
        writer.holdThresholdSec = 0.2
        writer.dragThresholdPx = 5
        writer.doubleClickIntervalSec = 0.45
        writer.showActionFeedback = false
        writer.closeIgnoresDesktop = false
        writer.excludedBundleIDs = ["com.example.game"]

        let reader = UserPreferences(defaults: defaults)
        XCTAssertEqual(reader.holdThresholdSec, 0.2, accuracy: 0.0001)
        XCTAssertEqual(reader.dragThresholdPx, 5, accuracy: 0.0001)
        XCTAssertEqual(reader.doubleClickIntervalSec, 0.45, accuracy: 0.0001)
        XCTAssertFalse(reader.showActionFeedback)
        XCTAssertFalse(reader.closeIgnoresDesktop)
        XCTAssertEqual(reader.excludedBundleIDs, ["com.example.game"])
    }

    func testCorruptBindingDataFallsBackToDefaults() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(Data("not json".utf8), forKey: "bindings")
        let prefs = UserPreferences(defaults: defaults)
        XCTAssertEqual(prefs.bindings.count, ActionBinding.defaults.count)
    }

    /// The whole point of replacing @AppStorage: mutations must publish.
    func testMutationPublishesChange() {
        let prefs = UserPreferences(defaults: freshDefaults().0)
        var notifications = 0
        let token = prefs.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        prefs.holdThresholdSec = 0.5
        prefs.bindings = []
        prefs.excludedBundleIDs = ["a"]

        XCTAssertEqual(notifications, 3)
    }

    /// The lookup index is cached; changing bindings must invalidate it.
    func testLookupIndexInvalidatesOnChange() {
        let prefs = UserPreferences(defaults: freshDefaults().0)
        prefs.bindings = [rule(B4, .click, .navigateBack)]
        XCTAssertTrue(prefs.hasBinding(button: B4, modifiers: []))
        XCTAssertFalse(prefs.hasBinding(button: B5, modifiers: []))

        prefs.bindings = [rule(B5, .click, .navigateForward)]
        XCTAssertFalse(prefs.hasBinding(button: B4, modifiers: []))
        XCTAssertTrue(prefs.hasBinding(button: B5, modifiers: []))
    }

    func testChordLookupIsOrderInsensitive() {
        let prefs = UserPreferences(defaults: freshDefaults().0)
        prefs.bindings = [rule(B4, .chord, .launchpad, chordPartner: B5)]

        XCTAssertNotNil(prefs.chordBinding(B4, B5, modifiers: []))
        XCTAssertNotNil(prefs.chordBinding(B5, B4, modifiers: []))
        XCTAssertNil(prefs.chordBinding(B4, B_MIDDLE, modifiers: []))
        XCTAssertNil(prefs.chordBinding(B4, B5, modifiers: [.command]))
    }

    /// The chord partner must also count as "bound", or its press is passed through
    /// and the chord can never complete.
    func testChordPartnerCountsAsBound() {
        let prefs = UserPreferences(defaults: freshDefaults().0)
        prefs.bindings = [rule(B4, .chord, .launchpad, chordPartner: B5)]
        XCTAssertTrue(prefs.hasBinding(button: B5, modifiers: []))
    }

    func testResetRestoresDefaults() {
        let prefs = UserPreferences(defaults: freshDefaults().0)
        prefs.bindings = []
        prefs.holdThresholdSec = 0.9
        prefs.excludedBundleIDs = ["com.example.game"]

        prefs.resetToDefaults()

        XCTAssertEqual(prefs.bindings.count, ActionBinding.defaults.count)
        XCTAssertEqual(prefs.holdThresholdSec, 0.35, accuracy: 0.0001)
        XCTAssertTrue(prefs.excludedBundleIDs.isEmpty)
    }
}

final class ModelTests: XCTestCase {

    func testModifierSetIgnoresIncidentalEventFlags() {
        // Real mouse events always carry maskNonCoalesced and device bits.
        let flags: CGEventFlags = [.maskCommand, .maskNonCoalesced, .maskAlphaShift]
        XCTAssertEqual(ModifierSet(cgFlags: flags), [.command])
    }

    func testModifierSetRoundTripsThroughCGFlags() {
        let original: ModifierSet = [.control, .option, .command, .shift]
        XCTAssertEqual(ModifierSet(cgFlags: original.cgFlags), original)
    }

    func testModifierSymbolsUseCanonicalOrder() {
        XCTAssertEqual(ModifierSet([.command, .control]).symbols, "⌃⌘")
        XCTAssertEqual(ModifierSet([.shift, .option, .command, .control]).symbols, "⌃⌥⇧⌘")
        XCTAssertEqual(ModifierSet().symbols, "—")
    }

    func testKeystrokeDisplay() {
        // Canonical macOS order is ⌃⌥⇧⌘, regardless of how the set was built.
        XCTAssertEqual(Keystroke(keyCode: 0x15, modifiers: [.command, .shift]).display, "⇧⌘4")
        XCTAssertEqual(Keystroke(keyCode: 0x7E).display, "↑")
        XCTAssertEqual(Keystroke(keyCode: 999).display, "Key 999")
    }

    func testActionRunnability() {
        XCTAssertFalse(ActionSpec(kind: .none).isRunnable)
        XCTAssertTrue(ActionSpec(kind: .missionControl).isRunnable)
        XCTAssertFalse(ActionSpec(kind: .customKeystroke).isRunnable)
        XCTAssertTrue(ActionSpec(kind: .customKeystroke, keystroke: Keystroke(keyCode: 0)).isRunnable)
        XCTAssertFalse(ActionSpec(kind: .runShortcut, shortcutName: "").isRunnable)
        XCTAssertTrue(ActionSpec(kind: .runShortcut, shortcutName: "Do Thing").isRunnable)
    }

    func testEveryActionKindHasATitleAndGroup() {
        for kind in ActionKind.allCases where kind != .none {
            XCTAssertFalse(kind.title.isEmpty, "\(kind) has no title")
            XCTAssertTrue(ActionKind.groupOrder.contains(kind.group),
                          "\(kind) is in group '\(kind.group)', which the picker won't show")
        }
    }
}
