import CoreGraphics
import Foundation
@testable import MacHancerCore

/// Deferred work that only runs when a test says so, plus a controllable clock.
final class ManualTiming: HoldTiming {
    private(set) var scheduledDelays: [TimeInterval] = []
    private var pending: [(id: Int, work: () -> Void)] = []
    private(set) var cancelCount = 0
    private var nextID = 0

    /// Test-controlled clock for double-click spacing.
    var currentTime: TimeInterval = 1_000
    var now: TimeInterval { currentTime }

    var hasPendingWork: Bool { !pending.isEmpty }
    var lastDelay: TimeInterval? { scheduledDelays.last }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> HoldToken {
        nextID += 1
        scheduledDelays.append(delay)
        pending.append((nextID, work))
        return Token(owner: self, id: nextID)
    }

    /// Run everything currently pending (simulates all timers elapsing).
    func fireAll() {
        let due = pending
        pending.removeAll()
        for item in due { item.work() }
    }

    /// Advance the clock without running timers.
    func advance(_ seconds: TimeInterval) { currentTime += seconds }

    private struct Token: HoldToken {
        let owner: ManualTiming
        let id: Int
        func cancel() {
            owner.cancelCount += 1
            owner.pending.removeAll { $0.id == id }
        }
    }
}

final class Recorder {
    var requests: [ActionRequest] = []

    /// Just the action kinds that fired, in order — what most assertions care about.
    var kinds: [ActionKind] {
        requests.compactMap {
            if case let .run(binding, _) = $0 { return binding.action.kind }
            return nil
        }
    }

    var dockRequests: Int {
        requests.filter { if case .newDockInstance = $0 { return true } else { return false } }.count
    }
}

/// A `UserPreferences` over a throwaway defaults domain, with no bindings.
func makePrefs(_ bindings: [ActionBinding] = []) -> UserPreferences {
    let name = UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let prefs = UserPreferences(defaults: defaults)
    prefs.bindings = bindings
    return prefs
}

func makeEngine(
    prefs: UserPreferences,
    timing: ManualTiming = ManualTiming(),
    frontmostBundleID: String? = "com.example.test"
) -> (GestureEngine, Recorder) {
    let recorder = Recorder()
    let engine = GestureEngine(
        prefs: prefs,
        timing: timing,
        log: EventLog(),
        frontmostBundleID: { frontmostBundleID }
    )
    engine.onAction = { recorder.requests.append($0) }
    return (engine, recorder)
}

// MARK: - Input builders

func down(_ button: Int, _ point: CGPoint = .zero, _ modifiers: ModifierSet = []) -> MouseInput {
    MouseInput(phase: .down, button: button, location: point, modifiers: modifiers)
}

func dragged(_ button: Int, _ point: CGPoint) -> MouseInput {
    MouseInput(phase: .dragged, button: button, location: point)
}

func up(_ button: Int, _ point: CGPoint = .zero) -> MouseInput {
    MouseInput(phase: .up, button: button, location: point)
}

// MARK: - Binding builders

func rule(
    _ button: Int,
    _ trigger: TriggerKind = .click,
    _ kind: ActionKind,
    modifiers: ModifierSet = [],
    chordPartner: Int? = nil
) -> ActionBinding {
    ActionBinding(
        button: button,
        modifiers: modifiers,
        trigger: trigger,
        chordPartner: chordPartner,
        action: ActionSpec(kind: kind)
    )
}

let B_MIDDLE = MouseButton.middle    // 2
let B4 = MouseButton.button4         // 3
let B5 = MouseButton.button5         // 4
