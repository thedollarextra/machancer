import XCTest
import CoreGraphics
@testable import MacHancerCore

final class GestureEngineTests: XCTestCase {

    // MARK: - Native button pass-through

    /// A button bound to "stay yourself" must not be suppressed at all — the real event
    /// has to reach the OS for the built-in back/forward behaviour to happen.
    func testNativeButtonIsNeverSuppressed() {
        let prefs = makePrefs([rule(B4, .click, .mouseButton)])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertFalse(engine.handle(down(B4)))
        XCTAssertFalse(engine.handle(up(B4)))
        XCTAssertTrue(rec.requests.isEmpty, "the physical event does the work; nothing to dispatch")
    }

    /// But when something else needs the press held back, the click can no longer pass
    /// through untouched — it has to be claimed and re-posted synthetically.
    func testNativeButtonIsClaimedWhenAHoldSharesTheButton() {
        let prefs = makePrefs([
            rule(B5, .click, .mouseButton),
            rule(B5, .hold, .appExpose),
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertTrue(engine.handle(down(B5)))
        XCTAssertTrue(engine.handle(up(B5)))
        XCTAssertEqual(rec.kinds, [.mouseButton])
    }

    /// Retargeting — button 5 asked to behave as button 4 — is never a pass-through,
    /// because the button number has to actually change on the way out.
    func testRetargetedNativeButtonIsClaimed() {
        var binding = rule(B5, .click, .mouseButton)
        binding.action.mouseButtonNumber = B4
        let prefs = makePrefs([binding])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertTrue(engine.handle(down(B5)))
        XCTAssertTrue(engine.handle(up(B5)))
        XCTAssertEqual(rec.kinds, [.mouseButton])
    }

    /// A modified press must not borrow the plain button's pass-through.
    func testModifiedPressIsUnaffectedByNativePassthrough() {
        let prefs = makePrefs([
            rule(B4, .click, .mouseButton),
            rule(B4, .click, .missionControl, modifiers: [.command]),
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertFalse(engine.handle(down(B4)))
        XCTAssertFalse(engine.handle(up(B4)))

        XCTAssertTrue(engine.handle(down(B4, .zero, [.command])))
        XCTAssertTrue(engine.handle(up(B4)))
        XCTAssertEqual(rec.kinds, [.missionControl])
    }

    /// A chord partner still needs its press claimed, or the chord can never complete.
    func testNativeButtonStillClaimedWhenItIsAChordPartner() {
        let prefs = makePrefs([
            rule(B4, .click, .mouseButton),
            rule(B5, .chord, .closeWindow, chordPartner: B4),
        ])
        let (engine, _) = makeEngine(prefs: prefs)

        XCTAssertTrue(engine.handle(down(B4)))
    }

    // MARK: - Click

    func testClickFiresBoundAction() {
        let prefs = makePrefs([rule(B4, .click, .navigateBack)])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertTrue(engine.handle(down(B4, CGPoint(x: 10, y: 10))))
        XCTAssertTrue(engine.handle(up(B4, CGPoint(x: 10, y: 10))))

        XCTAssertEqual(rec.kinds, [.navigateBack])
    }

    func testUnboundButtonPassesThrough() {
        let prefs = makePrefs([rule(B4, .click, .navigateBack)])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertFalse(engine.handle(down(B5)), "button with no binding must not be swallowed")
        XCTAssertFalse(engine.handle(up(B5)))
        XCTAssertTrue(rec.requests.isEmpty)
    }

    func testDisabledBindingIsInert() {
        var binding = rule(B4, .click, .navigateBack)
        binding.isEnabled = false
        let prefs = makePrefs([binding])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertFalse(engine.handle(down(B4)))
        XCTAssertTrue(rec.requests.isEmpty)
    }

    /// A `.customKeystroke` with nothing recorded is configured but not runnable —
    /// it must not swallow the click either, or the button goes dead for no reason.
    func testUnconfiguredPayloadActionIsInert() {
        let prefs = makePrefs([rule(B4, .click, .customKeystroke)])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertFalse(engine.handle(down(B4)))
        XCTAssertTrue(rec.requests.isEmpty)
    }

    func testLeftAndRightButtonsAreNeverTouched() {
        let prefs = makePrefs([rule(0, .click, .navigateBack), rule(1, .click, .navigateBack)])
        let (engine, rec) = makeEngine(prefs: prefs)

        // Even if a binding somehow exists, buttons 0/1 never reach the tap's mask.
        // What matters is the engine doesn't invent behaviour for them.
        _ = engine.handle(down(0))
        _ = engine.handle(up(0))
        XCTAssertEqual(rec.kinds.count, 1, "only the explicitly configured binding may fire")
    }

    // MARK: - Modifier matching

    func testModifiersMustMatchExactly() {
        let prefs = makePrefs([
            rule(B4, .click, .navigateBack),
            rule(B4, .click, .missionControl, modifiers: [.command]),
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B4, .zero, [.command]))
        _ = engine.handle(up(B4))
        XCTAssertEqual(rec.kinds, [.missionControl], "⌘ variant wins; plain binding must not also fire")

        _ = engine.handle(down(B4, .zero, []))
        _ = engine.handle(up(B4))
        XCTAssertEqual(rec.kinds, [.missionControl, .navigateBack])
    }

    func testUnmatchedModifierCombinationPassesThrough() {
        let prefs = makePrefs([rule(B4, .click, .navigateBack, modifiers: [.command])])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertFalse(engine.handle(down(B4, .zero, [.control])),
                       "⌃+Button4 has no binding, so the app underneath should see it")
        XCTAssertTrue(rec.requests.isEmpty)
    }

    func testMultiModifierCombination() {
        let prefs = makePrefs([
            rule(B_MIDDLE, .click, .closeWindow, modifiers: [.control, .option, .command])
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertTrue(engine.handle(down(B_MIDDLE, .zero, [.control, .option, .command])))
        _ = engine.handle(up(B_MIDDLE))
        XCTAssertEqual(rec.kinds, [.closeWindow])
    }

    func testPartialModifierMatchDoesNotFire() {
        let prefs = makePrefs([
            rule(B_MIDDLE, .click, .closeWindow, modifiers: [.control, .option, .command])
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertFalse(engine.handle(down(B_MIDDLE, .zero, [.control, .command])))
        XCTAssertTrue(rec.requests.isEmpty)
    }

    /// Modifiers are captured at press time — releasing ⌘ mid-drag must not
    /// re-target the gesture to a different binding.
    func testModifiersAreLatchedAtPress() {
        let prefs = makePrefs([
            rule(B5, .dragUp, .missionControl, modifiers: [.command]),
            rule(B5, .dragUp, .appExpose),
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B5, CGPoint(x: 0, y: 500), [.command]))
        _ = engine.handle(dragged(B5, CGPoint(x: 0, y: 400)))   // no modifiers on the drag
        XCTAssertEqual(rec.kinds, [.missionControl])
    }

    // MARK: - Hold

    func testHoldFiresAndSuppressesClick() {
        let prefs = makePrefs([
            rule(B5, .click, .navigateForward),
            rule(B5, .hold, .appExpose),
        ])
        let timing = ManualTiming()
        let (engine, rec) = makeEngine(prefs: prefs, timing: timing)

        _ = engine.handle(down(B5))
        XCTAssertEqual(timing.lastDelay, 0.35)
        timing.fireAll()
        XCTAssertEqual(rec.kinds, [.appExpose])

        _ = engine.handle(up(B5))
        XCTAssertEqual(rec.kinds, [.appExpose], "click must not follow a hold")
    }

    func testHoldUsesLiveThreshold() {
        let prefs = makePrefs([rule(B5, .hold, .appExpose)])
        prefs.holdThresholdSec = 0.2
        let timing = ManualTiming()
        let (engine, _) = makeEngine(prefs: prefs, timing: timing)

        _ = engine.handle(down(B5))
        XCTAssertEqual(timing.lastDelay, 0.2)
    }

    func testNoHoldTimerWhenHoldUnbound() {
        let prefs = makePrefs([rule(B5, .click, .navigateForward)])
        let timing = ManualTiming()
        let (engine, _) = makeEngine(prefs: prefs, timing: timing)

        _ = engine.handle(down(B5))
        XCTAssertFalse(timing.hasPendingWork)
    }

    // MARK: - Drag, all four directions

    func testDragDirections() {
        let prefs = makePrefs([
            rule(B5, .dragUp, .missionControl),
            rule(B5, .dragDown, .appExpose),
            rule(B5, .dragLeft, .spaceLeft),
            rule(B5, .dragRight, .spaceRight),
        ])
        let origin = CGPoint(x: 500, y: 500)

        // Screen coordinates grow downward, so a smaller y is upward movement.
        let cases: [(CGPoint, ActionKind)] = [
            (CGPoint(x: 500, y: 470), .missionControl),
            (CGPoint(x: 500, y: 530), .appExpose),
            (CGPoint(x: 470, y: 500), .spaceLeft),
            (CGPoint(x: 530, y: 500), .spaceRight),
        ]

        for (destination, expected) in cases {
            let (engine, rec) = makeEngine(prefs: prefs)
            _ = engine.handle(down(B5, origin))
            _ = engine.handle(dragged(B5, destination))
            XCTAssertEqual(rec.kinds, [expected], "drag to \(destination)")
        }
    }

    /// A sloppy diagonal should resolve to what the user mostly did, not to whichever
    /// axis happened to cross the threshold first.
    func testDominantAxisWinsForDiagonalDrag() {
        let prefs = makePrefs([
            rule(B5, .dragUp, .missionControl),
            rule(B5, .dragRight, .spaceRight),
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B5, CGPoint(x: 500, y: 500)))
        _ = engine.handle(dragged(B5, CGPoint(x: 520, y: 440)))  // 20 right, 60 up
        XCTAssertEqual(rec.kinds, [.missionControl])
    }

    func testDragBelowThresholdStillCountsAsClick() {
        let prefs = makePrefs([
            rule(B5, .click, .navigateForward),
            rule(B5, .dragUp, .missionControl),
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B5, CGPoint(x: 0, y: 500)))
        _ = engine.handle(dragged(B5, CGPoint(x: 0, y: 486)))  // 14px, threshold 15
        XCTAssertTrue(rec.requests.isEmpty)

        _ = engine.handle(up(B5, CGPoint(x: 0, y: 486)))
        XCTAssertEqual(rec.kinds, [.navigateForward])
    }

    func testDragFiresOnlyOncePerGesture() {
        let prefs = makePrefs([rule(B5, .dragUp, .missionControl)])
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B5, CGPoint(x: 0, y: 500)))
        for y in stride(from: 480, through: 380, by: -10) {
            _ = engine.handle(dragged(B5, CGPoint(x: 0, y: CGFloat(y))))
        }
        _ = engine.handle(up(B5, CGPoint(x: 0, y: 380)))

        XCTAssertEqual(rec.kinds, [.missionControl], "a continuous drag is one gesture")
    }

    func testDragCancelsPendingHold() {
        let prefs = makePrefs([
            rule(B5, .hold, .appExpose),
            rule(B5, .dragUp, .missionControl),
        ])
        let timing = ManualTiming()
        let (engine, rec) = makeEngine(prefs: prefs, timing: timing)

        _ = engine.handle(down(B5, CGPoint(x: 0, y: 500)))
        _ = engine.handle(dragged(B5, CGPoint(x: 0, y: 400)))
        timing.fireAll()   // the hold timer, had it survived

        XCTAssertEqual(rec.kinds, [.missionControl])
    }

    func testUnboundDragDirectionStillEndsTheGesture() {
        let prefs = makePrefs([
            rule(B5, .click, .navigateForward),
            rule(B5, .dragUp, .missionControl),
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B5, CGPoint(x: 500, y: 500)))
        _ = engine.handle(dragged(B5, CGPoint(x: 500, y: 560)))  // down: nothing bound
        _ = engine.handle(up(B5, CGPoint(x: 500, y: 560)))

        XCTAssertTrue(rec.requests.isEmpty, "a drag that went nowhere useful is not a click")
    }

    // MARK: - Double click

    func testDoubleClickFiresWithinInterval() {
        let prefs = makePrefs([
            rule(B4, .click, .navigateBack),
            rule(B4, .doubleClick, .missionControl),
        ])
        let timing = ManualTiming()
        let (engine, rec) = makeEngine(prefs: prefs, timing: timing)

        _ = engine.handle(down(B4)); _ = engine.handle(up(B4))
        XCTAssertTrue(rec.requests.isEmpty, "single click is deferred while a double is possible")

        timing.advance(0.1)
        _ = engine.handle(down(B4)); _ = engine.handle(up(B4))

        XCTAssertEqual(rec.kinds, [.missionControl])
        timing.fireAll()
        XCTAssertEqual(rec.kinds, [.missionControl], "the deferred single click must be cancelled")
    }

    func testSlowSecondClickIsTwoSingleClicks() {
        let prefs = makePrefs([
            rule(B4, .click, .navigateBack),
            rule(B4, .doubleClick, .missionControl),
        ])
        let timing = ManualTiming()
        let (engine, rec) = makeEngine(prefs: prefs, timing: timing)

        _ = engine.handle(down(B4)); _ = engine.handle(up(B4))
        timing.fireAll()                       // deferral expires → single click
        XCTAssertEqual(rec.kinds, [.navigateBack])

        timing.advance(1.0)
        _ = engine.handle(down(B4)); _ = engine.handle(up(B4))
        timing.fireAll()
        XCTAssertEqual(rec.kinds, [.navigateBack, .navigateBack])
    }

    /// Without a double-click binding there's nothing to wait for, so single clicks
    /// must stay instant.
    func testSingleClickIsNotDelayedWithoutDoubleClickBinding() {
        let prefs = makePrefs([rule(B4, .click, .navigateBack)])
        let timing = ManualTiming()
        let (engine, rec) = makeEngine(prefs: prefs, timing: timing)

        _ = engine.handle(down(B4)); _ = engine.handle(up(B4))
        XCTAssertEqual(rec.kinds, [.navigateBack])
        XCTAssertFalse(timing.hasPendingWork)
    }

    func testDoubleClickHonoursConfiguredInterval() {
        let prefs = makePrefs([
            rule(B4, .click, .navigateBack),
            rule(B4, .doubleClick, .missionControl),
        ])
        prefs.doubleClickIntervalSec = 0.2
        let timing = ManualTiming()
        let (engine, rec) = makeEngine(prefs: prefs, timing: timing)

        _ = engine.handle(down(B4)); _ = engine.handle(up(B4))
        timing.advance(0.25)                    // now outside the window
        _ = engine.handle(down(B4)); _ = engine.handle(up(B4))
        timing.fireAll()

        XCTAssertEqual(rec.kinds, [.navigateBack, .navigateBack])
    }

    // MARK: - Chording

    func testChordFiresWhenSecondButtonJoins() {
        let prefs = makePrefs([
            rule(B4, .click, .navigateBack),
            rule(B5, .click, .navigateForward),
            rule(B4, .chord, .launchpad, chordPartner: B5),
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertTrue(engine.handle(down(B4)))
        XCTAssertTrue(engine.handle(down(B5)))
        XCTAssertEqual(rec.kinds, [.launchpad])

        _ = engine.handle(up(B5))
        _ = engine.handle(up(B4))
        XCTAssertEqual(rec.kinds, [.launchpad], "neither button may also fire its own click")
    }

    func testChordIsOrderInsensitive() {
        let prefs = makePrefs([rule(B4, .chord, .launchpad, chordPartner: B5)])
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B5))
        _ = engine.handle(down(B4))
        XCTAssertEqual(rec.kinds, [.launchpad])
    }

    func testChordRequiresBothButtons() {
        let prefs = makePrefs([
            rule(B4, .click, .navigateBack),
            rule(B4, .chord, .launchpad, chordPartner: B5),
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B4))
        _ = engine.handle(up(B4))
        XCTAssertEqual(rec.kinds, [.navigateBack], "a lone press is still an ordinary click")
    }

    // MARK: - Exclusions

    func testExcludedAppPassesEverythingThrough() {
        let prefs = makePrefs([rule(B4, .click, .navigateBack)])
        prefs.excludedBundleIDs = ["com.example.game"]
        let (engine, rec) = makeEngine(prefs: prefs, frontmostBundleID: "com.example.game")

        XCTAssertFalse(engine.handle(down(B4)))
        XCTAssertFalse(engine.handle(up(B4)))
        XCTAssertTrue(rec.requests.isEmpty)
    }

    func testNonExcludedAppStillWorks() {
        let prefs = makePrefs([rule(B4, .click, .navigateBack)])
        prefs.excludedBundleIDs = ["com.example.game"]
        let (engine, rec) = makeEngine(prefs: prefs, frontmostBundleID: "com.example.editor")

        XCTAssertTrue(engine.handle(down(B4)))
        _ = engine.handle(up(B4))
        XCTAssertEqual(rec.kinds, [.navigateBack])
    }

    // MARK: - Dock

    func testPlainMiddleClickRequestsDockCheckWithoutSuppressing() {
        let prefs = makePrefs()
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertFalse(engine.handle(down(B_MIDDLE, CGPoint(x: 300, y: 1000))),
                       "middle clicks must reach the app underneath")
        XCTAssertEqual(rec.dockRequests, 1)
    }

    func testModifiedMiddleClickIsNotADockClick() {
        let prefs = makePrefs()
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B_MIDDLE, .zero, [.command]))
        XCTAssertEqual(rec.dockRequests, 0)
    }

    func testDockRespectsToggle() {
        let prefs = makePrefs()
        prefs.dockNewInstanceEnabled = false
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B_MIDDLE))
        XCTAssertEqual(rec.dockRequests, 0)
    }

    /// A middle click can be both a Dock check and a bound action; the binding wins
    /// on suppression.
    func testMiddleClickCanAlsoRunABinding() {
        let prefs = makePrefs([rule(B_MIDDLE, .click, .missionControl)])
        let (engine, rec) = makeEngine(prefs: prefs)

        XCTAssertTrue(engine.handle(down(B_MIDDLE)))
        _ = engine.handle(up(B_MIDDLE))
        XCTAssertEqual(rec.dockRequests, 1)
        XCTAssertEqual(rec.kinds, [.missionControl])
    }

    // MARK: - Event pairing

    /// A swallowed mouse-down whose mouse-up leaks through leaves the app underneath
    /// believing a button is still held.
    func testClaimedSequenceIsFullySwallowed() {
        let prefs = makePrefs([rule(B5, .click, .navigateForward)])
        let (engine, _) = makeEngine(prefs: prefs)

        XCTAssertTrue(engine.handle(down(B5, CGPoint(x: 10, y: 10))))
        XCTAssertTrue(engine.handle(dragged(B5, CGPoint(x: 12, y: 10))))
        XCTAssertTrue(engine.handle(up(B5, CGPoint(x: 12, y: 10))))
    }

    /// ...but events we never claimed must still pass through.
    func testUnclaimedTailPassesThrough() {
        let prefs = makePrefs([rule(B4, .click, .navigateBack)])
        let (engine, _) = makeEngine(prefs: prefs)

        XCTAssertFalse(engine.handle(up(B5)))
        XCTAssertFalse(engine.handle(dragged(B5, CGPoint(x: 0, y: 50))))
    }

    func testResetClearsPendingGestureState() {
        let prefs = makePrefs([rule(B5, .hold, .appExpose)])
        let timing = ManualTiming()
        let (engine, rec) = makeEngine(prefs: prefs, timing: timing)

        _ = engine.handle(down(B5))
        engine.reset()
        timing.fireAll()

        XCTAssertTrue(rec.requests.isEmpty, "a reset gesture must not fire later")
        XCTAssertFalse(engine.handle(up(B5)), "state is gone, so the stray up passes through")
    }

    /// Changing a binding mid-session must take effect on the very next event.
    func testRebindingAppliesImmediately() {
        let prefs = makePrefs([rule(B4, .click, .navigateBack)])
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B4)); _ = engine.handle(up(B4))
        prefs.bindings = [rule(B4, .click, .missionControl)]
        _ = engine.handle(down(B4)); _ = engine.handle(up(B4))

        XCTAssertEqual(rec.kinds, [.navigateBack, .missionControl])
    }

    func testTwoButtonsCanGestureIndependently() {
        let prefs = makePrefs([
            rule(B4, .click, .navigateBack),
            rule(B5, .dragUp, .missionControl),
        ])
        let (engine, rec) = makeEngine(prefs: prefs)

        _ = engine.handle(down(B5, CGPoint(x: 0, y: 500)))
        _ = engine.handle(down(B4))
        _ = engine.handle(up(B4))
        _ = engine.handle(dragged(B5, CGPoint(x: 0, y: 400)))
        _ = engine.handle(up(B5, CGPoint(x: 0, y: 400)))

        XCTAssertEqual(rec.kinds, [.navigateBack, .missionControl])
    }
}
